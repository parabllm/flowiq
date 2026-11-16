// Shared fixtures for the P3 acceptance tests (audio and recording).
//
// RULE: every line that touches an API shape the architecture leaves open carries
// "ASSUMPTION:" in the same line. The build agent may change ONLY those lines (names, labels,
// argument order). Expected values in the test files are fixed and must never be touched.
//
// Nothing here opens a microphone, captures desktop audio or needs a permission: all audio comes
// from `SyntheticSource`, a `CaptureSource` that plays generated sine, noise or silence buffers.
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQLog
@testable import FlowIQRecording

extension Tag {
    @Tag static var slow: Self
}

// MARK: - Assumed API surface (one place to adapt)

/// Fixed test devices.
enum Devices {
    static let builtIn = InputDevice(uid: "test-builtin", isBuiltIn: true)  // ASSUMPTION: InputDevice(uid:isBuiltIn:)
    static let airpods = InputDevice(uid: "test-airpods", isBuiltIn: false)  // ASSUMPTION: InputDevice(uid:isBuiltIn:)
    static let usb = InputDevice(uid: "test-usb", isBuiltIn: false)  // ASSUMPTION: InputDevice(uid:isBuiltIn:)
}

func uid(of lease: MicLease) -> String { lease.device.uid }  // ASSUMPTION: InputDevice.uid is the stable identity

/// Synthetic timeline: `AudioChunk.hostTime` is nanoseconds from the start of the test timeline.
func hostTime(_ seconds: Double) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }  // ASSUMPTION: hostTime unit is nanoseconds

extension AudioChunk {
    /// Chunk length in seconds.
    var length: Double { Double(samples.count) / sampleRate }
    /// Start on the synthetic timeline in seconds.
    var start: Double { Double(hostTime) / 1_000_000_000 }  // ASSUMPTION: hostTime unit is nanoseconds
    var end: Double { start + length }
}

let allEndReasons: [EndReason] = [.normal, .noRecognizerSession, .escape, .deadline, .recognizerFailed, .appQuit]  // ASSUMPTION: EndReason case names (the five end paths of A.5 point 4 plus app quit)

// MARK: - Signals

enum Signal {
    static let rate = 48_000.0

    /// Sine, phase continuous across chunks via `startSample`.
    static func sine(hz: Double = 440, amp: Float = 0.3, count: Int, startSample: Int = 0, rate: Double = rate) -> [Float] {
        (0..<count).map { amp * Float(sin(2 * Double.pi * hz * Double(startSample + $0) / rate)) }
    }

    /// Deterministic noise (linear congruential generator), peak amplitude `amp`.
    static func noise(amp: Float, count: Int, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amp * (Float(Int64(bitPattern: state) >> 40) / Float(1 << 23))
        }
    }

    static func rmsDB(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -200 }
        let mean = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return mean > 0 ? 10 * log10(mean) : -200
    }
}

func chunk(_ samples: [Float], at seconds: Double, rate: Double = Signal.rate) -> AudioChunk {
    AudioChunk(hostTime: hostTime(seconds), sampleRate: rate, samples: samples)  // ASSUMPTION: memberwise init of AudioChunk is visible to tests via @testable
}

// MARK: - Synthetic capture source

/// A `CaptureSource` driven by the test. Honours the contract "after `stop()` returns no buffer
/// arrives" (`emit` drops), and can break it on purpose (`emitRogue`) to model a late callback.
final class SyntheticSource: CaptureSource, Sendable {
    enum Phase: Sendable, Equatable { case idle, running, stopping, stopped }
    struct Counts: Sendable { var starts = 0, stopsBegun = 0, delivered = 0, droppedAfterStop = 0 }

    private struct State {
        var phase = Phase.idle
        var deliver: (@Sendable (AudioChunk) -> Void)?
        var onEnd: (@Sendable (CaptureEnd) -> Void)?  // ASSUMPTION: CaptureEnd reaches the source as an extra start parameter
        var counts = Counts()
        var deliveredSeconds = 0.0
        var failStart = false
    }

    let kind: SourceKind
    let stopDelay: Duration
    private let state = Mutex(State())

    init(kind: SourceKind, stopDelay: Duration = .zero) {
        self.kind = kind
        self.stopDelay = stopDelay
    }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws {
        try await start(deliver: deliver, onEnd: { _ in })
    }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {  // ASSUMPTION: start(deliver:onEnd:) is how a source reports its own end
        let refuse = state.withLock { s -> Bool in
            s.counts.starts += 1
            if s.failStart { return true }
            s.phase = .running
            s.deliver = deliver
            s.onEnd = onEnd
            return false
        }
        if refuse { throw SyntheticFailure.refusedToStart }
    }

    func stop() async {
        state.withLock {
            $0.phase = .stopping
            $0.counts.stopsBegun += 1
        }
        if stopDelay > .zero {
            do { try await Task.sleep(for: stopDelay) } catch { Issue.record("sleep interrupted: \(error)") }
        }
        state.withLock { $0.phase = .stopped }
    }

    // Test controls

    /// Delivers one chunk like a well-behaved source: only while running or stopping.
    @discardableResult
    func emit(_ c: AudioChunk) -> Bool {
        let deliver: (@Sendable (AudioChunk) -> Void)? = state.withLock { s in
            guard s.phase == .running || s.phase == .stopping else {
                s.counts.droppedAfterStop += 1
                return nil
            }
            s.counts.delivered += 1
            s.deliveredSeconds += c.length
            return s.deliver
        }
        deliver?(c)
        return deliver != nil
    }

    /// Delivers a chunk even after `stop()` returned: the late callback that emptied Panotti's files.
    func emitRogue(_ c: AudioChunk) {
        let deliver = state.withLock { $0.deliver }
        deliver?(c)
    }

    /// The source ends by itself with an error (device removed, stream stopped).
    func fail(_ message: String) {
        let onEnd = state.withLock { s -> (@Sendable (CaptureEnd) -> Void)? in
            s.phase = .stopped
            return s.onEnd
        }
        onEnd?(.failed(message))  // ASSUMPTION: CaptureEnd.failed(String)
    }

    func refuseNextStarts() { state.withLock { $0.failStart = true } }

    var phase: Phase { state.withLock { $0.phase } }
    var counts: Counts { state.withLock { $0.counts } }
    var deliveredSeconds: Double { state.withLock { $0.deliveredSeconds } }
}

enum SyntheticFailure: Error { case refusedToStart }

/// Plays `seconds` of sine into `source` in `step`-second chunks starting at timeline second `t`.
/// Returns the next timeline position.
@discardableResult
func feed(_ source: SyntheticSource, from t: Double, seconds: Double, hz: Double = 440, amp: Float = 0.3,
          step: Double = 0.1) -> Double {
    var position = t
    let steps = Int((seconds / step).rounded())
    for _ in 0..<steps {
        let first = Int((position * Signal.rate).rounded())
        let c = chunk(Signal.sine(hz: hz, amp: amp, count: Int(step * Signal.rate), startSample: first), at: position)
        source.emit(c)
        position += step
    }
    return position
}

// MARK: - Scratch folder, log, rig

final class Scratch: Sendable {
    let root: URL
    let paths: Paths
    let fs: SafeFS
    let log: EventLog

    var laufend: URL { paths.laufend }  // ASSUMPTION: Paths.laufend (listed in A.1, not yet in Paths.swift)
    var delivered: URL { paths.support.appending(path: "abgeliefert", directoryHint: .isDirectory) }
    /// Stand-in for the vault: nothing may ever grow here during a recording (R-046).
    var vault: URL { root.appending(path: "vault", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p3-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = Paths(profile: .development, applicationSupport: root)
        let folders = [paths.support, paths.log, paths.support.appending(path: "laufend", directoryHint: .isDirectory),
                       paths.support.appending(path: "abgeliefert", directoryHint: .isDirectory),
                       root.appending(path: "vault", directoryHint: .isDirectory)]
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        fs = SafeFS(paths: paths)  // ASSUMPTION: SafeFS(paths:) built from the profile paths
        log = EventLog(directory: paths.log)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
    }

    func events(_ kind: String? = nil) async -> [LoggedEvent] {
        await log.flush()
        let file = paths.log.appending(path: "ereignisse.ndjson")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            return try text.split(separator: "\n").compactMap { line in
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
                let event = LoggedEvent(object)
                return kind == nil || event.kind == kind ? event : nil
            }
        } catch {
            Issue.record("event log unreadable: \(error)")
            return []
        }
    }
}

struct LoggedEvent: Sendable {
    let kind: String
    let level: String
    let fields: [String: String]

    init(_ object: [String: Any]) {
        kind = object["kind"] as? String ?? ""
        level = object["level"] as? String ?? ""
        fields = object.mapValues { "\($0)" }
    }

    func int(_ key: String) -> Int? { fields[key].flatMap { Int($0) } }
    func double(_ key: String) -> Double? { fields[key].flatMap { Double($0) } }
}

/// Conductor wired to synthetic sources. `mics` lists every microphone source the conductor created.
final class Rig: Sendable {
    let scratch: Scratch
    let conductor: AudioConductor
    let mics: MicBox
    let desktops: DesktopBox
    /// The profile's single `laufend/.sperre` lock, held by the "app" for all sessions of this rig.
    let lock: RecordingLock

    init(standard: InputDevice = Devices.builtIn, fallback: InputDevice? = Devices.builtIn,
         micStopDelay: Duration = .zero) throws {
        let scratch = try Scratch()
        let mics = MicBox(stopDelay: micStopDelay)
        let desktops = DesktopBox()
        self.scratch = scratch
        self.mics = mics
        self.desktops = desktops
        lock = try RecordingLock.acquire(in: scratch.laufend)  // ASSUMPTION: RecordingLock.acquire(in:) throws when another holder has the folder
        conductor = AudioConductor(  // ASSUMPTION: AudioConductor(microphone:desktop:devices:log:) with source factories
            microphone: { mics.make($0) },
            desktop: { desktops.make() },
            devices: DeviceSetup(standard: standard, fallback: fallback),  // ASSUMPTION: DeviceSetup(standard:fallback:), fallback nil means no replacement device
            log: scratch.log)
    }

    func remove() { scratch.remove() }
}

final class MicBox: Sendable {
    private let list = Mutex<[SyntheticSource]>([])
    let stopDelay: Duration
    init(stopDelay: Duration) { self.stopDelay = stopDelay }

    func make(_ device: InputDevice) -> SyntheticSource {
        let source = SyntheticSource(kind: .microphone(device), stopDelay: stopDelay)
        list.withLock { $0.append(source) }
        return source
    }

    var all: [SyntheticSource] { list.withLock { $0 } }
    var current: SyntheticSource? { list.withLock { $0.last } }
}

final class DesktopBox: Sendable {
    private let list = Mutex<[SyntheticSource]>([])
    private let refuse = Mutex(false)

    func make() -> SyntheticSource {
        let source = SyntheticSource(kind: .desktop)
        if refuse.withLock({ $0 }) { source.refuseNextStarts() }
        list.withLock { $0.append(source) }
        return source
    }

    /// Every desktop source created from now on refuses to start (restart attempts fail).
    func refuseFromNowOn() { refuse.withLock { $0 = true } }
    var all: [SyntheticSource] { list.withLock { $0 } }
    var current: SyntheticSource? { list.withLock { $0.last } }
}

// MARK: - Consumers and waiting

actor ChunkBox {
    private(set) var chunks: [AudioChunk] = []
    func add(_ c: AudioChunk) { chunks.append(c) }
}

struct Collecting: Sendable {
    let box: ChunkBox
    let task: Task<Void, Never>

    func snapshot() async -> [AudioChunk] { await box.chunks }

    /// Waits until the stream finished (lease released) and returns everything received.
    func finish() async -> [AudioChunk] {
        await task.value
        return await box.chunks
    }
}

func collect(_ stream: AsyncStream<AudioChunk>) -> Collecting {
    let box = ChunkBox()
    let task = Task { for await c in stream { await box.add(c) } }
    return Collecting(box: box, task: task)
}

/// Polls `condition` until true or `timeout` passes.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {  // COMPILE-FIX (P3 build): @Sendable removed, callers capture `var t`, a Swift 6 error
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return await condition()
}

/// Largest hole between consecutive chunks in seconds (0 for a gapless timeline).
func largestGap(_ chunks: [AudioChunk]) -> Double {
    zip(chunks, chunks.dropFirst()).map { max(0, $1.start - $0.end) }.max() ?? 0
}

func isSilent(_ c: AudioChunk) -> Bool { c.samples.allSatisfy { $0 == 0 } }

// MARK: - Files

func fileSize(_ url: URL) -> Int {
    do { return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 } catch { return -1 }
}

func inode(_ url: URL) -> Int {
    do { return (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? -1 } catch { return -1 }
}

func listing(_ folder: URL) -> [String] {
    do { return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() } catch { return [] }
}

func audioDuration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)  // ASSUMPTION: AVAudioFile reads raw ADTS .aac and .m4a lengths in the test environment
    return Double(file.length) / file.processingFormat.sampleRate
}

/// Decodes a whole (short) file to mono Float samples.
func decode(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let capacity = AVAudioFrameCount(file.length)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData)
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
}

/// Process footprint (`phys_footprint`, the measure of the activity display) in bytes.
func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self(), task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

// MARK: - Recording adapters

func openWriter(_ s: Scratch, name: String = "diktat.aac", purpose: TrackPurpose = .dictation) async throws -> (writer: TrackWriter, url: URL) {
    let url = s.laufend.appending(path: name)
    let writer = try await TrackWriter.create(url: url, purpose: purpose, sampleRate: Signal.rate, fs: s.fs, log: s.log)  // ASSUMPTION: TrackWriter.create(url:purpose:sampleRate:fs:log:) claims the file exactly once
    return (writer, url)
}

/// Appends `seconds` of sine to the writer in 100 ms chunks from timeline second `t`.
@discardableResult
func append(_ writer: TrackWriter, from t: Double = 0, seconds: Double, hz: Double = 440) async -> Double {
    var position = t
    for _ in 0..<Int((seconds / 0.1).rounded()) {
        let first = Int((position * Signal.rate).rounded())
        await writer.append(chunk(Signal.sine(hz: hz, count: 4_800, startSample: first), at: position))  // ASSUMPTION: TrackWriter.append(_:) is non-throwing and discards late buffers itself
        position += 0.1
    }
    return position
}

func verdict(bytes: Int, seconds: Double, purpose: TrackPurpose) -> SizeVerdict {
    SizeCheck.verdict(bytes: bytes, seconds: seconds, purpose: purpose)  // ASSUMPTION: pure SizeCheck.verdict(bytes:seconds:purpose:) -> SizeVerdict { ok, suspicious, lost }
}

func startSession(_ kind: SessionKind, rig: Rig, stamp: String = "2026-01-01 10-00-00") async throws -> RecordingSession {
    try await RecordingSession.start(kind: kind, conductor: rig.conductor, folder: rig.scratch.laufend, stamp: stamp,
                                     fs: rig.scratch.fs, log: rig.scratch.log, lock: rig.lock)  // ASSUMPTION: RecordingSession.start(kind:conductor:folder:stamp:fs:log:lock:), kind is .call (mic + desktop) or .room (mic only)
}

func writtenSeconds(_ session: RecordingSession, _ track: TrackName) async -> Double {
    await session.writtenSeconds(of: track)  // ASSUMPTION: seconds of audio already written to the track's file
}

func status(_ session: RecordingSession, _ track: TrackName) async -> TrackStatus {
    await session.status(of: track)  // ASSUMPTION: TrackStatus { running, gapFilling, ended(String) }, Equatable
}

// MARK: - Test signal helpers

/// The chunks `feed` produces, without delivering them (to compare what consumers received).
func expectedSine(from t: Double, seconds: Double, hz: Double = 440, amp: Float = 0.3, step: Double = 0.1) -> [AudioChunk] {
    (0..<Int((seconds / step).rounded())).map { i in
        let position = t + Double(i) * step
        let first = Int((position * Signal.rate).rounded())
        return chunk(Signal.sine(hz: hz, amp: amp, count: Int(step * Signal.rate), startSample: first), at: position)
    }
}

/// Energy of one frequency in dB (Goertzel), for band comparisons.
func toneDB(_ samples: [Float], hz: Double, rate: Double = Signal.rate) -> Double {
    let w = 2 * Double.pi * hz / rate
    let coefficient = 2 * cos(w)
    var previous = 0.0, beforePrevious = 0.0
    for sample in samples {
        let current = Double(sample) + coefficient * previous - beforePrevious
        beforePrevious = previous
        previous = current
    }
    let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    return 10 * log10(max(power, 1e-30) / Double(samples.count * samples.count))
}

func micUID(_ source: SyntheticSource) -> String? {
    if case .microphone(let device) = source.kind { return device.uid }  // ASSUMPTION: InputDevice.uid
    return nil
}
