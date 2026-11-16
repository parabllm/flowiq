import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQDevices

/// Plugging in (16.11.): what happens with the switch off, on with an unknown and on with a known device, on a fresh
/// install and after Panotti's journal was taken over. The "volumes" are temporary folders that only carry the
/// recorders' names and layout; nothing here touches a mounted volume.
@Suite(.serialized) struct DevicePlugInTests {
    /// What is plugged in right now.
    final class Plugged: Sendable {
        let volumes: Mutex<[MountedVolume]>
        init(_ volumes: [MountedVolume]) { self.volumes = Mutex(volumes) }
        func set(_ now: [MountedVolume]) { volumes.withLock { $0 = now } }
    }
    /// A fresh install: no `geraete.json`, no profile; `plugged` can change between scans.
    static func fresh(_ rig: DeviceRig, profile: Profile = .production, on: Bool,
                      plugged: Plugged) async throws -> DeviceImporter {
        let importer = DeviceImporter(profile: profile, folders: rig.folders, fs: rig.fs, log: rig.log,
                                      transcriber: rig.transcriber, filing: rig.filing, post: { false },
                                      volumes: { plugged.volumes.withLock { $0 } }, now: { Date() }, settle: .zero)
        if on { try await importer.setEnabled(true) }
        return importer
    }
    static func pen(_ rig: DeviceRig) throws -> Data {
        let new = DeviceRig.wav(seconds: 3, channels: 2, seed: 21)
        try rig.put("REC_001.wav", new, folder: "RECORD/A")
        try rig.put("alt.wav", DeviceRig.wav(seconds: 3, channels: 2, seed: 22), folder: "ARCHIV")
        return new
    }
    static func logged(_ rig: DeviceRig) async throws -> [String] {
        await rig.log.flush()
        let file = rig.paths.log.appending(path: "ereignisse.ndjson")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { line in
            (try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["kind"] as? String
        }
    }

    /// The run the owner expects: fresh install, switch on, the pen is plugged in. Exactly the one new recording
    /// comes, the folder of files another app already moved away is not read, the device stays as it was.
    @Test func freshInstallImportsThePenAtOnce() async throws {
        let rig = try DeviceRig(profile: .production)
        let data = try Self.pen(rig), sha = DeviceRig.sha(data)
        try rig.lockDevice()
        let before = try rig.deviceSnapshot(), plugged = Plugged([rig.volume(name: "DVT1600")])
        let importer = try await Self.fresh(rig, on: true, plugged: plugged)
        let report = await importer.scan()
        #expect(report.imported == 1 && report.failed == 0)
        #expect(try rig.deviceSnapshot() == before)
        #expect(await importer.config.profiles == [DeviceProfile(kind: .dvt1600, volumeUUID: rig.volumeUUID)])
        let archived = try rig.archived()
        #expect(archived.count == 1 && archived[0].hasSuffix("-dvt1600-rec-001-\(sha.prefix(8)).wav"))
        let filed = await rig.filing.state.filed
        #expect(filed.map(\.label) == ["dvt1600-rec-001-\(sha.prefix(8))"])
        #expect(filed.first?.originalName == "REC_001.wav")
        let transcript = await importer.entries().last?.transcript
        #expect(transcript?.hasSuffix("-raum-dvt1600-rec-001-\(sha.prefix(8)).md") == true)
        #expect(await importer.notice == DeviceNotice(.imported(1), .dvt1600, name: "DVT1600", uuid: rig.volumeUUID))
        // plugged in again: nothing new, said as such, never a failure
        #expect(await importer.scan() == DeviceImporter.Report())
        #expect(await importer.notice?.what == .nothingNew)
        #expect(await importer.current == .hidden)
        let log = try await Self.logged(rig)
        #expect(log.filter { $0 == "device_adopted" }.count == 1 && log.contains("device_nothing_new"))
        // unplugged: the line goes with the device
        plugged.set([])
        await importer.look(announce: true)
        #expect(await importer.notice == nil)
    }

    /// Switch off: nothing is imported and no device is made known, but the recorder is seen and logged once.
    @Test func switchedOffSeesTheRecorderAndSaysSo() async throws {
        let rig = try DeviceRig(profile: .production)
        _ = try Self.pen(rig)
        let before = try rig.deviceSnapshot(), plugged = Plugged([rig.volume(name: "DVT1600")])
        let importer = try await Self.fresh(rig, on: false, plugged: plugged)
        #expect(await importer.scan() == DeviceImporter.Report())
        await importer.look()
        #expect(await importer.notice == DeviceNotice(.off, .dvt1600, name: "DVT1600", uuid: rig.volumeUUID))
        #expect(await importer.config.profiles.isEmpty)
        #expect(await rig.transcriber.state.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.folders.data.appending(path: "geraete.json").path))
        #expect(try rig.deviceSnapshot() == before)
        #expect(try await Self.logged(rig).filter { $0 == "device_import_off" }.count == 1)
        // the menu's step: on, and the import runs at once
        try await importer.setEnabled(true)
        #expect(await importer.scan().imported == 1)
        #expect(await importer.notice?.what == .imported(1))
        // off again and unplugged: no line
        try await importer.setEnabled(false)
        plugged.set([])
        await importer.look()
        #expect(await importer.notice == nil)
    }

    /// Development never says anything about a real recorder, and a volume without name and layout is none.
    @Test func noLineForDevelopmentOrAPlainStick() async throws {
        let rig = try DeviceRig()
        _ = try Self.pen(rig)
        let dev = try await Self.fresh(rig, profile: .development, on: false,
                                       plugged: Plugged([rig.volume(name: "DVT1600")]))
        await dev.look()
        #expect(await dev.notice == nil)
        let plain = try DeviceRig(profile: .production)
        try plain.put("musik.wav", DeviceRig.wav(seconds: 3))
        for on in [false, true] {
            let importer = try await Self.fresh(plain, on: on, plugged: Plugged([plain.volume(name: "NO NAME")]))
            #expect(await importer.scan() == DeviceImporter.Report())
            await importer.look()
            #expect(await importer.notice == nil)
            #expect(await importer.config.profiles.isEmpty)
        }
        #expect(await plain.transcriber.state.calls.isEmpty)
    }

    /// Only the name or only the layout: not imported on a guess; the line asks, one click in the list decides.
    @Test(arguments: [["DVT1600", ""], ["ZEPHYR", ""], ["STICK", "RECORD/A"], ["STICK", ".cache"]])
    func aVolumeThatOnlyMayBeARecorderWaitsForTheClick(_ c: [String]) async throws {
        let rig = try DeviceRig(profile: .production)
        let folder = c[1] == ".cache" || c[1].isEmpty ? "" : c[1]
        try rig.put("REC_001.wav", DeviceRig.wav(seconds: 3, seed: 31), folder: folder)
        if c[1] == ".cache" { try rig.put(".dat", Data([1]), folder: ".cache") }
        let volume = rig.volume(name: c[0], readOnly: true)
        let importer = try await Self.fresh(rig, on: true, plugged: Plugged([volume]))
        #expect(await importer.scan() == DeviceImporter.Report())
        let notice = try #require(await importer.notice)
        #expect(notice.what == .unknown && notice.name == c[0] && DeviceKind.recognize(volume)?.sure == false)
        #expect(await importer.config.profiles.isEmpty)
        #expect(await rig.transcriber.state.calls.isEmpty)
        #expect(try await Self.logged(rig).contains("device_unknown"))
        try await importer.register(volume, as: notice.kind)
        let lies = c[0] != "DVT1600"  // a pen without its recording folder holds nothing to read
        #expect(await importer.scan().imported == (lies ? 1 : 0))
        #expect(await importer.notice?.what == (lies ? .imported(1) : .nothingNew))
    }

    /// The second recorder is write-protected and names its files by its clock: read in at once as well, and the
    /// names carry the hash of the secured copy (its header is always repaired), as Panotti's names do.
    @Test func theWriteProtectedRecorderIsReadInAndNamedByItsCopy() async throws {
        let rig = try DeviceRig(profile: .production)
        let data = DeviceRig.wav(seconds: 3, seed: 41, claimExtra: 36)
        try rig.put("2026_11_10_20_21_50.wav", data, folder: "")
        try rig.put(".dat", Data([1]), folder: ".cache")
        try rig.lockDevice()
        let before = try rig.deviceSnapshot(), volume = rig.volume(name: "NO NAME", readOnly: true)
        #expect(DeviceKind.recognize(volume)?.kind == .zephyr && DeviceKind.recognize(volume)?.sure == true)
        let importer = try await Self.fresh(rig, on: true, plugged: Plugged([volume]))
        #expect(await importer.scan().imported == 1)
        #expect(try rig.deviceSnapshot() == before)
        let recording = try #require(await rig.filing.state.filed.first)
        #expect(recording.deviceSHA256 == DeviceRig.sha(data) && recording.sha256 != recording.deviceSHA256)
        #expect(recording.label == "zephyr-\(recording.sha256.prefix(8))")
        #expect(try rig.archived().first?.hasSuffix("-zephyr-\(recording.sha256.prefix(8)).wav") == true)
        #expect(await importer.config.profiles.first?.nameClock == true)
    }

    /// After Panotti's journal was taken over: the pen is read in by itself as well, and what Panotti already
    /// imported is not imported again, whether it still lies in the recording folder or not.
    @Test func afterTheTakeoverKnownRecordingsStayOut() async throws {
        let rig = try DeviceRig(profile: .production)
        let panotti = try DeviceTakeoverAndClockTests.panottiFolder(rig)
        try rig.put("probe-1.wav", panotti.files[0].data, folder: "RECORD/A")
        let importer = try await Self.fresh(rig, on: false, plugged: Plugged([rig.volume(name: "DVT1600")]))
        try await importer.takeover(try await importer.takeoverPlan(from: panotti.folder, settings: nil))
        await importer.look()  // the takeover neither switches on nor makes a device known
        #expect(await importer.notice?.what == .off)
        #expect(await importer.config.profiles.isEmpty)
        try await importer.setEnabled(true)
        #expect(await importer.scan() == DeviceImporter.Report())
        #expect(await importer.notice?.what == .nothingNew)
        #expect(await importer.config.profiles.map(\.kind) == [.dvt1600])
        try rig.put("REC_002.wav", DeviceRig.wav(seconds: 3, channels: 2, seed: 51), folder: "RECORD/A")
        #expect(await importer.scan().imported == 1)
        #expect(await rig.transcriber.state.calls.count == 1)
    }

    /// Every scan and every announced look ends with a sign on `progress`, so menu and list can follow.
    @Test func everyScanEndsWithASign() async throws {
        let rig = try DeviceRig(profile: .production)
        let importer = try await Self.fresh(rig, on: true, plugged: Plugged([]))
        let seen = Task { () -> Int in
            var n = 0
            for await _ in importer.progress { n += 1; if n == 3 { break } }
            return n
        }
        _ = await importer.scan()
        _ = await importer.scan()
        await importer.look(announce: true)
        #expect(await seen.value == 3)
    }
}
