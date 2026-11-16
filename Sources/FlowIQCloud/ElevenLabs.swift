public protocol RealtimeConnection: Sendable {
    var incoming: AsyncThrowingStream<String, any Error> { get }
    func send(_ text: String) async throws
    func close() async
}

public protocol RealtimeTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> any RealtimeConnection
}

/// The real transport: one WebSocket per session. Only `CloudGate` hands it out.
final class WebSocketTransport: RealtimeTransport {
    func connect(_ request: URLRequest) async throws -> any RealtimeConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return WebSocketConnection(task: task, incoming: AsyncThrowingStream {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        })
    }
}

struct WebSocketConnection: RealtimeConnection {
    let task: URLSessionWebSocketTask, incoming: AsyncThrowingStream<String, any Error>
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func close() async { task.cancel(with: .normalClosure, reason: nil) }
}

/// ElevenLabs realtime (M.4, M.5, [D] never run): key as header, PCM16 16 kHz, commit at pauses, reconnect in 1 s.
public actor ElevenLabsLiveRecognizer: LiveRecognizer {
    public nonisolated let engine = LiveEngine.elevenLabsRealtime, events: AsyncStream<LiveEvent>
    nonisolated let out: AsyncStream<LiveEvent>.Continuation, input: AsyncStream<AudioChunk>.Continuation
    let transport: any RealtimeTransport, keys: CloudKeys, clock: any Clock<Duration>, log: EventLog, allowed: Bool
    let permit: (@Sendable () async -> Bool)?
    private let chunks: AsyncStream<AudioChunk>
    private var request: URLRequest?, connection: (any RealtimeConnection)?, desktop = false, pump: Task<Void, Never>?
    private var carry: [Float] = [], pending: [Int16] = [], ring: [Int16] = [], ringStart = 0.0, position = 0.0
    private var anchor = 0.0, sinceCommit = 0.0, quiet = 0.0, spoke = false, previous = "", first = true, generation = 0
    private var done = false
    static let failures = ["auth_error": LiveFailure.authError, "quota_exceeded": .quotaExceeded,
                           "unaccepted_terms": .unacceptedTerms, "rate_limited": .rateLimited,
                           "resource_exhausted": .resourceExhausted, "transcriber_error": .transcriberError,
                           "queue_overflow": .queueOverflow, "session_time_limit_exceeded": .sessionTimeLimit]
    /// A real transport needs an order in development and `permit` (`CloudGate.liveRecognizer`, review 15.11.).
    public init(transport: any RealtimeTransport, keys: CloudKeys, clock: any Clock<Duration> = ContinuousClock(),
                log: EventLog, profile: Profile = .production, order: CloudOrder? = nil,
                permit: (@Sendable () async -> Bool)? = nil) {
        (self.transport, self.keys, self.clock, self.log, self.permit) = (transport, keys, clock, log, permit)
        allowed = profile == .production || order != nil || !(transport is WebSocketTransport)
        (events, out) = AsyncStream.makeStream()
        (chunks, input) = AsyncStream.makeStream()
    }
    public func start(_ setup: LiveSetup) async throws {
        let key = keys.current, address = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
        guard await permit?() ?? !(transport is WebSocketTransport) else { throw LiveFailure.notAllowed }
        guard allowed, let key, var url = URLComponents(string: address) else { throw LiveFailure.keyMissing }
        let fixed = [("model_id", "scribe_v3_live"), ("audio_format", "pcm_16000"), ("commit_strategy", "manual"),
                     ("language_code", setup.language == .de ? "de" : "en"), ("include_timestamps", "true")]
            + (setup.track == .desktop ? [("diarize", "true")] : [])
        url.queryItems = (fixed + setup.terms.map { ("keyterms", $0) }).map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let target = url.url else { throw LiveFailure.keyMissing }
        var request = URLRequest(url: target)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        (self.request, desktop, ringStart, position) = (request, setup.track == .desktop, setup.anchor, setup.anchor)
        previous = setup.previousText ?? ""
        do { try await connect() } catch { throw LiveFailure.networkDown }
        pump = Task { [chunks] in for await chunk in chunks { await self.take(chunk) } }
        setup.backlog.forEach { input.yield($0) }
    }
    public nonisolated func feed(_ chunk: AudioChunk) { input.yield(chunk) }
    /// The remainder goes out as the last packet, with a commit.
    public func finish() async {
        input.finish()
        await pump?.value
        done = true
        if !pending.isEmpty || spoke { await send(pending, final: true) }
        await connection?.close()
        out.finish()
    }
    private func connect() async throws {
        guard let request else { return }
        let connection = try await transport.connect(request)
        generation += 1
        (self.connection, first, anchor) = (connection, true, ringStart)
        Task { [generation] in await self.read(connection, generation) }
    }
    private func read(_ connection: any RealtimeConnection, _ g: Int) async {
        do {
            for try await text in connection.incoming {
                if !handle(text) { return await connection.close() }  // an error message ends the session
            }
        } catch { log.record(LogEvent("cloud_live_dropped")) }  // the reconnect below decides what follows
        guard g == generation, !done else { return }
        self.connection = nil
        for attempt in 0..<5 {  // at once, then once a second
            do {
                if attempt > 0 { try await clock.sleep(for: .seconds(1)) }
                try await connect()
                for at in stride(from: 0, to: ring.count, by: 3200) {
                    _ = await post(Array(ring[at..<min(at + 3200, ring.count)]), commit: false)
                }
                return
            } catch { continue }
        }
        log.record(LogEvent("cloud_live_lost", level: .error))
        out.yield(.failure(.networkDown))
    }
    /// One server message; false after an error message (the session ends, the caller decides what follows).
    private func handle(_ text: String) -> Bool {
        let message: [String: Any]
        do { message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:] } catch {
            return true
        }
        let type = message["message_type"] as? String ?? ""
        if let failure = Self.failures[type] {
            log.record(LogEvent("cloud_live_failure", level: .error, ["failure": .string("\(failure)")]))
            out.yield(.failure(failure))
            return false
        }
        if type == "partial_transcript" { out.yield(.partial(message["text"] as? String ?? "")) }
        guard type == "committed_transcript_with_timestamps" else { return true }
        let raw = (message["words"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String ?? "word") == "word" }
        let words = raw.compactMap { w -> TimedWord? in
            guard let text = w["text"] as? String, let start = w["start"] as? Double,
                  let end = w["end"] as? Double else { return nil }
            return TimedWord(text: text, start: anchor + start, end: anchor + end, confidence: nil)
        }
        let who = raw.first?["speaker_id"] as? String
        guard !words.isEmpty else { return true }
        let segment = LiveSegment(words: words, speaker: desktop ? "Gegenseite" + (who.map { " (\($0))" } ?? "") : nil)
        previous = String((previous + " " + segment.text).suffix(50)).trimmingCharacters(in: .whitespaces)
        out.yield(.committed(segment))
        return true
    }
    /// 48 kHz float (any rate) to 16 kHz PCM16 by averaging, then packets of 3200 samples.
    private func take(_ chunk: AudioChunk) async {
        carry += chunk.samples
        let ratio = chunk.sampleRate / 16_000, count = Int(Double(carry.count) / ratio)
        for i in 0..<count {
            let part = carry[Int(Double(i) * ratio)..<max(Int(Double(i) * ratio) + 1, Int(Double(i + 1) * ratio))]
            pending.append(Int16(max(-1, min(1, part.reduce(0, +) / Float(part.count))) * 32_767))
        }
        carry.removeFirst(min(carry.count, Int(Double(count) * ratio)))
        while pending.count >= 3200 {
            await send(Array(pending.prefix(3200)), final: false)
            pending.removeFirst(3200)
        }
    }
    private func send(_ samples: [Int16], final: Bool) async {
        let seconds = Double(samples.count) / 16_000, loud = samples.contains { abs(Int32($0)) > 650 }
        (quiet, spoke, position, sinceCommit) = (loud ? 0 : quiet + seconds, spoke || loud, position + seconds,
                                                  sinceCommit + seconds)
        ring += samples  // the audio since the last commit, at most 40 s (M.5)
        if ring.count > 640_000 {
            (ringStart, ring) = (ringStart + Double(ring.count - 640_000) / 16_000, Array(ring.suffix(640_000)))
        }
        let commit = final || spoke && sinceCommit >= 3 && (quiet >= 0.4 || sinceCommit >= 15)
        guard await post(samples, commit: commit), commit else { return }
        (sinceCommit, spoke, ring, ringStart) = (0, false, [], position)
    }
    /// The first packet of a connection carries `previous_text` (at most 50 characters); every packet sent is reported.
    private func post(_ samples: [Int16], commit: Bool) async -> Bool {
        guard let connection else { return false }
        var message: [String: Any] = ["message_type": "input_audio_chunk", "commit": commit, "sample_rate": 16_000,
                                      "audio_base_64": samples.withUnsafeBytes { Data($0) }.base64EncodedString()]
        if first, !previous.isEmpty { message["previous_text"] = String(previous.suffix(50)) }
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            try await connection.send(String(decoding: data, as: UTF8.self))
            first = false
            out.yield(.sent(seconds: Double(samples.count) / 16_000))
            return true
        } catch { return false }
    }
}

/// The after-run over ElevenLabs Scribe (A.10): one upload per track; failures as `OpenRouterBatch.failure`.
public struct ElevenLabsBatch: PostProcessor {
    public let name = "elevenlabs-scribe-v3"
    let keys: CloudKeys, permit: @Sendable (RecordingMode) async -> Bool
    var speakerName = "Ich", badge: CloudBadge? = nil
    /// Only `CloudGate.batchService` builds it, so the policy is asked before every upload (review 15.11.).
    var send = OpenRouterBatch.post  // the wire; tests put an artificial service here
    public func process(_ job: PostJob) async throws -> PostTranscript {
        guard job.choice != nil ? true : await permit(job.mode) else { throw PostFailure.notAllowed }
        guard let key = keys.current, let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text") else {
            throw PostFailure.keyMissing
        }
        let id = UUID().uuidString
        badge?.uploadStarted(id: id, mode: job.mode)
        defer { badge?.uploadFinished(id: id) }
        var words: [(start: Double, speaker: String, text: String)] = []
        for file in job.audio {
            let mic = file.lastPathComponent.contains("mikrofon") || job.mode == .dictation
            for word in try await upload(file, job, key: key, endpoint: endpoint, diarize: !mic)
            where word["type"] as? String == "word" {
                let speaker = word["speaker_id"] as? String ?? "speaker_0"
                words.append((word["start"] as? Double ?? 0, PostTranscript.who(speaker, mic: mic, job, speakerName),
                              word["text"] as? String ?? ""))
            }
        }
        return PostTranscript.grouped(words, source: name)
    }
    /// One multipart upload; the key only as `xi-api-key` header (M.7); the file part names its type (16.11.).
    func upload(_ file: URL, _ job: PostJob, key: String, endpoint: URL,
                diarize: Bool) async throws -> [[String: Any]] {
        let boundary = UUID().uuidString
        let fields = [("model_id", "scribe_v3"), ("language_code", job.language), ("diarize", String(diarize)),
                      ("timestamps_granularity", "word")] + (job.mode == .room ? [("num_speakers", "8")] : [])
            + job.terms.map { ("keyterms", $0) }
        let part = { (head: String) in
            Data("--\(boundary)\r\nContent-Disposition: form-data; name=\(head)\r\n\r\n".utf8)
        }
        var body = fields.reduce(Data()) { $0 + part("\"\($1.0)\"") + Data("\($1.1)\r\n".utf8) }
        body += part("\"file\"; filename=\"audio.\(file.pathExtension)\"\r\nContent-Type: application/octet-stream")
        body += try Data(contentsOf: file) + Data("\r\n--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: endpoint)
        (request.httpMethod, request.timeoutInterval, request.httpBody) = ("POST", 900, body)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await send(request)
        guard status == 200 else { throw OpenRouterBatch.failure(status, data) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["words"] as? [[String: Any]] ?? []
    }
}
