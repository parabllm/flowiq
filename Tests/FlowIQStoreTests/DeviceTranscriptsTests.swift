import FlowIQCore
import Foundation
import Testing
@testable import FlowIQStore

/// P6 filing of device recordings (A.9, A.11, R-064, R-068, R-074 search under `archive/`). Invented text only.
struct DeviceTranscriptsTests {
    typealias Rig = AftercareReviewTests.Rig
    static let segments = [LiveSegment(words: [TimedWord(text: "Probe", start: 1.5, end: 2, confidence: 0.8),
                                               TimedWord(text: "eins", start: 2, end: 2.5, confidence: 0.6)],
                                       speaker: nil)]

    func file(_ rig: Rig, label: String = "dvt1600-probe-1-1c5888b6", post: Bool = false,
              device: String = "dvt1600", deviceSHA: String = "aa") async throws -> URL {
        try await rig.aftercare.fileDevice(
            device: device, label: label, originalName: "PROBE_1.WAV", sha256: "aa", deviceSHA256: deviceSHA,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000), seconds: 75,
            audio: rig.root.appending(path: "a/x.wav"),
            segments: Self.segments, language: .de, post: post)
    }

    @Test func switchOffEndsLocalWithThePensContract() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let url = try await file(rig)
        #expect(url.lastPathComponent.hasSuffix("-raum-dvt1600-probe-1-1c5888b6.md"))
        let doc = VaultDoc(try Data(contentsOf: url))
        #expect(doc.fields["panotti_phase"] == "final-lokal" && doc.fields["nachlauf"] == "aus")
        #expect(doc.fields["pipeline"] == "dvt1600-import+lokal" && doc.fields["sprache"] == "deu")
        #expect(doc.fields["dauer"] == "01:15" && doc.fields["sha256"] == "aa" && doc.fields["sha256_geraet"] == nil)
        #expect(doc.fields["aufnahme"]?.hasSuffix("(PROBE_1.WAV)\"") == true)
        #expect(doc.fields["quelle_stift_original"] == "PROBE_1.WAV" && doc.fields["wort_konfidenz_mittel"] == "0.70")
        #expect(doc.lines == ["**[00:01] Raum:** Probe eins"])
        #expect(await rig.queue.count == 0)
    }

    @Test func anExistingNameAlsoUnderArchiveGetsANewVersion() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let first = try await file(rig)
        let archive = rig.locations.transcripts.appending(path: "archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: first, to: archive.appending(path: first.lastPathComponent))
        let before = try Data(contentsOf: archive.appending(path: first.lastPathComponent))
        let second = try await file(rig, deviceSHA: "bb")
        #expect(second.lastPathComponent.hasSuffix("-erneut-1.md"))
        let doc = VaultDoc(try Data(contentsOf: second))
        #expect(doc.fields["neufassung_von"] == first.lastPathComponent && doc.fields["sha256_geraet"] == "bb")
        #expect(try Data(contentsOf: archive.appending(path: first.lastPathComponent)) == before)
    }

    @Test func switchOnWaitsForTheAfterRun() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let url = try await file(rig, label: "zephyr-1c5888b6", post: true, device: "zephyr")
        #expect(url.lastPathComponent.hasSuffix("-raum-zephyr-1c5888b6.md"))
        let doc = VaultDoc(try Data(contentsOf: url))
        #expect(doc.fields["nachlauf"] == "wartet" && doc.fields["pipeline"] == "zephyr-import+lokal")
        #expect(await rig.queue.jobs.map(\.mode) == [.device])
    }

    /// Main window, "Nachlauf nur diesmal": a file that ended local is upgraded, the local version copied first,
    /// though the room's own switch stays off.
    @Test func aLocalFileCanBeUpgradedOnceWithItsOwnService() async throws {
        let rig = try Rig([nil], post: false)
        defer { rig.remove() }
        let url = try await rig.room()
        #expect(try rig.field(url, "panotti_phase") == "final-lokal")
        try await rig.aftercare.postNow(url, mode: .room, choice: .elevenLabs, model: nil)
        await rig.aftercare.settle()
        #expect(try rig.field(url, "panotti_phase") == "final-elevenlabs")
        let copies = try FileManager.default.contentsOfDirectory(atPath: rig.locations.dataFolder
            .appending(path: "fassungen").path)
        let waiting = await rig.queue.count
        #expect(copies.count == 1 && waiting == 0)
    }
}
