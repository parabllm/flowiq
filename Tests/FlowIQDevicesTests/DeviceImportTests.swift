import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQDevices

/// P6 acceptance from ABNAHME.md (R-064, R-068 to R-071, R-074 search is the store's, R-076) and appendix G, written
/// before the code. Artificial folders only (DeviceRig).
@Suite(.serialized) struct DeviceImportTests {
    /// R-068: three new files are copied, the copy hashes like the device, the audio lands in the archive, each
    /// file is transcribed once and filed once, the journal says done.
    @Test func threeNewFilesAreSecuredTranscribedAndFiled() async throws {
        let rig = try DeviceRig()
        var hashes: [String] = []
        for n in 1...3 {
            hashes.append(try DeviceRig.sha(rig.put("probe-\(n).wav", DeviceRig.wav(seconds: 3, seed: UInt8(n)))))
        }
        let importer = try await rig.importer()
        let report = await importer.scan()
        #expect(report.imported == 3)
        let archived = try rig.archived()
        #expect(archived.count == 3)
        let archivedHashes = try archived.map { try DeviceRig.sha(rig.archive.appending(path: $0)) }
        #expect(Set(archivedHashes) == Set(hashes))
        #expect(archived.allSatisfy { $0.hasSuffix(".wav") && $0.contains("-test-probe-") })
        #expect(await rig.transcriber.state.calls.count == 3)
        let filed = await rig.filing.state.filed
        #expect(Set(filed.map(\.sha256)) == Set(hashes))
        #expect(filed.allSatisfy { $0.sha256 == $0.deviceSHA256 && $0.segments.count == 1 && $0.seconds > 2.9 })
        #expect(filed.allSatisfy { FileManager.default.fileExists(atPath: $0.audio.path) })
        #expect(await importer.entries().filter { $0.phase == .done }.count == 3)
    }

    /// R-069: five more mounts import nothing; a fresh importer over the same journal neither.
    @Test func remountingImportsNothingTwice() async throws {
        let rig = try DeviceRig()
        for n in 1...2 { try rig.put("probe-\(n).wav", DeviceRig.wav(seconds: 2, seed: UInt8(n))) }
        let importer = try await rig.importer()
        #expect(await importer.scan().imported == 2)
        for _ in 1...5 { #expect(await importer.scan().imported == 0) }
        let again = try await rig.importer()
        #expect(await again.scan().imported == 0)
        #expect(await rig.transcriber.state.calls.count == 2)
        #expect(try rig.archived().count == 2)
    }

    /// R-069, C-052: the file name is never the identity. The firmware reuses a name for new content.
    @Test func sameNameNewContentIsImportedSameContentNeverAgain() async throws {
        let rig = try DeviceRig()
        let first = try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2, seed: 1))
        let importer = try await rig.importer()
        #expect(await importer.scan().imported == 1)
        try FileManager.default.removeItem(at: first)
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2, seed: 2))
        #expect(await importer.scan().imported == 1)
        try rig.put("probe-9.wav", DeviceRig.wav(seconds: 2, seed: 2))  // same content as before, new name
        #expect(await importer.scan().imported == 0)
        #expect(await rig.filing.state.filed.count == 2)
    }

    /// R-070: a write-protected device is read only: nothing on it changes, nothing is added, and the write
    /// wrapper refuses every device path.
    @Test func writeProtectedDeviceStaysUntouched() async throws {
        let rig = try DeviceRig()
        for n in 1...3 { try rig.put("probe-\(n).wav", DeviceRig.wav(seconds: 2, seed: UInt8(n))) }
        try rig.lockDevice()
        let before = try rig.deviceSnapshot()
        let importer = try await rig.importer(volumes: [rig.volume(readOnly: true)])
        #expect(await importer.scan().imported == 3)
        #expect(try rig.deviceSnapshot() == before)
        #expect(!rig.fs.allows(rig.device.appending(path: "aufnahmen/probe-1.wav")))
        #expect(!rig.fs.allows(rig.device.appending(path: "Time.txt")))
    }

    /// A.11, C-054: a header that promises more than the file holds is repaired in the copy only; the device
    /// hash stays the identity and the copy carries its own hash.
    @Test func brokenHeaderIsRepairedInTheCopyOnly() async throws {
        let rig = try DeviceRig()
        let data = DeviceRig.wav(seconds: 3, seed: 5, claimExtra: 36)
        let url = try rig.put("probe-1.wav", data)
        let importer = try await rig.importer()
        #expect(await importer.scan().imported == 1)
        let recording = try #require(await rig.filing.state.filed.first)
        #expect(recording.deviceSHA256 == DeviceRig.sha(data))
        #expect(try DeviceRig.sha(url) == DeviceRig.sha(data))
        let copy = try Data(contentsOf: recording.audio)
        #expect(copy.count == data.count && recording.sha256 == DeviceRig.sha(copy))
        #expect(recording.sha256 != recording.deviceSHA256)
        let riff = copy[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let size = copy[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        #expect(Int(riff) == copy.count - 8 && Int(size) == copy.count - 44)
        try FileManager.default.removeItem(at: url)
        try rig.put("probe-1.wav", data)
        #expect(await importer.scan().imported == 0)
    }

    /// R-064: the after-run is asked for only with the devices switch on.
    @Test(arguments: [false, true]) func afterRunFollowsTheDevicesSwitch(on: Bool) async throws {
        let rig = try DeviceRig()
        for n in 1...2 { try rig.put("probe-\(n).wav", DeviceRig.wav(seconds: 2, seed: UInt8(n))) }
        let importer = try await rig.importer(post: on)
        #expect(await importer.scan().imported == 2)
        #expect(await rig.filing.state.filed.allSatisfy { $0.post == on })
    }

    /// R-076: switched off nothing is watched and nothing imported.
    @MainActor @Test func switchedOffWatchesAndImportsNothing() async throws {
        let rig = try DeviceRig()
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2))
        let importer = try await rig.importer(enabled: false)
        #expect(await importer.scan().imported == 0)
        let watch = DeviceWatch(importer: importer)
        await watch.refresh()
        #expect(!watch.observing)
        try await importer.setEnabled(true)
        await watch.refresh()
        #expect(watch.observing)
        try await importer.setEnabled(false)
        await watch.refresh()
        #expect(!watch.observing)
        #expect(await rig.transcriber.state.calls.isEmpty)
    }

    /// 16.11.: a new storage place builds new devices; a stopped watch keeps no observer, even when refreshed
    /// again afterwards, and the progress reader of a closed importer ends.
    @MainActor @Test func aStoppedWatchKeepsNoObserverAndAClosedImporterEndsItsReader() async throws {
        let rig = try DeviceRig()
        let importer = try await rig.importer()
        let reader = Task { for await _ in importer.progress {}; return true }
        var observed = 0
        for _ in 0..<200 {
            let watch = DeviceWatch(importer: importer)
            await watch.refresh()
            observed += watch.observing ? 1 : 0
            watch.stop()
            await watch.refresh()
            observed -= watch.observing ? 0 : 1
        }
        #expect(observed == 0)
        importer.close()
        #expect(await reader.value)
    }

    /// Appendix D, A.11, G.2: development never imports from a real device profile, and refuses a volume named
    /// like a real device even when its identifier matches a test profile.
    @Test(arguments: ["DVT1600", "ZEPHYR", "NO NAME"]) func developmentRefusesRealDevices(name: String) async throws {
        let rig = try DeviceRig()
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2))
        let named = try await rig.importer(volumes: [rig.volume(name: name)])
        let refused = await named.scan()
        #expect(refused.imported == 0 && refused.refused == 1)
        for kind in [DeviceKind.dvt1600, .zephyr] {
            let real = try await rig.importer(kind: kind)
            #expect(await real.scan().imported == 0)
        }
        #expect(await rig.transcriber.state.calls.isEmpty)
    }

    /// Production imports a real profile (the same folder stands in for the device) and ignores the test kind.
    @Test func productionImportsRealProfilesOnly() async throws {
        let rig = try DeviceRig(profile: .production)
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2, channels: 2))
        let test = try await rig.importer(kind: .test, profile: .production)
        #expect(await test.scan().imported == 0)
        let pen = try await rig.importer(kind: .dvt1600, profile: .production)
        #expect(await pen.scan().imported == 1)
        #expect(try rig.archived().first?.contains("-dvt1600-probe-1-") == true)
    }

    /// B.4 step 4 and R-069: a failed transcription is retried from the local copy at the next mount, never copied
    /// again.
    @Test func failedTranscriptionResumesWithoutCopyingAgain() async throws {
        let rig = try DeviceRig()
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2))
        let importer = try await rig.importer()
        await rig.transcriber.state.setFail(true)
        let failed = await importer.scan()
        #expect(failed.imported == 0 && failed.failed == 1)
        #expect(await importer.entries().first?.phase == .failed)
        await rig.transcriber.state.setFail(false)
        #expect(await importer.scan().imported == 1)
        #expect(try rig.archived().count == 1)
        #expect(await rig.filing.state.filed.count == 1)
    }

    /// Panotti's rule for ignored files and a journal that cannot be read: nothing is imported rather than twice.
    @Test func unreadableJournalStopsTheImport() async throws {
        let rig = try DeviceRig()
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2))
        try FileManager.default.createDirectory(at: rig.folders.data, withIntermediateDirectories: true)
        try Data("{kaputt\n{\"auch\": kaputt}\n".utf8).write(to: rig.folders.data.appending(path: "journal.jsonl"))
        let importer = try await rig.importer()
        let report = await importer.scan()
        #expect(report.imported == 0 && report.blocked)
        #expect(await importer.current == .failed(.journalUnreadable))
    }

    /// R-072: the ring shows a share while copying, pulses while transcribing and is gone after the import.
    @Test func progressGoesThroughItsThreeStates() async throws {
        let rig = try DeviceRig()
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 30))
        let importer = try await rig.importer()
        let collector = Task { () -> [ImportProgress] in
            var seen: [ImportProgress] = []
            for await state in importer.progress {
                seen.append(state)
                if state == .hidden, seen.count > 1 { break }
            }
            return seen
        }
        #expect(await importer.scan().imported == 1)
        let seen = await collector.value
        let shares = seen.compactMap { if case .copying(let share) = $0 { share } else { nil } }
        #expect(!shares.isEmpty && shares.allSatisfy { $0 > 0 && $0 <= 1 } && shares == shares.sorted())
        #expect(seen.contains(.transcribing))
        #expect(seen.last == .hidden)
        #expect(await importer.current == .hidden)
    }

    /// B.5: during a dictation the copy waits between blocks; it finishes once the dictation is over.
    @Test func importWaitsWhileADictationRuns() async throws {
        let rig = try DeviceRig()
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 4))
        let busy = BusyState(paths: rig.paths, fs: rig.fs)
        try await busy.begin(.dictation)
        let importer = try await rig.importer(gate: ThrottleGate(busy, pause: .milliseconds(5)), busy: busy)
        let run = Task { await importer.scan() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await rig.transcriber.state.calls.isEmpty)
        #expect(await busy.reasons.contains(.import))
        try await busy.end(.dictation)
        #expect(await run.value.imported == 1)
        #expect(await !busy.reasons.contains(.import))
    }

    /// The Geräte list per file (R-072, Szenarien): waiting before the scan, failed with a retry after an unreadable
    /// file and after a failed recognition, filed once the retry worked.
    @Test func everyFileHasARowWithItsStateAndRetry() async throws {
        let rig = try DeviceRig()
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 2, seed: 1))
        try rig.put("probe-2.wav", Data("kein wav".utf8) + Data(repeating: 7, count: 4_000))
        let importer = try await rig.importer()
        await rig.transcriber.state.setFail(true)
        _ = await importer.scan()
        let failed = await importer.fileRows()
        #expect(failed.map(\.state) == ["fehlgeschlagen", "fehlgeschlagen"] && failed.allSatisfy(\.retry))
        await rig.transcriber.state.setFail(false)
        _ = await importer.scan()
        let rows = await importer.fileRows()
        #expect(rows.map(\.name) == ["probe-1.wav", "probe-2.wav"])
        #expect(rows.map(\.state) == ["abgelegt", "fehlgeschlagen"] && rows.map(\.retry) == [false, true])
    }
}
