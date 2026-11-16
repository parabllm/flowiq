/// Reads and writes settings.json. A file this build cannot read is never overwritten: `load` copies it to
/// `settings.unlesbar-<time>.json` and keeps defaults (Panotti B66); `save` re-reads and refuses then.
public actor SettingsStore {
    public struct Loaded: Sendable, Equatable { public let settings: Settings, problem: Problem? }
    public struct SaveRefused: Error, Equatable { public let problem: Problem }
    private enum OnDisk { case missing, readable(Settings), newer(Settings), unreadable(Data?) }
    private let url: URL, defaults: Settings, fs: SafeFS
    public init(paths: Paths, fs: SafeFS) {
        (url, defaults, self.fs) = (paths.settingsFile, .defaults(for: paths.profile), fs)
    }
    public func load(now: Date = .now) -> Loaded {
        switch read() {
        case .missing: Loaded(settings: defaults, problem: nil)
        case .readable(let settings): Loaded(settings: settings, problem: nil)
        case .newer(let settings): Loaded(settings: settings, problem: .settingsNewer(version: settings.version))
        case .unreadable(let data):
            Loaded(settings: defaults, problem: .settingsUnreadable(copy: data.flatMap { setAside($0, now: now) }))
        }
    }
    /// Writes atomically, but only over a missing or readable file.
    public func save(_ settings: Settings) throws {
        switch read() {
        case .missing, .readable: break
        case .newer(let found): throw SaveRefused(problem: .settingsNewer(version: found.version))
        case .unreadable: throw SaveRefused(problem: .settingsUnreadable(copy: nil))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.replace(url, with: encoder.encode(settings))
    }
    private func read() -> OnDisk {
        let data: Data
        do { data = try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch { return .unreadable(nil) }
        do {
            let settings = try Settings.decode(data, over: defaults)
            return settings.version > Settings.currentVersion ? .newer(settings) : .readable(settings)
        } catch { return .unreadable(data) }
    }
    private func setAside(_ data: Data, now: Date) -> URL? {
        let stamp = now.formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted))
        let copy = url.deletingLastPathComponent().appending(path: "settings.unlesbar-\(stamp).json")
        do { try fs.claimNew(copy, with: data) } catch { return nil }
        return copy
    }
}
