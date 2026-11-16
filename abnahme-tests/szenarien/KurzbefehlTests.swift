// Group 1b, bounce and chatter of the keys (A.3, R-014): Fn that bounces, a start and a stop in quick succession, a
// tap that is a lock or a late stop, Fn and the recording shortcuts pressed together. The gesture machine and the
// input service are pure; the coordinator must stay untouched by shortcuts that belong to the recordings.
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQInput

@Suite(.timeLimit(.minutes(2)))
struct KurzbefehlTests {
    struct Edge: Sendable {
        let key: PhysicalKey, down: Bool, ms: UInt64
        init(_ key: PhysicalKey, _ down: Bool, at ms: UInt64) { (self.key, self.down, self.ms) = (key, down, ms) }
        init(_ down: Bool, at ms: UInt64) { self.init(.trigger, down, at: ms) }
    }

    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let edges: [Edge]
        let tickAt: UInt64?  // a clock tick after the last edge (ms), e.g. the end of the tap window
        let expected: [InputAction]
        var description: String { name }
    }

    /// Fn contact chatter and fast legitimate gestures, each with the actions that must come out. Chatter below
    /// the 10 ms bounce window never starts or stops twice; a tap is a lock when the second press is inside the
    /// 360 ms window and a late stop when it is not.
    static let cases: [Case] = [
        Case(name: "chatter on press", edges: [Edge(true, at: 0), Edge(false, at: 4), Edge(true, at: 8), Edge(false, at: 500)],
             tickAt: nil, expected: [.start, .stop]),
        Case(name: "chatter on release", edges: [Edge(true, at: 0), Edge(false, at: 500), Edge(true, at: 504), Edge(false, at: 508)],
             tickAt: nil, expected: [.start, .stop]),
        Case(name: "double tap locks, third press stops",
             edges: [Edge(true, at: 0), Edge(false, at: 100), Edge(true, at: 200), Edge(false, at: 230), Edge(true, at: 1_000), Edge(false, at: 1_100)],
             tickAt: nil, expected: [.start, .lock, .stop]),
        Case(name: "single tap stops when the window ends", edges: [Edge(true, at: 0), Edge(false, at: 100)],
             tickAt: 460, expected: [.start, .stop]),
        Case(name: "second press just inside the window locks", edges: [Edge(true, at: 0), Edge(false, at: 100), Edge(true, at: 359)],
             tickAt: nil, expected: [.start, .lock]),
        Case(name: "second press just after the window starts a new dictation",
             edges: [Edge(true, at: 0), Edge(false, at: 100), Edge(true, at: 361)], tickAt: nil, expected: [.start, .stop, .start]),
        Case(name: "space while held locks", edges: [Edge(true, at: 0), Edge(.space, true, at: 200), Edge(false, at: 300)],
             tickAt: nil, expected: [.start, .lock]),
        Case(name: "escape while held cancels, the release is silent",
             edges: [Edge(true, at: 0), Edge(.escape, true, at: 100), Edge(false, at: 200)], tickAt: nil, expected: [.start, .cancel]),
        Case(name: "a lone release or repeated press is nothing", edges: [Edge(false, at: 0), Edge(false, at: 50)],
             tickAt: nil, expected: []),
    ]

    @Test(arguments: cases)
    func theGestureMachineAnswersChatterAndFastGesturesCorrectly(_ c: Case) {
        var machine = GestureMachine(profile: .production)
        var actions: [InputAction] = []
        for edge in c.edges { actions += machine.handle(KeyEvent(edge.key, down: edge.down, at: edge.ms * 1_000_000)) }
        if let tick = c.tickAt { actions += machine.tick(now: tick * 1_000_000) }
        #expect(actions == c.expected)
    }

    /// The same chatter through the real input service: the pill goes on once, one start and one stop come out,
    /// and the key callback never waits for anything.
    @Test func chatterOnPressThroughTheInputServiceIsOneStartAndOnePill() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let clock = ManualClock(), keys = SyntheticKeySource(), pill = PillRecorder()
        let input = InputService(source: keys, profile: .production, clock: clock, pill: pill, log: scratch.log)  // ASSUMPTION: InputService(source:profile:clock:pill:log:)
        try input.start()
        let seen = Mutex<[InputAction]>([])
        let reader = Task { for await envelope in input.stream { seen.withLock { $0.append(envelope.action) } } }
        defer { reader.cancel() }
        func send(_ down: Bool) { keys.send(KeyEvent(.trigger, down: down, at: clock.nowNanos)) }
        send(true)
        await clock.run(for: .milliseconds(4))
        send(false)
        await clock.run(for: .milliseconds(4))
        send(true)
        await clock.run(for: .milliseconds(500))
        send(false)
        #expect(await eventually { seen.withLock { $0.count } >= 2 })
        input.stop()
        #expect(seen.withLock { $0 } == [.start, .stop])
        #expect(pill.states == [.dictating])
    }

    /// Fn plus three recording shortcuts inside 50 ms: the shortcuts are not the coordinator's business, the
    /// dictation runs on and is inserted once, no second dictation is begun.
    @Test func recordingShortcutsDuringADictationNeverDisturbIt() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.recognizer.script(["diktat läuft"])
        rig.press()
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) })
        rig.input.post(.callGerman)
        await rig.clock.run(for: .milliseconds(15))
        rig.input.post(.roomEnglish)
        await rig.clock.run(for: .milliseconds(15))
        rig.input.post(.callEnglish)
        await rig.play(0.5)
        await rig.release()
        await rig.play(0.11, step: 0.01)
        #expect(await rig.settle())

        #expect(rig.target.field == "diktat läuft" && rig.target.pasteCount == 1)
        #expect(rig.scratch.dictationIDs().count == 1)
        #expect(rig.pill.states.first == .dictating && rig.pill.last == .hidden)
        #expect(await rig.scratch.errors().isEmpty)
    }

    /// Fn pressed again right after a refused start (the microphone said no): the next press is a new dictation,
    /// not a stuck one (the gesture machine is told with `abandon`).
    @Test func aRefusedMicrophoneDoesNotLeaveTheGestureStuck() async throws {
        var plan = SourceBox.Plan()
        plan.mic.refuseStart = true
        let rig = try Rig(plan: plan)
        defer { rig.remove() }
        rig.press()
        #expect(await eventually { rig.pill.last == .failed })
        #expect(await rig.settle())
        rig.key(.trigger, down: false)  // nothing is running, so there is no tail to wait for

        rig.sources.set { $0.mic.refuseStart = false }
        rig.recognizer.script(["jetzt geht es"])
        #expect(await rig.dictate(seconds: 0.5, keepPlaying: false))
        #expect(rig.target.field == "jetzt geht es")
    }
}
