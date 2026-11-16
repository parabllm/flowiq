// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Shared fixtures for the scenario acceptance tests (events x modes: simultaneity, failure and retry, display).
//
// RULE (same as p3 to p5): every line that touches an API shape the architecture leaves open carries
// "ASSUMPTION:" in the same line. The build agent may change ONLY those lines. Expected values in the test files
// are fixed; a wrong expectation goes to the owner.
//
// Nothing here opens a microphone or desktop capture, posts a key, touches the real pasteboard, the network, a
// mounted device or a permission. Everything outside sits behind the seams the other acceptance targets already use:
//   capture         -> SzSource            (CaptureSource; the real AudioConductor, Fanout, TrackWriter run on top)
//   keys            -> SyntheticKeySource  (KeyEventSource on its own "tap" thread; the real InputService on top)
//   recognizer      -> StubRecognizer      (DictationRecognizer)       text stage -> StubText
//   pasteboard      -> FakePasteboard      target app -> FakeTarget    pill -> PillRecorder
//   after-run       -> FakePost            (PostProcessor with a script of outcomes)
//   device          -> a plain temp folder (DeviceRig), never a mounted volume, never a real device name
//   every wait of dictation and insertion goes through ONE virtual clock (ManualClock)
// The targets of p3, p4, p5 and Tests/FlowIQDevicesTests are separate modules, so their fixtures are carried over
// here in trimmed form; names are the same where the shape is the same.
//
// Package.swift: needs a test target bound by path, suggested
//   .testTarget(name: "FlowIQSzenarienTests",
//               dependencies: [core, log, "FlowIQAudio", "FlowIQRecording", "FlowIQInput", "FlowIQInsert",
//                              "FlowIQSpeech", "FlowIQStore", "FlowIQText", "FlowIQDevices", "FlowIQCloud", "FlowIQ"],
//               path: "abnahme-tests/szenarien", exclude: ["README.md"], swiftSettings: strict)
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import FlowIQ  // ASSUMPTION: AppModel.alerts, StatusMenuModel, PillScene, Recorder are reachable via @testable import (as in FlowIQAppTests)
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQDevices
@testable import FlowIQInput
@testable import FlowIQInsert
@testable import FlowIQLog
@testable import FlowIQRecording
@testable import FlowIQSpeech
@testable import FlowIQStore
import FlowIQText

extension Tag {
    @Tag static var slow: Self
}

// MARK: - Devices and signals

enum Dev {
    static let builtIn = InputDevice(uid: "sz-builtin", isBuiltIn: true)
    static let airpods = InputDevice(uid: "sz-airpods", isBuiltIn: false, isBluetooth: true)
    static let usb = InputDevice(uid: "sz-usb", isBuiltIn: false)
}

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

func seconds(of chunks: [AudioChunk]) -> Double { chunks.reduce(0) { $0 + Double($1.samples.count) / $1.sampleRate } }

func fileSize(_ url: URL) -> Int {
    do { return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 } catch { return -1 }
}

func audioDuration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)  // ASSUMPTION: AVAudioFile reads raw ADTS .aac and .m4a lengths in the test environment
    return Double(file.length) / file.processingFormat.sampleRate
}

func names(in folder: URL) -> [String] {
    do { return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted() } catch { return [] }
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

/// A clock that only moves when the test says so; `run(for:)` wakes sleepers in deadline order.
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

// MARK: - Scratch, log, journal

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
    private var object: [String: Any] {
        do { return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] } catch { return [:] }
    }

    var event: String { string("event") ?? "" }  // ASSUMPTION: journal key "event" names the line (A.9)
    var id: String { string("id") ?? "" }  // ASSUMPTION: journal key "id" is the dictation id
    func string(_ key: String) -> String? { object[key] as? String }
    func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
}

final class Scratch: Sendable {
    let root: URL
    let paths: Paths
    let fs: SafeFS
    let log: EventLog

    var laufend: URL { paths.laufend }
    var delivered: URL { paths.support.appending(path: "abgeliefert", directoryHint: .isDirectory) }

    init(profile: Profile = .development) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-sz-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = Paths(profile: profile, applicationSupport: root)
        for folder in [paths.support, paths.log, paths.laufend, paths.diktate,  // ASSUMPTION: delivered spelled out, self is not complete here
                       paths.support.appending(path: "abgeliefert", directoryHint: .isDirectory)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        fs = SafeFS(paths: paths)
        log = EventLog(directory: paths.log, fs: fs)
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

    func errors(_ prefix: String = "") async -> [LoggedEvent] {
        await events().filter { $0.level == "error" && $0.kind.hasPrefix(prefix) }
    }

    /// Whole protocol as text, for the text-free check.
    func logText() async -> String {
        await log.flush()
        var text = ""
        for name in names(in: paths.log) {
            do { text += try String(contentsOf: paths.log.appending(path: name), encoding: .utf8) } catch { Issue.record("log unreadable: \(error)") }
        }
        return text
    }

    func journal() -> [JournalLine] {
        var all: [JournalLine] = []
        for name in names(in: paths.diktate) where name.hasPrefix("journal-") && name.hasSuffix(".jsonl") {
            do {
                let data = try Data(contentsOf: paths.diktate.appending(path: name))
                all += data.split(separator: 0x0A).map { JournalLine(data: Data($0)) }
            } catch { Issue.record("journal unreadable: \(error)") }
        }
        return all
    }

    func journal(of id: String) -> [JournalLine] { journal().filter { $0.id == id } }

    func dictationIDs() -> [String] {
        var seen = Set<String>()
        return journal().compactMap { $0.event == "begin" && seen.insert($0.id).inserted ? $0.id : nil }
    }

    func audioFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: paths.diktate, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "aac" }
    }

    func audioFile(for id: String) -> URL? { audioFiles().first { $0.deletingPathExtension().lastPathComponent == id } }
}

// MARK: - Synthetic capture sources

/// One capture source (microphone or desktop). Honours "after stop() no chunk arrives" and can end by itself.
final class SzSource: CaptureSource, Sendable {
    struct Options: Sendable {
        /// Virtual time `start` takes (the capture session starting up).
        var startDelay: Swift.Duration = .zero
        var refuseStart = false
        init() {}
    }

    enum Phase: Sendable, Equatable { case idle, starting, running, stopping, stopped }
    struct Counts: Sendable { var starts = 0, stopsBegun = 0, delivered = 0, droppedAfterStop = 0 }

    private struct State {
        var phase = Phase.idle
        var deliver: (@Sendable (AudioChunk) -> Void)?
        var onEnd: (@Sendable (CaptureEnd) -> Void)?
        var counts = Counts()
    }

    let kind: SourceKind
    private let options: Options
    private let clock: ManualClock
    private let state = Mutex(State())

    init(kind: SourceKind, options: Options, clock: ManualClock) {
        (self.kind, self.options, self.clock) = (kind, options, clock)
    }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        state.withLock {
            $0.counts.starts += 1
            $0.phase = .starting
            $0.deliver = deliver
            $0.onEnd = onEnd
        }
        if options.startDelay > .zero { try await clock.sleep(for: options.startDelay) }
        if options.refuseStart {
            state.withLock { $0.phase = .stopped }
            throw AudioError.rejected
        }
        state.withLock { $0.phase = .running }
    }

    func stop() async {
        state.withLock {
            $0.phase = .stopping
            $0.counts.stopsBegun += 1
        }
        state.withLock { $0.phase = .stopped }
    }

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

    /// The source ends by itself (device removed, stream stopped, permission withdrawn).
    func fail(_ message: String) {
        let onEnd = state.withLock { s -> (@Sendable (CaptureEnd) -> Void)? in
            s.phase = .stopped
            return s.onEnd
        }
        onEnd?(.failed(message))
    }

    var phase: Phase { state.withLock { $0.phase } }
    var counts: Counts { state.withLock { $0.counts } }
}

/// Creates the conductor's sources and lets a test change what the next ones do.
final class SourceBox: Sendable {
    struct Plan: Sendable {
        var mic = SzSource.Options()
        var desktop = SzSource.Options()
        init() {}
    }

    private struct State {
        var mics: [SzSource] = [], desktops: [SzSource] = [], plan = Plan()
    }

    let clock: ManualClock
    private let state = Mutex(State())

    init(clock: ManualClock, plan: Plan) {
        self.clock = clock
        state.withLock { $0.plan = plan }
    }

    func set(_ edit: (inout Plan) -> Void) { state.withLock { edit(&$0.plan) } }

    func makeMic(_ device: InputDevice) -> SzSource {
        let plan = state.withLock { $0.plan }
        let source = SzSource(kind: .microphone(device), options: plan.mic, clock: clock)
        state.withLock { $0.mics.append(source) }
        return source
    }

    func makeDesktop() -> SzSource {
        let plan = state.withLock { $0.plan }
        let source = SzSource(kind: .desktop, options: plan.desktop, clock: clock)
        state.withLock { $0.desktops.append(source) }
        return source
    }

    var allMics: [SzSource] { state.withLock { $0.mics } }
    var currentMic: SzSource? { state.withLock { $0.mics.last } }
    var allDesktops: [SzSource] { state.withLock { $0.desktops } }
    var currentDesktop: SzSource? { state.withLock { $0.desktops.last } }
}

/// What the conductor tells the pill and the menu (`AudioEvent`), collected for the test.
actor AudioEventBox {
    private(set) var list: [AudioEvent] = []
    func add(_ event: AudioEvent) { list.append(event) }
}

final class EventTap: Sendable {
    let box = AudioEventBox()
    private let reader: Task<Void, Never>

    init(_ stream: AsyncStream<AudioEvent>) {
        let box = box
        reader = Task { for await event in stream { await box.add(event) } }
    }

    var events: [AudioEvent] { get async { await box.list } }
    func stop() { reader.cancel() }
}

/// Free bytes on the volume as the test says them, changeable while a session runs.
final class FreeSpace: Sendable {
    private let value: Mutex<Int64?>
    init(_ bytes: Int64?) { value = Mutex(bytes) }
    func set(_ bytes: Int64?) { value.withLock { $0 = bytes } }
    var answer: RecordingSession.FreeSpace { { [self] _ in value.withLock { $0 } } }
}

// MARK: - Key source, pill, recognizer, text stage

final class SyntheticKeySource: KeyEventSource, Sendable {
    private let queue = DispatchQueue(label: "flowiq.sz.tap")
    private let handler = Mutex<(@Sendable (KeyEvent) -> Void)?>(nil)

    func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws { self.handler.withLock { $0 = handler } }
    func stop() { handler.withLock { $0 = nil } }

    func send(_ event: KeyEvent) {
        let callback = handler.withLock { $0 }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            callback?(event)
            done.signal()
        }
        done.wait()
    }
}

final class PillRecorder: PillSink, Sendable {
    private let list = Mutex<[PillState]>([])
    func set(_ state: PillState) { list.withLock { $0.append(state) } }
    var states: [PillState] { list.withLock { $0 } }
    var last: PillState? { list.withLock { $0.last } }
}

final class StubRecognizer: DictationRecognizer, Sendable {
    private struct State {
        var fail = false, scripts: [String] = [], runs: [[AudioChunk]] = [], served = 0
    }

    private let state = Mutex(State())

    func setFail(_ on: Bool) { state.withLock { $0.fail = on } }
    func script(_ texts: [String]) { state.withLock { $0.scripts.append(contentsOf: texts) } }
    var runs: [[AudioChunk]] { state.withLock { $0.runs } }

    func dictate(_ chunks: AsyncStream<AudioChunk>) async -> DictationRun {  // ASSUMPTION: DictationRecognizer.dictate(_:) async -> DictationRun
        var got: [AudioChunk] = []
        for await chunk in chunks { got.append(chunk) }
        let (text, fail) = state.withLock { s -> (String, Bool) in
            s.runs.append(got)
            s.served += 1
            return (s.scripts.isEmpty ? "satz nummer \(s.served)" : s.scripts.removeFirst(), s.fail)
        }
        if fail { return DictationRun(recognition: nil, failure: "synthetic recognizer failure") }  // ASSUMPTION: DictationRun(recognition:failure:)
        return DictationRun(recognition: Recognition(text: text, recognizerProfile: "stub"), failure: nil)
    }
}

extension StubRecognizer {
    /// The file run over a spool file (the retry seam): text when the file exists and has bytes, else a failure.
    func recognizeFile(_ url: URL) async -> DictationRun {
        guard fileSize(url) > 0 else { return DictationRun(recognition: nil, failure: "no_file") }
        return DictationRun(recognition: Recognition(text: "aus der datei", recognizerProfile: "stub-file"), failure: nil)
    }
}

struct StubText: TextProcessing {
    func process(_ recognition: Recognition) async -> ProcessedText {  // ASSUMPTION: TextProcessing.process(_:) async -> ProcessedText
        ProcessedText(text: recognition.text, interventions: [])
    }
}

/// What a running call or room learns of a dictation (R-102): the windows and the inserted jobs.
final class WindowRecorder: DictationObserver, Sendable {  // ASSUMPTION: DictationObserver { window(started:host:), inserted(_:) } as in DictationTypes.swift
    private let list = Mutex<[(started: Bool, host: UInt64)]>([])
    private let jobs = Mutex<[DictationJob]>([])
    func window(started: Bool, host: UInt64) async { list.withLock { $0.append((started, host)) } }
    func inserted(_ job: DictationJob) async { jobs.withLock { $0.append(job) } }
    var windows: [(started: Bool, host: UInt64)] { list.withLock { $0 } }
    var insertedJobs: [DictationJob] { jobs.withLock { $0 } }
}

// MARK: - Pasteboard and target app

enum FakeError: Error { case refused }

final class FakePasteboard: PasteboardPort, Sendable {
    private struct Promise {
        let text: String
        let onFetch: @Sendable () -> Void
    }

    private struct State {
        var items: [[String: Data]] = []
        var promise: Promise?
        var changeCount = 1, writes = 0
    }

    private let state = Mutex(State())
    var changeCount: Int { state.withLock { $0.changeCount } }
    var writes: Int { state.withLock { $0.writes } }

    func snapshot() throws -> PasteboardSnapshot { PasteboardSnapshot(items: state.withLock { $0.items }) }

    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int {
        state.withLock { s in
            s.promise = Promise(text: text, onFetch: onFetch)
            s.items = []
            s.changeCount += 1
            s.writes += 1
            return s.changeCount
        }
    }

    func restore(_ snapshot: PasteboardSnapshot) throws {
        state.withLock { s in
            s.items = snapshot.items
            s.promise = nil
            s.changeCount += 1
        }
    }

    func fetchPlainText() -> String? {
        let promise = state.withLock { $0.promise }
        promise?.onFetch()
        return promise?.text
    }
}

/// Stands in for the frontmost app: always a text field, fetches the pasted text after 20 ms of virtual time.
final class FakeTarget: KeyPosting, FocusProbing, FrontAppProbing, Sendable {
    private struct State {
        var field = "", pasteCount = 0
    }

    private let clock: ManualClock
    private let pasteboard: FakePasteboard
    private let state = Mutex(State())

    init(clock: ManualClock, pasteboard: FakePasteboard) {
        (self.clock, self.pasteboard) = (clock, pasteboard)
    }

    var field: String { state.withLock { $0.field } }
    var pasteCount: Int { state.withLock { $0.pasteCount } }

    func probe() async -> FocusState { .textField(preceding: state.withLock { $0.field.last }) }
    func frontmost() -> String? { "app.target" }
    var secureInputActive: Bool { false }

    func paste() throws {
        state.withLock { $0.pasteCount += 1 }
        Task {
            do { try await clock.sleep(for: .milliseconds(20)) } catch { return }
            let text = pasteboard.fetchPlainText() ?? ""
            state.withLock { $0.field += text }
        }
    }

    func undo() throws {}
}

// MARK: - The audio and dictation rig

/// Everything wired like the app: synthetic keys -> InputService -> FlowCoordinator -> real AudioConductor with
/// synthetic sources, real TrackWriter, journal and BusyState; RecordingSession on the same conductor and lock.
final class Rig: Sendable {
    let scratch: Scratch
    let clock: ManualClock
    let sources: SourceBox
    let conductor: AudioConductor
    let recognizer: StubRecognizer
    let pasteboard: FakePasteboard
    let target: FakeTarget
    let pill: PillRecorder
    let keySource: SyntheticKeySource
    let input: InputService
    let journal: DictationJournal
    let busy: BusyState
    let coordinator: FlowCoordinator
    let lock: RecordingLock
    private let pump: Task<Void, Never>
    private let fed = Mutex(0.0)

    init(standard: InputDevice = Dev.builtIn, fallback: InputDevice? = Dev.builtIn, lidOpen: Bool = true,
         plan: SourceBox.Plan = .init()) throws {
        let scratch = try Scratch()
        let clock = ManualClock()
        let sources = SourceBox(clock: clock, plan: plan)
        let pasteboard = FakePasteboard()
        let target = FakeTarget(clock: clock, pasteboard: pasteboard)
        let pill = PillRecorder()
        let keySource = SyntheticKeySource()
        let recognizer = StubRecognizer()
        let conductor = AudioConductor(  // ASSUMPTION: AudioConductor(microphone:desktop:devices:log:)
            microphone: { sources.makeMic($0) }, desktop: { sources.makeDesktop() },
            devices: DeviceSetup(standard: standard, fallback: fallback, lidOpen: lidOpen), log: scratch.log)
        let busy = BusyState(paths: scratch.paths, fs: scratch.fs)
        let journal = DictationJournal(paths: scratch.paths, fs: scratch.fs, log: scratch.log)
        let input = InputService(source: keySource, profile: .development, clock: clock, pill: pill, log: scratch.log)  // ASSUMPTION: InputService(source:profile:clock:pill:log:)
        let inserter = Inserter(focus: target, pasteboard: pasteboard, keys: target, front: target, clock: clock,
                                log: scratch.log)
        let coordinator = FlowCoordinator(  // ASSUMPTION: FlowCoordinator(paths:fs:conductor:recognizer:text:inserter:journal:busy:input:pill:log:clock:)
            paths: scratch.paths, fs: scratch.fs, conductor: conductor, recognizer: recognizer, text: StubText(),
            inserter: inserter, journal: journal, busy: busy, input: input, pill: pill, log: scratch.log, clock: clock)
        lock = try RecordingLock.acquire(in: scratch.laufend)
        (self.scratch, self.clock, self.sources, self.conductor, self.recognizer) = (scratch, clock, sources, conductor, recognizer)
        (self.pasteboard, self.target, self.pill, self.keySource, self.input) = (pasteboard, target, pill, keySource, input)
        (self.journal, self.busy, self.coordinator) = (journal, busy, coordinator)
        try input.start()
        pump = Task { for await item in input.stream { await coordinator.handle(item) } }
    }

    func remove() {
        pump.cancel()
        lock.release()
        scratch.remove()
    }

    // Keys

    func key(_ key: PhysicalKey, down: Bool, modifiers: KeyModifiers = []) {
        keySource.send(KeyEvent(key, down: down, modifiers: modifiers, at: clock.nowNanos))
    }

    func press() { key(.trigger, down: true) }

    /// Trigger up; waits (real time) until the coordinator registered its 110 ms tail on the virtual clock.
    func release() async {
        let before = clock.sleeperCount
        key(.trigger, down: false)
        _ = await clock.waitForSleepers(atLeast: before + 1)
    }

    /// Fn tap and second press inside the tap window: hands-free lock (the third edge stops it).
    func lockDictation() async {
        press()
        await clock.run(for: .milliseconds(100))
        key(.trigger, down: false)
        await clock.run(for: .milliseconds(100))
        press()
        await clock.run(for: .milliseconds(30))
        key(.trigger, down: false)  // the release after the lock is silent
    }

    // Sessions

    func startSession(_ kind: SessionKind, stamp: String = "2026-01-01 10-00-00",
                      freeSpace: @escaping RecordingSession.FreeSpace = RecordingSession.volumeFree) async throws -> RecordingSession {
        try await RecordingSession.start(kind: kind, conductor: conductor, folder: scratch.laufend, stamp: stamp,
                                         fs: scratch.fs, log: scratch.log, lock: lock, freeSpace: freeSpace)  // ASSUMPTION: RecordingSession.start(kind:conductor:folder:stamp:fs:log:lock:freeSpace:)
    }

    // Audio

    /// Seconds the microphone delivered so far (what every recording track must hold at the end).
    var micFed: Double { fed.withLock { $0 } }

    /// Emits `seconds` of tone to the current microphone and desktop source, advancing the virtual clock.
    @discardableResult
    func play(_ seconds: Double, step: Double = 0.05, hz: Double = 300) async -> [AudioChunk] {
        var sent: [AudioChunk] = []
        for index in 0..<Int((seconds / step).rounded()) {
            let t = clock.nowNanos
            let c = toneChunk(at: t, seconds: step, hz: hz + Double(index % 16) * 25)
            if sources.currentMic?.emit(c) == true {
                sent.append(c)
                fed.withLock { $0 += step }
            }
            sources.currentDesktop?.emit(toneChunk(at: t, seconds: step, hz: 700 + Double(index % 8) * 30))
            await clock.run(for: .seconds(step))
        }
        return sent
    }

    func awaitMicOpen(after count: Int = 0) async -> Bool {
        await eventually { sources.allMics.count > count && (sources.currentMic?.counts.starts ?? 0) >= 1 }
    }

    /// Runs the virtual clock until the coordinator has nothing running (while the call goes on with `play`).
    @discardableResult
    func settle(limit: Swift.Duration = .seconds(20), keepPlaying: Bool = false) async -> Bool {
        var spent = Swift.Duration.zero
        while spent < limit {
            if await coordinator.isIdle { return true }  // ASSUMPTION: FlowCoordinator.isIdle is true when no dictation is running or finishing
            if keepPlaying { await play(0.05) } else { await clock.run(for: .milliseconds(20)) }
            spent += .milliseconds(keepPlaying ? 50 : 20)
        }
        return await coordinator.isIdle
    }

    /// One whole dictation during whatever else runs: press, speak, release, finish. The recording goes on.
    @discardableResult
    func dictate(seconds: Double = 0.6, keepPlaying: Bool = true) async -> Bool {
        press()
        let opened = await eventually { await busy.reasons.contains(.dictation) }  // the lease is taken and the journal begun
        await play(seconds)
        await release()
        await play(0.11, step: 0.01)  // the 110 ms tail
        return await settle(keepPlaying: keepPlaying) && opened
    }
}

// MARK: - The after-run rig (store, queue, aftercare, scripted service)

struct Line: Sendable, Equatable {
    var seconds: Int
    var speaker: String
    var text: String
}

let sampleLines: [Line] = [
    Line(seconds: 3, speaker: "Mara", text: "Guten Morgen, wir starten."),
    Line(seconds: 11, speaker: "Gegenseite", text: "Hallo, Größe, Übung, Straße."),
    Line(seconds: 62, speaker: "Mara", text: "Zweite Minute."),
]

final class TestClock: Sendable {
    private let time: Mutex<Date>
    init(_ start: Date) { time = Mutex(start) }
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)) ?? Date(timeIntervalSince1970: 0)
}

enum Outcome: Sendable {
    case success([Line], speakers: Int)
    case fail(PostFailure)
}

/// A scripted after-run service; every call is counted and remembered.
actor FakePost: PostProcessor {
    nonisolated let name = "elevenlabs-scribe-v2"
    private var script: [Outcome]
    private let fallback: Outcome
    private(set) var seen: [PostJob] = []

    init(script: [Outcome] = [], fallback: Outcome? = nil) {
        self.script = script
        self.fallback = fallback ?? .success(
            [Line(seconds: 0, speaker: "Mara", text: "Neufassung eins."),
             Line(seconds: 5, speaker: "Gegenseite", text: "Neufassung zwei.")], speakers: 2)
    }

    var callCount: Int { seen.count }

    func process(_ job: PostJob) async throws -> PostTranscript {
        seen.append(job)
        switch script.isEmpty ? fallback : script.removeFirst() {
        case .success(let lines, let speakers):
            return PostTranscript(segments: lines.map { PostSegment(start: Double($0.seconds), speaker: $0.speaker, text: $0.text) },
                                  speakersDetected: speakers)
        case .fail(let failure):
            throw failure
        }
    }
}

/// Frontmatter of a vault file, read independently of the code under test.
struct Doc {
    let fields: [String: String]
    let body: [String]

    func value(_ key: String) -> String? { fields[key] }
    var contributions: [String] { body.filter { $0.hasPrefix("**[") && $0.dropFirst(3).first?.isNumber == true } }
    var notes: [String] { body.filter { $0.hasPrefix("_[") && !$0.contains("spricht gerade") } }
}

func readDoc(_ url: URL) throws -> Doc {
    var all = String(decoding: try Data(contentsOf: url), as: UTF8.self).components(separatedBy: "\n")
    var fields: [String: String] = [:]
    guard all.first == "---" else { return Doc(fields: [:], body: all) }
    all.removeFirst()
    while let line = all.first {
        all.removeFirst()
        if line == "---" { break }
        guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("-") else { continue }
        fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return Doc(fields: fields, body: all)
}

struct PostRig {
    let root: URL
    let paths: Paths
    let transcripts: URL
    let raw: URL
    let archiveAudio: URL
    let clock: TestClock
    let fs: SafeFS
    let log: EventLog
    let store: TranscriptStore
    let queue: PostQueue
    let aftercare: Aftercare
    let post: any PostProcessor

    var queueFile: URL { paths.support.appending(path: "nachlauf/warteschlange.jsonl") }  // path named in A.10
    var logDir: URL { paths.log }

    static func make(post: any PostProcessor = FakePost(), postEnabled: Bool = true,
                     start: Date = localDate(2026, 11, 13, 10, 0)) throws -> PostRig {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-sz-post-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = Paths(profile: .development, applicationSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory))
        let transcripts = root.appending(path: "vault/pipelines/audio/transcripts", directoryHint: .isDirectory)
        let raw = root.appending(path: "vault/pipelines/audio/raw", directoryHint: .isDirectory)
        let archive = root.appending(path: "Archive/audio-raw", directoryHint: .isDirectory)
        for dir in [transcripts, transcripts.appending(path: "archive"), raw, archive, root.appending(path: "links"),
                    paths.support, paths.laufend, paths.log, paths.support.appending(path: "nachlauf")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return try assemble(root: root, paths: paths, transcripts: transcripts, raw: raw, archive: archive,
                            fs: SafeFS(confinedTo: root), post: post, postEnabled: postEnabled, clock: TestClock(start))
    }

    private static func assemble(root: URL, paths: Paths, transcripts: URL, raw: URL, archive: URL, fs: SafeFS,
                                 post: any PostProcessor, postEnabled: Bool, clock: TestClock) throws -> PostRig {
        let log = EventLog(directory: paths.log, fs: fs)
        let locations = StoreLocations(transcripts: transcripts, raw: raw, archiveAudio: archive,  // ASSUMPTION: StoreLocations(transcripts:raw:archiveAudio:liveLink:dataFolder:)
                                       liveLink: root.appending(path: "links/live.md"), dataFolder: paths.support)
        let store = TranscriptStore(locations: locations, fs: fs, log: log, speakerName: "Mara", now: { clock.now })  // ASSUMPTION: TranscriptStore(locations:fs:log:speakerName:now:)
        let queue = PostQueue(folder: paths.support.appending(path: "nachlauf"), fs: fs, log: log, now: { clock.now })
        let aftercare = Aftercare(store: store, queue: queue, processor: post,
                                  postEnabled: [.call: postEnabled, .room: postEnabled, .dictation: postEnabled],
                                  confirmedTerms: { [] }, now: { clock.now })
        return PostRig(root: root, paths: paths, transcripts: transcripts, raw: raw, archiveAudio: archive, clock: clock,
                       fs: fs, log: log, store: store, queue: queue, aftercare: aftercare, post: post)
    }

    /// A fresh app process on the same folders: new store, new queue, new coordinator, new service.
    func restarted(post newPost: any PostProcessor, postEnabled: Bool = true) throws -> PostRig {
        try Self.assemble(root: root, paths: paths, transcripts: transcripts, raw: raw, archive: archiveAudio, fs: fs,
                          post: newPost, postEnabled: postEnabled, clock: clock)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
    }

    /// A call or room recorded and stopped: live file with the sample lines, raw item with its tracks, aftercare run.
    /// `settle: false` returns right after the stop, with the after-run attempt possibly still running.
    func record(_ kind: RecordingMode = .call, seconds: Double = 60,
                settle: Bool = true) async throws -> (live: LiveTranscript, raw: URL) {
        let live = try await store.beginLive(kind: kind, startedAt: clock.now, language: "de")  // ASSUMPTION: beginLive(kind:startedAt:language:)
        for l in sampleLines { await live.append(seconds: l.seconds, speaker: l.speaker, text: l.text) }  // ASSUMPTION: LiveTranscript.append(seconds:speaker:text:)
        let item = try makeRaw(kind, seconds: seconds)
        try await aftercare.finish(live, durationSeconds: seconds, rawAudio: item)  // ASSUMPTION: Aftercare.finish(_:durationSeconds:rawAudio:)
        if settle { await aftercare.settle() }
        return (live, item)
    }

    /// A raw recording as the recorder leaves it in `raw/`: call folder with two tracks, raum file with one.
    func makeRaw(_ kind: RecordingMode, seconds: Double, bytesPerSecond: Int = 12_000) throws -> URL {
        let f = DateFormatter()
        (f.locale, f.timeZone, f.dateFormat) = (Locale(identifier: "en_US_POSIX"), .current, "yyyy-MM-dd HH-mm-ss")
        let stamp = f.string(from: clock.now), size = Int(seconds * Double(bytesPerSecond))
        func fill(_ url: URL, salt: UInt8) throws { try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(salt)) }).write(to: url) }
        if kind == .call {
            let folder = raw.appending(path: "\(stamp) Call", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fill(folder.appending(path: "\(stamp) mikrofon.m4a"), salt: 1)
            try fill(folder.appending(path: "\(stamp) desktop.m4a"), salt: 2)
            return folder
        }
        let file = raw.appending(path: "\(stamp) raum.m4a")
        try fill(file, salt: 3)
        return file
    }

    func visible() async -> AftercareState { await aftercare.visibleState }  // ASSUMPTION: Aftercare.visibleState is .idle, .waiting(count:), .paused(count:)
    func pending() async -> Int { await queue.count }

    func trigger(_ trigger: AftercareTrigger) async {
        await aftercare.trigger(trigger)
        await aftercare.settle()
    }

    var transcriptFiles: [URL] {
        names(in: transcripts).filter { $0.hasSuffix(".md") }.map { transcripts.appending(path: $0) }
    }

    func events() async -> [LoggedEvent] {
        await log.flush()
        var out: [LoggedEvent] = []
        for name in names(in: logDir) where name.hasPrefix("ereignisse") {
            guard let text = try? String(contentsOf: logDir.appending(path: name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { out.append(LoggedEvent(obj)) }
            }
        }
        return out
    }

    func locations(of item: URL) -> (inRaw: Bool, inArchive: Bool) {
        let name = item.lastPathComponent
        return (FileManager.default.fileExists(atPath: raw.appending(path: name).path),
                FileManager.default.fileExists(atPath: archiveAudio.appending(path: name).path))
    }
}

/// What a killed process leaves in `laufend/`: a call folder with two ADTS tracks cut in the middle of a frame.
func writeTornCall(fs: SafeFS, log: EventLog, laufend: URL, stamp: String, seconds: Double) async throws -> URL {
    let folder = laufend.appending(path: "\(stamp) Call", directoryHint: .isDirectory)
    try fs.makeFolder(folder)
    for (name, cut) in [("mikrofon", 731), ("desktop", 1_303)] {
        let url = folder.appending(path: "\(name).aac")
        let writer = try await TrackWriter.create(url: url, purpose: .call, sampleRate: Signal.rate, fs: fs, log: log)  // ASSUMPTION: TrackWriter.create(url:purpose:sampleRate:fs:log:)
        for i in 0..<Int(seconds / 0.1) {
            await writer.append(toneChunk(at: UInt64(Double(i) * 0.1 * 1e9), seconds: 0.1, hz: 300 + Double(i % 8) * 20))
        }
        _ = await writer.close(reason: .normal, elapsed: nil)
        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - UInt64(cut))  // SIGKILL: the last frame is half there
        try handle.close()
    }
    return folder
}

// MARK: - The device rig (a plain folder stands in for the pen, never a mounted volume)

struct FakeTranscriberFailure: Error {}

actor FakeTranscriberState {
    var calls: [URL] = [], failing: Set<String> = [], hook: (@Sendable (URL) async -> Void)?
    func called(_ url: URL) async -> Bool {
        calls.append(url)
        await hook?(url)
        return failing.contains { url.lastPathComponent.contains($0) }
    }
    func fail(_ marks: Set<String>) { failing = marks }
    func onCall(_ hook: (@Sendable (URL) async -> Void)?) { self.hook = hook }
}

struct FakeTranscriber: DeviceTranscriber {
    let state = FakeTranscriberState()
    func transcribe(_ audio: URL, language: RecordingLanguage) async throws -> [LiveSegment] {
        if await state.called(audio) { throw FakeTranscriberFailure() }
        return [LiveSegment(words: [TimedWord(text: "Probe", start: 0.5, end: 1, confidence: 0.9)], speaker: nil)]
    }
}

actor FakeFilingState {
    var filed: [DeviceRecording] = [], hook: (@Sendable () async -> Void)?
    func add(_ r: DeviceRecording) async -> Int {
        await hook?()  // the journal says `transcribed` while the file is being filed
        filed.append(r)
        return filed.count
    }
    func onFile(_ hook: (@Sendable () async -> Void)?) { self.hook = hook }
}

struct FakeFiling: DeviceFiling {
    let state = FakeFilingState()
    func file(_ recording: DeviceRecording) async throws -> URL {
        URL(filePath: "/test-vault/transcripts/\(await state.add(recording))-raum-\(recording.label).md")
    }
}

final class DeviceRig: Sendable {
    let scratch: Scratch
    let device: URL, archive: URL
    let transcriber = FakeTranscriber(), filing = FakeFiling()
    let volumeUUID = "00000000-0000-4000-8000-00000000F10E"

    /// The device folder and the archive live below the scratch root, never at a real volume.
    init(scratch: Scratch) throws {
        self.scratch = scratch
        device = scratch.root.appending(path: "geraet-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        archive = scratch.paths.support.appending(path: "archiv", directoryHint: .isDirectory)
        for folder in [device, archive] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    var folders: DeviceImporter.Folders {
        .init(data: scratch.paths.support.appending(path: "geraete", directoryHint: .isDirectory), archive: archive)
    }

    func volume(name: String = "FLOWIQTEST") -> MountedVolume {
        MountedVolume(url: device, uuid: volumeUUID, name: name, readOnly: false)
    }

    func importer(gate: ThrottleGate = .open, busy: BusyState? = nil, post: Bool = false) async throws -> DeviceImporter {
        let vol = volume()
        let importer = DeviceImporter(profile: .development, folders: folders, fs: scratch.fs, log: scratch.log,  // ASSUMPTION: DeviceImporter(profile:folders:fs:log:transcriber:filing:post:gate:busy:volumes:now:settle:)
                                      transcriber: transcriber, filing: filing, post: { post }, gate: gate, busy: busy,
                                      volumes: { [vol] }, now: { Date() }, settle: .zero)
        try await importer.register(vol, as: .test, folders: ["aufnahmen"])  // never the real devices' layout (A.11)
        try await importer.setEnabled(true)
        return importer
    }

    /// PCM 16 bit WAV with a correct header; `seed` makes the content unique.
    static func wav(seconds: Double, rate: Int = 16_000, seed: UInt8 = 1) -> Data {
        let bytes = Int(seconds * Double(rate)) * 2
        var data = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        le(UInt32(36 + bytes))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Data("data".utf8))
        le(UInt32(bytes))
        data.append(contentsOf: (0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 7) })
        return data
    }

    @discardableResult
    func put(_ name: String, _ data: Data) throws -> URL {
        let dir = device.appending(path: "aufnahmen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha(_ url: URL) throws -> String { sha(try Data(contentsOf: url)) }

    /// Path, size and content hash of everything on the device: nothing there may ever change (A.11).
    func deviceSnapshot() throws -> [String] {
        guard let walk = FileManager.default.enumerator(at: device, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var rows: [String] = []
        for case let url as URL in walk {
            let regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            rows.append("\(url.lastPathComponent)|\(regular ? try Self.sha(url) : "dir")")
        }
        return rows.sorted()
    }

    func archived() -> [String] { names(in: archive) }
    func staging() -> [String] { names(in: folders.data.appending(path: "import", directoryHint: .isDirectory)) }
}

// MARK: - What the display says (pure pieces of the app target)

enum Display {
    /// The state of one pen file as the Geräte list says it; the words are the ones asked for.
    /// ASSUMPTION: no such row model exists yet (the pane lists only counts per device); this mapping IS the contract
    /// for it: no journal entry = wartet, copied = kopiert, transcribed = erkannt, done = abgelegt, failed =
    /// fehlgeschlagen with the next step "Erneut versuchen".
    static func rowText(_ entry: ImportEntry?) -> String {
        switch entry?.phase {
        case nil: "wartet"
        case .copied?: "kopiert"
        case .transcribed?: "erkannt"
        case .done?: "abgelegt"
        case .failed?: "fehlgeschlagen, Erneut versuchen"
        case .ignored?: "ignoriert"
        }
    }

    /// The journal entry of the file with this device name, if there is one.
    static func entry(named name: String, in entries: [ImportEntry]) -> ImportEntry? { entries.last { $0.name == name } }

    /// The state the app shows with `running` and `down` as `AppModel.refresh` builds it (lines "let rec = ...").
    /// ASSUMPTION: copy of that mapping; replace by a call once the app exposes `AppModel.scene(running:down:)`.
    static func scene(running: [Running], down: Set<TrackKind> = []) -> PillScene {
        var scene = PillScene()
        AppModel.show(shown { ($0.running, $0.down) = (running, down) }, in: &scene)  // COMPILE-FIX 16.11.2026 (Pille nach pille-neu.html): the app exposes the mapping now, the copy with marks and the shared-microphone flag is gone
        return scene
    }

    static func shown(_ edit: (inout AppModel.Shown) -> Void = { _ in }) -> AppModel.Shown {
        var ui = AppModel.Shown()
        ui.tapRunning = true  // the Fn tap runs in every scenario, so `tapStopped` never hides the case under test
        edit(&ui)
        return ui
    }

    /// `silent` as `AppModel.refresh` passes it to `alerts`.
    /// ASSUMPTION: copy of the formula in refresh ("let silent = running.contains { $0.silent } || ..."); replace by a call once it is a function.
    static func silent(_ ui: AppModel.Shown) -> Bool {
        // Own computation from the description, not the app's function (last look W4): a silent
        // microphone track, or the microphone source down while something records; a desktop that is down is
        // `noDesktop`, never a silent microphone (Szenarien, B.5).
        ui.running.contains { $0.silent } || ui.down.contains(.microphone) && !ui.running.isEmpty
    }

    static func alerts(_ ui: AppModel.Shown, silent: Bool = false, limit: Int = 0) -> [AppAlert] {
        AppModel.alerts(ui, silent: silent, limit: limit)
    }

    static func menu(_ edit: (inout MenuState) -> Void = { _ in }) -> [MenuEntry] {
        var state = MenuState(profile: .development, settings: .defaults(for: .development))
        edit(&state)
        return StatusMenuModel.entries(state)
    }
}
