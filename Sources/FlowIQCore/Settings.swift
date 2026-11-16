/// Persistent settings (A.1): a missing key takes the profile default, unknown keys are ignored (`SettingsStore`).
public struct Settings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int, launchAtLogin: Bool
    public var modes: [RecordingMode: ModeConfig]  // live recognizer, after-run and language per mode (M.1)
    public var keepDictationInClipboard = true  // R-117: the last dictation stays on the clipboard for Cmd-V
    public var postService = PostService.auto  // the cloud after-run's service (OpenRouter, 16.11.)
    public var openRouterModel = "elevenlabs/scribe-v2"  // a model id of OpenRouter's transcription endpoint
    public var transcriptFolder: String?, cloudLimitMinutes: Int?  // storage place (nil: neutral default), R-101
    public var historyDays: Int?  // how long the dictation history stays: nil always, else 90 or 30 days
    public var audioFolder: String?, panottiLink = false  // audio archive (nil: below the place); predecessor's link
    public var devCloudAllowed = false  // development only: the cloud may send on this explicit switch (review W3)
    public var menuBarHintShown = false  // the hint about a hidden menu bar icon came once (16.11.)
    public var alternateKeys = false  // keys as Panotti (Fn, ⌘⌥); on: right Option and ⌃⌥⌘ (16.11.)
    /// The key scheme for FlowIQInput, whose `Profile` parameter only picks keys: production keys unless alternate.
    public var keyScheme: Profile { alternateKeys ? .development : .production }
    public init(version: Int = Settings.currentVersion, launchAtLogin: Bool,
                modes: [RecordingMode: ModeConfig] = ModeConfig.table(post: .off, dictation: .off)) {
        (self.version, self.launchAtLogin, self.modes) = (version, launchAtLogin, modes)
    }
    /// Call, room, devices take the predecessor's after-run switch, dictation is on; development sends nothing (D).
    public static func defaults(for profile: Profile, panottiPostEnabled: Bool = true) -> Settings {
        let on = profile == .production
        return Settings(launchAtLogin: profile.launchAtLoginDefault, modes: ModeConfig.table(
            post: on && panottiPostEnabled ? .elevenLabs : .off, dictation: on ? .elevenLabs : .off))
    }
    /// The file laid over the encoded defaults key by key, so every new field only needs its declaration (A4).
    static func decode(_ data: Data, over defaults: Settings) throws -> Settings {
        func lay(_ base: Any, _ over: Any) -> Any {
            guard let b = base as? [String: Any], let o = over as? [String: Any] else { return over }
            return b.merging(o) { lay($0, $1) }
        }
        guard var file = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        if let modes = file["modes"] as? [String: Any] {
            file["modes"] = modes.filter { RecordingMode(rawValue: $0.key) != nil }
        }
        let merged = lay(try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)), file)
        return try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: merged))
    }
}

/// Something the user should see in the menu or the pill (A.1). Grows with later packages.
public enum Problem: Sendable, Equatable {
    case settingsUnreadable(copy: URL?)  // untouched, the copy sits next to it (nil: no copy possible)
    case settingsNewer(version: Int)  // written by a newer build: read, never overwritten
}

/// The login item at launch (K-14): with any settings problem it stays as it is; development never registers.
public enum LaunchAtLogin {
    public enum Decision: Sendable, Equatable { case apply(enabled: Bool), leaveUnchanged(Problem) }
    public static func decide(_ profile: Profile, _ loaded: SettingsStore.Loaded) -> Decision {
        if let problem = loaded.problem { return .leaveUnchanged(problem) }
        return .apply(enabled: profile == .production && loaded.settings.launchAtLogin)
    }
}
