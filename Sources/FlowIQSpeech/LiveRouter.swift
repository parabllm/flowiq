import Speech

/// Where the router's words go (M.3): accepted ones into the live file, the shadow's into the session journal.
public protocol RouterSink: Sendable {
    func accepted(_ segment: LiveSegment, from engine: LiveEngine) async
    func shadowed(_ segment: LiveSegment, from engine: LiveEngine) async
    func switched(at seconds: Double, to engine: LiveEngine, reason: SwitchReason) async
    func partial(_ text: String, from engine: LiveEngine) async
    func failed(at seconds: Double, _ trouble: LiveTrouble) async
}

extension RouterSink {
    public func partial(_ text: String, from engine: LiveEngine) async {}
    public func failed(at seconds: Double, _ trouble: LiveTrouble) async {}
}

/// Why local live recognition is out (review M4): the recording goes on, the file run writes the text after the stop.
public enum LiveTrouble: Error, Sendable, Equatable {
    case modelMissing(RecordingLanguage), recognizerFailed
    /// The visible line in the live file.
    public var text: String {
        if case .modelMissing(let l) = self {
            return "Live-Erkennung aus: Sprachmodell \(l == .en ? "Englisch" : "Deutsch") fehlt, Text nach dem Stopp"
        }
        return "Live-Erkennung ausgefallen, der Ton läuft weiter, Text nach dem Stopp"
    }
}

/// Stands in for Apple when the language's model is missing: its start throws, nothing falls back to German.
public struct UnavailableRecognizer: LiveRecognizer {
    public let trouble: LiveTrouble
    public let engine = LiveEngine.appleLocal, events = AsyncStream<LiveEvent> { $0.finish() }
    public init(_ trouble: LiveTrouble) { self.trouble = trouble }
    public func start(_ setup: LiveSetup) async throws { throw trouble }
    public func feed(_ chunk: AudioChunk) {}
    public func finish() async {}
}

/// Speech models on this Mac (review M4): checked before a recording, installed only on a click.
public enum SpeechModels {
    static func module(_ language: RecordingLanguage) -> SpeechTranscriber {
        FileTranscriber.module(Locale(identifier: language.rawValue))
    }
    public static func installed(_ language: RecordingLanguage) async -> Bool {
        await AssetInventory.status(forModules: [module(language)]) == .installed
    }
    public static func install(_ language: RecordingLanguage) async throws {
        try await AssetInventory.assetInstallationRequest(supporting: [module(language)])?.downloadAndInstall()
    }
}

/// Pure merge of both recognizers (M.3): the shadow waits; at the mark B only words centred at B or later pass.
public actor LiveRouter {
    public private(set) var active: LiveEngine, handoverMark: Double? = nil
    private(set) var lastEnd = -Double.infinity, tail = ""
    private var held: [LiveEngine: [LiveSegment]] = [:]
    private let sink: any RouterSink
    public init(start: LiveEngine, sink: any RouterSink) { (active, self.sink) = (start, sink) }
    public func feed(_ event: LiveEvent, from engine: LiveEngine) async {
        if case .partial(let text) = event, engine == active { await sink.partial(text, from: engine) }
        guard case .committed(let segment) = event else { return }
        guard engine == active else {
            held[engine, default: []].append(segment)
            return await sink.shadowed(segment, from: engine)
        }
        await accept(segment, from: engine)
    }
    public func switchTo(_ engine: LiveEngine, at seconds: Double, reason: SwitchReason) async {
        guard engine != active else { return }
        (active, handoverMark) = (engine, lastEnd.isFinite ? lastEnd : nil)
        await sink.switched(at: seconds, to: engine, reason: reason)
        for segment in held.removeValue(forKey: engine) ?? [] { await accept(segment, from: engine) }
    }
    /// Nothing waits for the file: shadow words never reach it, active ones went at once.
    public func finish() async { held = [:] }
    private func accept(_ segment: LiveSegment, from engine: LiveEngine) async {
        let words = segment.words.filter { ($0.start + $0.end) / 2 >= lastEnd }  // midpoint (review 15.11.)
        guard let last = words.last else { return }
        let taken = LiveSegment(words: words, speaker: segment.speaker)
        (lastEnd, tail) = (last.end, String((tail + " " + taken.text).suffix(50)).trimmingCharacters(in: .whitespaces))
        for key in held.keys { held[key]?.removeAll { ($0.words.last?.end ?? 0) <= lastEnd } }
        await sink.accepted(taken, from: engine)
    }
}
