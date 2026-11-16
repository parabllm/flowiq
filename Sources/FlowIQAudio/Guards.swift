public enum WarningLevel: Int, Sendable, Comparable {
    case none, stage1, stage2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// SAFETY: silent-track guard (A.4, R-040, K-18), pure: microphone under -60 dBFS for 10 s, desktop digital silence
/// for 10 s (after sound: 3 min while the microphone has sound); stage two 50 s later.
public struct TrackGuard: Sendable {
    static let micFloorDB = -60.0, desktopFloorDB = -90.0
    static let early = 10.0, midCall = 180.0, stageTwoAfter = 50.0
    public let kind: TrackKind
    public private(set) var level = WarningLevel.none
    private var silentFrames = 0, hadTone = false
    public init(kind: TrackKind) { self.kind = kind }
    /// The microphone's answer to the desktop guard of the same call.
    public var hasTone: Bool { hadTone && level == .none }
    public mutating func ingest(_ chunk: AudioChunk, peerHasTone: Bool) -> WarningLevel {
        if !isSilent(chunk.samples) {
            silentFrames = 0
            hadTone = true
            level = .none
            return level
        }
        silentFrames += chunk.samples.count
        let silent = Double(silentFrames) / chunk.sampleRate
        let first = kind == .desktop && hadTone && peerHasTone ? Self.midCall : Self.early
        let now: WarningLevel = silent >= first + Self.stageTwoAfter ? .stage2 : silent >= first ? .stage1 : .none
        level = max(level, now)  // only stronger while the silence lasts
        return level
    }
    private func isSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        if kind == .desktop {
            let floor = Float(pow(10, Self.desktopFloorDB / 20))
            return samples.allSatisfy { abs($0) < floor }
        }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return power <= 0 || 10 * log10(power) < Self.micFloorDB
    }
}

public struct TimelineOutput: Sendable {
    /// Fill chunks first, the incoming chunk last.
    public let chunks: [AudioChunk]
    /// Seconds of silence inserted, nil when nothing was filled.
    public let filledSeconds: Double?
}

/// Keeps a channel's timeline gapless (A.4): jumps over 200 ms filled with silence in chunks of at most a second.
public struct TimelineGuard: Sendable {
    public static let threshold: UInt64 = 200_000_000
    public let sampleRate: Double
    private var nextTime: UInt64?
    public init(sampleRate: Double) { self.sampleRate = sampleRate }
    public mutating func process(_ chunk: AudioChunk) -> TimelineOutput {
        defer { nextTime = chunk.endTime }
        guard let expected = nextTime, chunk.hostTime > expected + Self.threshold else {
            return TimelineOutput(chunks: [chunk], filledSeconds: nil)
        }
        let total = Int((Double(chunk.hostTime - expected) / 1e9 * sampleRate).rounded())
        let second = [Float](repeating: 0, count: Int(sampleRate))  // shared by every full second, copy on write
        var (fill, done) = ([AudioChunk](), 0)
        while done < total {
            let count = min(second.count, total - done)
            let start = expected + UInt64((Double(done) / sampleRate * 1e9).rounded())
            fill.append(AudioChunk(hostTime: start, sampleRate: sampleRate,
                                   samples: count == second.count ? second : Array(second[..<count])))
            done += count
        }
        return TimelineOutput(chunks: fill + [chunk], filledSeconds: Double(total) / sampleRate)
    }
}
