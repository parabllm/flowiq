// verbrauch.json that cannot be read is never overwritten (Leitsatz 5, like settings.json): it is set aside and
// counting starts in a fresh file; if setting it aside fails, nothing is written at all.
import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQCloud

struct UsageFileTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "flowiq-usage-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var file: URL { folder.appending(path: "verbrauch.json") }
    var aside: URL { folder.appending(path: "verbrauch.unlesbar-1800000000.json") }

    func remove() {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do { try FileManager.default.removeItem(at: folder) } catch { Issue.record("cleanup failed: \(error)") }
    }

    func prepare(_ bytes: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: file)
    }

    @Test func anUnreadableFileIsSetAsideAndCountingGoesOnInAFreshFile() async throws {
        defer { remove() }
        try prepare("{kaputt")
        let fs = SafeFS(confinedTo: folder)
        let meter = UsageMeter(folder: folder, fs: fs, now: { now }, log: EventLog(directory: folder, fs: fs))
        await meter.record(.room, .live, seconds: 30)
        await meter.flush()
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{kaputt", "the unreadable bytes must survive")
        #expect(abs(await UsageMeter(folder: folder, fs: fs, now: { now }).seconds(.room, .live) - 30) < 0.01)
    }

    /// 16.11.: the app never made the folder, so every save failed with `usage_unsaved`.
    @Test func theFirstSaveMakesTheMissingFolder() async throws {
        defer { remove() }
        let fs = SafeFS(confinedTo: folder.deletingLastPathComponent())
        let meter = UsageMeter(folder: folder, fs: fs, now: { now })
        await meter.record(.dictation, .post, seconds: 12)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(abs(await UsageMeter(folder: folder, fs: fs, now: { now }).seconds(.dictation, .post) - 12) < 0.01)
    }

    @Test func whenSettingAsideFailsTheFileIsNeverOverwritten() async throws {
        defer { remove() }
        try prepare("{kaputt")
        try Data("besetzt".utf8).write(to: aside)  // the aside name is taken, so the move fails
        let meter = UsageMeter(folder: folder, fs: SafeFS(confinedTo: folder), now: { now })
        await meter.record(.room, .live, seconds: 30)
        await meter.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == "{kaputt")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "besetzt")
    }
}
