import CryptoKit
import FlowIQCore
import Foundation
import Testing
@testable import FlowIQDevices

/// R-008 and A.11 (takeover from Panotti by dry run and one click), R-071 (recording time despite a wrong device
/// clock). The Panotti folder is artificial and written in Panotti's own encoding (05a B57).
@Suite(.serialized) struct DeviceTakeoverAndClockTests {
    /// Panotti's fast fingerprint (ExternalRecorder 1180): size, then SHA-256 of the first and the last 64 KB.
    static func panottiFingerprint(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data.prefix(65_536))
        if data.count > 131_072 { hasher.update(data: data.suffix(65_536)) }
        return "\(data.count)-" + hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    static func record(_ data: Data, device: String, name: String, phase: String, deviceSHA: String? = nil)
        -> [String: Any] {
        var r: [String: Any] = [
            "id": UUID().uuidString,
            "contentSHA256": deviceSHA == nil ? DeviceRig.sha(data) : "ab" + DeviceRig.sha(data).dropFirst(2),
            "fastFingerprint": panottiFingerprint(data), "deviceName": device, "sourceFileName": name,
            "sourceRelativePath": name, "fileSizeBytes": data.count, "durationSeconds": 2.0, "activeSpeechSeconds": 1,
            "rmsDB": -30.5, "peakDB": -3, "clippedPercent": 0.0, "recordedAt": 816_166_582, "importedAt": 816_170_000.5,
            "phase": phase, "qualityWarnings": [String](), "localRawWAVPath": "/archiv/x.wav",
            "vaultTranscriptPath": "/vault/x.md", "wordCount": 12, "meanConfidence": 0.8]
        if let deviceSHA { r["deviceSHA256"] = deviceSHA }
        return r
    }

    struct Panotti {
        let folder: URL, settings: URL, files: [(name: String, data: Data)], ignored: (name: String, data: Data)
    }

    static func panottiFolder(_ rig: DeviceRig) throws -> Panotti {
        let folder = rig.root.appending(path: "panotti-kopie", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pen = DeviceRig.wav(seconds: 2, channels: 2, seed: 11), zephyr = DeviceRig.wav(seconds: 3, seed: 12)
        let other = DeviceRig.wav(seconds: 2, seed: 13), old = DeviceRig.wav(seconds: 3, seed: 14)
        let records = [record(pen, device: "Philips VoiceTracer DVT1600", name: "probe-1.wav", phase: "Fehler"),
                       record(pen, device: "Philips VoiceTracer DVT1600", name: "probe-1.wav",
                              phase: "Abgeschlossen & archiviert"),
                       record(zephyr, device: "ZEPHYR-Rekorder", name: "probe-2.wav", phase: "Im Vault abgelegt",
                              deviceSHA: DeviceRig.sha(zephyr)),
                       record(other, device: "Philips VoiceTracer DVT1600", name: "probe-3.wav",
                              phase: "Prüfung nötig")]
        try JSONSerialization.data(withJSONObject: records).write(to: folder.appending(path: "external-imports.json"))
        let ignored: [[String: Any]] = [["device": "ZEPHYR-Rekorder", "name": "probe-4.wav", "size": old.count]]
        try JSONSerialization.data(withJSONObject: ignored)
            .write(to: folder.appending(path: "external-ignored-files.json"))
        let settings = folder.appending(path: "einstellungen.plist")
        try PropertyListSerialization.data(fromPropertyList: ["zephyrClockUTCOffsetMinutes": 60], format: .xml,
                                           options: 0).write(to: settings)
        return Panotti(folder: folder, settings: settings,
                       files: [("probe-1.wav", pen), ("probe-2.wav", zephyr), ("probe-3.wav", other)],
                       ignored: ("probe-4.wav", old))
    }

    /// R-008: the dry run shows the mapping and writes nothing; one click takes every record over 1 to 1; a second
    /// click adds nothing; the old files on the device then cause 0 imports, 0 transcriptions, 0 after-run jobs.
    @Test func takeoverByDryRunThenOneClick() async throws {
        let rig = try DeviceRig(profile: .production)
        let panotti = try Self.panottiFolder(rig)
        for file in panotti.files { try rig.put(file.name, file.data) }
        try rig.put(panotti.ignored.name, panotti.ignored.data)
        let importer = try await rig.importer(kind: .zephyr, profile: .production, post: true)
        let journal = rig.folders.data.appending(path: "journal.jsonl")
        let plan = try await importer.takeoverPlan(from: panotti.folder, settings: panotti.settings)
        #expect(plan.entries.count == 4 && plan.ignored.count == 1 && plan.known == 0 && plan.failedInPanotti == 1)
        #expect(plan.byKind == [.dvt1600: 3, .zephyr: 1])
        #expect(plan.clockOffsetMinutes == 60)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(try await importer.takeover(plan) == 5)
        #expect(await importer.config.clockOffsetMinutes == 60)
        let again = try await importer.takeoverPlan(from: panotti.folder, settings: nil)
        #expect(again.known == 5)
        #expect(try await importer.takeover(again) == 0)
        for _ in 1...5 { #expect(await importer.scan().imported == 0) }
        #expect(await rig.transcriber.state.calls.isEmpty)
        #expect(await rig.filing.state.filed.isEmpty)
        #expect(try rig.archived().isEmpty)
        let entries = await importer.entries()
        #expect(entries.filter { $0.origin == "panotti" }.count == 4)
    }

    /// An unreadable Panotti journal is never half taken over.
    @Test func unreadablePanottiJournalTakesNothingOver() async throws {
        let rig = try DeviceRig()
        let panotti = try Self.panottiFolder(rig)
        try Data("[{\"kaputt\"".utf8).write(to: panotti.folder.appending(path: "external-imports.json"))
        let importer = try await rig.importer()
        await #expect(throws: (any Error).self) { try await importer.takeoverPlan(from: panotti.folder, settings: nil) }
    }

    static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .current

    static func date(_ s: String, zone: TimeZone = berlin) -> Date {
        let f = DateFormatter()
        (f.locale, f.timeZone, f.dateFormat) = (Locale(identifier: "en_US_POSIX"), zone, "yyyy-MM-dd HH:mm:ss")
        return f.date(from: s) ?? .distantPast
    }

    /// R-071 DVT1600, clock never set (C-053: it starts at 2023-01-01): the latest file ended about when the pen was
    /// plugged in, every other start follows from the distances on the device clock. Five samples, ± 2 min.
    @Test(arguments: [(0.0, 120.0), (600, 1800), (3600, 3600), (7200, 45), (86_400, 900)])
    func penWithUnsetClock(before: Double, seconds: Double) {
        let mount = Self.date("2026-11-12 18:00:00"), latestEnd = mount.addingTimeInterval(-60)
        let deviceZero = Self.date("2023-01-01 00:00:00"), deviceLatest = deviceZero.addingTimeInterval(500_000)
        let trueStart = latestEnd.addingTimeInterval(-before - seconds)
        let modified = deviceLatest.addingTimeInterval(-before)
        let start = RecordingTime.start(name: "probe.wav", created: deviceZero, modified: modified, seconds: seconds,
                                        latestModified: deviceLatest, mount: mount, nameClock: false,
                                        offsetMinutes: 480)
        #expect(abs(start.timeIntervalSince(trueStart)) <= 120)
    }

    /// R-071 DVT1600 with a clock set through Time.txt: creation time wins, else modification minus duration.
    @Test(arguments: [("2026-11-10 09:15:00", true), ("2026-11-10 23:59:30", true), ("2026-10-16 07:00:00", false),
                      ("2026-11-01 12:30:00", false), ("2026-11-12 17:01:00", false)])
    func penWithSetClock(start text: String, created: Bool) {
        let trueStart = Self.date(text), seconds = 1234.0
        let start = RecordingTime.start(name: "probe.wav", created: created ? trueStart : nil,
                                        modified: trueStart.addingTimeInterval(seconds), seconds: seconds,
                                        latestModified: trueStart.addingTimeInterval(seconds),
                                        mount: Self.date("2026-11-12 18:00:00"), nameClock: false, offsetMinutes: 480)
        #expect(abs(start.timeIntervalSince(trueStart)) <= 120)
    }

    /// R-071 ZEPHYR: the start is in the file name, read in the device clock's zone (UTC+8 measured 09.11., C-054);
    /// a changed offset is honoured; a name that would end in the future falls back to the mount.
    @Test(arguments: [("2026-11-09 12:02:40", 480), ("2026-11-10 08:00:00", 480), ("2026-11-11 23:30:05", 480),
                      ("2026-11-12 10:10:10", 60), ("2026-10-25 02:30:00", 0)])
    func zephyrClockFromName(start text: String, offset: Int) throws {
        let trueStart = Self.date(text), zone = try #require(TimeZone(secondsFromGMT: offset * 60))
        let f = DateFormatter()
        (f.locale, f.timeZone, f.dateFormat) = (Locale(identifier: "en_US_POSIX"), zone, "yyyy_MM_dd_HH_mm_ss")
        let name = f.string(from: trueStart) + ".wav"
        let start = RecordingTime.start(name: name, created: nil, modified: nil, seconds: 600,
                                        latestModified: trueStart, mount: Self.date("2026-11-13 09:00:00"),
                                        nameClock: true, offsetMinutes: offset)
        #expect(abs(start.timeIntervalSince(trueStart)) <= 120)
    }

    @Test func zephyrNameInTheFutureFallsBackToTheMount() {
        let mount = Self.date("2026-11-13 09:00:00")
        let start = RecordingTime.start(name: "2027_01_01_00_00_00.wav", created: nil, modified: mount,
                                        seconds: 300, latestModified: mount, mount: mount, nameClock: true,
                                        offsetMinutes: 480)
        #expect(abs(start.timeIntervalSince(mount.addingTimeInterval(-300))) <= 120)
    }

    /// R-071 end to end: the corrected time is in the archive name and in what the store gets.
    @Test func correctedTimeReachesNameAndRecording() async throws {
        let rig = try DeviceRig()
        let mount = Self.date("2026-11-12 18:00:00")
        let modified = Self.date("2023-01-03 10:00:00")
        try rig.put("probe-1.wav", DeviceRig.wav(seconds: 60), modified: modified,
                    created: Self.date("2023-01-01 00:00:00"))
        let importer = try await rig.importer(now: mount)
        #expect(await importer.scan().imported == 1)
        let recording = try #require(await rig.filing.state.filed.first)
        #expect(abs(recording.recordedAt.timeIntervalSince(mount.addingTimeInterval(-60))) <= 120)
        let stamp = DateFormatter()
        (stamp.locale, stamp.dateFormat) = (Locale(identifier: "en_US_POSIX"), "yyyy-MM-dd-HHmm")
        #expect(try rig.archived().first?.hasPrefix(stamp.string(from: recording.recordedAt)) == true)
        #expect(recording.label.hasPrefix("test-probe-1-") && recording.label.count == "test-probe-1-".count + 8)
    }
}
