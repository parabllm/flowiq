/// Call and room keys (16.11.): ⌘⌥U and ⌘⌥R alone are German, with E held as well English, in either order.
/// Pure: the caller hands in key edges with their time and asks `deadline` for the one pending decision.
public struct LanguageChord: Sendable {
    /// How long a lone U or R waits for an E pressed right after it; an E already down decides at once.
    public static let window: UInt64 = 150_000_000
    private var eDown = false, pending: (letter: HotKey, until: UInt64)?
    public init() {}
    /// When the pending U or R turns German (nanoseconds); nil while nothing waits.
    public var deadline: UInt64? { pending?.until }
    /// One edge of a registered key; `running` says the letter's recording runs or starts, so it stops at once.
    public mutating func handle(_ key: HotKey, down: Bool, at: UInt64, running: Bool) -> [Shortcut] {
        var out = tick(now: at)
        switch (key, down) {
        case (.english, true):
            eDown = true
            if let p = pending { (pending, out) = (nil, out + [Self.shortcut(p.letter, english: true)]) }
        case (.english, false): releaseE()
        case (.call, true), (.room, true):
            let bounce = pending?.letter == key  // the same letter again inside the wait: one start, not two
            if let p = pending { (pending, out) = (nil, out + [Self.shortcut(p.letter, english: false)]) }
            if bounce { break }
            if eDown || running { out.append(Self.shortcut(key, english: eDown)) } else {
                pending = (key, at + Self.window)
            }
        case (.correct, true): out.append(.correctLast)
        default: break  // the release of U, R or K
        }
        return out
    }
    /// E is up, also when its release never came (⌘ let go first): it must not make the next letter English.
    public mutating func releaseE() { eDown = false }
    /// The wait ran out without an E: German.
    public mutating func tick(now: UInt64) -> [Shortcut] {
        guard let p = pending, now >= p.until else { return [] }
        pending = nil
        return [Self.shortcut(p.letter, english: false)]
    }
    static func shortcut(_ letter: HotKey, english: Bool) -> Shortcut {
        letter == .call ? (english ? .callEnglish : .callGerman) : (english ? .roomEnglish : .roomGerman)
    }
}
