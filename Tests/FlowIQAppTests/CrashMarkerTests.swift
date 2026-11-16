// 16.11.: after a crash the next start knows it (the marker of the run is still there), logs the newest crash report
// of this app since then (its path only) and says one plain line in the menu what the rescue of `laufend/` found.
import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQ

struct CrashMarkerTests {
    @Test func aMarkerLeftStandingIsACrashWithTheNewestReportOfThisApp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-crash-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
        let paths = Paths(profile: .development, applicationSupport: root.appending(path: "support"))
        let fs = SafeFS(paths: paths), reports = root.appending(path: "berichte", directoryHint: .isDirectory)
        try paths.prepare(using: fs)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var runtime = Runtime(profile: .development, log: EventLog(directory: paths.log, fs: fs),
                              store: SettingsStore(paths: paths, fs: fs))
        #expect(!runtime.previousRun(paths, fs: fs, app: "Probe", reports: reports), "the first start ever")
        for name in ["Probe-2026-11-16-230938.ips", "Andere-2026-11-16-230938.ips", "Probe-notiz.txt"] {
            try Data().write(to: reports.appending(path: name))
        }
        #expect(runtime.previousRun(paths, fs: fs, app: "Probe", reports: reports), "no app.stop since the last start")
        runtime.marker = paths.support.appending(path: "lauf")
        await runtime.stop()
        #expect(!runtime.previousRun(paths, fs: fs, app: "Probe", reports: reports), "a clean stop is no crash")
        await runtime.log.flush()
        let text = try String(contentsOf: paths.log.appending(path: "fehler.ndjson"), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.contains("previous_run_crashed") }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("Probe-2026-11-16-230938.ips") == true)
        #expect(lines.first?.contains("Andere") == false)
    }

    @Test func theMenuLineSaysWhatTheRescueFound() {
        #expect(AppModel.crashNote("FlowIQ", (0, 0)) == "FlowIQ war unerwartet beendet, nichts verloren")
        #expect(AppModel.crashNote("FlowIQ", (2, 0)).hasSuffix("beendet, unterbrochene Aufnahme gerettet"))
        #expect(AppModel.crashNote("FlowIQ", (2, 1)).hasSuffix("eine Aufnahme ließ sich nicht ganz retten"))
    }
}
