/// Port of Panotti B03 (A.3, R-014), pure: hold, tap 0.36 s, locks, Escape, 10 ms bounce; keeps no character.
public struct GestureMachine: Sendable {
    public static let tapWindow: UInt64 = 360_000_000, bounce: UInt64 = 10_000_000
    enum Phase: Sendable, Equatable { case idle, held(since: UInt64), tapped(until: UInt64), locked }
    public let profile: Profile
    private(set) var phase = Phase.idle
    private var triggerDown = false, lastEdge: UInt64? = nil
    public private(set) var keySinceInsert = false
    public init(profile: Profile) { self.profile = profile }
    public var isRecording: Bool { phase != .idle }
    /// When a pending tap stops (nanoseconds); nil without a pending tap.
    public var pendingStop: UInt64? { if case .tapped(let until) = phase { until } else { nil } }
    public mutating func noteInsert() { keySinceInsert = false }
    /// The dictation could not start (microphone refused): the next down starts a new one.
    public mutating func abandon() { (phase, lastEdge) = (.idle, nil) }
    public mutating func tick(now: UInt64) -> [InputAction] {
        guard case .tapped(let until) = phase, now >= until else { return [] }
        return to(.idle, .stop)
    }
    public mutating func handle(_ event: KeyEvent) -> [InputAction] {
        let out = tick(now: event.at)
        if event.key == .trigger { return out + trigger(event) }
        guard event.down else { return out }
        keySinceInsert = true
        let reinsert: KeyModifiers = profile == .production ? [.control, .command] : [.control, .option, .command]
        switch (event.key, phase) {
        case (.escape, .idle): return out
        case (.escape, _): return out + to(.idle, .cancel)
        case (.space, .held): return out + to(.locked, .lock)
        case (.v, .held) where profile == .development, (.other, .held) where profile == .development:
            return out + to(.idle, .chordAbort)
        case (.v, _) where event.modifiers == reinsert: return out + [.reinsert]
        default: return out
        }
    }
    private mutating func to(_ next: Phase, _ action: InputAction) -> [InputAction] {
        phase = next
        return [action]
    }
    private mutating func trigger(_ event: KeyEvent) -> [InputAction] {
        guard event.down != triggerDown else { return [] }  // key repeat or an up without a down
        if let lastEdge, event.at >= lastEdge, event.at - lastEdge < Self.bounce { return [] }
        triggerDown = event.down
        let before = phase
        var out: [InputAction] = []
        switch (phase, event.down) {
        case (.idle, true): out = to(.held(since: event.at), .start)
        case (.tapped, true): out = to(.locked, .lock)
        case (.locked, true): out = to(.idle, .stop)
        case (.held(let since), false) where event.at - since < Self.tapWindow:
            phase = .tapped(until: since + Self.tapWindow)
        case (.held, false): out = to(.idle, .stop)
        default: break  // the release after a lock, a cancel or a chord abort is silent
        }
        if phase != before { lastEdge = event.at }  // only an edge that did something opens a bounce window
        return out
    }
}
