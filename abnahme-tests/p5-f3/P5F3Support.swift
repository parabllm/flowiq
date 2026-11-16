// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Shared fixtures for the P5 acceptance tests, architecture version 3 additions (live source per mode, LiveRouter with
// the Apple shadow, cloud fallback, cloud badge, key in the keychain, usage counter, vault contract notes, aftercare
// for dictations, aftercare deviations as suggestions). Companion of the frozen `abnahme-tests/p5` (untouched); the two
// targets share nothing, so this file carries its own seams and a trimmed copy of the store rig.
//
// RULE: every line that touches an API shape the architecture leaves open carries "ASSUMPTION:" in the same line.
// The build agent may change ONLY those lines (names, labels, argument order, wire field names, import lines).
// Expected values in the test files are fixed and must never be touched. A wrong expectation goes to the owner.
//
// Synthetic only: temp folders, a manual clock, an artificial keychain, an artificial transport, scripted
// recognizers, a scripted batch service. No network, no real key, no microphone, no real vault, no real live link.
// The test link is a path inside the temp folder; `/tmp/panotti-live.md` is never written.
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCloud  // ASSUMPTION: FlowIQPost became FlowIQCloud with P5a (M.9): realtime, batch, queue, keychain, usage, policy, badge
@testable import FlowIQCore
@testable import FlowIQLog
@testable import FlowIQSpeech  // ASSUMPTION: LiveRouter and LiveSession (M.3, M.5) are pure and netfree, in FlowIQSpeech
@testable import FlowIQStore
import FlowIQText

// MARK: - Assumed API surface of the version 3 additions (one place to adapt; shapes only, no behaviour)
//
//  FlowIQCore   LiveEngine { appleLocal, elevenLabsRealtime }, PostEngine { off, elevenLabs }, ModeConfig(live:post:language:),
//               RecordingMode { dictation, call, room, device }, Settings[mode], Settings.effective(_:hasKey:),
//               TimedWord(text:start:end:confidence:), LiveSegment(words:speaker:), LiveEvent, LiveFailure,
//               LiveSetup(language:terms:track:anchor:previousText:backlog:), LiveRecognizer, PostProcessor, PostJob, PostTranscript
//  FlowIQSpeech LiveRouter(start:sink:), RouterSink, SwitchReason, LiveSession(apple:makeCloud:sink:clock:usage:)
//  FlowIQCloud  ElevenLabsLiveRecognizer, RealtimeTransport / RealtimeConnection, KeychainPort, CloudKeys, UsageMeter,
//               CloudBadge, CloudPolicy, PostQueue, CloudTerms
//  FlowIQStore  TranscriptStore / LiveTranscript with liveSource and switch notes, Aftercare with dictation jobs,
//               LexiconStore, CorrectionLedger (suggestions)

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


// MARK: - Dates, manual date clock, deterministic random numbers

final class TestClock: Sendable {
    private let time: Mutex<Date>
    init(_ start: Date) { time = Mutex(start) }
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func set(_ date: Date) { time.withLock { $0 = date } }
}

func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)) ?? Date(timeIntervalSince1970: 0)
}

func stampString(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH-mm-ss"
    return f.string(from: date)
}

struct Lcg {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

// MARK: - Contributions and the frontmatter reader (independent of the code under test)

struct Line: Sendable, Equatable {
    var seconds: Int
    var speaker: String
    var text: String
}

func isContributionLine(_ s: String) -> Bool { s.hasPrefix("**[") && s.dropFirst(3).first?.isNumber == true }  // the pattern of the live reader script (A.9)
func isVolatileLine(_ s: String) -> Bool { s.hasPrefix("_[") && s.contains("spricht gerade") }  // COMPILE-FIX (P5 build): FrontmatterVermerkTests uses it, defined only in the frozen P5 support (same body)
func isSwitchLine(_ s: String) -> Bool { s.hasPrefix("_[") && s.contains("Live-Erkennung:") }  // ASSUMPTION: switch lines read `_[MM:SS] Live-Erkennung: <Quelle>_` (M.3)

struct Doc {
    let keys: [String]
    let fields: [String: String]
    let lists: [String: [String]]
    let body: [String]

    func value(_ key: String) -> String? { fields[key] }
    var contributions: [String] { body.filter(isContributionLine) }
    var switchLines: [String] { body.filter(isSwitchLine) }
    var lines: [Line] { contributions.compactMap { c in c.range(of: ":** ").map { Line(seconds: 0, speaker: "", text: String(c[$0.upperBound...])) } } }  // COMPILE-FIX (P5 build): CorrectionEverywhereTests reads `lines` (contribution texts), which this Doc lacked
}

func readDoc(_ url: URL) throws -> Doc {
    var all = String(decoding: try Data(contentsOf: url), as: UTF8.self).components(separatedBy: "\n")
    var keys: [String] = []
    var fields: [String: String] = [:]
    var lists: [String: [String]] = [:]
    guard all.first == "---" else { return Doc(keys: [], fields: [:], lists: [:], body: all) }
    all.removeFirst()
    var openList: String?
    while let line = all.first {
        all.removeFirst()
        if line == "---" { break }
        if line.hasPrefix("  - ") || line.hasPrefix("- "), let key = openList {  // ASSUMPTION: list values (live_wechsel) are written as a block list, one `- ` item per line
            lists[key, default: []].append(line.drop { $0 == " " }.dropFirst(2).trimmingCharacters(in: .whitespaces))
            continue
        }
        guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
        let key = String(line[..<colon])
        keys.append(key)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        fields[key] = value
        openList = value.isEmpty ? key : nil
    }
    return Doc(keys: keys, fields: fields, lists: lists, body: all)
}

// MARK: - A word timeline with unique markers (every word is its own "Satzmarke")

/// Word i starts at i * 0.5 s and ends 0.4 s later; its text is the marker "s<i>".
struct Mark: Sendable, Equatable {
    let id: Int
    var start: Double { Double(id) * 0.5 }
    var end: Double { start + 0.4 }
    var text: String { "s\(id)" }
}

func marks(seconds: Double) -> [Mark] { (0..<Int(seconds * 2)).map(Mark.init) }

func segment(_ list: some Sequence<Mark>) -> LiveSegment {
    LiveSegment(words: list.map { TimedWord(text: $0.text, start: $0.start, end: $0.end, confidence: nil) }, speaker: nil)  // ASSUMPTION: TimedWord(text:start:end:confidence:) and LiveSegment(words:speaker:) memberwise, public
}

func markID(_ word: TimedWord) -> Int { Int(word.text.dropFirst()) ?? -1 }

/// What the router passed on, in order.
final class RecordingSink: RouterSink, Sendable {  // ASSUMPTION: protocol RouterSink { accepted(_:from:) async; switched(at:to:reason:) async; shadowed(_:from:) async }
    struct Accepted: Sendable { let word: TimedWord; let engine: LiveEngine }
    struct Switch: Sendable, Equatable { let seconds: Double; let engine: LiveEngine; let reason: SwitchReason }

    private struct State {
        var accepted: [Accepted] = []
        var shadowed: [Accepted] = []
        var switches: [Switch] = []
    }

    private let state = Mutex(State())
    var accepted: [Accepted] { state.withLock { $0.accepted } }
    var shadowed: [Accepted] { state.withLock { $0.shadowed } }
    var switches: [Switch] { state.withLock { $0.switches } }

    func accepted(_ segment: LiveSegment, from engine: LiveEngine) async {
        state.withLock { s in s.accepted += segment.words.map { Accepted(word: $0, engine: engine) } }
    }

    func shadowed(_ segment: LiveSegment, from engine: LiveEngine) async {
        state.withLock { s in s.shadowed += segment.words.map { Accepted(word: $0, engine: engine) } }
    }

    func switched(at seconds: Double, to engine: LiveEngine, reason: SwitchReason) async {
        state.withLock { $0.switches.append(Switch(seconds: seconds, engine: engine, reason: reason)) }
    }

    /// Missing and doubled markers against the expected 0..<count.
    func check(count: Int) -> (missing: [Int], doubled: [Int]) {
        var seen: [Int: Int] = [:]
        for a in accepted { seen[markID(a.word), default: 0] += 1 }
        let missing = (0..<count).filter { seen[$0] == nil }
        let doubled = seen.filter { $0.value > 1 }.map(\.key).sorted()
        return (missing, doubled)
    }

    /// The accepted markers strictly increase (no reordering, no overlap in time).
    var inOrder: Bool {
        let ids = accepted.map { markID($0.word) }
        return zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// Number of times the providing engine changes along the accepted words.
    var engineChanges: Int {
        zip(accepted, accepted.dropFirst()).filter { $0.engine != $1.engine }.count
    }
}

/// One scripted recording for the router: both recognizers produce the whole timeline, each in its own grouping and
/// with its own delay; switches happen at given moments. Delivery order is by delivery time.
struct RouterScenario {
    struct Step: Sendable { let at: Double; let to: LiveEngine; let reason: SwitchReason }

    var seconds = 600.0
    var start = LiveEngine.appleLocal
    var steps: [Step] = []
    var appleGroup = 4, cloudGroup = 6
    var appleDelay = 0.5, cloudDelay = 1.5
    /// The cloud only knows audio from here on (it was started mid recording with a short pre-roll).
    var cloudFrom: Double?

    private enum Item { case segment(LiveSegment, LiveEngine, Double), step(Step) }

    func run(into sink: RecordingSink) async -> LiveRouter {
        let router = LiveRouter(start: start, sink: sink)  // ASSUMPTION: LiveRouter(start:sink:)
        var items: [Item] = []
        let all = marks(seconds: seconds)
        for (engine, group, delay, from) in [(LiveEngine.appleLocal, appleGroup, appleDelay, 0.0),
                                             (LiveEngine.elevenLabsRealtime, cloudGroup, cloudDelay, cloudFrom ?? 0.0)] {
            let own = all.filter { $0.start >= from }
            for chunk in stride(from: 0, to: own.count, by: group) {
                let part = Array(own[chunk..<min(chunk + group, own.count)])
                items.append(.segment(segment(part), engine, (part.last?.end ?? 0) + delay))
            }
        }
        items += steps.map(Item.step)
        let order = items.enumerated().sorted { lhs, rhs in
            let l = time(lhs.element), r = time(rhs.element)
            return l == r ? lhs.offset < rhs.offset : l < r
        }
        for (_, item) in order {
            switch item {
            case .segment(let seg, let engine, _): await router.feed(.committed(seg), from: engine)  // ASSUMPTION: LiveRouter.feed(_:from:) takes the events of BOTH recognizers
            case .step(let step): await router.switchTo(step.to, at: step.at, reason: step.reason)  // ASSUMPTION: LiveRouter.switchTo(_:at:reason:) with `at` in seconds from the recording start
            }
        }
        await router.finish()  // ASSUMPTION: LiveRouter.finish() hands over what is still buffered
        return router
    }

    private func time(_ item: Item) -> Double {
        switch item {
        case .segment(_, _, let t): t
        case .step(let s): s.at
        }
    }
}

// MARK: - Scripted live recognizer (the "künstlicher Cloud-Erkenner mit erzwungenem Abbruch")

final class ScriptedLive: LiveRecognizer, Sendable {
    struct Started: Sendable { let setup: LiveSetup; let at: Swift.Duration }

    let engine: LiveEngine
    let events: AsyncStream<LiveEvent>
    private let continuation: AsyncStream<LiveEvent>.Continuation
    private struct State {
        var starts: [LiveSetup] = []
        var fed: [AudioChunk] = []
        var finished = false
        var failStart: (any Error)?
    }

    private let state = Mutex(State())
    private let clock: ManualClock

    init(engine: LiveEngine, clock: ManualClock) {
        self.engine = engine
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream()
    }

    var starts: [LiveSetup] { state.withLock { $0.starts } }
    var fed: [AudioChunk] { state.withLock { $0.fed } }
    var finished: Bool { state.withLock { $0.finished } }
    func failNextStart(with error: any Error) { state.withLock { $0.failStart = error } }

    func start(_ setup: LiveSetup) async throws {  // ASSUMPTION: LiveRecognizer.start(_:) async throws
        try state.withLock { s in
            if let error = s.failStart { throw error }
            s.starts.append(setup)
        }
    }

    func feed(_ chunk: AudioChunk) { state.withLock { $0.fed.append(chunk) } }  // ASSUMPTION: LiveRecognizer.feed(_:) never blocks
    func finish() async {
        state.withLock { $0.finished = true }
        continuation.finish()
    }

    func emit(_ event: LiveEvent) { continuation.yield(event) }
    func commit(_ list: some Sequence<Mark>) { continuation.yield(.committed(segment(list))) }

    /// The forced abort: the connection is gone, with the reason the service (or the network) gave.
    func abort(_ failure: LiveFailure) { continuation.yield(.failure(failure)) }
}

struct TestError: Error {}

// MARK: - Artificial keychain and artificial transport

final class FakeKeychain: KeychainPort, Sendable {  // ASSUMPTION: protocol KeychainPort { read(service:account:) throws -> String?; write(_:service:account:) throws; delete(service:account:) throws }
    private struct State {
        var items: [String: String] = [:]
        var services: [String] = []
        var reads = 0
    }

    private let state = Mutex(State())
    var services: [String] { state.withLock { $0.services } }
    var reads: Int { state.withLock { $0.reads } }
    var isEmpty: Bool { state.withLock { $0.items.isEmpty } }

    func read(service: String, account: String) throws -> String? {
        state.withLock { s in
            s.reads += 1
            return s.items[service + "/" + account]
        }
    }

    func write(_ secret: String, service: String, account: String) throws {
        state.withLock { s in
            s.items[service + "/" + account] = secret
            s.services.append(service)
        }
    }

    func delete(service: String, account: String) throws {
        state.withLock { _ = $0.items.removeValue(forKey: service + "/" + account) }
    }
}

/// The wire format (client messages and server messages) as the documentation describes it [D]; never tried with a key.
enum Wire {
    static let audioType = "input_audio_chunk"  // ASSUMPTION: message_type of the client audio message
    static let audioField = "audio_base_64"  // ASSUMPTION: base64 PCM16 payload field
    static let commitField = "commit"  // ASSUMPTION: boolean on the audio message that asks the service to commit
    static let previousTextField = "previous_text"  // ASSUMPTION: only on the first audio message of a (re)connected session
    static let sampleRateField = "sample_rate"  // ASSUMPTION: integer on the audio message
    static let partial = "partial_transcript"  // ASSUMPTION: server message types
    static let committed = "committed_transcript_with_timestamps"
    static let errorTypes: [(String, LiveFailure)] = [  // ASSUMPTION: error message_type names from the realtime documentation and the failure each maps to
        ("auth_error", .authError), ("quota_exceeded", .quotaExceeded), ("unaccepted_terms", .unacceptedTerms),
        ("rate_limited", .rateLimited), ("resource_exhausted", .resourceExhausted), ("transcriber_error", .transcriberError),
        ("queue_overflow", .queueOverflow), ("session_time_limit_exceeded", .sessionTimeLimit),
    ]

    static func committedMessage(_ seg: LiveSegment) -> String {
        let words = seg.words.map { #"{"text":"\#($0.text)","start":\#($0.start),"end":\#($0.end),"type":"word"}"# }.joined(separator: ",")
        let text = seg.words.map(\.text).joined(separator: " ")
        return #"{"message_type":"\#(committed)","text":"\#(text)","words":[\#(words)]}"#
    }

    static func decode(_ text: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
    }
}

final class FakeConnection: RealtimeConnection, Sendable {  // ASSUMPTION: protocol RealtimeConnection { send(_:) async throws; incoming: AsyncThrowingStream<String, any Error>; close() async }
    let request: URLRequest
    let incoming: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let sentText = Mutex<[String]>([])
    private let closed = Mutex(false)
    private let onSend: @Sendable (String) -> Void

    init(request: URLRequest, onSend: @escaping @Sendable (String) -> Void = { _ in }) {
        self.request = request
        self.onSend = onSend
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    var sent: [String] { sentText.withLock { $0 } }
    var isClosed: Bool { closed.withLock { $0 } }
    var messages: [[String: Any]] { sent.map(Wire.decode) }
    var audioMessages: [[String: Any]] { messages.filter { ($0["message_type"] as? String) == Wire.audioType } }

    func send(_ text: String) async throws {
        sentText.withLock { $0.append(text) }
        onSend(text)
    }

    func close() async {
        closed.withLock { $0 = true }
        continuation.finish()
    }

    /// The server speaks.
    func serve(_ text: String) { continuation.yield(text) }
    /// The connection dies from the outside (network, service).
    func drop() { continuation.finish(throwing: TestError()) }
}

final class FakeTransport: RealtimeTransport, Sendable {  // ASSUMPTION: protocol RealtimeTransport { connect(_ request: URLRequest) async throws -> any RealtimeConnection }
    private struct State {
        var connections: [FakeConnection] = []
        var refuse: (any Error)?
        var onSend: @Sendable (String) -> Void = { _ in }
    }

    private let state = Mutex(State())
    var connections: [FakeConnection] { state.withLock { $0.connections } }
    var last: FakeConnection? { connections.last }
    func refuseConnections(with error: (any Error)?) { state.withLock { $0.refuse = error } }
    func onSend(_ hook: @escaping @Sendable (String) -> Void) { state.withLock { $0.onSend = hook } }

    func connect(_ request: URLRequest) async throws -> any RealtimeConnection {
        let (connection, refusal) = state.withLock { s -> (FakeConnection, (any Error)?) in
            let c = FakeConnection(request: request, onSend: { [self] text in state.withLock { $0.onSend }(text) })  // TEST-FIX (geprüft, Prüfnotiz Nr. 4): the hook is looked up at send time under the lock and called outside it, so a hook set after connect reaches the open connection
            if s.refuse == nil { s.connections.append(c) }
            return (c, s.refuse)
        }
        if let refusal { throw refusal }
        return connection
    }
}

/// 48 kHz mono chunks of a tone (speech) or of silence, `seconds` long, starting at `at` (host time in nanoseconds).
func audio(at nanos: UInt64, seconds: Double, loud: Bool = true) -> AudioChunk {
    let count = Int(seconds * AudioChunk.channelRate)
    let samples = (0..<count).map { loud ? Float(sin(Double($0) * 0.05)) * 0.4 : 0 }
    return AudioChunk(hostTime: nanos, sampleRate: AudioChunk.channelRate, samples: samples)
}

// MARK: - Terms, words, lexicon entries

func entry(_ canonical: String, status: EntryStatus = .confirmed, variants: [HearingVariant] = []) -> CanonEntry {
    CanonEntry(id: "e-" + canonical.lowercased(), canonical: canonical, kind: .name, family: nil, spokenForms: [], hearingVariants: variants,
               status: status, origin: .seed, compound: .none, counters: Counters(), createdAt: Date(timeIntervalSince1970: 0),
               confirmedAt: status == .confirmed ? Date(timeIntervalSince1970: 1) : nil)
}

func variant(_ heard: String, status: VariantStatus) -> HearingVariant {
    HearingVariant(id: "v-" + heard, heard: [heard], context: [], status: status, origin: .userClick, replacesProtectedWord: false, counters: Counters())
}

enum Words {
    static let german: Set<String> = ["wir", "treffen", "uns", "morgen", "dann", "denn", "das", "ist", "ein", "satz", "heute", "und", "der", "die", "mit", "nicht", "hier", "bitte", "kommt", "gut"]
    static var frozen: FrozenWordSet { FrozenWordSet(german: german.union(german.map { $0.capitalized }), english: []) }  // ASSUMPTION: FrozenWordSet(german:english:)
}

// MARK: - Batch service attrappe and the store rig

enum Trigger { case appStart, networkBack, click, timer }

/// What the scripted batch service answers on one call.
enum Outcome: Sendable {
    case success([Line], speakers: Int)
    case fail(PostFailure)
}

struct SeenJob: Sendable {
    var audio: [URL]
    var language: String
    var terms: [String]
    var mode: RecordingMode
}

actor FakeBatch: PostProcessor {  // ASSUMPTION: protocol PostProcessor { var name: String { get }; func process(_ job: PostJob) async throws -> PostTranscript }
    nonisolated let name = "elevenlabs-scribe-v3"
    private var script: [Outcome]
    private let fallback: Outcome
    private(set) var seen: [SeenJob] = []

    init(script: [Outcome] = [], fallback: Outcome? = nil) {
        self.script = script
        self.fallback = fallback ?? .success([Line(seconds: 0, speaker: "Mara", text: "Neufassung eins.")], speakers: 1)
    }

    var callCount: Int { seen.count }

    func process(_ job: PostJob) async throws -> PostTranscript {
        seen.append(SeenJob(audio: job.audio, language: job.language, terms: job.terms, mode: job.mode))  // ASSUMPTION: PostJob has audio [URL], language "de"/"en", terms [String], mode RecordingMode
        let outcome = script.isEmpty ? fallback : script.removeFirst()
        switch outcome {
        case .success(let lines, let speakers):
            return PostTranscript(segments: lines.map { PostSegment(start: Double($0.seconds), speaker: $0.speaker, text: $0.text) }, speakersDetected: speakers)  // ASSUMPTION: PostTranscript(segments:speakersDetected:) and PostSegment(start:speaker:text:)
        case .fail(let failure):
            throw failure  // ASSUMPTION: PostFailure cases networkDown, quotaExhausted, keyMissing, server(status:)
        }
    }
}

struct StoreRig {
    let root: URL
    let paths: Paths
    let transcripts: URL
    let raw: URL
    let archiveAudio: URL
    let clock: TestClock
    let fs: SafeFS
    let log: EventLog
    let lexicon: LexiconStore
    let ledger: CorrectionLedger
    let store: TranscriptStore
    let queue: PostQueue
    let usage: UsageMeter
    let aftercare: Aftercare
    let batch: FakeBatch

    var queueFile: URL { paths.support.appending(path: "nachlauf/warteschlange.jsonl") }

    static func make(batch: FakeBatch = FakeBatch(), post: [RecordingMode: Bool] = [.call: true, .room: true, .device: true, .dictation: true],
                     lexicon entries: [CanonEntry] = [], monthLimitMinutes: Int? = nil,
                     start: Date = localDate(2026, 11, 13, 10, 0), reopening existing: URL? = nil) async throws -> StoreRig {
        let root = existing ?? FileManager.default.temporaryDirectory.appending(path: "flowiq-p5f3-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = Paths(profile: .development, applicationSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory))
        let vault = root.appending(path: "vault", directoryHint: .isDirectory)
        let transcripts = vault.appending(path: "pipelines/audio/transcripts", directoryHint: .isDirectory)
        let raw = vault.appending(path: "pipelines/audio/raw", directoryHint: .isDirectory)
        let archive = root.appending(path: "Archive/audio-raw", directoryHint: .isDirectory)
        let link = root.appending(path: "links/live.md")
        for dir in [transcripts, transcripts.appending(path: "archive"), raw, archive, link.deletingLastPathComponent(), paths.support, paths.laufend,
                    paths.log, paths.support.appending(path: "nachlauf"), paths.support.appending(path: "fassungen"), paths.support.appending(path: "cloud")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let clock = TestClock(start)
        let fs = SafeFS(confinedTo: root)
        let log = EventLog(directory: paths.log, fs: fs)
        let lexicon = LexiconStore(folder: paths.support.appending(path: "lexikon", directoryHint: .isDirectory), fs: fs, log: log, now: { clock.now })  // ASSUMPTION: LexiconStore(folder:fs:log:now:)
        if existing == nil { try await lexicon.seed(entries) }  // ASSUMPTION: seed(_:) replaces the store content with starting entries (test only)
        let ledger = CorrectionLedger(lexicon: lexicon, fs: fs, log: log)  // ASSUMPTION: CorrectionLedger(lexicon:fs:log:)
        let usage = UsageMeter(folder: paths.support.appending(path: "cloud"), fs: fs, now: { clock.now }, monthLimitMinutes: monthLimitMinutes)  // ASSUMPTION: UsageMeter(folder:fs:now:monthLimitMinutes:) persists to <folder>/verbrauch.json (M.8)
        let stage: @Sendable () async -> TextStage = {
            TextStage(lexicon: LexiconSnapshot(entries: await lexicon.entries(), families: []), protection: Words.frozen, config: TextStageConfig())
        }
        let locations = StoreLocations(transcripts: transcripts, raw: raw, archiveAudio: archive, liveLink: link, dataFolder: paths.support)  // ASSUMPTION: StoreLocations(transcripts:raw:archiveAudio:liveLink:dataFolder:)
        let store = TranscriptStore(locations: locations, fs: fs, log: log, speakerName: "Mara", textStage: stage, now: { clock.now })  // ASSUMPTION: TranscriptStore(locations:fs:log:speakerName:textStage:now:); the stage runs on every finished contribution before it is appended (N.4)
        let queue = PostQueue(folder: paths.support.appending(path: "nachlauf"), fs: fs, log: log, now: { clock.now })  // ASSUMPTION: PostQueue(folder:fs:log:now:) persists to <folder>/warteschlange.jsonl
        let aftercare = Aftercare(store: store, queue: queue, processor: batch, postEnabled: post, usage: usage, ledger: ledger,  // ASSUMPTION: Aftercare(store:queue:processor:postEnabled:usage:ledger:textStage:confirmedTerms:now:); postEnabled is per mode; the protection lives in the stage
                                  textStage: stage, confirmedTerms: { [] }, now: { clock.now })
        return StoreRig(root: root, paths: paths, transcripts: transcripts, raw: raw, archiveAudio: archive, clock: clock, fs: fs, log: log,
                        lexicon: lexicon, ledger: ledger, store: store, queue: queue, usage: usage, aftercare: aftercare, batch: batch)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A fresh app process on the same folders: new store, queue, usage meter, aftercare and batch service.
    static func reopen(_ old: StoreRig, batch: FakeBatch, post: [RecordingMode: Bool] = [.call: true, .room: true, .device: true, .dictation: true]) async throws -> StoreRig {
        try await make(batch: batch, post: post, start: old.clock.now, reopening: old.root)
    }

    // MARK: Recording helpers

    func begin(_ kind: RecordingMode, at date: Date, language: String = "de", live: LiveEngine = .appleLocal) async throws -> LiveTranscript {  // ASSUMPTION: LiveTranscript is the live-file handle of A.9
        try await store.beginLive(kind: kind, startedAt: date, language: language, liveSource: live)  // ASSUMPTION: beginLive(kind:startedAt:language:liveSource:) throws
    }

    func add(_ live: LiveTranscript, _ l: Line, dictation: Bool = false, from engine: LiveEngine = .appleLocal) async {
        await live.append(seconds: l.seconds, speaker: l.speaker, text: l.text, dictation: dictation, from: engine)  // ASSUMPTION: append(seconds:speaker:text:dictation:from:) adds one finished contribution; the text stage runs on it before it is appended, whichever recognizer it came from (N.4)
        await live.flush()  // ASSUMPTION: flush() writes all handed-over text to disk before returning
    }

    /// A switch of the live source as the router reports it (an italic line in the text, a note for the header at the stop).
    func noteSwitch(_ live: LiveTranscript, at seconds: Int, to engine: LiveEngine, reason: SwitchReason) async {
        await live.noteSwitch(seconds: seconds, to: engine, reason: reason)  // ASSUMPTION: LiveTranscript.noteSwitch(seconds:to:reason:)
        await live.flush()
    }

    func finish(_ live: LiveTranscript, seconds: Double, raw item: URL, cloudLiveSeconds: Double = 0) async throws {
        try await aftercare.finish(live, durationSeconds: seconds, rawAudio: item, cloudLiveSeconds: cloudLiveSeconds)  // ASSUMPTION: finish(_:durationSeconds:rawAudio:cloudLiveSeconds:) throws
        await aftercare.settle()  // ASSUMPTION: settle() returns when no attempt is running and nothing is due
    }

    /// A finished dictation: the audio in the dictation folder, the text as inserted; the after-run may start only now.
    func dictationInserted(id: String, text: String, language: String = "de") async throws -> URL {
        let audio = root.appending(path: "diktate/\(id).aac")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 6_000).write(to: audio)
        await aftercare.dictationInserted(DictationJob(id: id, audio: audio, language: language, insertedText: text))  // ASSUMPTION: Aftercare.dictationInserted(_:) with DictationJob(id:audio:language:insertedText:); the coordinator calls it after the insertion, never before
        await aftercare.settle()
        return audio
    }

    func trigger(_ t: Trigger) async {
        switch t {
        case .appStart: await aftercare.trigger(.appStart)  // ASSUMPTION: trigger(_:) with appStart, networkBack, click, timer
        case .networkBack: await aftercare.trigger(.networkBack)  // ASSUMPTION: see above
        case .click: await aftercare.trigger(.click)  // ASSUMPTION: see above
        case .timer: await aftercare.trigger(.timer)  // ASSUMPTION: see above
        }
        await aftercare.settle()
    }

    enum Visible: Equatable { case idle, waiting(Int), paused(Int) }

    func visible() async -> Visible {
        switch await aftercare.visibleState {  // ASSUMPTION: visibleState is what pill or menu show: .idle, .waiting(count:), .paused(count:)
        case .idle: .idle
        case .waiting(let n): .waiting(n)
        case .paused(let n): .paused(n)
        }
    }

    func makeRaw(_ kind: RecordingMode, at date: Date, seconds: Double, bytesPerSecond: Int = 12_000) throws -> URL {
        let stamp = stampString(date)
        let size = Int(seconds * Double(bytesPerSecond))
        func fill(_ url: URL, salt: UInt8) throws {
            var state = UInt64(salt) &+ 99
            var data = Data(capacity: size)
            for _ in 0..<size {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                data.append(UInt8(truncatingIfNeeded: state >> 33))
            }
            try data.write(to: url)
        }
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

    var transcriptFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whole data folder as text, for "never stored anywhere" checks (the audio and the lexicon are not text, but harmless).
    func everythingAsText() -> String {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        var text = ""
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            if let data = try? Data(contentsOf: url) { text += String(decoding: data, as: UTF8.self) }
        }
        return text
    }

    func logText() async -> String {
        await log.flush()
        var text = ""
        for name in (try? FileManager.default.contentsOfDirectory(atPath: paths.log.path)) ?? [] {
            text += (try? String(contentsOf: paths.log.appending(path: name), encoding: .utf8)) ?? ""
        }
        return text
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
}
