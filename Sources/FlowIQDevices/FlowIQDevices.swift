import FlowIQCore
import Foundation

/// The recorders FlowIQ imports from (A.11); `test` is the only kind development ever imports (appendix D).
public enum DeviceKind: String, Sendable, Codable, CaseIterable {
    case dvt1600, zephyr, test
    /// Folders below the volume root: the pen files by letter, the ZEPHYR flat (05a B59), the test image its own.
    var folders: [String] {
        [.dvt1600: ["RECORD/A", "RECORD/B", "RECORD/C", "RECORD/D", "RECORD"], .zephyr: [""]][self] ?? ["aufnahmen"]
    }
    /// The ZEPHYR leaves header-only stubs below 2 s (16 kHz mono).
    var minimumBytes: Int64 { self == .zephyr ? 44 + 2 * 32_000 : 44 }
}

extension DeviceKind {
    /// A plugged-in volume that looks like a supported recorder (16.11.): `sure` needs the name and the layout
    /// (the pen's `RECORD`, the ZEPHYR's `.cache/.dat`); one of both is a guess the user confirms. Reads only.
    public static func recognize(_ v: MountedVolume) -> (kind: DeviceKind, sure: Bool)? {
        let name = v.name.uppercased()
        let has = { (sub: String) in FileManager.default.fileExists(atPath: v.url.appending(path: sub).path) }
        let (pen, zephyr) = (has("RECORD"), has(".cache/.dat"))
        if name == "DVT1600" { return (.dvt1600, pen) }
        if name == "ZEPHYR" || name == "NO NAME" && zephyr { return (.zephyr, zephyr) }
        return pen ? (.dvt1600, false) : zephyr ? (.zephyr, false) : nil
    }
}

/// What the last look at the plugged-in devices found, one line in the menu (16.11.): a recorder while the switch
/// is off, a volume that only may be one, nothing new, or how many recordings came.
public struct DeviceNotice: Sendable, Equatable {
    public enum What: Sendable, Equatable { case off, unknown, nothingNew, imported(Int) }
    public let what: What, kind: DeviceKind, name: String, uuid: String
    public init(_ what: What, _ kind: DeviceKind, name: String, uuid: String) {
        (self.what, self.kind, self.name, self.uuid) = (what, kind, name, uuid)
    }
}

/// One known device in `geraete.json`, recognized by its volume identifier, never by its name.
public struct DeviceProfile: Sendable, Codable, Equatable {
    public var kind: DeviceKind, volumeUUID: String, folders: [String], minimumBytes: Int64
    /// The recording start is in the file name, in the device clock's zone (ZEPHYR).
    public var nameClock: Bool
    public init(kind: DeviceKind, volumeUUID: String, folders: [String]? = nil, minimumBytes: Int64? = nil,
                nameClock: Bool? = nil) {
        (self.kind, self.volumeUUID, self.folders) = (kind, volumeUUID, folders ?? kind.folders)
        (self.minimumBytes, self.nameClock) = (minimumBytes ?? kind.minimumBytes, nameClock ?? (kind == .zephyr))
    }
}

/// `geraete.json` in the data folder: the switch, the profiles, the ZEPHYR clock zone (minutes east of UTC).
public struct DeviceConfig: Sendable, Codable, Equatable {
    public var enabled = false, profiles: [DeviceProfile] = []
    public var clockOffsetMinutes = 480, language = RecordingLanguage.de
    public init() {}
}

public struct MountedVolume: Sendable, Equatable {
    public let url: URL, uuid: String, name: String, readOnly: Bool
    public init(url: URL, uuid: String, name: String, readOnly: Bool) { (self.url, self.uuid) = (url, uuid)
        (self.name, self.readOnly) = (name, readOnly) }
}

public enum ImportProblem: String, Sendable, Codable { case journalUnreadable, unreadable, copy, transcribe, filing }
/// The ring at the pill (R-072): a share while copying, a pulse while transcribing, gone after.
public enum ImportProgress: Sendable, Equatable { case hidden, copying(Double), transcribing, failed(ImportProblem) }

/// Local recognition of a secured copy; the app wires `FlowIQSpeech`'s file run in (Speech and Devices never meet).
public protocol DeviceTranscriber: Sendable { func transcribe(_ audio: URL, language: RecordingLanguage) async throws
    -> [LiveSegment] }

/// Vault side (A.9): the store writes `<stamp>-raum-<label>.md` (searching `archive/`), after-run only on `post`.
public protocol DeviceFiling: Sendable { func file(_ recording: DeviceRecording) async throws -> URL }

public struct DeviceRecording: Sendable, Equatable {
    public let kind: DeviceKind, originalName: String, sha256: String, deviceSHA256: String, bytes: Int64
    public let recordedAt: Date, seconds: Double, audio: URL, segments: [LiveSegment]
    public let language: RecordingLanguage, post: Bool
    /// Panotti's name part after the stamp: `dvt1600-rec-001-1c5888b6`, `zephyr-1c5888b6` (05b 1.1).
    /// The hash is the one of the secured copy, as in Panotti's names (differs from the device after a header repair).
    public var label: String { Self.label(kind, originalName, sha256) }
    static func label(_ kind: DeviceKind, _ name: String, _ sha: String) -> String {
        let original = name.lowercased().replacing("_", with: "-").replacing(".wav", with: "")
        return [kind.rawValue, kind == .zephyr ? nil : original, String(sha.prefix(8))].compactMap { $0 }
            .joined(separator: "-")
    }
}

/// When background work may run (A.1, B.5): it waits while a dictation runs and yields during a recording.
public struct ThrottleGate: Sendable {
    let busy: @Sendable () async -> Set<BusyState.Reason>, pause: Duration
    public init(pause: Duration = .milliseconds(50), busy: @escaping @Sendable () async -> Set<BusyState.Reason>) {
        (self.busy, self.pause) = (busy, pause)
    }
    public init(_ state: BusyState, pause: Duration = .milliseconds(50)) {
        self.init(pause: pause) { await state.reasons } }
    public static let open = ThrottleGate { [] }
    /// False when cancelled while waiting.
    func pass() async -> Bool {
        while await busy().contains(.dictation) {
            do { try await Task.sleep(for: pause) } catch { return false }
        }
        if await busy().contains(.recording) { await Task.yield() }
        return true
    }
}
