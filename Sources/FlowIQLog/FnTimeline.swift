/// Clock for all latency marks: `mach_continuous_time` ticks (keeps counting through sleep).
public enum MachTime {
    public static func now() -> UInt64 { mach_continuous_time() }
    /// Signed difference `to - from` in milliseconds.
    public static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(Int64(bitPattern: end &- start)) * nanosPerTick / 1_000_000
    }
    /// Key events carry nanoseconds on this clock (FlowIQInput); marks are ticks.
    public static func ticks(nanos: UInt64) -> UInt64 { UInt64(Double(nanos) / nanosPerTick) }
    public static func nanos(ticks: UInt64) -> UInt64 { UInt64(Double(ticks) * nanosPerTick) }
    static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
}

/// Measuring points of one dictation, docs/ARCHITEKTUR.md appendix C (t0 to t13).
public enum FnMark: String, Sendable, CaseIterable {
    case keyDown = "t0", callback = "t1", pillShown = "t2", micStart = "t3", firstBuffer = "t4"
    case recognizerAttached = "t5", firstResult = "t6", keyUp = "t7", streamClosed = "t8"
    case recognized = "t9", textStage = "t10", journal = "t11", pasted = "t12", confirmed = "t13"
}

/// Timestamps of one dictation, closed as exactly one log event.
public struct FnTimeline: Sendable, Equatable {
    public let dictationID: String
    public private(set) var marks: [FnMark: UInt64] = [:]
    public init(dictationID: String) { self.dictationID = dictationID }
    public mutating func mark(_ mark: FnMark, at ticks: UInt64 = MachTime.now()) { marks[mark] = ticks }
    public func milliseconds(from start: FnMark, to end: FnMark) -> Double? {
        guard let a = marks[start], let b = marks[end] else { return nil }
        return MachTime.milliseconds(from: a, to: b)
    }
    /// `fn.timeline` with every mark as `<tN>_ms` relative to t0 (or the earliest mark without t0).
    public func event() -> LogEvent {
        var fields: [String: LogValue] = ["id": .string(dictationID)]
        if let origin = marks[.keyDown] ?? marks.values.min() {
            for (mark, ticks) in marks {
                fields["\(mark.rawValue)_ms"] = .double(MachTime.milliseconds(from: origin, to: ticks))
            }
        }
        return LogEvent("fn.timeline", fields)
    }
}
