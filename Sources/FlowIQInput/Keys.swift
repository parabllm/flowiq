/// The keys the gesture machine tells apart (A.3). `trigger` is Fn in production, right Option in development.
public enum PhysicalKey: Sendable, Equatable { case trigger, space, escape, v, other }

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1), control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4), command = Self(rawValue: 8)
    /// From `CGEventFlags` raw values: shift bit 17, control 18, alternate 19, command 20.
    init(flagsRaw: UInt64) {
        let bits: [(UInt64, Self)] = [(1 << 17, .shift), (1 << 18, .control), (1 << 19, .option), (1 << 20, .command)]
        self = bits.reduce(into: []) { if flagsRaw & $1.0 != 0 { $0.insert($1.1) } }
    }
}

/// One key edge without any character (R-014, A.3); `at` in nanoseconds of the caller's clock.
public struct KeyEvent: Sendable, Equatable {
    public let key: PhysicalKey, down: Bool, modifiers: KeyModifiers, at: UInt64
    public init(_ key: PhysicalKey, down: Bool, modifiers: KeyModifiers = [], at: UInt64) {
        (self.key, self.down, self.modifiers, self.at) = (key, down, modifiers, at)
    }
}

public enum Shortcut: String, Sendable, CaseIterable {
    case callGerman, callEnglish, roomGerman, roomEnglish, correctLast, rawVersion
}

public enum InputAction: Sendable, Equatable {
    case start, stop, lock, cancel, chordAbort, reinsert
    case shortcut(Shortcut)
}

/// Raw tap values to key events (A.3, D): Fn (63, bit 23) in production, right Option (61, bit 6) in development.
public struct KeyMapper: Sendable {
    public let profile: Profile
    private var triggerDown = false
    public init(profile: Profile) { self.profile = profile }
    public mutating func map(keyCode: Int64, flagsRaw: UInt64, isFlagsChanged: Bool, isKeyDown: Bool,
                             at: UInt64) -> KeyEvent? {
        let (code, mask): (Int64, UInt64) = profile == .production ? (63, 1 << 23) : (61, 1 << 6)
        guard !isFlagsChanged else {
            guard keyCode == code, (flagsRaw & mask != 0) != triggerDown else { return nil }
            triggerDown.toggle()
            return KeyEvent(.trigger, down: triggerDown, at: at)
        }
        let key = [49: PhysicalKey.space, 53: .escape, 9: .v][keyCode] ?? .other
        return KeyEvent(key, down: isKeyDown, modifiers: KeyModifiers(flagsRaw: flagsRaw), at: at)
    }
}
