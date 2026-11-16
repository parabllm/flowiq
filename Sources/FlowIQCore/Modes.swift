/// The four modes; each chooses its own live recognizer, after-run and language (M.1).
public enum RecordingMode: String, Sendable, Codable, CodingKeyRepresentable, CaseIterable {
    case dictation, call, room, device
}
public enum LiveEngine: String, Sendable, Codable, CaseIterable { case appleLocal, elevenLabsRealtime }
/// `elevenLabs` means the cloud after-run is on; `Settings.postService` says which service runs it.
public enum PostEngine: String, Sendable, Codable, CaseIterable { case off, elevenLabs }
/// Which service runs the cloud after-run (16.11.): auto tries ElevenLabs, then OpenRouter; only with keys.
public enum PostService: String, Sendable, Codable, CaseIterable { case elevenLabs, openRouter, auto }
public enum ModeChoiceError: Error, Sendable, Equatable { case keyMissing, notOffered }

public struct ModeConfig: Sendable, Codable, Equatable {
    public var live: LiveEngine, post: PostEngine, language: RecordingLanguage
    public init(live: LiveEngine, post: PostEngine, language: RecordingLanguage) {
        (self.live, self.post, self.language) = (live, post, language)
    }
    public static func table(post: PostEngine, dictation: PostEngine) -> [RecordingMode: ModeConfig] {
        Dictionary(uniqueKeysWithValues: RecordingMode.allCases.map {
            ($0, ModeConfig(live: .appleLocal, post: $0 == .dictation ? dictation : post, language: .de)) })
    }
}

extension Settings {
    public subscript(mode: RecordingMode) -> ModeConfig {
        get { modes[mode] ?? ModeConfig(live: .appleLocal, post: .off, language: .de) }
        set { modes[mode] = newValue }
    }
}

public enum LiveSourcePress: Sendable, Equatable {
    case switchRunning(to: LiveEngine), armedForNext(LiveEngine), refused(ModeChoiceError)
}

/// "Live-Quelle umschalten" (K-29), no key since 16.11. (only the frozen P5 tests use it): running or next (R-057).
public struct LiveSourceShortcut: Sendable, Equatable {
    private var armed: LiveEngine?
    public init() {}
    public mutating func press(running: LiveEngine?, configured: LiveEngine, hasKey: Bool) -> LiveSourcePress {
        let to: LiveEngine = (running ?? armed ?? configured) == .appleLocal ? .elevenLabsRealtime : .appleLocal
        if to == .elevenLabsRealtime && !hasKey { return .refused(.keyMissing) }
        if running != nil { return .switchRunning(to: to) }
        armed = to
        return .armedForNext(to)
    }
    public mutating func nextRecording(configured: LiveEngine) -> LiveEngine {
        defer { armed = nil }
        return armed ?? configured
    }
}

/// Language of one recording (A.1, R-055 to R-057).
public enum RecordingLanguage: String, Sendable, Codable, CaseIterable { case de = "de-DE", en = "en-US" }

/// Menu preset for the next recording only; a shortcut wins, afterwards German again. Never persisted.
public struct NextRecordingLanguage: Sendable, Equatable {
    public private(set) var preset: RecordingLanguage = .de
    public init() {}
    public mutating func select(_ language: RecordingLanguage) { preset = language }
    /// Language for the recording that starts now; resets the preset.
    public mutating func consume(shortcut: RecordingLanguage?) -> RecordingLanguage {
        defer { preset = .de }
        return shortcut ?? preset
    }
}
