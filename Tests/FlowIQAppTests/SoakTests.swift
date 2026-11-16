// Hours of use in fast motion (16.11., after the stack overflow on the tap thread after 2 h 20 min). Tens of
// thousands of keys through the real tap code while the app asks the input to start at every refresh and input
// monitoring goes and comes back, dictations through the real coordinator, thousands of refreshes and menu looks,
// a new storage place with new devices again and again, recorders plugged in and out, call and room audio leases,
// keys saved and removed, the resource monitor started again. Afterwards the depth of the key handler, the
// handlers handed out, observers, readers, capture tasks, timers and the process's threads are where they were.
import CoreGraphics
import FlowIQCloud
import FlowIQCore
import FlowIQInsert
import FlowIQSpeech
import FlowIQStore
import FlowIQText
import Foundation
import Synchronization
import Testing
@testable import FlowIQ
@testable import FlowIQAudio
@testable import FlowIQDevices
@testable import FlowIQInput

/// The real tap's context as key source: the handler is stored and read exactly as on the tap thread. Its depth
/// is measured below the caller of `receive`, so keys from the test's tasks compare with keys from the loop.
private final class TapRig: KeyEventSource, Sendable {
    let context: TapContext, starts = Mutex(0), base = Mutex<UInt>(0), depths = Mutex<(low: Int, high: Int)>((.max, 0))
    init(log: EventLog) { context = TapContext(profile: .development, log: log) }
    func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws {
        starts.withLock { $0 += 1 }
        context.handler.withLock { $0 = Handler { [self] event in
            let depth = Int(base.withLock { $0 }) - Int(stackMark())
            depths.withLock { $0 = (min($0.low, depth), max($0.high, depth)) }
            handler(event)
        } }
    }
    func stop() { context.stop() }
    /// How far the handler's depth moved over all keys, in bytes.
    var spread: Int { depths.withLock { $0.low == .max ? 0 : $0.high - $0.low } }
    /// One edge as the tap delivers it; the trigger is right Option in development (key code 61, flag bit 6).
    func key(_ code: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        let mark = stackMark()
        base.withLock { $0 = mark }
        guard code == 61 else { return context.receive(down ? .keyDown : .keyUp, event) }
        event.flags = down ? CGEventFlags(rawValue: 1 << 6 | CGEventFlags.maskAlternate.rawValue) : []
        context.receive(.flagsChanged, event)
    }
}

private final class Board: PasteboardPort, KeyPosting, FocusProbing, FrontAppProbing, Sendable {
    let state = Mutex<(text: String, count: Int)>(("", 0))
    var changeCount: Int { state.withLock { $0.count } }
    func snapshot() throws -> PasteboardSnapshot { PasteboardSnapshot(items: []) }
    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int { try writePlain(text) }
    func writePlain(_ text: String) throws -> Int { state.withLock { $0 = (text, $0.count + 1); return $0.count } }
    func restore(_ snapshot: PasteboardSnapshot) throws {}
    func paste() throws {}
    func undo() throws {}
    func probe() async -> FocusState { .textField(preceding: nil) }
    func frontmost() -> String? { "pid-1" }
    func frontmostName() -> String? { "Notizen" }
    var secureInputActive: Bool { false }
}

/// Synthetic audio every 10 ms; `running` counts the capture tasks of all tones alive.
private final class Tone: CaptureSource, Sendable {
    static let running = Mutex(0)
    let kind = SourceKind.microphone(InputDevice(uid: "test", isBuiltIn: true))
    let task = Mutex<Task<Void, Never>?>(nil)
    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        Self.running.withLock { $0 += 1 }
        task.withLock { $0 = Task {
            defer { Self.running.withLock { $0 -= 1 } }
            var t: UInt64 = 0
            while !Task.isCancelled {
                deliver(AudioChunk(hostTime: t, sampleRate: AudioChunk.channelRate,
                                   samples: [Float](repeating: 0.1, count: 480)))
                t += 10_000_000
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        } }
    }
    func stop() async { task.withLock { $0?.cancel() } }
}

private struct Words: DictationRecognizer {
    func dictate(_ chunks: AsyncStream<AudioChunk>) async -> DictationRun {
        for await _ in chunks {}
        return DictationRun(recognition: Recognition(text: "Hallo Welt"), failure: nil)
    }
}

private struct Same: TextProcessing {
    func process(_ r: Recognition) async -> ProcessedText { ProcessedText(text: r.text, interventions: []) }
}

private struct NoPill: PillSink { func set(_ state: PillState) {} }
private struct NoText: DeviceTranscriber {
    func transcribe(_ audio: URL, language: RecordingLanguage) async throws -> [LiveSegment] { [] }
}
private struct NoFiling: DeviceFiling {
    func file(_ recording: DeviceRecording) async throws -> URL { recording.audio }
}
private final class MemoryKeychain: KeychainPort, Sendable {
    let store = Mutex<[String: String]>([:])
    func read(service: String, account: String) throws -> String? { store.withLock { $0[service + account] } }
    func write(_ secret: String, service: String, account: String) throws {
        store.withLock { $0[service + account] = secret }
    }
    func delete(service: String, account: String) throws { store.withLock { $0[service + account] = nil } }
}

/// Threads of this process now.
private func threads() -> Int {
    var task = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    return proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, size) == size ? Int(task.pti_threadnum) : 0
}

private final class Folder: Sendable {
    let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-soak-\(UUID().uuidString)")
    deinit {
        do { try FileManager.default.removeItem(at: root) } catch { print("cleanup failed: \(error)") }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SoakTests {
    /// The crash path: 40 000 keys through the tap, a start at every 40th (a refresh), input monitoring off and on
    /// every 4 000, then three dictations held with the trigger. Before the fix the depth sank about 80 bytes a key.
    @Test func keysAndDictationsKeepTheHandlerFlatAndHandedOutOnce() async throws {
        let folder = Folder(), paths = Paths(profile: .development, applicationSupport: folder.root)
        let fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        let log = EventLog(directory: paths.log, fs: fs), clock = ContinuousClock(), board = Board()
        let rig = TapRig(log: log)
        let input = InputService(source: rig, profile: .development, clock: clock, pill: NoPill(), log: log)
        let conductor = AudioConductor(microphone: { _ in Tone() }, desktop: { Tone() },
                                       devices: DeviceSetup(standard: InputDevice(uid: "test", isBuiltIn: true),
                                                            fallback: nil), log: log)
        let journal = DictationJournal(paths: paths, fs: fs, log: log)
        let coordinator = FlowCoordinator(
            paths: paths, fs: fs, conductor: conductor, recognizer: Words(), text: Same(),
            inserter: Inserter(focus: board, pasteboard: board, keys: board, front: board, clock: clock, log: log),
            journal: journal, busy: BusyState(paths: paths, fs: fs), input: input, pill: NoPill(), log: log,
            clock: clock)
        try input.start()
        let pump = Task { for await e in input.stream { await coordinator.handle(e) } }
        defer { pump.cancel() }
        for n in 0..<40_000 {
            rig.key(0, down: n % 2 == 0)
            if n % 40 == 0 { try input.start() }
            if n % 4_000 == 3_999 {
                input.stop()
                try input.start()
            }
            if n % 1_000 == 0, rig.spread > 100_000 { break }  // a sinking handler: red here, not a crashed run
        }
        #expect(rig.spread == 0, "the handler sank \(rig.spread) bytes")
        #expect(rig.starts.withLock { $0 } == 11, "one handler per start, plus one per permission change")
        for _ in 0..<3 {
            rig.key(61, down: true)
            try await Task.sleep(for: .milliseconds(450))
            rig.key(61, down: false)
            for _ in 0..<200 where !(await coordinator.isIdle) { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(await journal.history(limit: 10).count == 3 && board.state.withLock { $0.text } == "Hallo Welt")
        #expect(await coordinator.isIdle && rig.spread == 0)
        input.stop()
        #expect(rig.context.tap.withLock { $0 } == nil && rig.context.handler.withLock { $0 } == nil)
    }

    /// The app side: refreshes, menu looks, storage places with new devices, plug in and out, call and room audio,
    /// keys, the monitor. Every made thing is counted where it can be; threads and memory get a wide margin,
    /// since other suites run in the same process at the same time.
    @MainActor @Test func refreshesPlacesDevicesAudioAndKeysLeaveNothingBehind() async throws {
        let folder = Folder(), paths = Paths(profile: .development, applicationSupport: folder.root)
        let fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        let log = EventLog(directory: paths.log, fs: fs), before = (threads: threads(), mb: try await footprint())
        let model = AppModel(profile: .development, settings: .defaults(for: .development), pill: PillView(show: false))
        for n in 0..<3_000 {
            await model.refresh(full: n % 100 == 0)  // the busy tick, a full one as after an action
            _ = model.menuState  // the menu is built at every opening
        }
        #expect(model.parts.tick == nil, "nothing runs, so no tick timer")

        var watches: [DeviceWatch] = [], readers: [Task<Void, Never>] = [], current: DevicesModel?
        for n in 0..<300 {  // a new storage place builds new devices, as AppModel.relocate does
            let importer = DeviceImporter(
                profile: .development, folders: .init(data: paths.support.appending(path: "geraete-\(n % 3)"),
                                                     archive: paths.support.appending(path: "archiv")),
                fs: fs, log: log, transcriber: NoText(), filing: NoFiling(), post: { false }, volumes: { [] },
                settle: .zero)
            try await importer.setEnabled(true)
            readers.append(Task { for await _ in importer.progress {} })
            let devices = DevicesModel(importer)
            await devices.watch?.refresh()
            current?.stop()
            (current, watches) = (devices, watches + [devices.watch].compactMap { $0 })
        }
        #expect(watches.filter(\.observing).count == 1, "only the current place watches the mounts")
        for reader in readers.dropLast() { await reader.value }  // ended, or the time limit turns it red
        current?.stop()

        let conductor = AudioConductor(microphone: { _ in Tone() }, desktop: { Tone() },
                                       devices: DeviceSetup(standard: InputDevice(uid: "test", isBuiltIn: true),
                                                            fallback: nil), log: log)
        let headset = DeviceSetup(standard: InputDevice(uid: "headset", isBuiltIn: false),
                                  fallback: InputDevice(uid: "test", isBuiltIn: true))
        for n in 0..<200 {  // call (microphone and desktop) or room, a headset plugged in and out now and then
            let mic = try await conductor.acquireMic(for: n % 2 == 0 ? .call : .room)
            let desktop = n % 2 == 0 ? try await conductor.acquireDesktop() : nil
            await mic.release()
            await desktop?.release()
            if n % 10 == 0 {
                await conductor.updateDevices(n % 20 == 0 ? headset : DeviceSetup(
                    standard: InputDevice(uid: "test", isBuiltIn: true), fallback: nil))
            }
        }
        for _ in 0..<100 where Tone.running.withLock({ $0 }) > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(Tone.running.withLock { $0 } == 0, "every capture task ended with its lease")

        let cloud = paths.support.appending(path: "cloud", directoryHint: .isDirectory)
        try fs.makeFolder(cloud)
        let meter = UsageMeter(folder: cloud, fs: fs)
        model.parts.cloud = CloudParts(
            keys: CloudKeys(keychain: MemoryKeychain(), profile: .development),
            usage: MonthUsage(meter: meter, limitMinutes: nil), badge: CloudBadge(), live: false, post: nil,
            profile: .development, log: log,
            policy: { CloudPolicy(settings: .defaults(for: .development), hasKey: false) })
        for n in 0..<300 {  // a key saved, then removed again
            model.ui.keyDraft = n % 2 == 0 ? "sk_\(n)" : ""
            model.storeKey()
        }
        let monitor = ResourceMonitor()
        for _ in 0..<300 { monitor.start(log: log) { false } }
        monitor.stop()
        for _ in 0..<50 { await Task.yield() }
        await log.flush()
        let after = (threads: threads(), mb: try await footprint())
        #expect(after.threads <= before.threads + 32, "threads \(before.threads) -> \(after.threads)")
        #expect(after.mb < before.mb + 300, "memory \(before.mb) -> \(after.mb) MB")
    }

    private func footprint() async throws -> Double {
        Double(try await ResourceProbe.sample().footprintBytes) / 1_048_576
    }
}
