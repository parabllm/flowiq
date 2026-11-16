@_exported import FlowIQAudio
@_exported import FlowIQLog
@_exported import FlowIQText
@_exported import Synchronization
import AVFoundation
import Speech

/// Neutral result of one file (K-01): final segments with alternatives, runs with time and confidence.
public struct FileRecognition: Sendable, Codable {
    public struct Segment: Sendable, Codable {
        public let text: String, start: Double, end: Double, alternatives: [String]
    }
    public typealias Run = TimedWord  // Paket V A5: one word type
    /// One section; `missingFrom` to `end` stayed without text after its second try (`incomplete`, `failed`).
    public struct Section: Sendable, Codable {
        public enum State: String, Sendable, Codable { case complete, retried, incomplete, failed }
        public let start: Double, end: Double, state: State, missingFrom: Double?, reason: String?
    }
    /// `text` marks every stretch without text at its place; `millis` is compute time, `sections` nil before 13.11.
    public let text: String, segments: [Segment], runs: [Run], seconds: Double, millis: Int, sections: [Section]?
    public var unrecognized: [Section] { (sections ?? []).filter { $0.missingFrom != nil } }
}

/// File run (A.6, E-04): sections cut in pauses, fresh analyzer each, a deadline and one retry; reads the file only.
public enum FileTranscriber {
    public static let tailSilence = 0.16
    static let rotation = 600.0, overlap = 10.0, search = 15.0  // seconds; rotation only bounds a hang (13.11.)
    public struct Failure: Error, Sendable { public let reason: String }
    /// Reserves the language for this process (Spike 2); nil when the asset service does not answer within 10 s.
    public static func reserve(_ locale: Locale) async -> Bool? {
        do { return try await within(.seconds(10)) { try await AssetInventory.reserve(locale: locale) } } catch {
            return false
        }
    }
    /// Gives up after `limit` (`timeout`); sections without text go to `log`; all sections failed throws.
    public static func recognize(_ url: URL, locale: Locale, limit: Duration,
                                 log: EventLog? = nil) async throws -> FileRecognition {
        guard let result = try await within(limit, { try await recognize(url, locale: locale) }) else {
            throw Failure(reason: "timeout")
        }
        events(result.unrecognized).forEach { log?.record($0) }
        if let sections = result.sections, sections.allSatisfy({ $0.state == .failed }) {
            throw Failure(reason: sections.first?.reason ?? "failed")
        }
        return result
    }
    /// Review M4: contributions of the file run over closed tracks (url, speaker, seconds); nil when one fails.
    public static func contributions(_ tracks: [(URL, String, Double)], _ language: RecordingLanguage, log: EventLog)
        async -> [(seconds: Int, speaker: String, text: String)]? {
        var said: [(seconds: Int, speaker: String, text: String)] = []
        for (url, who, seconds) in tracks {
            do {
                let file = try await recognize(url, locale: Locale(identifier: language.rawValue),
                                               limit: .seconds(60 + seconds), log: log)
                said += file.segments.map { (Int($0.start), who, $0.text) }
            } catch {
                log.record(LogEvent("file_run_failed", level: .error))
                return nil
            }
        }
        return said
    }
    static func events(_ sections: [FileRecognition.Section]) -> [LogEvent] {
        sections.map { s in
            LogEvent("file_section_unrecognized", level: .error,
                     ["state": .string(s.state.rawValue), "start": .double(s.missingFrom ?? s.start),
                      "end": .double(s.end), "reason": .string(s.reason ?? "")])
        }
    }
    static func recognize(_ url: URL, locale: Locale) async throws -> FileRecognition {
        let started = ContinuousClock.now, file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module(locale)])
        else { throw Failure(reason: "format") }
        let owned = try Sections.plan(seconds, every: rotation) { try quietest(file, around: $0, within: search) }
        let (pieces, sections) = try await transcribe(owned, seconds: seconds,
                                                      limit: { .seconds(20 + ($0.upperBound - $0.lowerBound) / 2) }) {
            AppleSection(module: module(locale), url: url, format: format)
        }
        let segments = pieces.map(\.segment)
        return FileRecognition(text: transcript(segments, sections), segments: segments, runs: pieces.flatMap(\.runs),
                               seconds: seconds, millis: Int((ContinuousClock.now - started) / .milliseconds(1)),
                               sections: sections)
    }
    /// Sections one after another, merged at seams; a cut-short one is retried from its last final word, never dropped.
    static func transcribe(_ owned: [Range<Double>], seconds: Double, limit: (Range<Double>) -> Duration,
                           make: () -> any SectionRecognizer) async throws
        -> (pieces: [Piece], sections: [FileRecognition.Section]) {
        var pieces: [Piece] = [], sections: [FileRecognition.Section] = []
        for own in owned {
            var from = own.lowerBound, failures: [String] = []
            while failures.count < 2 {
                try Task.checkCancellation() // the file's own limit has passed: start no further analyzer
                let window = max(0, from - overlap)..<min(seconds, own.upperBound + overlap)
                let got = await section(window, make(), limit: limit(window))
                let kept = got.pieces.compactMap { $0.keeping(from..<own.upperBound) }
                pieces += kept
                guard let failure = got.failure else { break }
                failures.append(failure)
                from = max(from, kept.map(\.segment.end).max() ?? from)
            }
            let state: FileRecognition.Section.State = failures.isEmpty ? .complete : failures.count == 1 ? .retried
                : failures.last == "timeout" ? .incomplete : .failed
            sections.append(.init(start: own.lowerBound, end: min(own.upperBound, seconds), state: state,
                                  missingFrom: failures.count == 2 ? from : nil, reason: failures.last))
        }
        return (pieces, sections)
    }
    /// Segment texts in order; a stretch without text gets "[Abschnitt 00:40:00 bis 00:50:00 nicht erkannt]".
    static func transcript(_ segments: [FileRecognition.Segment], _ sections: [FileRecognition.Section]) -> String {
        func clock(_ s: Double) -> String {
            String(format: "%02d:%02d:%02d", Int(s) / 3600, Int(s) / 60 % 60, Int(s) % 60)
        }
        var marks = sections.compactMap { s in
            s.missingFrom.map { (at: $0, text: "[Abschnitt \(clock($0)) bis \(clock(s.end)) nicht erkannt]") }
        }
        var words: [String] = []
        for segment in segments where !segment.text.isEmpty {
            while let mark = marks.first, mark.at <= segment.start { words.append(marks.removeFirst().text) }
            words.append(segment.text)
        }
        return (words + marks.map(\.text)).joined(separator: " ")
    }
    /// One fresh recognizer over one window; on the deadline it is stopped (within 5 s), the finals by then count.
    static func section(_ window: Range<Double>, _ recognizer: any SectionRecognizer,
                        limit: Duration) async -> (pieces: [Piece], failure: String?) {
        let sink = Sink()
        do {
            let done: Void? = try await within(limit) { try await recognizer.run(window, into: sink) }
            if done != nil { return (sink.pieces, nil) }
            _ = await within(.seconds(5)) { await recognizer.stop() }
            return (sink.pieces, "timeout")
        } catch {
            let reason = (error as? Failure)?.reason ?? "\((error as NSError).domain) \((error as NSError).code)"
            return (sink.pieces, reason)
        }
    }
    /// The one module setup (A7): alternatives, time and confidence; live adds volatile results.
    static func module(_ locale: Locale, volatile: Bool = false) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: volatile ? [.alternativeTranscriptions, .volatileResults]
                              : [.alternativeTranscriptions],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }
}

/// The seam for tests: `run` feeds the window and finishes, finals go to the sink in file seconds; `stop` ends it.
protocol SectionRecognizer: Sendable {
    func run(_ window: Range<Double>, into sink: Sink) async throws
    func stop() async
}

/// SpeechAnalyzer behind the seam: one module and analyzer per section, the window pulled through `Feed`.
struct AppleSection: SectionRecognizer {
    let module: SpeechTranscriber, analyzer: SpeechAnalyzer, url: URL, format: AVAudioFormat
    init(module: SpeechTranscriber, url: URL, format: AVAudioFormat) {
        (self.module, self.url, self.format) = (module, url, format)
        analyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated,
                                                                                     modelRetention: .processLifetime))
    }
    func run(_ window: Range<Double>, into sink: Sink) async throws {
        let reader = Task { [module] in
            for try await r in module.results where r.isFinal {
                sink.add(Piece(r.text, r.range, r.alternatives, window.lowerBound))
            }
        }
        _ = try await analyzer.analyzeSequence(Feed(url: url, window: window, format: format))
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await reader.value
    }
    func stop() async { await analyzer.cancelAndFinishNow() }
}
