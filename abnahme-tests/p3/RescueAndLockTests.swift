// Groups 3 and 4: rescue after a hard abort (A.5 `Rescue.run`, R-039) and the lock (`RecordingLock`,
// flock on `laufend/.sperre`, one folder per profile).
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQRecording

struct RescueTests {
    /// Writes a real ADTS file of `seconds` into `laufend/<folder>/<name>` and returns it.
    private func writeTrack(_ s: Scratch, folder: String, name: String, seconds: Double, purpose: TrackPurpose = .call) async throws -> URL {
        try FileManager.default.createDirectory(at: s.laufend.appending(path: folder), withIntermediateDirectories: true)
        let (writer, url) = try await openWriter(s, name: "\(folder)/\(name)", purpose: purpose)
        await append(writer, seconds: seconds)
        _ = await writer.close(reason: .normal, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:)
        return url
    }

    /// Cuts the file in the middle of a frame: what SIGKILL leaves behind.
    private func tear(_ url: URL, removing bytes: Int) throws {
        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - UInt64(bytes))
        try handle.close()
    }

    private func everyFile(under root: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL]) ?? []
    }

    @Test(arguments: [60.0, 600.0])
    func halfWrittenFilesAreRescuedAtStartWithAtMostTwoSecondsLost(seconds: Double) async throws {
        let s = try Scratch()
        defer { s.remove() }
        let folder = "2026-01-01 10-00-00 Call"
        let mic = try await writeTrack(s, folder: folder, name: "mikrofon.aac", seconds: seconds)
        let desktop = try await writeTrack(s, folder: folder, name: "desktop.aac", seconds: seconds)
        try tear(mic, removing: 731)
        try tear(desktop, removing: 1_303)
        try Data().write(to: s.laufend.appending(path: ".sperre"))  // stale lock file of the dead instance, not held by anyone

        let report = try await Rescue.run(laufend: s.laufend, deliverTo: s.delivered, fs: s.fs, log: s.log)  // ASSUMPTION: Rescue.run(laufend:deliverTo:fs:log:) -> RescueReport
        #expect(report.rescuedTracks.count == 2)  // ASSUMPTION: RescueReport.rescuedTracks (the menu line "n Aufnahmen gerettet" counts from it)
        #expect(report.failed.isEmpty)  // ASSUMPTION: RescueReport.failed

        for rescued in report.rescuedTracks {
            let playable = try audioDuration(rescued.url)  // ASSUMPTION: RescuedTrack.url points at the delivered .m4a
            #expect(playable >= seconds - 2)
            #expect(playable <= seconds + 0.5)
        }
        #expect(!(await s.events("rescued")).isEmpty)  // ASSUMPTION: event kind rescued
    }

    @Test func rescueNeverDeletesWhatItCannotVerify() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let folder = s.laufend.appending(path: "2026-01-01 11-00-00 Raum")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let garbage = Data(Signal.noise(amp: 1, count: 2_000).flatMap { value in withUnsafeBytes(of: value) { Array($0) } })
        let broken = folder.appending(path: "mikrofon.aac")
        try garbage.write(to: broken)  // not decodable as ADTS at all

        let report = try await Rescue.run(laufend: s.laufend, deliverTo: s.delivered, fs: s.fs, log: s.log)  // ASSUMPTION: Rescue.run(...)
        #expect(report.rescuedTracks.isEmpty)
        #expect(report.failed.count == 1)

        let survivors = everyFile(under: s.paths.support).filter { fileSize($0) == garbage.count }
        let kept = try survivors.contains { try Data(contentsOf: $0) == garbage }
        #expect(kept)  // the unreadable original still exists, byte for byte, somewhere under the support folder
        #expect(!(await s.events("rescue_failed")).isEmpty)  // ASSUMPTION: event kind rescue_failed, error level
    }

    @Test func rescueKeepsTheSourceUntilTheDurationCheckPasses() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let folder = "2026-01-01 12-00-00 Raum"
        let url = try await writeTrack(s, folder: folder, name: "mikrofon.aac", seconds: 30, purpose: .room)
        try tear(url, removing: 500)
        let expected = try audioDuration(url)

        let report = try await Rescue.run(laufend: s.laufend, deliverTo: s.delivered, fs: s.fs, log: s.log)  // ASSUMPTION: Rescue.run(...)
        let rescued = try #require(report.rescuedTracks.first)
        let m4a = try audioDuration(rescued.url)  // ASSUMPTION: RescuedTrack.url
        let sourceStillThere = FileManager.default.fileExists(atPath: url.path)
        // A.5: the .aac may go only after the duration check (difference at most 0.5 s) passed.
        #expect(sourceStillThere || abs(m4a - expected) <= 0.5)
    }

    @Test func secondRunFindsNothingAndLosesNothing() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let url = try await writeTrack(s, folder: "2026-01-01 13-00-00 Call", name: "mikrofon.aac", seconds: 20)
        try tear(url, removing: 400)
        let first = try await Rescue.run(laufend: s.laufend, deliverTo: s.delivered, fs: s.fs, log: s.log)  // ASSUMPTION: Rescue.run(...)
        let delivered = try #require(first.rescuedTracks.first)
        let sizeBefore = fileSize(delivered.url)  // ASSUMPTION: RescuedTrack.url

        let second = try await Rescue.run(laufend: s.laufend, deliverTo: s.delivered, fs: s.fs, log: s.log)  // ASSUMPTION: Rescue.run(...)
        #expect(second.rescuedTracks.isEmpty)
        #expect(fileSize(delivered.url) == sizeBefore)
    }

    @Test func rescueRefusesToTouchFilesWhileAnotherInstanceHoldsTheLock() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let url = try await writeTrack(s, folder: "2026-01-01 14-00-00 Call", name: "mikrofon.aac", seconds: 20)
        try tear(url, removing: 400)
        let size = fileSize(url)
        let holder = try RecordingLock.acquire(in: s.laufend)  // ASSUMPTION: RecordingLock.acquire(in:)

        await #expect(throws: (any Error).self) {
            _ = try await Rescue.run(laufend: s.laufend, deliverTo: s.delivered, fs: s.fs, log: s.log)  // ASSUMPTION: Rescue.run(...)
        }
        #expect(fileSize(url) == size)  // a live recording is never "rescued" out from under its owner
        holder.release()  // ASSUMPTION: RecordingLock.release()
    }
}

struct RecordingLockTests {
    @Test func secondInstanceDoesNotGetTheProfile() throws {
        let s = try Scratch()
        defer { s.remove() }
        let first = try RecordingLock.acquire(in: s.laufend)  // ASSUMPTION: RecordingLock.acquire(in:)
        #expect(FileManager.default.fileExists(atPath: s.laufend.appending(path: ".sperre").path))

        #expect(throws: (any Error).self) { _ = try RecordingLock.acquire(in: s.laufend) }  // ASSUMPTION: acquire throws while held
        #expect(throws: (any Error).self) { _ = try RecordingLock.acquire(in: s.laufend) }  // still refused, no wear-down

        first.release()  // ASSUMPTION: RecordingLock.release()
        let again = try RecordingLock.acquire(in: s.laufend)  // ASSUMPTION: RecordingLock.acquire(in:)
        again.release()  // ASSUMPTION: RecordingLock.release()
    }

    @Test func lockFallsAwayWithItsHolder() throws {
        let s = try Scratch()
        defer { s.remove() }
        do {
            let holder = try RecordingLock.acquire(in: s.laufend)  // ASSUMPTION: RecordingLock.acquire(in:)
            #expect(throws: (any Error).self) { _ = try RecordingLock.acquire(in: s.laufend) }  // ASSUMPTION: acquire throws while held
            _ = holder
        }
        // A killed holder ends the same way: the kernel drops the flock, the stale file stays.
        let next = try RecordingLock.acquire(in: s.laufend)  // ASSUMPTION: RecordingLock.acquire(in:)
        next.release()  // ASSUMPTION: RecordingLock.release()
    }

    @Test func profilesLockIndependentFolders() throws {
        let s = try Scratch()
        defer { s.remove() }
        let production = Paths(profile: .production, applicationSupport: s.root)
        try FileManager.default.createDirectory(at: production.laufend, withIntermediateDirectories: true)  // ASSUMPTION: Paths.laufend
        let dev = try RecordingLock.acquire(in: s.laufend)  // ASSUMPTION: RecordingLock.acquire(in:)
        let prod = try RecordingLock.acquire(in: production.laufend)  // ASSUMPTION: RecordingLock.acquire(in:)
        #expect(s.laufend != production.laufend)
        dev.release()  // ASSUMPTION: RecordingLock.release()
        prod.release()  // ASSUMPTION: RecordingLock.release()
    }
}
