/// Fan-out of one channel (A.4) on the callback thread (order kept): fills holes over 200 ms, bounds streams at
/// 30 s (`overflow`), drops `late_buffers`; "halbwarm" keeps the last 500 ms.
final class Fanout: Sendable {
    static let limitSeconds = 30.0, prerollSeconds = 0.5, fillLogEvery = 60_000.0
    private struct Subscriber {
        let queue: LeaseQueue, label: String
        var pendingDrops = 0, everDropped = false
    }
    private struct State {
        var subscribers: [UInt64: Subscriber] = [:], generation: UInt64? = nil
        var timeline = TimelineGuard(sampleRate: AudioChunk.channelRate), lastEnd: UInt64?, preroll: [AudioChunk] = []
        var late = 0, fillPendingMs = 0.0, filling = false
    }
    let kind: TrackKind
    private let log: EventLog, state = Mutex(State())
    init(kind: TrackKind, log: EventLog) {
        self.kind = kind
        self.log = log
    }
    func subscribe(_ id: UInt64, label: String) -> AsyncStream<AudioChunk> {
        let queue = LeaseQueue()
        let events = state.withLock { s -> [LogEvent] in
            s.subscribers[id] = Subscriber(queue: queue, label: label)
            let preroll = s.preroll
            s.preroll = []
            return preroll.flatMap { Self.yield($0, to: id, in: &s, kind: kind) }
        }
        events.forEach(log.record)
        return AsyncStream { await queue.next() }
    }
    /// Ends one stream after logging drops not yet reported.
    func finish(_ id: UInt64) {
        let events = state.withLock { s -> [LogEvent] in
            guard let sub = s.subscribers.removeValue(forKey: id) else { return [] }
            sub.queue.finish()
            return sub.pendingDrops > 0 ? [Self.overflow(sub, kind: kind)] : []
        }
        events.forEach(log.record)
    }
    /// Chunks of `generation` pass; nil closes the gate; a fresh start begins a timeline, a switch continues it.
    func admit(_ generation: UInt64?, fresh: Bool = false) {
        state.withLock { s in
            s.generation = generation
            guard fresh else { return }
            (s.timeline, s.lastEnd, s.preroll) = (TimelineGuard(sampleRate: AudioChunk.channelRate), nil, [])
        }
    }
    func deliver(_ chunk: AudioChunk, from generation: UInt64) {
        let events = state.withLock { s -> [LogEvent] in
            guard s.generation == generation else {
                s.late += 1
                guard s.late & (s.late - 1) == 0 else { return [] }  // 1, 2, 4, 8 ...: visible, never a flood
                return [LogEvent("late_buffers", ["track": .string(kind.logName), "total": .int(Int64(s.late))])]
            }
            let out = s.timeline.process(chunk)
            var events = out.chunks.flatMap { Self.distribute($0, in: &s, kind: kind) }
            if let filled = out.filledSeconds {
                events.append(LogEvent("gap_filled", ["track": .string(kind.logName), "ms": .double(filled * 1000),
                                                      "cause": "timeline"]))
            }
            return events
        }
        events.forEach(log.record)
    }
    /// Source down: `seconds` of silence (A.4, B.5), logged at the first fill, every minute and at `endFill`.
    func fillSilence(seconds: Double) {
        let events = state.withLock { s -> [LogEvent] in
            let start = s.lastEnd ?? DispatchTime.now().uptimeNanoseconds
            let count = Int((seconds * AudioChunk.channelRate).rounded())
            guard count > 0 else { return [] }
            let silence = AudioChunk(hostTime: start, sampleRate: AudioChunk.channelRate,
                                     samples: [Float](repeating: 0, count: count))
            var events = s.timeline.process(silence).chunks.flatMap { Self.distribute($0, in: &s, kind: kind) }
            s.fillPendingMs += seconds * 1000
            if !s.filling || s.fillPendingMs >= Self.fillLogEvery { events.append(Self.fillEvent(&s, kind: kind)) }
            s.filling = true
            return events
        }
        events.forEach(log.record)
    }
    func endFill() {
        let event = state.withLock { s -> LogEvent? in
            defer { s.filling = false }
            return s.fillPendingMs > 0 ? Self.fillEvent(&s, kind: kind) : nil
        }
        if let event { log.record(event) }
    }
    private static func fillEvent(_ s: inout State, kind: TrackKind) -> LogEvent {
        defer { s.fillPendingMs = 0 }
        return LogEvent("gap_filled", ["track": .string(kind.logName), "ms": .double(s.fillPendingMs),
                                       "cause": "down"])
    }
    private static func distribute(_ chunk: AudioChunk, in s: inout State, kind: TrackKind) -> [LogEvent] {
        s.lastEnd = chunk.endTime
        if s.subscribers.isEmpty {
            s.preroll.append(chunk)
            while s.preroll.dropFirst().reduce(0.0, { $0 + $1.seconds }) >= prerollSeconds { s.preroll.removeFirst() }
            return []
        }
        return s.subscribers.keys.sorted().flatMap { yield(chunk, to: $0, in: &s, kind: kind) }
    }
    /// A full stream drops the newest chunk; the first drop is logged at once, then every 100 and at the end.
    private static func yield(_ chunk: AudioChunk, to id: UInt64, in s: inout State, kind: TrackKind) -> [LogEvent] {
        guard var sub = s.subscribers[id], !sub.queue.push(chunk, limit: Int(limitSeconds * chunk.sampleRate)) else {
            return []
        }
        defer { s.subscribers[id] = sub }
        sub.pendingDrops += 1
        guard !sub.everDropped || sub.pendingDrops >= 100 else { return [] }
        sub.everDropped = true
        defer { sub.pendingDrops = 0 }
        return [overflow(sub, kind: kind)]
    }
    private static func overflow(_ sub: Subscriber, kind: TrackKind) -> LogEvent {
        LogEvent("overflow", level: .error, ["track": .string(kind.logName), "purpose": .string(sub.label),
                                             "count": .int(Int64(sub.pendingDrops))])
    }
}

/// The buffer of one lease, counted in frames, so the 30 s bound is exact however long the chunks are.
private final class LeaseQueue: Sendable {
    private struct State {
        var items: [AudioChunk] = [], head = 0, frames = 0, finished = false
        var waiter: CheckedContinuation<AudioChunk?, Never>? = nil
    }
    private let state = Mutex(State())
    /// False when the chunk would take the buffer over `limit` frames, or the lease has ended.
    func push(_ chunk: AudioChunk, limit: Int) -> Bool {
        var accepted = false
        let waiter = state.withLock { s -> CheckedContinuation<AudioChunk?, Never>? in
            guard !s.finished, s.frames + chunk.samples.count <= limit else { return nil }
            accepted = true
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            s.items.append(chunk)
            s.frames += chunk.samples.count
            return nil
        }
        waiter?.resume(returning: chunk)
        return accepted
    }
    func finish() {
        let waiter = state.withLock { s -> CheckedContinuation<AudioChunk?, Never>? in
            defer { s.waiter = nil }
            s.finished = true
            return s.waiter
        }
        waiter?.resume(returning: nil)
    }
    /// The next chunk; nil once the lease has ended and everything buffered was taken.
    func next() async -> AudioChunk? {
        await withCheckedContinuation { (waiter: CheckedContinuation<AudioChunk?, Never>) in
            let ready = state.withLock { s -> AudioChunk?? in
                guard s.head < s.items.count else {
                    if s.finished { return .some(nil) }
                    s.waiter = waiter
                    return .none
                }
                let chunk = s.items[s.head]
                s.head += 1
                s.frames -= chunk.samples.count
                if s.head >= 64, s.head * 2 >= s.items.count { (s.items, s.head) = (Array(s.items[s.head...]), 0) }
                return .some(chunk)
            }
            if let ready { waiter.resume(returning: ready) }
        }
    }
}
