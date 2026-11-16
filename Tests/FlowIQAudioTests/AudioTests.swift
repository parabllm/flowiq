import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQLog

// Own tests beyond the P3 acceptance set. Synthetic sources only: no microphone, no desktop sound.

private let builtIn = InputDevice(uid: "b", isBuiltIn: true)
private let pods = InputDevice(uid: "p", isBuiltIn: false, isBluetooth: true)
private let usb = InputDevice(uid: "u", isBuiltIn: false)

struct DevicePolicyTests {
    struct Case: Sendable {
        let purpose: MicPurpose
        let setup: DeviceSetup
        let running: InputDevice?
        let expected: InputDevice?
    }

    static let cases: [Case] = [
        Case(purpose: .dictation, setup: DeviceSetup(standard: pods, fallback: builtIn), running: nil,
             expected: builtIn),
        Case(purpose: .room, setup: DeviceSetup(standard: pods, fallback: builtIn), running: nil, expected: builtIn),
        Case(purpose: .call, setup: DeviceSetup(standard: pods, fallback: builtIn), running: nil, expected: pods),
        Case(purpose: .dictation, setup: DeviceSetup(standard: pods, fallback: builtIn, lidOpen: false), running: nil,
             expected: pods),
        Case(purpose: .dictation, setup: DeviceSetup(standard: usb, fallback: builtIn), running: nil, expected: usb),
        Case(purpose: .call, setup: DeviceSetup(standard: pods, fallback: builtIn, explicit: usb), running: nil,
             expected: usb),
        Case(purpose: .room, setup: DeviceSetup(standard: pods, fallback: builtIn, explicit: usb), running: pods,
             expected: pods),
        Case(purpose: .dictation, setup: DeviceSetup(standard: nil, fallback: builtIn), running: nil,
             expected: builtIn),
        Case(purpose: .call, setup: DeviceSetup(standard: nil, fallback: nil), running: nil, expected: nil),
    ]

    @Test(arguments: cases)
    func choosesLikePanottiB07(_ c: Case) {
        #expect(DevicePolicy.choose(for: c.purpose, setup: c.setup, running: c.running) == c.expected)
    }

    @Test func logTagNamesTheKindNeverTheIdentity() {
        let tag = InputDevice(uid: "AppleUSBAudioEngine:Vendor:Model:4711:1", isBuiltIn: false).logTag
        #expect(tag.hasPrefix("external-"))
        #expect(!tag.contains("Vendor") && !tag.contains("4711"))
        #expect(tag == InputDevice(uid: "AppleUSBAudioEngine:Vendor:Model:4711:1", isBuiltIn: false).logTag)
    }
}

/// Test source driven by hand.
final class HandSource: CaptureSource {
    let kind: SourceKind
    private struct State {
        var deliver: (@Sendable (AudioChunk) -> Void)?
        var onEnd: (@Sendable (CaptureEnd) -> Void)?
        var starts = 0, stops = 0
    }
    private let state = Mutex(State())
    private let refuse: Bool
    private let delay: Duration

    init(_ kind: SourceKind, refuse: Bool = false, delay: Duration = .zero) {
        (self.kind, self.refuse, self.delay) = (kind, refuse, delay)
    }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        if delay > .zero { try await Task.sleep(for: delay) }  // a slow device start
        if refuse { throw AudioError.rejected }
        state.withLock { ($0.deliver, $0.onEnd, $0.starts) = (deliver, onEnd, $0.starts + 1) }
    }

    func stop() async { state.withLock { ($0.deliver, $0.stops) = (nil, $0.stops + 1) } }

    func emit(_ seconds: Double, from start: Double, amp: Float = 0.2) {
        for index in 0..<Int((seconds * 10).rounded()) {
            let time = UInt64(((start + Double(index) / 10) * 1e9).rounded())
            state.withLock { $0.deliver }?(AudioChunk(hostTime: time, sampleRate: 48_000,
                                                      samples: [Float](repeating: amp, count: 4_800)))
        }
    }

    func fail() {
        let onEnd = state.withLock { s -> (@Sendable (CaptureEnd) -> Void)? in
            defer { s.onEnd = nil }
            return s.onEnd
        }
        onEnd?(.failed("gone"))
    }
    var stops: Int { state.withLock { $0.stops } }
}

final class SourceList: Sendable {
    private let list = Mutex<[HandSource]>([])
    private let refusing = Mutex(false)
    private let startDelay = Mutex(Duration.zero)

    func make(_ kind: SourceKind) -> HandSource {
        let source = HandSource(kind, refuse: refusing.withLock { $0 }, delay: startDelay.withLock { $0 })
        list.withLock { $0.append(source) }
        return source
    }

    func refuse(_ value: Bool) { refusing.withLock { $0 = value } }
    func slowStarts(_ delay: Duration) { startDelay.withLock { $0 = delay } }
    var all: [HandSource] { list.withLock { $0 } }
    var last: HandSource? { list.withLock { $0.last } }
}

struct ConductorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-audio-\(UUID().uuidString)")
    let mics = SourceList()
    let desktops = SourceList()
    let log: EventLog
    let conductor: AudioConductor

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = EventLog(directory: root)
        let (mics, desktops) = (mics, desktops)
        conductor = AudioConductor(microphone: { mics.make(.microphone($0)) }, desktop: { desktops.make(.desktop) },
                                   devices: DeviceSetup(standard: usb, fallback: nil), log: log)
    }

    private func cleanup() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
    }

    private func events(_ kind: String) async throws -> [[String: Any]] {
        await log.flush()
        let text = try String(contentsOf: root.appending(path: "ereignisse.ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["kind"] as? String == kind }
    }

    private func settle(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// AirPods test 16.11.: every change of the system's inputs is logged without names and handed to the app.
    @Test func deviceChangesAreLoggedAndHandedOn() async throws {
        defer { cleanup() }
        let pods = InputDevice(uid: "BT-PODS", isBuiltIn: false, isBluetooth: true)
        let iterator = Task { [conductor] in
            var seen: [InputDevice?] = []
            for await setup in conductor.deviceChanges {
                seen.append(setup.standard)
                if seen.count == 2 { break }
            }
            return seen
        }
        await conductor.updateDevices(DeviceSetup(standard: pods, fallback: nil))
        await conductor.updateDevices(DeviceSetup(standard: pods, fallback: nil))  // no change, no line
        await conductor.updateDevices(DeviceSetup(standard: nil, fallback: nil))
        #expect(await iterator.value == [pods, nil])
        let lines = try await events("devices_changed")
        #expect(lines.map { $0["change"] as? String } == ["standard_changed", "standard_gone"])
        #expect(lines.first?["bluetooth"] as? Bool == true)
        let standard = lines.first?["standard"] as? String
        #expect(standard?.contains("PODS") == false, "no device name in the log")
    }

    /// Review V1: a source still down when its last lease ends reports `sourceRestored`, so no warning stays.
    @Test func theLastReleaseOfADownSourceEndsItsWarning() async throws {
        defer { cleanup() }
        desktops.refuse(true)
        let lease = try await conductor.acquireDesktop()
        #expect(await conductor.isDown(.desktop))
        await lease.release()
        let restored = Task { [conductor] in
            for await event in conductor.events where event == .sourceRestored(.desktop) { return true }
            return false
        }
        try await settle { await !conductor.isDown(.desktop) }
        #expect(await within(.seconds(2)) { await restored.value } == true)
        restored.cancel()
        await log.flush()  // the log task writes its last lines before the folder goes
    }

    /// A desktop source that comes back after a failed start says so (`source_up`), so the warning can end.
    @Test func aRestartedDesktopReportsSourceUp() async throws {
        defer { cleanup() }
        desktops.refuse(true)
        let lease = try await conductor.acquireDesktop()
        desktops.refuse(false)
        try await settle { await !conductor.isDown(.desktop) }
        #expect(try await events("source_up").first?["track"] as? String == "desktop")
        await lease.release()
    }

    @Test func halfWarmKeepsTheDeviceAndHandsTheLastHalfSecondToTheNextLease() async throws {
        defer { cleanup() }
        let first = try await conductor.acquireMic(for: .dictation)
        let source = try #require(mics.last)
        source.emit(1, from: 0)
        await first.release(hold: .seconds(30))
        source.emit(2, from: 1, amp: 0.5)  // spoken before the next key press
        let second = try await conductor.acquireMic(for: .dictation)
        source.emit(1, from: 3)
        await second.release(hold: .zero)
        var received: [AudioChunk] = []
        for await chunk in second.chunks { received.append(chunk) }
        #expect(mics.all.count == 1)  // never opened twice
        #expect(source.stops == 1)
        let preroll = received.prefix { $0.samples.first == 0.5 }
        #expect(abs(preroll.reduce(0) { $0 + $1.seconds } - 0.5) <= 0.1)
        #expect(received.count == preroll.count + 10)
    }

    @Test func desktopRestartSucceedsAndEndsTheFill() async throws {
        defer { cleanup() }
        let lease = try await conductor.acquireDesktop()
        let first = try #require(desktops.last)
        first.emit(1, from: 0)
        first.fail()
        try await settle { await conductor.isDown(.desktop) }
        #expect(await conductor.isDown(.desktop))
        try await settle { desktops.all.count == 2 }  // first attempt after 1 s
        try await settle { !(await conductor.isDown(.desktop)) }
        #expect(!(await conductor.isDown(.desktop)))
        let restarts = try await events("desktop_restart")
        #expect(restarts.first?["ok"] as? Bool == true)
        #expect(try await !events("gap_filled").isEmpty)
        await lease.release()
    }

    @Test func refusedDesktopStillGivesALeaseAndIsMarkedDown() async throws {
        defer { cleanup() }
        desktops.refuse(true)
        let lease = try await conductor.acquireDesktop()
        #expect(await conductor.isDown(.desktop))
        #expect(try await !events("capture_start_failed").isEmpty)
        await lease.release()
        #expect(!(await conductor.isDown(.desktop)))
    }

    @Test func returningDeviceEndsTheFillOfALostMicrophone() async throws {
        defer { cleanup() }
        let lease = try await conductor.acquireMic(for: .room)
        try #require(mics.last).emit(1, from: 0)
        try #require(mics.last).fail()
        try await settle { await conductor.isDown(.microphone) }
        #expect(await conductor.isDown(.microphone))  // no fallback configured
        await conductor.updateDevices(DeviceSetup(standard: pods, fallback: builtIn))
        #expect(!(await conductor.isDown(.microphone)))
        #expect(micUID(mics.last) == builtIn.uid)  // room with Bluetooth standard: built-in microphone
        let switches = try await events("device_switch")
        #expect(switches.first?["reason"] as? String == "returned")
        await lease.release()
    }

    /// Review A8: the last lease ends while a menu switch is still opening the new device.
    @Test func lastLeaseEndingDuringASwitchClosesTheNewSource() async throws {
        defer { cleanup() }
        let lease = try await conductor.acquireMic(for: .room)
        mics.slowStarts(.milliseconds(300))
        async let switched: Void = conductor.switchMic(to: builtIn)
        try await Task.sleep(for: .milliseconds(100))
        await lease.release()
        await switched
        #expect(mics.all.count == 2)
        #expect(try #require(mics.last).stops == 1)  // not left open without a consumer
        #expect(!(await conductor.isDown(.microphone)))
    }

    private func micUID(_ source: HandSource?) -> String? {
        if case .microphone(let device) = source?.kind { return device.uid }
        return nil
    }
}

struct FileSourceTests {
    @Test func fileSourcePlaysMonoAtTheChannelRateThenSilence() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "flowiq-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) } catch { Issue.record("cleanup failed: \(error)") }
        }
        let url = folder.appending(path: "ton.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
            buffer.frameLength = 22_050
            for channel in 0..<2 {
                for index in 0..<22_050 {
                    buffer.floatChannelData?[channel][index] = Float(sin(Double(index) * 0.1)) * 0.4
                }
            }
            try file.write(from: buffer)
        }
        let got = Mutex<[AudioChunk]>([])
        let source = FileSource(url: url, speed: 50)
        try await source.start(deliver: { chunk in got.withLock { $0.append(chunk) } }, onEnd: { _ in })
        for _ in 0..<300 where got.withLock({ $0.count }) < 15 { try await Task.sleep(for: .milliseconds(5)) }
        await source.stop()
        let chunks = got.withLock { $0 }
        let count = chunks.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(got.withLock { $0.count } == count)  // nothing after stop
        #expect(chunks.allSatisfy { $0.sampleRate == 48_000 && $0.samples.count == 4_800 })
        let sound = chunks.prefix(9).flatMap(\.samples).map { abs($0) }.max() ?? 0
        #expect(sound > 0.2)  // the file, mixed down to mono
        #expect(chunks.dropFirst(12).allSatisfy { $0.samples.allSatisfy { $0 == 0 } })  // after the end: silence
        let starts = chunks.map(\.hostTime)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 == 100_000_000 })
    }
}
