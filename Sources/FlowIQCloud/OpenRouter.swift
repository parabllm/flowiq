extension PostTranscript {
    /// Words in order to contributions by speaker, sorted by start (both after-run services).
    static func grouped(_ words: [(start: Double, speaker: String, text: String)], source: String) -> PostTranscript {
        var segments: [PostSegment] = []
        for w in words {
            if segments.last?.speaker == w.speaker, let last = segments.popLast() {
                segments.append(PostSegment(start: last.start, speaker: w.speaker, text: last.text + " " + w.text))
            } else { segments.append(PostSegment(start: w.start, speaker: w.speaker, text: w.text)) }
        }
        let sorted = segments.sorted { $0.start < $1.start }
        return PostTranscript(segments: sorted, speakersDetected: Set(sorted.map(\.speaker)).count, source: source)
    }
    /// Microphone track under the speaker name, desktop as `Gegenseite (speaker_n)`, room by label.
    static func who(_ label: String, mic: Bool, _ job: PostJob, _ speakerName: String) -> String {
        mic ? speakerName : job.mode == .call ? "Gegenseite (\(label))" : label
    }
}

/// One model of OpenRouter's transcription endpoint as `Resources/Cloud/openrouter-modelle.json` lists it.
public struct OpenRouterModel: Sendable, Codable, Equatable {
    public let id: String, name: String, usdPerHour: Double, words: Bool, speakers: Bool, format: String, hint: String
}

/// The curated list for the settings (a free model id stays possible); without the file only Scribe v2.
public enum OpenRouterModels {
    public static let fallback = [OpenRouterModel(id: "elevenlabs/scribe-v2", name: "ElevenLabs Scribe v2",
                                                  usdPerHour: 0.2196, words: true, speakers: true, format: "m4a",
                                                  hint: "Vorgabe")]
    public static func load(_ url: URL? = Bundle.main.url(forResource: "openrouter-modelle", withExtension: "json"))
        -> [OpenRouterModel] {
        url.flatMap { JSON.read($0, or: fallback) }.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
}

/// The after-run per job as the policy says; auto falls back from ElevenLabs to OpenRouter until the next day.
actor CloudPost: PostProcessor {
    nonisolated let name = "cloud", elevenLabs: ElevenLabsBatch, openRouter: OpenRouterBatch?
    let policy: CloudGate.Policy, log: EventLog?
    private var fallbackUntil: Date?
    init(elevenLabs: ElevenLabsBatch, openRouter: OpenRouterBatch?, policy: @escaping CloudGate.Policy,
         log: EventLog?) {
        (self.elevenLabs, self.openRouter, self.policy, self.log) = (elevenLabs, openRouter, policy, log)
    }
    func process(_ job: PostJob) async throws -> PostTranscript {
        let p = await policy()
        guard job.choice != nil || p.allows(.post, for: job.mode), let service = job.choice ?? p.service  // a click's
        else { throw PostFailure.notAllowed }
        guard service != .elevenLabs, let openRouter else { return try await elevenLabs.process(job) }
        let model = job.model ?? p.settings.openRouterModel
        if service == .openRouter || fallbackUntil.map({ $0 > .now }) ?? false {
            return try await openRouter.run(job, model: model)
        }
        do { return try await elevenLabs.process(job) } catch let failure as PostFailure where Self.fallsBack(failure) {
            log?.record(LogEvent("nachlauf_rueckfall", ["reason": .string("\(failure)")]))
            if failure == .quotaExhausted { fallbackUntil = Calendar.current.startOfDay(for: .now + 86_400) }
            return try await openRouter.run(job, model: model)
        }
    }
    static func fallsBack(_ f: PostFailure) -> Bool {
        if case .server(let status) = f { return status >= 500 || status == 429 }
        return f == .quotaExhausted || f == .keyMissing
    }
}

/// OpenRouter after-run (16.11., recherche-openrouter.md, [D] never run): pieces of 600 s plus 10 s, words
/// kept by middle (`Sections`), speakers matched over the overlap, failed pieces marked; key only as Bearer (M.7).
struct OpenRouterBatch: PostProcessor {
    let name = "openrouter/elevenlabs/scribe-v2"
    static let model = "elevenlabs/scribe-v2", piece = 600.0, overlap = 10.0, tries = 2, limit = Duration.seconds(240)
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")
    typealias Word = (start: Double, end: Double, speaker: String, text: String)
    let keys: CloudKeys, speakerName: String, badge: CloudBadge?, permit: @Sendable (RecordingMode) async -> Bool
    let send: @Sendable (URLRequest) async throws -> (Data, Int)  // the wire; tests put an artificial service here
    let cut: CloudGate.PieceCut  // one window of a track in a format; an empty window measures the length
    let catalog: [OpenRouterModel], costs: UsageMeter?
    func process(_ job: PostJob) async throws -> PostTranscript { try await run(job, model: Self.model) }
    /// `model` is any id of the endpoint; its catalog price counts as cost unless the answer reports one.
    func run(_ job: PostJob, model: String) async throws -> PostTranscript {
        guard job.choice != nil ? true : await permit(job.mode) else { throw PostFailure.notAllowed }
        guard let key = keys.current, let endpoint = Self.endpoint else { throw PostFailure.keyMissing }
        let id = UUID().uuidString
        badge?.uploadStarted(id: id, mode: job.mode)
        defer { badge?.uploadFinished(id: id) }
        var words: [(start: Double, speaker: String, text: String)] = [], pieces = 0, failed: [Range<Double>] = []
        for file in job.audio {
            let mic = file.lastPathComponent.contains("mikrofon") || job.mode == .dictation
            let seconds = try await cut(file, 0..<0, "m4a").seconds
            var previous: [Word] = [], labels = 0
            for own in Sections.plan(seconds, every: Self.piece, cut: { $0 }) {
                let window = max(0, own.lowerBound - Self.overlap)..<min(seconds, own.upperBound + Self.overlap)
                pieces += 1
                guard let got = try await piece(file, window, job, key, endpoint, model: model, diarize: !mic) else {
                    (failed, previous) = (failed + [own.lowerBound..<min(own.upperBound, seconds)], [])
                    continue
                }
                let matched = got.labeled ? Self.match(got.words, to: previous, next: &labels) : got.words
                let track = mic ? speakerName : job.mode == .call ? "Gegenseite" : "Raum"  // a model without speakers
                words += matched.filter { Sections.owns(own, start: $0.start, end: $0.end) }.map {
                    let who = got.labeled ? PostTranscript.who($0.speaker, mic: mic, job, speakerName) : track
                    return ($0.start, who, $0.text)
                }
                previous = matched
            }
        }
        guard failed.count < pieces else { throw PostFailure.piecesFailed }
        let marks = failed.map { r in (start: r.lowerBound, speaker: "FlowIQ",
            text: "[Abschnitt \(Self.clock(r.lowerBound)) bis \(Self.clock(r.upperBound)) nicht erkannt]") }
        return PostTranscript.grouped(words + marks, source: "openrouter/" + model)
    }
    /// One window, two tries; key and quota end the job; no word times: text spans the window; no labels: one voice.
    func piece(_ file: URL, _ window: Range<Double>, _ job: PostJob, _ key: String, _ endpoint: URL, model: String,
               diarize: Bool) async throws -> (words: [Word], labeled: Bool)? {
        let format = catalog.first { $0.id == model }?.format ?? "m4a"  // MAI-Transcribe-2 takes FLAC only
        let audio = try await cut(file, window, format).data
        var body: [String: Any] = ["model": model,
                                   "input_audio": ["data": audio.base64EncodedString(), "format": format],
                                   "language": String(job.language.prefix(2)), "response_format": "verbose_json",
                                   "timestamp_granularities": ["word"],
                                   "provider": ["data_collection": "deny", "allow_fallbacks": false,
                                                "options": ["elevenlabs": ["diarize": diarize]
                                                    .merging(job.mode == .room ? ["num_speakers": 8] : [:]) {
                                                        a, _ in a }]]]
        if !job.terms.isEmpty { body["keyterms"] = job.terms }
        var request = URLRequest(url: endpoint)
        (request.httpMethod, request.timeoutInterval) = ("POST", 240)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var offline = false  // every try without network: the job waits for it, nothing was sent
        for _ in 0..<Self.tries {
            let answer: (Data, Int)?
            do { answer = try await within(Self.limit) { [send, request] in try await send(request) } } catch {
                offline = (error as? PostFailure) == .networkDown
                continue
            }
            offline = false
            guard let (data, status) = answer else { continue }
            if [401, 402, 403].contains(status) { throw status == 401 ? PostFailure.keyMissing : .quotaExhausted }
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let usd = (json["usage"] as? [String: Any])?["cost"] as? Double
                ?? (catalog.first { $0.id == model }?.usdPerHour ?? 0) * (window.upperBound - window.lowerBound) / 3600
            await costs?.recordCost("openrouter", usd: usd)
            let raw = (json["words"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String ?? "word") == "word" }
            let timed = raw.isEmpty ? json["segments"] as? [[String: Any]] ?? [] : raw
            var words: [Word] = timed.compactMap { w in
                guard let text = w["word"] as? String ?? w["text"] as? String, let start = w["start"] as? Double,
                      let end = w["end"] as? Double else { return nil }
                return (window.lowerBound + start, window.lowerBound + end,
                        w["speaker"] as? String ?? w["speaker_id"] as? String ?? "speaker_0", text)
            }
            if words.isEmpty, let text = json["text"] as? String, !text.isEmpty {
                words = [(window.lowerBound, window.upperBound, "speaker_0", text)]
            }
            return (words, timed.contains { $0["speaker"] != nil || $0["speaker_id"] != nil })
        }
        if offline { throw PostFailure.networkDown }
        return nil
    }
    /// A new piece's labels follow the previous piece's for the same words in the overlap, else the next `speaker_n`.
    static func match(_ words: [Word], to previous: [Word], next: inout Int) -> [Word] {
        var votes: [String: [String: Int]] = [:]
        for w in words {
            let mid = (w.start + w.end) / 2
            if let p = previous.first(where: { abs(($0.start + $0.end) / 2 - mid) < 0.3 && $0.text == w.text }) {
                votes[w.speaker, default: [:]][p.speaker, default: 0] += 1
            }
        }
        var map: [String: String] = [:]
        for label in words.map(\.speaker) where map[label] == nil {
            map[label] = votes[label]?.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
            if map[label] == nil { (map[label], next) = ("speaker_\(next)", next + 1) }
        }
        return words.map { ($0.start, $0.end, map[$0.speaker] ?? $0.speaker, $0.text) }
    }
    static func clock(_ s: Double) -> String {
        String(format: "%02d:%02d:%02d", Int(s) / 3600, Int(s) / 60 % 60, Int(s) % 60)
    }
    /// The real wire (only `CloudGate` builds this type).
    static let post: @Sendable (URLRequest) async throws -> (Data, Int) = { request in
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { throw PostFailure.networkDown }
    }
}
