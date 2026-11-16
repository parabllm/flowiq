// Group 1: the gesture machine as a table (A.3, G.1 "Input", R-014). Pure: events in, actions out, no thread,
// no clock; a short tap is resolved by `tick(now:)` or by the next event.
//
// Contract used here (from A.3 and R-014, read as follows; see README "Auslegungen"):
//  - key down starts at once (no waiting), key up of a hold stops at once;
//  - double tap = two key downs within 0.36 s of each other: the second one locks (the dictation keeps running);
//    a tap shorter than the window stops only after the window has passed without a second down;
//  - trigger + Space while held locks; the next key down while locked stops; Escape cancels held or locked;
//  - production (Fn): other keys while held are ignored; development (right option): any other key while held
//    discards the dictation (chordAbort), except Space (lock) and Escape (cancel);
//  - contact bounce: an up right after a down, or a down right after an up, inside the bounce window is noise.
import Testing
@testable import FlowIQCore
@testable import FlowIQInput

private let base: UInt64 = 5_000_000_000
/// Gap used for bounce noise; the bounce window is below 10 ms, a deliberate re-press is far above it.
private let bounceGap = 4  // ASSUMPTION: the machine's bounce window is 10 ms (any value above 4 ms and far below a deliberate tap)

enum Input: Sendable {
    case triggerDown, triggerUp, spaceDown, spaceUp, escapeDown, otherDown, otherUp, tick
    case reinsert(KeyModifiers)
}

struct Step: Sendable {
    let ms: Int
    let input: Input
    let expect: [InputAction]
    init(_ ms: Int, _ input: Input, _ expect: [InputAction] = []) {
        self.ms = ms
        self.input = input
        self.expect = expect
    }
}

struct GestureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let profile: Profile
    let steps: [Step]
    var testDescription: String { name }
}

private func apply(_ step: Step, to machine: inout GestureMachine) -> [InputAction] {  // ASSUMPTION: GestureMachine is a value type with mutating handle(_:) and tick(now:)
    let at = base + UInt64(step.ms) * 1_000_000
    switch step.input {
    case .tick: return machine.tick(now: at)  // ASSUMPTION: tick(now:) takes nanoseconds and returns the actions that became due
    case .triggerDown: return machine.handle(KeyEvent(.trigger, down: true, at: at))
    case .triggerUp: return machine.handle(KeyEvent(.trigger, down: false, at: at))
    case .spaceDown: return machine.handle(KeyEvent(.space, down: true, at: at))
    case .spaceUp: return machine.handle(KeyEvent(.space, down: false, at: at))
    case .escapeDown: return machine.handle(KeyEvent(.escape, down: true, at: at))
    case .otherDown: return machine.handle(KeyEvent(.other, down: true, at: at))
    case .otherUp: return machine.handle(KeyEvent(.other, down: false, at: at))
    case .reinsert(let modifiers): return machine.handle(KeyEvent(.v, down: true, modifiers: modifiers, at: at))
    }
}

private let shared: [GestureCase] = [
    GestureCase(name: "hold starts at once and stops at release", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(800, .triggerUp, [.stop])]),
    GestureCase(name: "key repeat while held is ignored", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(30, .triggerDown), Step(60, .triggerDown), Step(900, .triggerUp, [.stop])]),
    GestureCase(name: "up without down is ignored", profile: .production, steps: [
        Step(0, .triggerUp), Step(50, .triggerUp)]),
    GestureCase(name: "double tap locks, next tap stops", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(250, .triggerDown, [.lock]),
        Step(350, .triggerUp), Step(3000, .triggerDown, [.stop]), Step(3100, .triggerUp)]),
    GestureCase(name: "second tap after the window starts a new dictation", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(380, .triggerDown, [.stop, .start]),
        Step(900, .triggerUp, [.stop])]),
    GestureCase(name: "single short tap stops only after the 0.36 s window", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(300, .tick), Step(359, .tick),
        Step(361, .tick, [.stop])]),
    GestureCase(name: "tap that stops a lock does not arm a double tap", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(250, .triggerDown, [.lock]), Step(350, .triggerUp),
        Step(3000, .triggerDown, [.stop]), Step(3050, .triggerUp), Step(3200, .triggerDown, [.start]),
        Step(3800, .triggerUp, [.stop])]),
    GestureCase(name: "escape while held cancels, the release after it is silent", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(300, .escapeDown, [.cancel]), Step(500, .triggerUp),
        Step(900, .triggerDown, [.start]), Step(1500, .triggerUp, [.stop])]),
    GestureCase(name: "escape while locked cancels", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(250, .triggerDown, [.lock]), Step(350, .triggerUp),
        Step(2000, .escapeDown, [.cancel]), Step(3000, .triggerDown, [.start])]),
    GestureCase(name: "escape while idle does nothing", profile: .production, steps: [
        Step(0, .escapeDown), Step(100, .escapeDown)]),
    GestureCase(name: "trigger plus space locks, release is silent, next tap stops", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(400, .spaceDown, [.lock]), Step(450, .spaceUp), Step(600, .triggerUp),
        Step(2000, .triggerDown, [.stop]), Step(2100, .triggerUp)]),
    GestureCase(name: "space repeat after the lock changes nothing", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(400, .spaceDown, [.lock]), Step(430, .spaceDown), Step(460, .spaceDown),
        Step(600, .triggerUp)]),
    GestureCase(name: "space alone starts nothing", profile: .production, steps: [
        Step(0, .spaceDown), Step(50, .spaceUp)]),
    GestureCase(name: "bounce at press is ignored", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(bounceGap, .triggerUp), Step(2 * bounceGap, .triggerDown),
        Step(900, .triggerUp, [.stop])]),
    GestureCase(name: "bounce at release is ignored", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(800, .triggerUp, [.stop]), Step(800 + bounceGap, .triggerDown),
        Step(800 + 2 * bounceGap, .triggerUp), Step(2000, .triggerDown, [.start]), Step(2600, .triggerUp, [.stop])]),
    GestureCase(name: "bounce at the release of a tap does not count as a double tap", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(100 + bounceGap, .triggerDown),
        Step(100 + 2 * bounceGap, .triggerUp), Step(400, .tick, [.stop])]),
    GestureCase(name: "reinsert: control and command with V", profile: .production, steps: [
        Step(0, .reinsert([.control, .command]), [.reinsert]), Step(100, .reinsert([.command])),
        Step(200, .reinsert([.control])), Step(300, .reinsert([]))]),
]

private let production: [GestureCase] = [
    GestureCase(name: "production: other keys while held are ignored", profile: .production, steps: [
        Step(0, .triggerDown, [.start]), Step(200, .otherDown), Step(250, .otherUp), Step(800, .triggerUp, [.stop])]),
]

private let development: [GestureCase] = [
    GestureCase(name: "dev: other key while held discards the dictation", profile: .development, steps: [
        Step(0, .triggerDown, [.start]), Step(200, .otherDown, [.chordAbort]), Step(250, .otherUp),
        Step(800, .triggerUp), Step(1500, .triggerDown, [.start]), Step(2100, .triggerUp, [.stop])]),
    GestureCase(name: "dev: a key typed before the trigger is no chord", profile: .development, steps: [
        Step(0, .otherDown), Step(50, .otherUp), Step(100, .triggerDown, [.start]), Step(700, .triggerUp, [.stop])]),
    GestureCase(name: "dev: a key typed while locked is no chord", profile: .development, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(250, .triggerDown, [.lock]), Step(350, .triggerUp),
        Step(1000, .otherDown), Step(1050, .otherUp), Step(3000, .triggerDown, [.stop])]),
    GestureCase(name: "dev: escape is a cancel, not a chord", profile: .development, steps: [
        Step(0, .triggerDown, [.start]), Step(300, .escapeDown, [.cancel]), Step(500, .triggerUp)]),
    GestureCase(name: "dev: trigger plus space locks, not a chord", profile: .development, steps: [
        Step(0, .triggerDown, [.start]), Step(400, .spaceDown, [.lock]), Step(600, .triggerUp),
        Step(2000, .triggerDown, [.stop])]),
    GestureCase(name: "dev: double tap locks like Fn", profile: .development, steps: [
        Step(0, .triggerDown, [.start]), Step(100, .triggerUp), Step(250, .triggerDown, [.lock]), Step(350, .triggerUp),
        Step(3000, .triggerDown, [.stop])]),
    GestureCase(name: "dev: reinsert is control, option, command with V", profile: .development, steps: [
        Step(0, .reinsert([.control, .option, .command]), [.reinsert]), Step(100, .reinsert([.control, .command])),
        Step(200, .reinsert([.command]))]),
]

struct GestureMachineTests {
    @Test(arguments: shared + production + development)
    func tableCase(_ c: GestureCase) {
        var machine = GestureMachine(profile: c.profile)  // ASSUMPTION: GestureMachine(profile:), the profile picks the other-key rule
        for (index, step) in c.steps.enumerated() {
            let actual = apply(step, to: &machine)
            #expect(actual == step.expect, "\(c.name): step \(index) at \(step.ms) ms")
        }
    }

    @Test(arguments: [Profile.production, Profile.development])
    func sameInputGivesSameActions(_ profile: Profile) {
        // The machine is a pure value: two copies fed the same events agree (no hidden clock, no global).
        var a = GestureMachine(profile: profile)  // ASSUMPTION: GestureMachine(profile:)
        var b = GestureMachine(profile: profile)  // ASSUMPTION: GestureMachine(profile:)
        let steps = [Step(0, .triggerDown), Step(100, .triggerUp), Step(250, .triggerDown), Step(300, .triggerUp)]
        for step in steps {
            #expect(apply(step, to: &a) == apply(step, to: &b))
        }
    }

    @Test func noKeyHistoryBeyondOneFlag() {
        // R-014 / A.3: no character is stored; the only memory is "a key since the insert, yes or no".
        var machine = GestureMachine(profile: .production)  // ASSUMPTION: GestureMachine(profile:)
        machine.noteInsert()  // ASSUMPTION: noteInsert() is called when a dictation was inserted
        #expect(machine.keySinceInsert == false)  // ASSUMPTION: keySinceInsert is a Bool property
        _ = machine.handle(KeyEvent(.trigger, down: true, at: base))
        _ = machine.handle(KeyEvent(.trigger, down: false, at: base + 800_000_000))
        #expect(machine.keySinceInsert == false)  // the trigger itself is not "a key typed"
        _ = machine.handle(KeyEvent(.other, down: true, at: base + 900_000_000))
        #expect(machine.keySinceInsert == true)
        machine.noteInsert()  // ASSUMPTION: noteInsert()
        #expect(machine.keySinceInsert == false)
        _ = machine.handle(KeyEvent(.space, down: true, at: base + 1_000_000_000))
        #expect(machine.keySinceInsert == true)
    }

    @Test func keyEventCarriesNoCharacter() {
        // Code-level guard on top of the G-CHECK search: the event type has no field that could hold text.
        let event = KeyEvent(.other, down: true, at: base)
        for child in Mirror(reflecting: event).children {
            #expect(!(child.value is String), "KeyEvent.\(child.label ?? "?") would carry text")
            #expect(!(child.value is Character), "KeyEvent.\(child.label ?? "?") would carry text")
        }
    }
}

/// Mapping of raw tap values to key events (A.3, Anhang D). Key codes are macOS virtual key codes, the flag values
/// the CGEventFlags raw values (alternate 0x80000, secondary Fn 0x800000, right-option device bit 0x40).
struct KeyMapperTests {
    private let alt: UInt64 = 0x80000
    private let rightAltDevice: UInt64 = 0x40
    private let fn: UInt64 = 0x800000

    @Test func developmentUsesRightOptionOnly() {
        var mapper = KeyMapper(profile: .development)  // ASSUMPTION: KeyMapper(profile:) is a value that remembers the trigger state
        let down = mapper.map(keyCode: 61, flagsRaw: alt | rightAltDevice, isFlagsChanged: true, isKeyDown: false, at: base)  // ASSUMPTION: KeyMapper.map(keyCode:flagsRaw:isFlagsChanged:isKeyDown:at:) -> KeyEvent?
        #expect(down == KeyEvent(.trigger, down: true, at: base))
        let up = mapper.map(keyCode: 61, flagsRaw: 0, isFlagsChanged: true, isKeyDown: false, at: base + 1)  // ASSUMPTION: KeyMapper.map(...)
        #expect(up == KeyEvent(.trigger, down: false, at: base + 1))
        let left = mapper.map(keyCode: 58, flagsRaw: alt, isFlagsChanged: true, isKeyDown: false, at: base + 2)  // ASSUMPTION: KeyMapper.map(...)
        #expect(left?.key != .trigger)  // the left option key is no trigger
        let fnKey = mapper.map(keyCode: 63, flagsRaw: fn, isFlagsChanged: true, isKeyDown: false, at: base + 3)  // ASSUMPTION: KeyMapper.map(...)
        #expect(fnKey?.key != .trigger)  // the development profile never reacts to Fn
    }

    @Test func productionUsesFnOnly() {
        var mapper = KeyMapper(profile: .production)  // ASSUMPTION: KeyMapper(profile:)
        let down = mapper.map(keyCode: 63, flagsRaw: fn, isFlagsChanged: true, isKeyDown: false, at: base)  // ASSUMPTION: KeyMapper.map(...)
        #expect(down == KeyEvent(.trigger, down: true, at: base))
        let up = mapper.map(keyCode: 63, flagsRaw: 0, isFlagsChanged: true, isKeyDown: false, at: base + 1)  // ASSUMPTION: KeyMapper.map(...)
        #expect(up == KeyEvent(.trigger, down: false, at: base + 1))
        let option = mapper.map(keyCode: 61, flagsRaw: alt | rightAltDevice, isFlagsChanged: true, isKeyDown: false, at: base + 2)  // ASSUMPTION: KeyMapper.map(...)
        #expect(option?.key != .trigger)
    }

    @Test(arguments: [Profile.production, Profile.development])
    func plainKeysMapToTheirNames(_ profile: Profile) {
        var mapper = KeyMapper(profile: profile)  // ASSUMPTION: KeyMapper(profile:)
        let space = mapper.map(keyCode: 49, flagsRaw: 0, isFlagsChanged: false, isKeyDown: true, at: base)  // ASSUMPTION: KeyMapper.map(...)
        #expect(space?.key == .space)
        let escape = mapper.map(keyCode: 53, flagsRaw: 0, isFlagsChanged: false, isKeyDown: true, at: base)  // ASSUMPTION: KeyMapper.map(...)
        #expect(escape?.key == .escape)
        let control: UInt64 = 0x40000, command: UInt64 = 0x100000
        let v = mapper.map(keyCode: 9, flagsRaw: control | command, isFlagsChanged: false, isKeyDown: true, at: base)  // ASSUMPTION: KeyMapper.map(...)
        #expect(v?.key == .v)
        #expect(v?.modifiers == [.control, .command])
    }
}
