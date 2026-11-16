// Group 2c and 3b, the pen import (A.11, B.4, R-064, R-068 to R-072): unplugged during the copy, a damaged file next to
// good ones, the progress of every file (wartet, kopiert, erkannt, abgelegt, fehlgeschlagen) and the retry that
// follows a failure. The "pen" is a plain temp folder with generated WAV files (DeviceRig), never a mounted volume.
// Rule of the whole group: nothing on the device ever changes, a half file never counts as imported, a failure
// is repeated by the next scan and only for the file that failed.
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQDevices

private actor Counter {
    private(set) var calls = 0
    func next() -> Int {
        calls += 1
        return calls
    }
}

/// The rows of the pen list at one moment, as `Display.rowText` words them.
private actor Rows {
    private(set) var snapshots: [[String]] = []
    func add(_ entries: [ImportEntry], names: [String]) {
        snapshots.append(names.map { Display.rowText(Display.entry(named: $0, in: entries)) })
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct StiftImportTests {
    private let names = ["probe-1.wav", "probe-2.wav", "probe-3.wav"]

    /// The list of the pen as the words of `Display.rowText`, one per file.
    private func rows(_ importer: DeviceImporter) async -> [String] {
        let entries = await importer.entries()
        return names.map { Display.rowText(Display.entry(named: $0, in: entries)) }
    }

    private func rig() throws -> (Scratch, DeviceRig) {
        let scratch = try Scratch()
        return (scratch, try DeviceRig(scratch: scratch))
    }

    // MARK: Stift wird während des Kopierens abgezogen

    /// B.4 step 3: the pen goes away in the middle of the copy (the file ends early): the staging copy is removed,
    /// nothing is in the archive, the journal knows no half file, the failure is reported; at the next plug-in the
    /// file is imported once, with the very bytes of the device, and the device was never touched.
    @Test func aPenUnpluggedDuringTheCopyIsContinuedAtTheNextPlugInWithoutAHalfFile() async throws {
        let (scratch, devices) = try rig()
        defer { scratch.remove() }
        let data = DeviceRig.wav(seconds: 40, seed: 5)  // about 1.2 MB: twenty blocks
        let url = try devices.put("probe-1.wav", data)
        let before = try devices.deviceSnapshot()
        let blocks = Counter()
        let gate = ThrottleGate(pause: .milliseconds(5)) { () -> Set<BusyState.Reason> in
            if await blocks.next() == 5 {  // in front of the third block the pen is gone: the file ends at 100 KB
                do {
                    let handle = try FileHandle(forUpdating: url)
                    try handle.truncate(atOffset: 100_000)
                    try handle.close()
                } catch { Issue.record("could not cut the file: \(error)") }
            }
            return []
        }
        let importer = try await devices.importer(gate: gate)

        let failed = await importer.scan()
        #expect(failed.imported == 0 && failed.failed == 1)
        #expect(devices.archived().isEmpty, "a half copy is in the archive")
        #expect(devices.staging().isEmpty, "the staging copy was not removed")
        #expect(await importer.entries().isEmpty, "a half file counts as imported")
        #expect(await importer.current == .failed(.copy))  // what the pill and the list show for this file
        #expect(await devices.filing.state.filed.isEmpty)
        #expect(await devices.transcriber.state.calls.isEmpty)
        #expect(await scratch.errors("device_import_failed").count == 1)

        try data.write(to: url)  // plugged in again
        #expect(try devices.deviceSnapshot() == before, "the device was changed")
        let resumed = await importer.scan()
        #expect(resumed.imported == 1 && resumed.failed == 0)
        let archived = devices.archived()
        #expect(archived.count == 1)
        #expect(try DeviceRig.sha(devices.archive.appending(path: archived[0])) == DeviceRig.sha(data))
        #expect(await importer.entries().map(\.phase) == [.done])
        #expect(await importer.current == .hidden)
        #expect(await devices.filing.state.filed.count == 1)
        #expect(try devices.deviceSnapshot() == before)
    }

    // MARK: Beschädigte Stiftdatei

    /// A damaged file is reported and left alone; the good ones around it are imported; the next scan tries the
    /// damaged one again (and only it), and a good file under the same name is imported at once.
    @Test func aDamagedPenFileIsReportedAndTheOthersRunOn() async throws {
        let (scratch, devices) = try rig()
        defer { scratch.remove() }
        try devices.put("probe-1.wav", DeviceRig.wav(seconds: 2, seed: 1))
        let damaged = try devices.put("probe-2.wav", Data("kein wav, nur Rauschen".utf8) + Data(repeating: 7, count: 4_000))
        try devices.put("probe-3.wav", DeviceRig.wav(seconds: 2, seed: 3))
        let importer = try await devices.importer()

        let first = await importer.scan()
        #expect(first.imported == 2 && first.failed == 1)
        #expect(await importer.current == .failed(.unreadable))
        #expect(devices.archived().count == 2)
        #expect(await devices.filing.state.filed.count == 2)
        let entries = await importer.entries()
        #expect(entries.count == 2 && entries.allSatisfy { $0.phase == .done })
        let failures = await scratch.errors("device_import_failed")
        #expect(failures.count == 1 && failures.first?.fields["problem"] == "unreadable")

        let again = await importer.scan()
        #expect(again.imported == 0 && again.failed == 1, "only the damaged file is tried again")
        #expect(devices.archived().count == 2)
        #expect(await devices.filing.state.filed.count == 2)

        try FileManager.default.removeItem(at: damaged)  // the pen is repaired
        try devices.put("probe-2.wav", DeviceRig.wav(seconds: 2, seed: 2))
        let repaired = await importer.scan()
        #expect(repaired.imported == 1 && repaired.failed == 0)
        #expect(devices.archived().count == 3)
        #expect(await importer.current == .hidden)
    }

    // MARK: Fortschritt je Datei

    /// R-072 and the list of the pen: every file goes wartet, kopiert, erkannt, abgelegt in this order, the others
    /// keep their state meanwhile; the ring shows a rising share over the whole import, pulses while recognizing
    /// and is gone at the end.
    @Test func everyFileShowsItsStatesInOrderAndTheRingRisesOverTheWholeImport() async throws {
        let (scratch, devices) = try rig()
        defer { scratch.remove() }
        for (index, name) in names.enumerated() { try devices.put(name, DeviceRig.wav(seconds: 3, seed: UInt8(index + 1))) }
        let importer = try await devices.importer()
        let fileNames = names
        let atRecognition = Rows(), atFiling = Rows()
        await devices.transcriber.state.onCall { _ in await atRecognition.add(await importer.entries(), names: fileNames) }
        await devices.filing.state.onFile { await atFiling.add(await importer.entries(), names: fileNames) }
        let collector = Task { () -> [ImportProgress] in
            var seen: [ImportProgress] = []
            for await state in importer.progress {
                seen.append(state)
                if state == .hidden, seen.count > 1 { break }
            }
            return seen
        }

        #expect(await rows(importer) == ["wartet", "wartet", "wartet"])
        #expect(await importer.scan().imported == 3)

        #expect(await atRecognition.snapshots == [["kopiert", "wartet", "wartet"], ["abgelegt", "kopiert", "wartet"],
                                                  ["abgelegt", "abgelegt", "kopiert"]])
        #expect(await atFiling.snapshots == [["erkannt", "wartet", "wartet"], ["abgelegt", "erkannt", "wartet"],
                                             ["abgelegt", "abgelegt", "erkannt"]])
        #expect(await rows(importer) == ["abgelegt", "abgelegt", "abgelegt"])

        let seen = await collector.value
        let shares = seen.compactMap { if case .copying(let share) = $0 { share } else { nil } }
        #expect(!shares.isEmpty && shares.allSatisfy { $0 > 0 && $0 <= 1 } && shares == shares.sorted())
        #expect(seen.contains(.transcribing) && seen.last == .hidden)
        #expect(await importer.current == .hidden)
    }

    // MARK: Fehlgeschlagen mit "Erneut versuchen"

    /// One file fails in the recognition: its row says fehlgeschlagen with the next step "Erneut versuchen", the
    /// others are abgelegt; the retry is the next scan, it copies nothing again, recognizes only the failed file and
    /// files every file exactly once.
    @Test func aFailedFileShowsTheRetryAndTheRetryRunsOnlyThatFile() async throws {
        let (scratch, devices) = try rig()
        defer { scratch.remove() }
        for (index, name) in names.enumerated() { try devices.put(name, DeviceRig.wav(seconds: 2, seed: UInt8(index + 1))) }
        let importer = try await devices.importer()
        await devices.transcriber.state.fail(["probe-2"])

        let first = await importer.scan()
        #expect(first.imported == 2 && first.failed == 1)
        #expect(await rows(importer) == ["abgelegt", "fehlgeschlagen, Erneut versuchen", "abgelegt"])
        #expect(await importer.current == .failed(.transcribe))
        #expect(devices.archived().count == 3, "the copy of the failed file is kept for the retry")
        #expect(await devices.filing.state.filed.count == 2)

        await devices.transcriber.state.fail([])  // the cause is gone (service back, disk free)
        let retry = await importer.scan()  // "Erneut versuchen"
        #expect(retry.imported == 1 && retry.failed == 0)
        #expect(await devices.transcriber.state.calls.count == 4, "three files, one retry: not a second recognition of the good ones")
        #expect(devices.archived().count == 3, "the retry copied again")
        #expect(await devices.filing.state.filed.count == 3)
        #expect(await rows(importer) == ["abgelegt", "abgelegt", "abgelegt"])
        #expect(await importer.current == .hidden)
    }
}
