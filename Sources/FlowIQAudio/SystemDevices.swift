import AVFoundation
import CoreAudio
import IOKit

/// Reads the system's audio inputs for the device rule (A.4, R-044), never sets anything; needs no permission.
public enum SystemDevices {
    public static func current() -> DeviceSetup {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                                     position: .unspecified).devices
        return DeviceSetup(standard: AVCaptureDevice.default(for: .audio).map(device),
                           fallback: found.map(device).first { $0.isBuiltIn }, lidOpen: lidOpen())
    }
    /// Calls `changed` whenever the standard input or the device list changes (CoreAudio listeners, never setting).
    public static func watch(_ changed: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil) { _, _ in
                changed()
            }
        }
    }
    static func device(_ capture: AVCaptureDevice) -> InputDevice {
        let transport = UInt32(bitPattern: capture.transportType)
        let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport)
        return InputDevice(uid: capture.uniqueID, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                           isBluetooth: bluetooth)
    }
    /// `AppleClamshellState` of the power management root; an unreadable state counts as open.
    static func lidOpen() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) != true
    }
}
