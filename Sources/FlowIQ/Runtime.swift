/// Build stamp from Info.plist (written by scripts/bundle.sh); "lokal" without a bundle.
nonisolated struct BuildInfo: Sendable {
    let build: String, commit: String
    init(_ bundle: Bundle) {
        build = bundle.object(forInfoDictionaryKey: "FlowIQBuild") as? String ?? "lokal"
        commit = bundle.object(forInfoDictionaryKey: "FlowIQCommit") as? String ?? "lokal"
    }
    var line: String { "Bau \(build) · \(commit)" }
}

/// Everything the app does besides drawing. All entry points leave the main thread.
nonisolated struct Runtime: Sendable {
    static let fallback = Logger(subsystem: "de.flowiq", category: "app")
    let profile: Profile, log: EventLog, store: SettingsStore
    let monitor = ResourceMonitor()  // periodic RAM and CPU line (16.11.), started once the recorder exists
    var crashed = false, marker: URL?  // the previous run ended without app.stop; this run's marker (16.11.)
    @concurrent
    static func start(profile: Profile, info: BuildInfo) async throws -> (Runtime, SettingsStore.Loaded) {
        let paths = Paths(profile: profile), fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        var runtime = Runtime(profile: profile, log: EventLog(directory: paths.log, fs: fs),
                              store: SettingsStore(paths: paths, fs: fs))
        let loaded = await runtime.store.load()
        runtime.log.record(LogEvent("app.start", [
            "profile": .string(profile.rawValue), "build": .string(info.build), "commit": .string(info.commit),
            "pid": .int(Int64(ProcessInfo.processInfo.processIdentifier)),
            "fonts_bundled": .bool(FlowIQTheme.Font.isBundled),
        ]))
        (runtime.crashed, runtime.marker) = (runtime.previousRun(paths, fs: fs), paths.support.appending(path: "lauf"))
        if let problem = loaded.problem {
            runtime.log.record(LogEvent("settings.problem", level: .error, ["text": .string(describe(problem))]))
        }
        await runtime.applyLoginItem(LaunchAtLogin.decide(profile, loaded))
        await runtime.sample("start")
        return (runtime, loaded)
    }
    /// With a settings problem nothing is registered or unregistered; the skip is logged as an error.
    @concurrent
    func applyLoginItem(_ decision: LaunchAtLogin.Decision) async {
        guard case .apply(let enabled) = decision else {
            if case .leaveUnchanged(let problem) = decision {
                log.record(LogEvent("login_item", level: .error,
                                    ["outcome": "left_unchanged", "reason": .string(Self.describe(problem))]))
            }
            return
        }
        let result = await LoginItem.apply(enabled: enabled)
        var fields: [String: LogValue] = ["enabled": .bool(enabled), "outcome": .string(result.outcome.rawValue)]
        if let error = result.error { fields["error"] = .string(error) }
        log.record(LogEvent("login_item", level: result.outcome == .failed ? .error : .info, fields))
    }
    @concurrent
    func sample(_ reason: String) async {
        do {
            var fields = try await ResourceProbe.sample().fields
            fields["reason"] = .string(reason)
            log.record(LogEvent("resources", fields))
        } catch {
            let fields: [String: LogValue] = ["call": .string(error.call), "code": .int(Int64(error.code))]
            log.record(LogEvent("resources", level: .error, fields))
        }
    }
    @concurrent
    func stop() async {
        monitor.stop()
        await sample("stop")
        if let marker, case let fs = SafeFS(confinedTo: marker.deletingLastPathComponent()) {
            log.attempt("run_marker_failed") { try fs.delete(marker) }
        }
        log.record(LogEvent("app.stop"))
        await log.flush()
    }
    /// The marker `lauf` stands from the start to `stop` (16.11.): found at a start, the previous run ended without
    /// app.stop. Logged with the newest crash report of this app since that start, its path only; nothing is sent.
    func previousRun(_ paths: Paths, fs: SafeFS, app: String = ProcessInfo.processInfo.processName,
                     reports: URL = URL.libraryDirectory.appending(path: "Logs/DiagnosticReports")) -> Bool {
        let marker = paths.support.appending(path: "lauf"), since = Self.modified(marker)
        defer { log.attempt("run_marker_failed") { try fs.replace(marker, with: Data()) } }
        guard let since else { return false }
        var found: [URL] = []
        do { found = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil) } catch {
            log.record(.failure("crash_reports_unreadable", error))
        }
        let newest = found.filter { $0.lastPathComponent.hasPrefix(app + "-") && $0.pathExtension == "ips" }
            .compactMap { url in Self.modified(url).map { (url, $0) } }.filter { $0.1 >= since }.max { $0.1 < $1.1 }
        var fields: [String: LogValue] = ["since": .string(since.ISO8601Format())]
        if let newest { fields["report"] = .string(newest.0.path) }
        log.record(LogEvent("previous_run_crashed", level: .error, fields))
        return true
    }
    static func modified(_ url: URL) -> Date? {
        do { return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } catch {
            return nil
        }
    }
    /// Menu and log text for a problem (German, it is shown to the user).
    static func describe(_ problem: Problem) -> String {
        switch problem {
        case .settingsUnreadable(let copy?): "Einstellungen unlesbar, Kopie \(copy.lastPathComponent)"
        case .settingsUnreadable(nil): "Einstellungen unlesbar, Änderungen werden nicht gespeichert"
        case .settingsNewer(let version): "Einstellungen aus neuerer Fassung (\(version)), nur lesend"
        }
    }
}

/// Launch at login via `SMAppService.mainApp` (K-14); development never registers and unregisters itself.
nonisolated enum LoginItem {
    enum Outcome: String, Sendable { case unchanged, registered, unregistered, requiresApproval, failed }
    @concurrent
    static func apply(enabled: Bool) async -> (outcome: Outcome, error: String?) {
        let service = SMAppService.mainApp
        do {
            switch (enabled, service.status) {
            case (true, .enabled): return (.unchanged, nil)
            case (true, .requiresApproval): return (.requiresApproval, nil)
            case (true, _):
                try service.register()
                return (service.status == .requiresApproval ? .requiresApproval : .registered, nil)
            case (false, .enabled), (false, .requiresApproval):
                try await service.unregister()
                return (.unregistered, nil)
            case (false, _): return (.unchanged, nil)
            }
        } catch { return (.failed, error.localizedDescription) }
    }
}
