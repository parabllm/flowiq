// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Shared fixtures for the P4 acceptance tests, architecture version 3 additions (correction window, replace in the
// target field, learning from a correction, dictation stays local). Companion of the frozen `abnahme-tests/p4`
// (which stays untouched); nothing is shared between the two targets, so this file carries its own seams.
//
// RULE: every line that touches an API shape the architecture leaves open carries "ASSUMPTION:" in the same line.
// The build agent may change ONLY those lines (names, labels, argument order, import lines). Expected values in the
// test files are fixed and must never be touched. A wrong expectation goes to the owner as a question.
//
// Nothing here posts a real key event, opens a window, reads another app's field, touches the real pasteboard or
// opens the network. The outside world sits behind seams and every wait goes through ONE injected virtual clock:
//   target app + field  -> FieldTarget        (KeyPosting + FocusProbing + FrontAppProbing + FieldEditing)
//   pasteboard          -> FakePasteboard     (PasteboardPort)
//   correction window   -> FakeWindowHost     (CorrectionWindowPresenting + FrontAppActivating)
//   dictation history   -> StaticHistory      (DictationHistory)
//   microphone          -> ToneMic            (CaptureSource; the real AudioConductor runs on top)
//   cloud recognizer    -> CountingLive       (LiveRecognizer that only counts what it was fed)
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import FlowIQ  // ASSUMPTION: CorrectionSession and StatusMenuModel (A.12, N.2) live in the app target
@testable import FlowIQAudio
@testable import FlowIQCloud  // ASSUMPTION: CloudPolicy (M.9) is reachable from here
@testable import FlowIQCore
@testable import FlowIQInsert
@testable import FlowIQLog
@testable import FlowIQSpeech  // ASSUMPTION: CallLiveFeed (the glue between a mic lease and LiveRecognizer values) lives in FlowIQSpeech
@testable import FlowIQStore
@testable import FlowIQText  // ASSUMPTION: Intervention has an internal memberwise init, reachable through @testable (it is public-read only)

// MARK: - Assumed API surface of the version 3 additions (one place to adapt; shapes only, no behaviour)
//
//  FlowIQCore    LiveEngine, PostEngine, ModeConfig, RecordingMode { dictation, call, room, device },
//                Settings[mode] subscript, Settings.effective(_:hasKey:) -> ModeConfig, LiveRecognizer, LiveEvent
//  FlowIQInsert  FieldEditing { value(), replace(_:with:) }, Inserter.replaceInLastInsertion(range:with:keySinceInsert:)
//                -> ReplaceResult { fieldReplaced, undoReinserted, clipboardHint, nothingToReplace }
//  FlowIQStore   DictationJournal (append-only JSONL), LexiconStore (entries, variants, review list), CorrectionLedger
//  FlowIQ (app)  CorrectionSession, CorrectionView, CorrectionOptions, CorrectionChoice, CorrectionOutcome,
//                DictationRecord, DictationHistory, CorrectionWindowPresenting, FrontAppActivating
//  FlowIQCloud   CloudPolicy.allows(_:for:)
//  FlowIQSpeech  CallLiveFeed (mic lease -> live recognizers, with a dictation gate)

// MARK: - Journal vocabulary (event names fixed by A.9 and Anhang I, key names are the open part)

enum JE {
    static let begin = "begin", audio = "audio", recognized = "recognized", inserted = "inserted", reject = "reject"
    static let correction = "correction", rejectIntervention = "reject_intervention"
}

enum JK {
    static let event = "event"  // ASSUMPTION: key holding the event name of a journal line
    static let id = "id"  // ASSUMPTION: key holding the dictation id on every line
    static let time = "ts"  // ASSUMPTION: key holding the wall-clock time as a number
    static let finalText = "final_text"  // ASSUMPTION: text after the stage, on `recognized`
    static let rejected = "interventions_rejected"  // ASSUMPTION: count on `reject`
    static let choice = "choice"  // ASSUMPTION: on `correction`: alternative, lexicon, raw or typed
    static let replaceResult = "replace_result"  // ASSUMPTION: on `correction`: ReplaceResult raw value
    static let entryID = "entry_id"  // ASSUMPTION: on `reject_intervention`: entry of the rejected intervention
    static let variantID = "variant_id"  // ASSUMPTION: on `reject_intervention`: variant of the rejected intervention
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


// MARK: - Scratch folder, protocol, journal

final class F3Scratch: Sendable {
    let root: URL
    let paths: Paths
    let fs: SafeFS
    let log: EventLog

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p4f3-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = Paths(profile: .development, applicationSupport: root)
        for folder in [paths.support, paths.log, paths.laufend, paths.diktate] {  // ASSUMPTION: Paths.diktate (A.1)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        fs = SafeFS(paths: paths)
        log = EventLog(directory: paths.log)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// The whole text-free protocol (events and errors) as one string.
    func logText() async -> String {
        await log.flush()
        var text = ""
        for name in ["ereignisse.ndjson", "fehler.ndjson"] {
            let file = paths.log.appending(path: name)
            if let part = try? String(contentsOf: file, encoding: .utf8) { text += part }
        }
        return text
    }

    func journalBytes() -> Data {
        let files = ((try? FileManager.default.contentsOfDirectory(at: paths.diktate, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("journal-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var data = Data()
        for file in files { if let part = try? Data(contentsOf: file) { data.append(part) } }
        return data
    }

    func journal() -> [JournalLine] {
        String(decoding: journalBytes(), as: UTF8.self).split(separator: "\n").map { JournalLine(Data($0.utf8)) }
    }

    /// Every byte below the scratch root, as text, for "never stored anywhere" checks.
    func everythingAsText() -> String {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        var text = ""
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            if let data = try? Data(contentsOf: url) { text += String(decoding: data, as: UTF8.self) }
        }
        return text
    }
}

struct JournalLine: Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
    private var object: [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
    var event: String { string(JK.event) ?? "" }
    var id: String { string(JK.id) ?? "" }
    func string(_ key: String) -> String? { object[key] as? String }
    func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
    var keys: Set<String> { Set(object.keys) }
}

extension [JournalLine] {
    func events() -> [String] { map(\.event) }
    func lines(of id: String) -> [JournalLine] { filter { $0.id == id } }
}

// MARK: - Pasteboard and target app with a readable field

enum FakeError: Error { case refused }

final class FakePasteboard: PasteboardPort, Sendable {  // ASSUMPTION: protocol PasteboardPort { changeCount, snapshot(), writePromise(_:onFetch:), writePlain(_:), restore(_:) }
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
    }

    private let state = Mutex(State())

    init(items: [[String: Data]] = []) { state.withLock { $0.items = items } }

    var changeCount: Int { state.withLock { $0.changeCount } }
    var items: [[String: Data]] { state.withLock { $0.items } }
    var writes: Int { state.withLock { $0.writes } }
    var restores: Int { state.withLock { $0.restores } }

    /// The plain text a user would paste now: promise data first, else the first item.
    var plainText: String? {
        state.withLock { s in
            if let promise = s.promise { return promise.text }
            return s.items.first?[Self.plain].map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func snapshot() throws -> PasteboardSnapshot {  // ASSUMPTION: PasteboardSnapshot(items:)
        state.withLock { PasteboardSnapshot(items: $0.items) }
    }

    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int {  // ASSUMPTION: writePromise(_:onFetch:) returns the change count after the own write
        state.withLock { s in
            s.promise = Promise(text: text, onFetch: onFetch)
            s.items = []
            s.changeCount += 1
            s.writes += 1
            return s.changeCount
        }
    }

    func writePlain(_ text: String) throws -> Int {  // ASSUMPTION: writePlain(_:) puts plain text on the clipboard for the "copied for you" hint (no promise, stays there)
        state.withLock { s in
            s.promise = nil
            s.items = [[Self.plain: Data(text.utf8)]]
            s.changeCount += 1
            s.writes += 1
            return s.changeCount
        }
    }

    func restore(_ snapshot: PasteboardSnapshot) throws {  // ASSUMPTION: restore(_:) puts every item back
        state.withLock { s in
            s.items = snapshot.items  // ASSUMPTION: PasteboardSnapshot.items
            s.promise = nil
            s.changeCount += 1
            s.restores += 1
        }
    }

    func fetchPlainText() -> String? {
        let (promise, old) = state.withLock { ($0.promise, $0.items.first?[Self.plain]) }
        if let promise {
            promise.onFetch()
            return promise.text
        }
        return old.map { String(decoding: $0, as: UTF8.self) }
    }
}

func richClipboard() -> [[String: Data]] {
    [[FakePasteboard.plain: Data("alter Inhalt".utf8), "public.rtf": Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D])],
     ["public.png": Data((0..<32).map { UInt8($0) })]]
}

/// Stands in for the frontmost app and its focused field. The field holds characters; offsets are character offsets.
final class FieldTarget: KeyPosting, FocusProbing, FrontAppProbing, FieldEditing, Sendable {  // ASSUMPTION: protocols KeyPosting { paste() throws; undo() throws }, FocusProbing { probe() async -> FocusState }, FrontAppProbing { frontmost() -> String?; secureInputActive }, FieldEditing { value() async -> String?; replace(_:with:) async throws }
    enum Kind: Sendable { case text, nonText, unreadable }

    private struct State {
        var field: String
        var kind = Kind.text
        var frontApp = "app.target"
        var secure = false
        var fetchDelay = Swift.Duration.milliseconds(20)
        var failReplace = false
        var posted: [String] = []
        var segments: [String] = []
        var replaced: [Range<Int>] = []
    }

    private let clock: ManualClock
    private let pasteboard: FakePasteboard
    private let state: Mutex<State>

    init(clock: ManualClock, pasteboard: FakePasteboard, field: String = "") {
        self.clock = clock
        self.pasteboard = pasteboard
        state = Mutex(State(field: field))
    }

    var field: String { state.withLock { $0.field } }
    var posted: [String] { state.withLock { $0.posted } }
    var replaced: [Range<Int>] { state.withLock { $0.replaced } }
    func setKind(_ kind: Kind) { state.withLock { $0.kind = kind } }
    func setFront(_ app: String) { state.withLock { $0.frontApp = app } }
    func setSecure(_ on: Bool) { state.withLock { $0.secure = on } }
    func setFailReplace(_ on: Bool) { state.withLock { $0.failReplace = on } }

    /// The app (not the user) changes characters inside the field without a key event: autocorrect, sync.
    func mutateSilently(_ range: Range<Int>, with text: String) {
        state.withLock { s in
            var chars = Array(s.field)
            chars.replaceSubrange(range, with: Array(text))
            s.field = String(chars)
        }
    }

    func probe() async -> FocusState {  // ASSUMPTION: FocusState { textField(preceding: Character?), notTextField, unreadable }
        let (kind, last) = state.withLock { ($0.kind, $0.field.last) }
        switch kind {
        case .text: return .textField(preceding: last)  // ASSUMPTION: FocusState.textField(preceding:)
        case .nonText: return .notTextField  // ASSUMPTION: FocusState.notTextField
        case .unreadable: return .unreadable  // ASSUMPTION: FocusState.unreadable
        }
    }

    func frontmost() -> String? { state.withLock { $0.frontApp } }  // ASSUMPTION: FrontAppProbing.frontmost()
    var secureInputActive: Bool { state.withLock { $0.secure } }  // ASSUMPTION: FrontAppProbing.secureInputActive

    func paste() throws {
        state.withLock { $0.posted.append("paste") }
        let delay = state.withLock { $0.fetchDelay }
        Task {
            do { try await clock.sleep(for: delay) } catch { return }
            let text = pasteboard.fetchPlainText() ?? ""
            state.withLock { s in
                s.field += text
                s.segments.append(text)
            }
        }
    }

    func undo() throws {
        state.withLock { s in
            s.posted.append("undo")
            guard let last = s.segments.popLast() else { return }
            s.field.removeLast(min(last.count, s.field.count))
        }
    }

    func value() async -> String? {  // the accessibility read: nil for unreadable and non-text fields
        state.withLock { $0.kind == .text ? $0.field : nil }
    }

    func replace(_ range: Range<Int>, with text: String) async throws {
        try state.withLock { s in
            if s.failReplace { throw FakeError.refused }
            var chars = Array(s.field)
            chars.replaceSubrange(range, with: Array(text))
            s.field = String(chars)
            s.replaced.append(range)
        }
    }
}

// MARK: - Insert rig

final class InsertRig: Sendable {
    let scratch: F3Scratch
    let clock = ManualClock()
    let pasteboard: FakePasteboard
    let target: FieldTarget
    let inserter: Inserter

    init(field: String = "", clipboard: [[String: Data]] = richClipboard()) throws {
        scratch = try F3Scratch()
        pasteboard = FakePasteboard(items: clipboard)
        target = FieldTarget(clock: clock, pasteboard: pasteboard, field: field)
        inserter = Inserter(focus: target, pasteboard: pasteboard, keys: target, front: target, field: target, clock: clock, log: scratch.log)  // ASSUMPTION: Inserter(focus:pasteboard:keys:front:field:clock:log:)
    }

    func remove() { scratch.remove() }

    /// Starts `work` and runs the virtual clock until it returned (or `limit` passed).
    func drive<T: Sendable>(limit: Swift.Duration = .seconds(5), _ work: @escaping @Sendable () async -> T) async -> T? {
        let box = Mutex<T?>(nil)
        let task = Task { let value = await work(); box.withLock { $0 = value } }
        var spent = Swift.Duration.zero
        while spent < limit {
            await clock.run(for: .milliseconds(10))
            spent += .milliseconds(10)
            if let value = box.withLock({ $0 }) { return value }
        }
        task.cancel()
        return nil
    }

    func insert(_ text: String) async -> InsertResult? {  // ASSUMPTION: InsertResult
        let inserter = inserter
        return await drive { await inserter.insert(text) }  // ASSUMPTION: Inserter.insert(_:) async -> InsertResult
    }

    func replace(_ range: Range<Int>, with text: String, keySinceInsert: Bool = false) async -> ReplaceResult? {
        let inserter = inserter
        return await drive { await inserter.replaceInLastInsertion(range: range, with: text, keySinceInsert: keySinceInsert) }  // ASSUMPTION: replaceInLastInsertion(range:with:keySinceInsert:) async -> ReplaceResult; range counts characters of the INSERTED text
    }

    func settle() async { await clock.run(for: .seconds(3)) }
}

// MARK: - Scripted dictations and the correction rig

/// One dictation as the correction window sees it. Words are 1:1 between `spoken` and `final`; an intervention
/// replaces one spoken word by one final word (the windows work on word positions).
struct Scripted: Sendable {
    var id: String
    var spoken: [String]
    var final: [String]
    var alternatives: [Int: [String]] = [:]  // per word position, as the recognizer delivered them
    var app = "app.target"

    var finalText: String { final.joined(separator: " ") }
    var spokenText: String { spoken.joined(separator: " ") }

    var interventions: [Intervention] {
        spoken.indices.filter { spoken[$0] != final[$0] }.map { i in
            Intervention(tRule: "R2", tBefore: spoken[i], tAfter: final[i], tReason: "variant", entryID: "e-" + final[i].lowercased(),  // ASSUMPTION: Intervention memberwise init as declared in StageTypes.swift
                         variantID: "v-" + spoken[i].lowercased(), pieces: [i, i + 1], score: 1, margin: 1, sourceProtection: ["open"])
        }
    }

    var record: DictationRecord {
        let tokens = spoken.enumerated().map { Recognition.Token(text: $0.element, start: Double($0.offset) * 0.4, end: Double($0.offset) * 0.4 + 0.3, confidence: 0.9) }  // ASSUMPTION: Recognition.Token has this memberwise init
        let segmentAlternatives = spoken.indices.map { alternatives[$0] ?? [] }  // ASSUMPTION: segmentAlternatives is aligned per word position in these scripts (one token per segment)
        return DictationRecord(id: id, recognition: Recognition(text: spokenText, tokens: tokens, segmentAlternatives: segmentAlternatives),  // ASSUMPTION: DictationRecord(id:recognition:finalText:interventions:targetApp:)
                               finalText: finalText, interventions: interventions, targetApp: app)
    }
}

final class StaticHistory: DictationHistory, Sendable {  // ASSUMPTION: protocol DictationHistory { func recent(limit: Int) async -> [DictationRecord] }
    private let list = Mutex<[DictationRecord]>([])
    func add(_ record: DictationRecord) { list.withLock { $0.insert(record, at: 0) } }
    func recent(limit: Int) async -> [DictationRecord] { Array(list.withLock { $0 }.prefix(limit)) }
}

/// The correction window and the activation of apps, as one fake.
final class FakeWindowHost: CorrectionWindowPresenting, FrontAppActivating, Sendable {  // ASSUMPTION: protocols CorrectionWindowPresenting { present(_:) async; dismiss() async } and FrontAppActivating { frontmost() -> String?; activate(_:) }
    private struct State {
        var front = "app.target"
        var windowKey = false
        var presented: [CorrectionView] = []
        var activations: [String] = []
    }

    private let state = Mutex(State())
    private let target: FieldTarget

    init(target: FieldTarget) { self.target = target }

    var windowIsKey: Bool { state.withLock { $0.windowKey } }
    var presented: [CorrectionView] { state.withLock { $0.presented } }
    var activations: [String] { state.withLock { $0.activations } }

    func present(_ view: CorrectionView) async {  // ASSUMPTION: the window becomes key and the previous app is no longer in front
        state.withLock { s in
            s.presented.append(view)
            s.windowKey = true
            s.front = "flowiq.window"
        }
        target.setFront("flowiq.window")
    }

    func dismiss() async { state.withLock { $0.windowKey = false } }

    func frontmost() -> String? { state.withLock { $0.front } }

    func activate(_ app: String) {
        state.withLock { s in
            s.front = app
            s.activations.append(app)
        }
        target.setFront(app)
    }
}

/// Words of the fake system dictionary: what counts as "a real word" for the learning rules (N.2 point 4).
enum Words {
    static let german: Set<String> = ["wir", "treffen", "uns", "morgen", "um", "uhr", "dann", "denn", "das", "ist", "ein", "probesatz",
                                      "bitte", "kommt", "heute", "pulse", "und", "der", "die", "mit", "nicht", "hier", "da", "dort"]
    static var frozen: FrozenWordSet { FrozenWordSet(german: german.union(german.map { $0.capitalized }), english: []) }  // ASSUMPTION: FrozenWordSet(german:english:)
}

func entry(_ canonical: String, status: EntryStatus = .confirmed, variants: [HearingVariant] = []) -> CanonEntry {
    CanonEntry(id: "e-" + canonical.lowercased(), canonical: canonical, kind: .name, family: nil, spokenForms: [], hearingVariants: variants,
               status: status, origin: .seed, compound: .none, counters: Counters(), createdAt: Date(timeIntervalSince1970: 0),
               confirmedAt: status == .confirmed ? Date(timeIntervalSince1970: 1) : nil)
}

func variant(_ heard: String, status: VariantStatus, origin: VariantOrigin = .userClick, protectedWord: Bool = false, context: [String] = []) -> HearingVariant {
    HearingVariant(id: "v-" + heard, heard: [heard], context: context, status: status, origin: origin, replacesProtectedWord: protectedWord, counters: Counters())
}

final class CorrectionRig: Sendable {
    let scratch: F3Scratch
    let clock = ManualClock()
    let pasteboard: FakePasteboard
    let target: FieldTarget
    let inserter: Inserter
    let host: FakeWindowHost
    let history = StaticHistory()
    let lexicon: LexiconStore
    let ledger: CorrectionLedger
    let journal: DictationJournal
    let session: CorrectionSession

    init(lexicon entries: [CanonEntry] = [], prefix: String = "", clipboard: [[String: Data]] = richClipboard()) async throws {
        scratch = try F3Scratch()
        pasteboard = FakePasteboard(items: clipboard)
        target = FieldTarget(clock: clock, pasteboard: pasteboard, field: prefix)
        inserter = Inserter(focus: target, pasteboard: pasteboard, keys: target, front: target, field: target, clock: clock, log: scratch.log)  // ASSUMPTION: Inserter(focus:pasteboard:keys:front:field:clock:log:)
        host = FakeWindowHost(target: target)
        lexicon = LexiconStore(folder: scratch.paths.support.appending(path: "lexikon", directoryHint: .isDirectory), fs: scratch.fs, log: scratch.log, now: { Date(timeIntervalSince1970: 1_800_000_000) })  // ASSUMPTION: LexiconStore(folder:fs:log:now:)
        ledger = CorrectionLedger(lexicon: lexicon, fs: scratch.fs, log: scratch.log)  // ASSUMPTION: CorrectionLedger(lexicon:fs:log:)
        journal = DictationJournal(paths: scratch.paths, fs: scratch.fs, log: scratch.log)  // ASSUMPTION: DictationJournal(paths:fs:log:)
        session = CorrectionSession(history: history, inserter: inserter, lexicon: lexicon, ledger: ledger, journal: journal, protection: Words.frozen,  // ASSUMPTION: CorrectionSession(history:inserter:lexicon:ledger:journal:protection:window:activator:clock:log:)
                                    window: host, activator: host, clock: clock, log: scratch.log)
        try await lexicon.seed(entries)  // ASSUMPTION: seed(_:) replaces the store content with confirmed starting entries (test only)
    }

    func remove() { scratch.remove() }

    func drive<T: Sendable>(limit: Swift.Duration = .seconds(5), _ work: @escaping @Sendable () async -> T) async -> T? {
        let box = Mutex<T?>(nil)
        let task = Task { let value = await work(); box.withLock { $0 = value } }
        var spent = Swift.Duration.zero
        while spent < limit {
            await clock.run(for: .milliseconds(10))
            spent += .milliseconds(10)
            if let value = box.withLock({ $0 }) { return value }
        }
        task.cancel()
        return nil
    }

    /// A finished dictation: written to the journal the way the coordinator does, kept in the history, inserted in the field.
    func dictate(_ d: Scripted) async throws {
        history.add(d.record)
        try await journal.append(.begin(id: d.id))  // ASSUMPTION: DictationJournal.append(_:) takes JournalEntry values with these cases
        try await journal.append(.recognized(id: d.id, recognizerText: d.spokenText, finalText: d.finalText, interventions: d.interventions))  // ASSUMPTION: JournalEntry.recognized(id:recognizerText:finalText:interventions:)
        let inserter = inserter
        let text = d.finalText
        _ = await drive { await inserter.insert(text) }  // ASSUMPTION: Inserter.insert(_:)
        try await journal.append(.inserted(id: d.id, result: "landed"))  // ASSUMPTION: JournalEntry.inserted(id:result:)
        await clock.run(for: .seconds(1))
    }

    func open() async -> CorrectionView? {
        let session = session
        return await drive { await session.open() }  // ASSUMPTION: CorrectionSession.open() async -> CorrectionView (newest dictation first)
    }

    func options(_ range: Range<Int>) async -> CorrectionOptions {
        await session.options(for: range)  // ASSUMPTION: options(for:) async -> CorrectionOptions for a word range of the shown dictation
    }

    func apply(_ choice: CorrectionChoice, to range: Range<Int>) async -> CorrectionOutcome? {
        let session = session
        return await drive { await session.apply(choice, to: range) }  // ASSUMPTION: apply(_:to:) async -> CorrectionOutcome
    }

    func entries() async -> [CanonEntry] { await lexicon.entries() }  // ASSUMPTION: entries() async -> [CanonEntry] with ALL statuses
    func entry(_ canonical: String) async -> CanonEntry? { await entries().first { $0.canonical == canonical } }
}

// MARK: - A tiny microphone and a counting cloud recognizer for the "dictation stays local" test

final class ToneMic: CaptureSource, Sendable {
    private let device: InputDevice
    private let deliver = Mutex<(@Sendable (AudioChunk) -> Void)?>(nil)

    init(device: InputDevice) { self.device = device }

    var kind: SourceKind { .microphone(device) }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void, onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        self.deliver.withLock { $0 = deliver }
    }

    func stop() async { deliver.withLock { $0 = nil } }

    func emit(at nanos: UInt64, seconds: Double = 0.05) {
        let count = Int(seconds * AudioChunk.channelRate)
        let samples = (0..<count).map { Float(sin(Double($0) * 0.04)) * 0.3 }
        deliver.withLock { $0 }?(AudioChunk(hostTime: nanos, sampleRate: AudioChunk.channelRate, samples: samples))
    }
}

/// A LiveRecognizer that counts what it is fed. Used as the "cloud" side; it never talks to anything.
final class CountingLive: LiveRecognizer, Sendable {
    let engine: LiveEngine
    private let fedTimes = Mutex<[UInt64]>([])
    let events: AsyncStream<LiveEvent>
    private let continuation: AsyncStream<LiveEvent>.Continuation

    init(engine: LiveEngine) {
        self.engine = engine
        (events, continuation) = AsyncStream.makeStream()
    }

    func start(_ setup: LiveSetup) async throws {}  // ASSUMPTION: LiveRecognizer.start(_:) async throws
    func feed(_ chunk: AudioChunk) { fedTimes.withLock { $0.append(chunk.hostTime) } }  // ASSUMPTION: LiveRecognizer.feed(_:) never blocks
    func finish() async { continuation.finish() }

    var hostTimes: [UInt64] { fedTimes.withLock { $0 } }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
}
