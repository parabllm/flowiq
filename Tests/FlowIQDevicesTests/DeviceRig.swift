import CryptoKit
import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQDevices

/// Artificial devices for P6 (A.11, G.1): plain temporary folders, never a mounted volume, never a volume name of a
/// real device, never their folder layout. Audio is generated PCM, so nothing private is ever involved.
final class DeviceRig: Sendable {
    let root: URL, support: URL, device: URL, archive: URL
    let paths: Paths, fs: SafeFS, log: EventLog
    let transcriber = FakeTranscriber(), filing = FakeFiling()
    let volumeUUID = "00000000-0000-4000-8000-00000000F10E"

    init(profile: Profile = .development) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p6-\(UUID().uuidString)")
        let paths = Paths(profile: profile, applicationSupport: root.appending(path: "support"))
        (self.paths, support) = (paths, paths.support)
        device = root.appending(path: "geraet-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        archive = support.appending(path: "archiv", directoryHint: .isDirectory)
        for folder in [support, device, archive, paths.log, paths.laufend] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        fs = SafeFS(paths: paths)
        log = EventLog(directory: paths.log, fs: fs)
    }

    deinit {
        Self.unlock(root)
        do { try FileManager.default.removeItem(at: root) } catch { print("cleanup failed") }
    }

    var folders: DeviceImporter.Folders {
        .init(data: support.appending(path: "geraete", directoryHint: .isDirectory), archive: archive)
    }

    func volume(name: String = "FLOWIQTEST", readOnly: Bool = false, uuid: String? = nil) -> MountedVolume {
        MountedVolume(url: device, uuid: uuid ?? volumeUUID, name: name, readOnly: readOnly)
    }

    /// An importer with the test device registered and switched on.
    func importer(kind: DeviceKind = .test, profile: Profile = .development, post: Bool = false,
                  gate: ThrottleGate = .open, busy: BusyState? = nil, volumes: [MountedVolume]? = nil,
                  now: Date = Date(), enabled: Bool = true) async throws -> DeviceImporter {
        let vols = volumes ?? [volume()]
        let importer = DeviceImporter(profile: profile, folders: folders, fs: fs, log: log,
                                      transcriber: transcriber, filing: filing, post: { post }, gate: gate,
                                      busy: busy, volumes: { vols }, now: { now }, settle: .zero)
        // Never the real devices' layout (A.11): every kind reads the rig's own folder.
        try await importer.register(volume(uuid: vols.first?.uuid), as: kind, folders: ["aufnahmen"])
        try await importer.setEnabled(enabled)
        return importer
    }

    /// PCM 16 bit WAV with a correct header; `seed` makes the content unique.
    static func wav(seconds: Double, rate: Int = 16_000, channels: Int = 1, seed: UInt8 = 1,
                    claimExtra: UInt32 = 0) -> Data {
        let frames = Int(seconds * Double(rate)), bytes = frames * channels * 2
        var data = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        le(UInt32(36 + bytes) + claimExtra)
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(channels)); le(UInt32(rate))
        le(UInt32(rate * channels * 2)); le(UInt16(channels * 2)); le(UInt16(16))
        data.append(contentsOf: Data("data".utf8))
        le(UInt32(bytes) + claimExtra)
        data.append(contentsOf: (0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 7) })
        return data
    }

    @discardableResult
    func put(_ name: String, _ data: Data, folder: String = "aufnahmen", modified: Date? = nil,
             created: Date? = nil) throws -> URL {
        let dir = device.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try data.write(to: url)
        var attributes: [FileAttributeKey: Any] = [:]
        if let modified { attributes[.modificationDate] = modified }
        if let created { attributes[.creationDate] = created }
        if !attributes.isEmpty { try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path) }
        return url
    }

    static func sha(_ url: URL) throws -> String { sha(try Data(contentsOf: url)) }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Path, size, modification time and content hash of everything on the device.
    func deviceSnapshot() throws -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: device, includingPropertiesForKeys: keys) else { return [] }
        var rows: [String] = []
        for case let url as URL in walk {
            let v = try url.resourceValues(forKeys: Set(keys))
            let hash = v.isRegularFile == true ? try Self.sha(url) : "dir"
            let time = v.contentModificationDate?.timeIntervalSince1970 ?? 0
            rows.append("\(url.path)|\(v.fileSize ?? -1)|\(time)|\(hash)")
        }
        return rows.sorted()
    }

    func archived() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: archive.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    func lockDevice() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: device.path)
        for sub in files { try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                                                 ofItemAtPath: device.appending(path: sub).path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: device.path)
    }

    static func unlock(_ folder: URL) {
        guard let walk = FileManager.default.enumerator(atPath: folder.path) else { return }
        for case let sub as String in walk {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: folder.appending(path: sub).path) } catch {
                continue  // a file the test removed itself
            }
        }
    }
}

/// Counts runs; `fail` makes the next runs throw.
actor FakeTranscriberState {
    var calls: [URL] = [], fail = false
    func called(_ url: URL) -> Bool { calls.append(url); return fail }
    func setFail(_ on: Bool) { fail = on }
}

struct FakeTranscriber: DeviceTranscriber {
    struct Failure: Error {}
    let state = FakeTranscriberState()
    func transcribe(_ audio: URL, language: RecordingLanguage) async throws -> [LiveSegment] {
        if await state.called(audio) { throw Failure() }
        return [LiveSegment(words: [TimedWord(text: "Probe", start: 0.5, end: 1, confidence: 0.9)], speaker: nil)]
    }
}

actor FakeFilingState {
    var filed: [DeviceRecording] = []
    func add(_ r: DeviceRecording) -> Int { filed.append(r); return filed.count }
}

struct FakeFiling: DeviceFiling {
    let state = FakeFilingState()
    func file(_ recording: DeviceRecording) async throws -> URL {
        let n = await state.add(recording)
        return URL(filePath: "/test-vault/transcripts/\(n)-raum-\(recording.label).md")
    }
}
