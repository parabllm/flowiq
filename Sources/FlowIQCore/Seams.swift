/// One block of mono audio as a value (Leitsatz 3); `hostTime` is the start in host-clock nanoseconds.
public struct AudioChunk: Sendable, Equatable {
    public let hostTime: UInt64, sampleRate: Double, samples: [Float]
    public init(hostTime: UInt64, sampleRate: Double, samples: [Float]) {
        (self.hostTime, self.sampleRate, self.samples) = (hostTime, sampleRate, samples)
    }
    public var seconds: Double { Double(samples.count) / sampleRate }
    public var endTime: UInt64 { hostTime + UInt64((seconds * 1e9).rounded()) }
    /// Rate of every capture channel; sources convert to it, files keep it (A.4).
    public static let channelRate = 48_000.0
}

/// The two capture channels; as `TrackName` also the file name of a recording track.
public enum TrackKind: String, Sendable, CaseIterable {
    case microphone = "mikrofon", desktop
    public var logName: String { self == .microphone ? "microphone" : "desktop" }  // English in the log, rule 7
}

/// The seam of live recognition (M.2) for Apple and ElevenLabs; times are seconds from the recording start.
public struct TimedWord: Sendable, Codable, Equatable {
    public let text: String, start: Double, end: Double, confidence: Double?
    public init(text: String, start: Double, end: Double, confidence: Double?) {
        (self.text, self.start, self.end, self.confidence) = (text, start, end, confidence)
    }
}

public struct LiveSegment: Sendable, Codable, Equatable {
    public let words: [TimedWord], speaker: String?
    public init(words: [TimedWord], speaker: String?) { (self.words, self.speaker) = (words, speaker) }
    /// Words joined by spaces; punctuation (a run of its own at Apple) sticks to the word before.
    public var text: String {
        words.map(\.text).reduce("") { $0.isEmpty || ".,;:!?".contains($1.prefix(1)) ? $0 + $1 : $0 + " " + $1 }
    }
}

/// Why a live session stopped. Never carries text from the service: an error message may echo the key (R-100).
public enum LiveFailure: Error, Sendable, Equatable {
    case connectionClosed, sessionTimeLimit, rateLimited, resourceExhausted, transcriberError, queueOverflow
    case networkDown, authError, quotaExceeded, unacceptedTerms, keyMissing, limit, notAllowed
    /// A short abort gets a new session at once (M.5 stage 1); everything else hands over to Apple.
    public var isShort: Bool { [.connectionClosed, .sessionTimeLimit, .rateLimited, .resourceExhausted,
                                .transcriberError, .queueOverflow].contains(self) }
    /// Never retried automatically: the key or the account must change first.
    public var isFinal: Bool { [.authError, .unacceptedTerms, .keyMissing, .limit, .notAllowed].contains(self) }
}

public enum LiveEvent: Sendable {
    case partial(String), committed(LiveSegment), failure(LiveFailure), sent(seconds: Double)
}
public enum SwitchReason: String, Sendable, Codable { case manual, networkError, returnToCloud, limit }

/// `anchor`: recording second the audio starts at; `backlog`: audio since then; `previousText`: at most 50 characters.
public struct LiveSetup: Sendable {
    public let language: RecordingLanguage, terms: [String], track: TrackKind, anchor: Double
    public let previousText: String?, backlog: [AudioChunk]
    public init(language: RecordingLanguage, terms: [String], track: TrackKind, anchor: Double, previousText: String?,
                backlog: [AudioChunk]) {
        (self.language, self.terms, self.track, self.anchor) = (language, terms, track, anchor)
        (self.previousText, self.backlog) = (previousText, backlog)
    }
}

public protocol LiveRecognizer: Sendable {
    var engine: LiveEngine { get }
    var events: AsyncStream<LiveEvent> { get }
    func start(_ setup: LiveSetup) async throws
    func feed(_ chunk: AudioChunk)  // never blocks
    func finish() async  // last commit, then closed
}

/// The after-run service (A.10, M.2): `ElevenLabsBatch` and the test attrappes implement it.
public protocol PostProcessor: Sendable {
    var name: String { get }
    func process(_ job: PostJob) async throws -> PostTranscript
}

public struct PostJob: Sendable {
    public let audio: [URL], language: String, terms: [String], mode: RecordingMode
    public var choice: PostService?, model: String?  // one run's own service and model, asked for by a click
    public init(audio: [URL], language: String, terms: [String], mode: RecordingMode) {
        (self.audio, self.language, self.terms, self.mode) = (audio, language, terms, mode)
    }
}

public struct PostSegment: Sendable, Codable {
    public let start: Double, speaker: String, text: String
    public init(start: Double, speaker: String, text: String) {
        (self.start, self.speaker, self.text) = (start, speaker, text)
    }
}

public struct PostTranscript: Sendable {
    public let segments: [PostSegment], speakersDetected: Int, source: String  // `source`: who delivered (auto)
    public init(segments: [PostSegment], speakersDetected: Int, source: String = "") {
        (self.segments, self.speakersDetected, self.source) = (segments, speakersDetected, source)
    }
}

/// Quota, key and policy pause a job until a click or the next day; else 1, 5, 15, 60 min, then hourly.
public enum PostFailure: Error, Sendable, Equatable {
    case networkDown, quotaExhausted, keyMissing, server(status: Int), empty, notAllowed, piecesFailed
    case rejected(String)  // 400 or 422: the request itself is wrong, a retry cannot help; the service's reason
    /// The audio left the Mac before this failure, so it counts as usage (R-101).
    public var sent: Bool {
        switch self { case .server, .rejected, .empty, .piecesFailed: true; default: false }
    }
}

/// Seconds of audio sent to the cloud per source and kind, and the optional monthly limit (M.8, R-101).
public enum UsageSource: String, Sendable, Codable, CaseIterable { case dictation, callMic, callDesktop, room, device }
public enum UsageKind: String, Sendable, Codable, CaseIterable { case live, post, postOpenRouter }
public protocol CloudUsage: Sendable {
    func record(_ source: UsageSource, _ kind: UsageKind, seconds: Double) async
    var limitReached: Bool { get async }
}

/// Cutting a long file into owned stretches, shared by the file run and the OpenRouter after-run.
public enum Sections {
    /// Owned stretches: a cut near every `every` seconds (`cut` moves it into a pause); the stretch after the last
    /// cut runs to the end and is at least half a section long. `cut` must return increasing times.
    public static func plan(_ seconds: Double, every: Double, cut: (Double) throws -> Double) rethrows
        -> [Range<Double>] {
        var bounds = [0.0], mark = every
        while mark + every / 2 < seconds {
            bounds.append(try cut(mark))
            mark += every
        }
        bounds.append(.infinity)
        return zip(bounds, bounds.dropFirst()).map { $0..<$1 }
    }
    /// The stretch a word belongs to: the one that holds its middle (M.3), so overlapping pieces never double one.
    public static func owns(_ owned: Range<Double>, start: Double, end: Double) -> Bool {
        owned.contains((start + end) / 2)
    }
}
