/// File locations of one profile (A.1). Folders are created only by `prepare(using:)` at launch, never on the side.
public struct Paths: Sendable, Equatable {
    public let profile: Profile
    public let support: URL  // `~/Library/Application Support/FlowIQ/` or `.../FlowIQ-Dev/`
    public init(profile: Profile, applicationSupport: URL = .applicationSupportDirectory) {
        self.profile = profile
        support = applicationSupport.appending(path: profile.supportFolderName, directoryHint: .isDirectory)
    }
    public var log: URL { support.appending(path: "protokoll", directoryHint: .isDirectory) }
    /// Growing recordings live here, never below the vault (R-046); one lock per profile (A.5).
    public var laufend: URL { support.appending(path: "laufend", directoryHint: .isDirectory) }
    /// Dictation audio `<year>/<month>/<id>.aac` and the append-only journal `journal-YYYY-MM.jsonl` (A.9).
    public var diktate: URL { support.appending(path: "diktate", directoryHint: .isDirectory) }
    public var settingsFile: URL { support.appending(path: "settings.json", directoryHint: .notDirectory) }
    /// Link to the running live transcript; development never touches the production link (appendix D). In
    /// production this is the predecessor app Panotti's link, used only after its data were taken over (optional).
    public var liveLink: URL {
        URL(filePath: profile == .production ? "/tmp/panotti-live.md" : "/tmp/flowiq-dev-live.md")
    }
    /// Creates the folders this build uses. Called once at launch.
    public func prepare(using fs: SafeFS) throws {
        for folder in [support, log, laufend, diktate] { try fs.makeFolder(folder) }
    }
}
