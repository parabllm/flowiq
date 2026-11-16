// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Shared fixtures for the P4 acceptance tests (dictation: Fn tap, gestures, recognition, insertion).
//
// RULE: every line that touches an API shape the architecture leaves open carries "ASSUMPTION:" in the same
// line. The build agent may change ONLY those lines (names, labels, argument order, import lines). Expected
// values in the test files are fixed and must never be touched.
//
// Nothing here posts a real key event, opens a microphone, writes the real pasteboard or needs a permission.
// All outside world sits behind seams, and every wait goes through ONE injected virtual clock:
//   key events      -> SyntheticKeySource   (a KeyEventSource driven by the test, on its own "tap" thread)
//   microphone      -> P4Mic                (a CaptureSource; the real AudioConductor and TrackWriter run on top)
//   recognizer      -> StubRecognizer       (a DictationRecognizer that records every chunk it gets)
//   text stage      -> StubText             (a TextProcessing with scripted interventions)
//   pasteboard      -> FakePasteboard       (a PasteboardPort with promise data, change count, items of many types)
//   target app      -> FakeTarget           (KeyPosting + FocusProbing + FrontAppProbing; "fetches" like a real app)
//   pill            -> PillRecorder         (a PillSink)
// The contract behind the virtual clock: no component may wait with Task.sleep or DispatchQueue.after; every
// wait (tail, tap window, probe deadline, restore delay, mic start) uses the `Clock` it was given.
import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing
@testable import FlowIQ  // ASSUMPTION: FlowCoordinator (A.12) lives in the app target and is reachable via @testable import
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQInput
@testable import FlowIQInsert
@testable import FlowIQLog
@testable import FlowIQRecording
@testable import FlowIQSpeech  // ASSUMPTION: DictationRecognizer and DictationRun are public in FlowIQSpeech (A.6)
@testable import FlowIQStore
import FlowIQText

extension Tag {
    @Tag static var slow: Self
}

// MARK: - Assumed API surface of P4 (one place to adapt; shapes only, no behaviour)
//
//  FlowIQInput    PhysicalKey { trigger, space, escape, v, other }          KeyModifiers: OptionSet
//                 KeyEvent(key, down:, modifiers:, at:)  at = nanoseconds    InputAction { start, stop, lock, cancel,
//                 chordAbort, reinsert }  GestureMachine(profile:) with handle(_:), tick(now:), keySinceInsert,
//                 noteInsert()  KeyEventSource  InputService(...)  PillSink / PillState  KeyMapper
//  FlowIQInsert   FocusState, FocusProbing, PasteboardPort, PasteboardSnapshot, KeyPosting, FrontAppProbing,
//                 InsertResult, Inserter
//  FlowIQSpeech   DictationRecognizer, DictationRun (seen from the app target)
//  FlowIQStore    DictationJournal (append-only JSONL under paths.diktate)
//  FlowIQ (app)   FlowCoordinator, TextProcessing, ProcessedText, RawResult

/// Fixed test devices.
enum P4Devices {
    static let builtIn = InputDevice(uid: "p4-builtin", isBuiltIn: true)
    static let airpods = InputDevice(uid: "p4-airpods", isBuiltIn: false, isBluetooth: true)
}

/// Journal vocabulary. Event names are fixed by A.9; the key names are the open part.
enum JE {
    static let begin = "begin", audio = "audio", audioLost = "audio_lost", recognized = "recognized"
    static let inserted = "inserted", retry = "retry", reject = "reject"
}

enum JK {
    static let event = "event"  // ASSUMPTION: key holding the event name of a journal line
    static let id = "id"  // ASSUMPTION: key holding the dictation id on every line
    static let time = "ts"  // ASSUMPTION: key holding the line's wall-clock time as a number (seconds since 1970)
    static let recognizerText = "recognizer_text"  // ASSUMPTION: recognizer text before any stage
    static let finalText = "final_text"  // ASSUMPTION: text after the stage
    static let interventions = "interventions"  // ASSUMPTION: array with one entry per applied intervention
    static let recognizeMs = "recognize_ms"  // ASSUMPTION: milliseconds from stream closed to recognition done
    static let stageMs = "stage_ms"  // ASSUMPTION: milliseconds of the text stage
    static let result = "result"  // ASSUMPTION: insert result raw value on `inserted`
    static let bytes = "bytes"  // ASSUMPTION: audio size on `audio`
    static let seconds = "seconds"  // ASSUMPTION: audio duration on `audio`
    static let verdict = "verdict"  // ASSUMPTION: size check verdict raw value on `audio`
    static let endReason = "end_reason"  // ASSUMPTION: EndReason raw value on `audio`
    static let rejected = "interventions_rejected"  // ASSUMPTION: count of rejected interventions on `reject`
}

// MARK: - Virtual clock

struct ManualInstant: InstantProtocol {
    typealias Duration = Swift.Duration
    var offset: Swift.Duration
    func advanced(by duration: Swift.Duration) -> Self { Self(offset: offset + duration) }
    func duration(to other: Self) -> Swift.Duration { other.offset - offset }
    static func < (a: Self, b: Self) -> Bool { a.offset < b.offset }
}

extension Duration {
    var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
    var nanos: UInt64 { UInt64(max(0, Double(components.seconds) * 1e9 + Double(components.attoseconds) / 1e9)) }
}

/// A clock that only moves when the test says so. `run(for:)` wakes sleepers in deadline order and lets the
/// woken work (which may register new sleepers) settle before it moves on.
final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = ManualInstant

    private struct Sleeper {
        let id: Int
        let deadline: Swift.Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Swift.Duration.seconds(1)
        var sleepers: [Sleeper] = []
        var nextID = 0
    }

    private enum Plan { case resume, cancel, wait }

    private let state = Mutex(State())

    var now: ManualInstant { ManualInstant(offset: state.withLock { $0.now }) }
    var nowNanos: UInt64 { state.withLock { $0.now }.nanos }
    var minimumResolution: Swift.Duration { .nanoseconds(1) }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: ManualInstant, tolerance: Swift.Duration? = nil) async throws {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let plan = state.withLock { s -> Plan in
                    if Task.isCancelled { return .cancel }
                    if deadline.offset <= s.now { return .resume }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline.offset, continuation: continuation))
                    return .wait
                }
                switch plan {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let waiting = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index).continuation
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    /// Lets real work run: yields, then waits until the sleeper list stops changing.
    func settle() async {
        for _ in 0..<8 { await Task.yield() }
        var stable = 0
        var last = sleeperCount
        while stable < 3 {
            await realPause(.milliseconds(2))
            let current = sleeperCount
            stable = current == last ? stable + 1 : 0
            last = current
        }
    }

    /// Moves virtual time forward by `span`, waking every sleeper whose deadline falls inside.
    func run(for span: Swift.Duration) async {
        let target = state.withLock { $0.now } + span
        await settle()
        while true {
            let due = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                let candidates = s.sleepers.enumerated().filter { $0.element.deadline <= target }
                guard let first = candidates.min(by: { $0.element.deadline < $1.element.deadline }) else {
                    s.now = target
                    return nil
                }
                s.now = max(s.now, first.element.deadline)
                return s.sleepers.remove(at: first.offset).continuation
            }
            guard let due else { break }
            due.resume()
            await settle()
        }
    }

    /// Real-time wait until at least `count` sleepers are registered (work that must use the clock did so).
    func waitForSleepers(atLeast count: Int, timeout: Swift.Duration = .seconds(3)) async -> Bool {
        await eventually(timeout: timeout) { sleeperCount >= count }
    }
}

func realPause(_ duration: Swift.Duration) async {
    do { try await ContinuousClock().sleep(for: duration) } catch { Issue.record("pause interrupted: \(error)") }
}

/// Polls `condition` in REAL time until true or `timeout` passes.
func eventually(timeout: Swift.Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await realPause(.milliseconds(5))
    }
    return await condition()
}

// MARK: - Trace

/// Ordered record of what the seams saw: name, virtual time, and whether the call ran on the main thread.
final class Trace: Sendable {
    struct Entry: Sendable {
        let seq: Int
        let name: String
        let virtual: Swift.Duration
        let onMain: Bool
    }

    let clock: ManualClock
    private let list = Mutex<[Entry]>([])

    init(clock: ManualClock) { self.clock = clock }

    func add(_ name: String) {
        let onMain = pthread_main_np() != 0
        let virtual = clock.now.offset
        list.withLock { $0.append(Entry(seq: $0.count, name: name, virtual: virtual, onMain: onMain)) }
    }

    var entries: [Entry] { list.withLock { $0 } }
    func first(_ prefix: String) -> Entry? { entries.first { $0.name.hasPrefix(prefix) } }
    func all(_ prefix: String) -> [Entry] { entries.filter { $0.name.hasPrefix(prefix) } }
    var onMainThread: [String] { entries.filter(\.onMain).map(\.name) }
}

// MARK: - Key source, pill

final class SyntheticKeySource: KeyEventSource, Sendable {  // ASSUMPTION: protocol KeyEventSource { start(_ handler:) throws; stop() }
    private let queue = DispatchQueue(label: "flowiq.test.tap")
    private let handler = Mutex<(@Sendable (KeyEvent) -> Void)?>(nil)

    func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws {  // ASSUMPTION: start(_:) hands the callback over
        self.handler.withLock { $0 = handler }
    }

    func stop() { handler.withLock { $0 = nil } }

    /// Delivers one event on the tap thread and returns how long the callback took in REAL time.
    @discardableResult
    func send(_ event: KeyEvent) -> Swift.Duration {
        let callback = handler.withLock { $0 }
        let done = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        queue.async {
            callback?(event)
            done.signal()
        }
        done.wait()
        return ContinuousClock.now - started
    }
}

final class PillRecorder: PillSink, Sendable {  // ASSUMPTION: protocol PillSink { func set(_ state: PillState) }, callable from any thread
    struct Change: Sendable {
        let state: PillState  // ASSUMPTION: PillState { hidden, dictating, notInserted, failed }, Equatable
        let real: ContinuousClock.Instant
    }

    private let trace: Trace
    private let list = Mutex<[Change]>([])

    init(trace: Trace) { self.trace = trace }

    func set(_ state: PillState) {  // ASSUMPTION: PillState
        trace.add("pill.\(state)")
        list.withLock { $0.append(Change(state: state, real: ContinuousClock.now)) }
    }

    var changes: [Change] { list.withLock { $0 } }
    var last: PillState? { list.withLock { $0.last?.state } }  // ASSUMPTION: PillState
}

// MARK: - Synthetic microphone

final class P4Mic: CaptureSource, Sendable {
    struct Options: Sendable {
        /// Virtual time `start` takes (the capture session starting up). Chunks may arrive while it runs.
        var startDelay: Swift.Duration = .zero
        /// REAL time `start` blocks its thread (Panotti: 130 ms on the main thread).
        var blockStartReal: Swift.Duration = .zero
        var refuseStart = false
        init() {}
    }

    enum Phase: Sendable, Equatable { case idle, starting, running, stopping, stopped }
    struct Counts: Sendable { var starts = 0, stopsBegun = 0, delivered = 0, droppedAfterStop = 0 }

    private struct State {
        var phase = Phase.idle
        var deliver: (@Sendable (AudioChunk) -> Void)?
        var counts = Counts()
    }

    let kind: SourceKind
    private let options: Options
    private let clock: ManualClock
    private let trace: Trace
    private let state = Mutex(State())

    init(device: InputDevice, options: Options, clock: ManualClock, trace: Trace) {
        kind = .microphone(device)
        self.options = options
        self.clock = clock
        self.trace = trace
    }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        trace.add("mic.start.begin")
        state.withLock {
            $0.counts.starts += 1
            $0.phase = .starting
            $0.deliver = deliver
        }
        if options.blockStartReal > .zero { usleep(UInt32(options.blockStartReal.ms * 1000)) }
        if options.startDelay > .zero { try await clock.sleep(for: options.startDelay) }
        if options.refuseStart { throw AudioError.rejected }
        state.withLock { $0.phase = .running }
        trace.add("mic.start.end")
    }

    func stop() async {
        trace.add("mic.stop")
        state.withLock {
            $0.phase = .stopping
            $0.counts.stopsBegun += 1
        }
        state.withLock { $0.phase = .stopped }
    }

    /// A well-behaved delivery: only while starting, running or stopping.
    @discardableResult
    func emit(_ chunk: AudioChunk) -> Bool {
        let deliver: (@Sendable (AudioChunk) -> Void)? = state.withLock { s in
            guard s.phase == .starting || s.phase == .running || s.phase == .stopping else {
                s.counts.droppedAfterStop += 1
                return nil
            }
            s.counts.delivered += 1
            return s.deliver
        }
        deliver?(chunk)
        return deliver != nil
    }

    /// A late callback after `stop()` returned: the bug that emptied Panotti's dictation files.
    func emitRogue(_ chunk: AudioChunk) { state.withLock { $0.deliver }?(chunk) }

    var phase: Phase { state.withLock { $0.phase } }
    var counts: Counts { state.withLock { $0.counts } }
}

final class P4MicBox: Sendable {
    private let list = Mutex<[P4Mic]>([])
    private let optionsBox = Mutex(P4Mic.Options())
    let clock: ManualClock
    let trace: Trace

    init(clock: ManualClock, trace: Trace, options: P4Mic.Options) {
        self.clock = clock
        self.trace = trace
        optionsBox.withLock { $0 = options }
    }

    func set(_ options: P4Mic.Options) { optionsBox.withLock { $0 = options } }

    func make(_ device: InputDevice) -> P4Mic {
        trace.add("mic.factory")
        let source = P4Mic(device: device, options: optionsBox.withLock { $0 }, clock: clock, trace: trace)
        list.withLock { $0.append(source) }
        return source
    }

    var all: [P4Mic] { list.withLock { $0 } }
    var current: P4Mic? { list.withLock { $0.last } }
}

/// Desktop side of a call: delivers whatever the test emits, never refuses.
final class P4Desktop: CaptureSource, Sendable {
    let kind = SourceKind.desktop
    private let deliver = Mutex<(@Sendable (AudioChunk) -> Void)?>(nil)
    private let running = Mutex(false)

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        self.deliver.withLock { $0 = deliver }
        running.withLock { $0 = true }
    }

    func stop() async { running.withLock { $0 = false } }

    func emit(_ chunk: AudioChunk) {
        guard running.withLock({ $0 }) else { return }
        deliver.withLock { $0 }?(chunk)
    }
}

final class P4DesktopBox: Sendable {
    private let list = Mutex<[P4Desktop]>([])
    func make() -> P4Desktop {
        let source = P4Desktop()
        list.withLock { $0.append(source) }
        return source
    }
    var current: P4Desktop? { list.withLock { $0.last } }
}

// MARK: - Recognizer and text stage

final class StubRecognizer: DictationRecognizer, Sendable {  // ASSUMPTION: protocol DictationRecognizer { func dictate(_ chunks:) async -> DictationRun }
    struct Options: Sendable {
        /// Virtual time before the recognizer starts consuming (prepareToAnalyze: audio waits in the stream).
        var prepareDelay: Swift.Duration = .zero
        /// Virtual time from the end of the stream to the result.
        var finalizeDelay: Swift.Duration = .zero
        var fail = false
        init() {}
    }

    private struct State {
        var options = Options()
        var scripts: [String] = []
        var runs: [[AudioChunk]] = []
        var served = 0
    }

    private let clock: ManualClock
    private let trace: Trace
    private let state = Mutex(State())

    init(clock: ManualClock, trace: Trace, options: Options) {
        self.clock = clock
        self.trace = trace
        state.withLock { $0.options = options }
    }

    func set(_ options: Options) { state.withLock { $0.options = options } }
    /// Texts the next dictations will "hear", in order; afterwards a generic sentence per dictation.
    func script(_ texts: [String]) { state.withLock { $0.scripts.append(contentsOf: texts) } }
    /// Chunks per finished dictation, in dictation order.
    var runs: [[AudioChunk]] { state.withLock { $0.runs } }

    func dictate(_ chunks: AsyncStream<AudioChunk>) async -> DictationRun {  // ASSUMPTION: dictate(_:) async -> DictationRun
        trace.add("recognizer.dictate")
        let options = state.withLock { $0.options }
        if options.prepareDelay > .zero { await sleepQuietly(options.prepareDelay) }
        trace.add("recognizer.attached")
        var got: [AudioChunk] = []
        for await chunk in chunks { got.append(chunk) }
        trace.add("recognizer.closed")
        if options.finalizeDelay > .zero { await sleepQuietly(options.finalizeDelay) }
        let text = state.withLock { s -> String in
            s.runs.append(got)
            s.served += 1
            return s.scripts.isEmpty ? "das ist flowiq probesatz nummer \(s.served)" : s.scripts.removeFirst()
        }
        trace.add("recognizer.done")
        if options.fail { return DictationRun(recognition: nil, failure: "synthetic recognizer failure") }  // ASSUMPTION: DictationRun(recognition:failure:)
        return DictationRun(recognition: Recognition(text: text, recognizerProfile: "stub"), failure: nil)  // ASSUMPTION: DictationRun(recognition:failure:)
    }

    private func sleepQuietly(_ span: Swift.Duration) async {
        do { try await clock.sleep(for: span) } catch { return }
    }
}

struct StubText: TextProcessing {  // ASSUMPTION: protocol TextProcessing { func process(_ recognition: Recognition) async -> ProcessedText }
    let trace: Trace

    func process(_ recognition: Recognition) async -> ProcessedText {  // ASSUMPTION: ProcessedText
        trace.add("text.process")
        var text = recognition.text
        var rules: [String] = []
        for (spoken, written) in [("flowiq", "FlowIQ"), ("napiq", "NapIQ")] where text.contains(spoken) {
            text = text.replacingOccurrences(of: spoken, with: written)
            rules.append("R1")
        }
        return ProcessedText(text: text, interventions: rules)  // ASSUMPTION: ProcessedText(text:interventions:) with interventions as [String] of rule names
    }
}

// MARK: - Pasteboard and target app

enum FakeError: Error { case refused }

final class FakePasteboard: PasteboardPort, Sendable {  // ASSUMPTION: protocol PasteboardPort { changeCount, snapshot(), writePromise(_:onFetch:), restore(_:) }
    static let plain = "public.utf8-plain-text"

    private struct Promise {
        let text: String
        let onFetch: @Sendable () -> Void
    }

    private struct State {
        var items: [[String: Data]] = []
        var promise: Promise?
        var changeCount = 1
        var writes = 0
        var restores = 0
        var failSnapshot = false
        var failWrite = false
        var fetchedAt: Swift.Duration?
        var restoredAt: Swift.Duration?
    }

    private let trace: Trace
    private let state = Mutex(State())

    init(trace: Trace, items: [[String: Data]] = []) {
        self.trace = trace
        state.withLock { $0.items = items }
    }

    var changeCount: Int { state.withLock { $0.changeCount } }
    var items: [[String: Data]] { state.withLock { $0.items } }
    var hasPromise: Bool { state.withLock { $0.promise != nil } }
    var writes: Int { state.withLock { $0.writes } }
    var restores: Int { state.withLock { $0.restores } }
    var fetchedAt: Swift.Duration? { state.withLock { $0.fetchedAt } }
    var restoredAt: Swift.Duration? { state.withLock { $0.restoredAt } }
    func setFailSnapshot(_ value: Bool) { state.withLock { $0.failSnapshot = value } }
    func setFailWrite(_ value: Bool) { state.withLock { $0.failWrite = value } }

    func snapshot() throws -> PasteboardSnapshot {  // ASSUMPTION: PasteboardSnapshot(items:) holds every item with every type as bytes
        trace.add("pasteboard.snapshot")
        return try state.withLock { s in
            if s.failSnapshot { throw FakeError.refused }
            return PasteboardSnapshot(items: s.items)  // ASSUMPTION: PasteboardSnapshot(items:)
        }
    }

    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int {  // ASSUMPTION: writePromise(_:onFetch:) returns the change count after the own write
        trace.add("pasteboard.write")
        return try state.withLock { s in
            if s.failWrite { throw FakeError.refused }
            s.promise = Promise(text: text, onFetch: onFetch)
            s.items = []
            s.changeCount += 1
            s.writes += 1
            return s.changeCount
        }
    }

    func restore(_ snapshot: PasteboardSnapshot) throws {  // ASSUMPTION: restore(_:) puts every item back
        trace.add("pasteboard.restore")
        let at = trace.clock.now.offset
        state.withLock { s in
            s.items = snapshot.items  // ASSUMPTION: PasteboardSnapshot.items
            s.promise = nil
            s.changeCount += 1
            s.restores += 1
            s.restoredAt = at
        }
    }

    /// The target app asks for plain text. Promise data is handed out on demand; otherwise the old content.
    func fetchPlainText() -> String? {
        trace.add("pasteboard.fetch")
        let at = trace.clock.now.offset
        let (promise, old) = state.withLock { s -> (Promise?, Data?) in
            if s.promise != nil { s.fetchedAt = at }
            return (s.promise, s.items.first?[Self.plain])
        }
        if let promise {
            promise.onFetch()
            return promise.text
        }
        return old.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The user copies something else while the insertion is running.
    func userCopies(_ text: String) {
        state.withLock { s in
            s.items = [[Self.plain: Data(text.utf8)]]
            s.promise = nil
            s.changeCount += 1
        }
    }
}

/// A rich clipboard of the user: text, RTF bytes, a file reference and an image blob in two items.
func richClipboard() -> [[String: Data]] {
    [[FakePasteboard.plain: Data("alter Inhalt".utf8), "public.rtf": Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D]),
      "public.html": Data("<b>alt</b>".utf8)],
     ["public.file-url": Data("file:///tmp/p4-probe.txt".utf8), "public.png": Data((0..<64).map { UInt8($0) })]]
}

/// Stands in for the frontmost app: focus state, key posting, front app identity, secure input.
final class FakeTarget: KeyPosting, FocusProbing, FrontAppProbing, Sendable {  // ASSUMPTION: protocols KeyPosting { paste() throws; undo() throws }, FocusProbing { probe() async -> FocusState }, FrontAppProbing { frontmost() -> String?; secureInputActive }
    enum Kind: Sendable { case text, nonText, unreadable }

    private struct State {
        var field = ""
        var kind = Kind.text
        var frontApp = "app.target"
        var secure = false
        var fetchDelay = Swift.Duration.milliseconds(20)
        var neverFetch = false
        var failPaste = false
        var probeHangs = false
        var pasteCount = 0
        var undoCount = 0
        var posted: [String] = []
        var segments: [String] = []
        var beforePaste: (@Sendable () -> Void)?
    }

    private let clock: ManualClock
    private let trace: Trace
    private let pasteboard: FakePasteboard
    private let state = Mutex(State())

    init(clock: ManualClock, trace: Trace, pasteboard: FakePasteboard) {
        self.clock = clock
        self.trace = trace
        self.pasteboard = pasteboard
    }

    var field: String { state.withLock { $0.field } }
    var pasteCount: Int { state.withLock { $0.pasteCount } }
    var undoCount: Int { state.withLock { $0.undoCount } }
    /// Runs at the instant Cmd-V is posted (before the app could fetch anything).
    func onPaste(_ hook: @escaping @Sendable () -> Void) { state.withLock { $0.beforePaste = hook } }
    var posted: [String] { state.withLock { $0.posted } }
    func configure(_ change: (inout Configuration) -> Void) {
        state.withLock { s in
            var c = Configuration(field: s.field, kind: s.kind, frontApp: s.frontApp, secure: s.secure,
                                  fetchDelay: s.fetchDelay, neverFetch: s.neverFetch, failPaste: s.failPaste,
                                  probeHangs: s.probeHangs)
            change(&c)
            (s.field, s.kind, s.frontApp, s.secure) = (c.field, c.kind, c.frontApp, c.secure)
            (s.fetchDelay, s.neverFetch, s.failPaste, s.probeHangs) = (c.fetchDelay, c.neverFetch, c.failPaste, c.probeHangs)
        }
    }

    struct Configuration {
        var field: String
        var kind: Kind
        var frontApp: String
        var secure: Bool
        var fetchDelay: Swift.Duration
        var neverFetch: Bool
        var failPaste: Bool
        var probeHangs: Bool
    }

    func probe() async -> FocusState {  // ASSUMPTION: FocusState { textField(preceding: Character?), notTextField, unreadable }
        trace.add("focus.probe")
        if state.withLock({ $0.probeHangs }) {
            do { try await clock.sleep(for: .seconds(10)) } catch { return .unreadable }  // ASSUMPTION: FocusState.unreadable
        }
        let (kind, last) = state.withLock { ($0.kind, $0.field.last) }
        switch kind {
        case .text: return .textField(preceding: last)  // ASSUMPTION: FocusState.textField(preceding:)
        case .nonText: return .notTextField  // ASSUMPTION: FocusState.notTextField
        case .unreadable: return .unreadable  // ASSUMPTION: FocusState.unreadable
        }
    }

    func frontmost() -> String? { state.withLock { $0.frontApp } }  // ASSUMPTION: FrontAppProbing.frontmost() identifies the frontmost app
    var secureInputActive: Bool { state.withLock { $0.secure } }  // ASSUMPTION: FrontAppProbing.secureInputActive

    func paste() throws {
        trace.add("keys.paste")
        state.withLock { $0.beforePaste }?()
        let plan = state.withLock { s -> (fail: Bool, delivers: Bool, delay: Swift.Duration) in
            s.pasteCount += 1
            s.posted.append("paste")
            return (s.failPaste, s.kind != .nonText && !s.neverFetch, s.fetchDelay)
        }
        if plan.fail { throw FakeError.refused }
        guard plan.delivers else { return }
        Task {
            do { try await clock.sleep(for: plan.delay) } catch { return }
            let text = pasteboard.fetchPlainText() ?? ""
            state.withLock { s in
                s.field += text
                s.segments.append(text)
            }
        }
    }

    func undo() throws {
        trace.add("keys.undo")
        state.withLock { s in
            s.undoCount += 1
            s.posted.append("undo")
            guard let last = s.segments.popLast() else { return }
            s.field.removeLast(last.count)
        }
    }
}

// MARK: - Scratch, log, journal

final class P4Scratch: Sendable {
    let root: URL
    let paths: Paths
    let fs: SafeFS
    let log: EventLog

    var laufend: URL { paths.laufend }

    init(profile: Profile = .development) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p4-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = Paths(profile: profile, applicationSupport: root)
        let folders = [paths.support, paths.log, paths.laufend, paths.diktate]  // ASSUMPTION: Paths.diktate (listed in A.1, not yet in Paths.swift)
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        fs = SafeFS(paths: paths)
        log = EventLog(directory: paths.log)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
    }

    /// Whole protocol file as text (for text-free checks).
    func logText() async -> String {
        await log.flush()
        var text = ""
        for name in ["ereignisse.ndjson", "fehler.ndjson"] {
            let file = paths.log.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do { text += try String(contentsOf: file, encoding: .utf8) } catch { Issue.record("log unreadable: \(error)") }
        }
        return text
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

    func errorEvents() async -> Int {
        await log.flush()
        let file = paths.log.appending(path: "fehler.ndjson")
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        do { return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count } catch { return 0 }
    }

    // MARK: Journal and audio files

    func journalFiles() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: paths.diktate, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("journal-") && $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch { return [] }
    }

    func journalBytes() -> Data {
        var data = Data()
        for file in journalFiles() {
            do { data.append(try Data(contentsOf: file)) } catch { Issue.record("journal unreadable: \(error)") }
        }
        return data
    }

    func journal() -> [JournalLine] {
        String(decoding: journalBytes(), as: UTF8.self).split(separator: "\n").compactMap { line in
            let data = Data(line.utf8)
            do {
                guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                    Issue.record("journal line is not an object: \(line.prefix(60))")
                    return nil
                }
                return JournalLine(data)
            } catch {
                Issue.record("journal line is not valid JSON (cut off?): \(error)")
                return nil
            }
        }
    }

    /// Every `.aac` below `diktate/`, whatever the folder layout (`<year>/<month>/<id>.aac`).
    func audioFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: paths.diktate, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "aac" }
    }

    func audioFile(for id: String) -> URL? { audioFiles().first { $0.deletingPathExtension().lastPathComponent == id } }
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

    func double(_ key: String) -> Double? { fields[key].flatMap { Double($0) } }
    func int(_ key: String) -> Int? { fields[key].flatMap { Int($0) } }
}

/// One journal line as bytes (so it is Sendable); fields are read on demand.
struct JournalLine: Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }

    private var object: [String: Any] {
        do { return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] } catch { return [:] }
    }

    var event: String { string(JK.event) ?? "" }
    var id: String { string(JK.id) ?? "" }
    var time: Double? { number(JK.time) }
    func string(_ key: String) -> String? { object[key] as? String }
    func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
    func list(_ key: String) -> [Any]? { object[key] as? [Any] }
}

extension [JournalLine] {
    func lines(of id: String) -> [JournalLine] { filter { $0.id == id } }
    func ids() -> [String] {
        var seen = Set<String>()
        return compactMap { $0.event == JE.begin && seen.insert($0.id).inserted ? $0.id : nil }
    }
}

// MARK: - The rig

/// Everything wired like the app: synthetic keys -> InputService -> FlowCoordinator -> real AudioConductor with
/// a synthetic microphone, stub recognizer and text stage, real TrackWriter and journal, Inserter on fakes.
final class DictationRig: Sendable {
    let scratch: P4Scratch
    let clock: ManualClock
    let trace: Trace
    let mics: P4MicBox
    let desktops: P4DesktopBox
    let conductor: AudioConductor
    let recognizer: StubRecognizer
    let pasteboard: FakePasteboard
    let target: FakeTarget
    let pill: PillRecorder
    let keySource: SyntheticKeySource
    let input: InputService
    let inserter: Inserter
    let journal: DictationJournal
    let busy: BusyState
    let coordinator: FlowCoordinator
    let lock: RecordingLock
    let profile: Profile
    private let pump: Task<Void, Never>

    init(profile: Profile = .development, standard: InputDevice = P4Devices.builtIn,
         fallback: InputDevice? = P4Devices.builtIn, mic: P4Mic.Options = .init(),
         recognizer options: StubRecognizer.Options = .init(), clipboard: [[String: Data]] = []) throws {
        let scratch = try P4Scratch(profile: profile)
        let clock = ManualClock()
        let trace = Trace(clock: clock)
        let mics = P4MicBox(clock: clock, trace: trace, options: mic)
        let desktops = P4DesktopBox()
        let pasteboard = FakePasteboard(trace: trace, items: clipboard)
        let target = FakeTarget(clock: clock, trace: trace, pasteboard: pasteboard)
        let pill = PillRecorder(trace: trace)
        let keySource = SyntheticKeySource()
        let recognizer = StubRecognizer(clock: clock, trace: trace, options: options)
        let conductor = AudioConductor(
            microphone: { mics.make($0) }, desktop: { desktops.make() },
            devices: DeviceSetup(standard: standard, fallback: fallback), log: scratch.log)
        let busy = BusyState(paths: scratch.paths, fs: scratch.fs)
        let journal = DictationJournal(paths: scratch.paths, fs: scratch.fs, log: scratch.log)  // ASSUMPTION: DictationJournal(paths:fs:log:)
        let input = InputService(source: keySource, profile: profile, clock: clock, pill: pill, log: scratch.log)  // ASSUMPTION: InputService(source:profile:clock:pill:log:)
        let inserter = Inserter(focus: target, pasteboard: pasteboard, keys: target, front: target, clock: clock, log: scratch.log)  // ASSUMPTION: Inserter(focus:pasteboard:keys:front:clock:log:)
        let coordinator = FlowCoordinator(  // ASSUMPTION: FlowCoordinator(paths:fs:conductor:recognizer:text:inserter:journal:busy:input:pill:log:clock:)
            paths: scratch.paths, fs: scratch.fs, conductor: conductor, recognizer: recognizer,
            text: StubText(trace: trace), inserter: inserter, journal: journal, busy: busy, input: input,
            pill: pill, log: scratch.log, clock: clock)
        lock = try RecordingLock.acquire(in: scratch.laufend)
        self.scratch = scratch
        self.clock = clock
        self.trace = trace
        self.mics = mics
        self.desktops = desktops
        self.conductor = conductor
        self.recognizer = recognizer
        self.pasteboard = pasteboard
        self.target = target
        self.pill = pill
        self.keySource = keySource
        self.input = input
        self.inserter = inserter
        self.journal = journal
        self.busy = busy
        self.coordinator = coordinator
        self.profile = profile
        try input.start()  // ASSUMPTION: InputService.start() throws when the tap cannot be installed
        pump = Task { for await item in input.stream { await coordinator.handle(item) } }  // ASSUMPTION: InputService.stream delivers InputEnvelope values; FlowCoordinator.handle(_:)
    }

    func remove() {
        pump.cancel()
        lock.release()
        scratch.remove()
    }

    // MARK: Keys

    @discardableResult
    func key(_ key: PhysicalKey, down: Bool, modifiers: KeyModifiers = []) -> Swift.Duration {
        keySource.send(KeyEvent(key, down: down, modifiers: modifiers, at: clock.nowNanos))  // ASSUMPTION: KeyEvent(_:down:modifiers:at:)
    }

    /// Trigger down. Returns the real time the callback took.
    @discardableResult
    func press() -> Swift.Duration { key(.trigger, down: true) }

    /// Trigger up. With `waitForTail` it waits (real time) until the coordinator registered its tail wait on the
    /// virtual clock, so the test's next `run(for:)` measures from the key-up instant.
    func release(waitForTail: Bool = true) async {
        let before = clock.sleeperCount
        key(.trigger, down: false)
        if waitForTail { _ = await clock.waitForSleepers(atLeast: before + 1) }
    }

    func tap(_ key: PhysicalKey, modifiers: KeyModifiers = []) {
        self.key(key, down: true, modifiers: modifiers)
        self.key(key, down: false, modifiers: modifiers)
    }

    // MARK: Audio

    /// Waits until a microphone source created after the first `count` ones has begun its start.
    func awaitMicOpen(after count: Int = 0) async -> Bool {
        await eventually { mics.all.count > count && (mics.current?.counts.starts ?? 0) >= 1 }
    }

    /// Emits chunks of `step` seconds for `seconds` into the current microphone, advancing the virtual clock after
    /// each. Returns the chunks as emitted (hostTime is the virtual time in nanoseconds).
    @discardableResult
    func speak(_ seconds: Double, step: Double = 0.05, hz: Double = 300) async -> [AudioChunk] {
        guard let source = mics.current else {
            Issue.record("speak: no microphone source exists")
            return []
        }
        var sent: [AudioChunk] = []
        for index in 0..<Int((seconds / step).rounded()) {
            let c = toneChunk(at: clock.nowNanos, seconds: step, hz: hz + Double(index % 16) * 25)
            if source.emit(c) { sent.append(c) }
            await clock.run(for: .seconds(step))
        }
        return sent
    }

    /// Waits until the current microphone source is open for chunks (starting or running).
    func awaitLiveMic() async -> Bool {
        await eventually {
            let phase = mics.current?.phase
            return phase == .starting || phase == .running
        }
    }

    /// Runs the virtual clock until the coordinator has nothing running. False when `limit` passes first.
    @discardableResult
    func settle(limit: Swift.Duration = .seconds(20)) async -> Bool {
        var spent = Swift.Duration.zero
        while spent < limit {
            if await coordinator.isIdle { return true }  // ASSUMPTION: FlowCoordinator.isIdle is true when no dictation is running or finishing
            await clock.run(for: .milliseconds(20))
            spent += .milliseconds(20)
        }
        return await coordinator.isIdle
    }

    /// Moves the virtual clock in 20 ms steps until `condition` holds (true) or `limit` passes (false).
    @discardableResult
    func run(until condition: () async -> Bool, limit: Swift.Duration = .seconds(10)) async -> Bool {
        var spent = Swift.Duration.zero
        while spent < limit {
            if await condition() { return true }
            await clock.run(for: .milliseconds(20))
            spent += .milliseconds(20)
        }
        return await condition()
    }

    /// Runs `work` while the virtual clock moves on; returns its value (nil when `limit` passes first).
    func drive<T: Sendable>(limit: Swift.Duration = .seconds(10), _ work: @escaping @Sendable () async -> T) async -> T? {
        let result = Mutex<T?>(nil)
        let task = Task { let value = await work(); result.withLock { $0 = value } }
        var spent = Swift.Duration.zero
        while spent < limit {
            await clock.run(for: .milliseconds(10))
            spent += .milliseconds(10)
            if let value = result.withLock({ $0 }) { return value }
        }
        task.cancel()
        return nil
    }

    /// One whole dictation: press, wait for the mic, speak, release, finish. Returns what the test needs.
    @discardableResult
    func dictate(seconds: Double = 0.6, step: Double = 0.05) async -> DictationOutcome {
        let pressedAt = clock.now.offset
        let sources = mics.all.count
        press()
        let opened = await awaitMicOpen(after: sources)
        let sent = await speak(seconds, step: step)
        let releasedAt = clock.now.offset
        await release()
        let finished = await settle()
        return DictationOutcome(opened: opened, finished: finished, sent: sent, pressedAt: pressedAt, releasedAt: releasedAt)
    }
}

struct DictationOutcome {
    let opened: Bool
    let finished: Bool
    let sent: [AudioChunk]
    let pressedAt: Swift.Duration
    let releasedAt: Swift.Duration
}

// MARK: - Signals and files

enum Signal {
    static let rate = 48_000.0
}

func toneChunk(at nanos: UInt64, seconds: Double, hz: Double = 300, amp: Float = 0.3) -> AudioChunk {
    let first = Int((Double(nanos) * Signal.rate / 1e9).rounded())
    let samples = (0..<Int((seconds * Signal.rate).rounded())).map {
        amp * Float(sin(2 * Double.pi * hz * Double(first + $0) / Signal.rate))
    }
    return AudioChunk(hostTime: nanos, sampleRate: Signal.rate, samples: samples)
}

func fileSize(_ url: URL) -> Int {
    do { return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 } catch { return -1 }
}

func audioDuration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

/// Seconds covered by chunks (sum of lengths).
func seconds(of chunks: [AudioChunk]) -> Double { chunks.reduce(0) { $0 + Double($1.samples.count) / $1.sampleRate } }

/// Percentile by nearest rank on a list of values.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = Int((Double(sorted.count) * p).rounded(.up))
    return sorted[min(sorted.count - 1, max(0, rank - 1))]
}

/// Deterministic pseudo random numbers for the randomized runs.
struct Lcg {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return range.lowerBound + Int((state >> 33) % UInt64(range.upperBound - range.lowerBound + 1))
    }
}

// MARK: - Insert-only rig (no audio, no input)

final class InsertRig: Sendable {
    let scratch: P4Scratch
    let clock: ManualClock
    let trace: Trace
    let pasteboard: FakePasteboard
    let target: FakeTarget
    let inserter: Inserter

    init(clipboard: [[String: Data]] = richClipboard()) throws {
        let scratch = try P4Scratch()
        let clock = ManualClock()
        let trace = Trace(clock: clock)
        let pasteboard = FakePasteboard(trace: trace, items: clipboard)
        let target = FakeTarget(clock: clock, trace: trace, pasteboard: pasteboard)
        self.scratch = scratch
        self.clock = clock
        self.trace = trace
        self.pasteboard = pasteboard
        self.target = target
        inserter = Inserter(focus: target, pasteboard: pasteboard, keys: target, front: target, clock: clock, log: scratch.log)  // ASSUMPTION: Inserter(focus:pasteboard:keys:front:clock:log:)
    }

    func remove() { scratch.remove() }

    /// Starts an insertion and runs the virtual clock until it returns (or `limit` passes).
    func insert(_ text: String, limit: Swift.Duration = .seconds(5)) async -> InsertResult? {  // ASSUMPTION: InsertResult
        let result = Mutex<InsertResult?>(nil)  // ASSUMPTION: InsertResult
        let task = Task {
            let value = await inserter.insert(text)  // ASSUMPTION: Inserter.insert(_:) async -> InsertResult
            result.withLock { $0 = value }
        }
        var spent = Swift.Duration.zero
        while spent < limit {
            await clock.run(for: .milliseconds(10))
            spent += .milliseconds(10)
            if let value = result.withLock({ $0 }) { return value }
        }
        task.cancel()
        return nil
    }

    /// Lets the virtual clock run on (restore delay, file work) after `insert` returned.
    func runOn(_ span: Swift.Duration = .seconds(3)) async { await clock.run(for: span) }
}
