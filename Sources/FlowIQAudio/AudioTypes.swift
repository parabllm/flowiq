@_exported import FlowIQLog
@_exported import Synchronization

@_exported import FlowIQCore  // AudioChunk and TrackKind live in Core (M.2), every client of Audio sees them

public struct InputDevice: Sendable, Hashable {
    public let uid: String, isBuiltIn: Bool, isBluetooth: Bool
    public init(uid: String, isBuiltIn: Bool, isBluetooth: Bool = false) {
        self.uid = uid
        self.isBuiltIn = isBuiltIn
        self.isBluetooth = isBluetooth
    }
    /// Kind plus short hash for the text-free log (A.2): never a device name.
    public var logTag: String {
        let hash = uid.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return (isBuiltIn ? "builtin-" : isBluetooth ? "bluetooth-" : "external-") + String(hash % 65_536, radix: 16)
    }
}

public enum SourceKind: Sendable, Equatable {
    case microphone(InputDevice), desktop, file(URL)
}

/// How a source ends by itself; a normal `stop()` reports nothing.
public enum CaptureEnd: Sendable, Equatable {
    case failed(String)
}

/// The seam for real devices, the file source and test sources (A.4, Ä-3).
public protocol CaptureSource: Sendable {
    var kind: SourceKind { get }
    /// `deliver` runs on the source's own callback queue, in order; `onEnd` reports a failure of the source.
    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws
    /// After return no chunk arrives any more.
    func stop() async
}

public enum MicPurpose: String, Sendable {
    case dictation, room, call
}

/// What the device rule sees (read only, R-044). `fallback` is the built-in microphone, nil without one.
public struct DeviceSetup: Sendable, Equatable {
    public var standard: InputDevice? = nil, fallback: InputDevice? = nil, explicit: InputDevice? = nil, lidOpen: Bool
    public init(standard: InputDevice?, fallback: InputDevice?, explicit: InputDevice? = nil, lidOpen: Bool = true) {
        self.standard = standard
        self.fallback = fallback
        self.explicit = explicit
        self.lidOpen = lidOpen
    }
}

/// Port of Panotti B07 (A.4, E6): a running device wins, then the choice; Bluetooth with lid open uses built-in.
public enum DevicePolicy {
    public static func choose(for purpose: MicPurpose, setup: DeviceSetup, running: InputDevice?) -> InputDevice? {
        if let running { return running }
        if let explicit = setup.explicit { return explicit }
        if purpose != .call, setup.lidOpen, setup.standard?.isBluetooth == true, let builtIn = setup.fallback {
            return builtIn
        }
        return setup.standard ?? setup.fallback
    }
}

/// For the pill and the menu (P4, P7); the log carries the same facts.
public enum AudioEvent: Sendable, Equatable {
    case deviceSwitched(InputDevice, lost: Bool)
    case sourceDown(TrackKind)
    case sourceRestored(TrackKind)
}

public enum AudioError: Error, Equatable {
    case noDevice, deviceMissing, rejected, notRunning, permission  // permission: screen recording not granted
}

/// A consumer's share of the microphone. Release ends the stream; the last release stops the device.
public struct MicLease: Sendable {
    public let id: UInt64, chunks: AsyncStream<AudioChunk>, device: InputDevice
    let conductor: AudioConductor
    /// `hold` above zero keeps the device open (stage "halbwarm", K-17); default off.
    public func release(hold: Duration = .zero) async { await conductor.release(id, of: .microphone, hold: hold) }
}

public struct DesktopLease: Sendable {
    public let id: UInt64, chunks: AsyncStream<AudioChunk>
    let conductor: AudioConductor
    public func release() async { await conductor.release(id, of: .desktop, hold: .zero) }
}
