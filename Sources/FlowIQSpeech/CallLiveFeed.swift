/// Pumps a call lease into its live recognizers, never audio inside a dictation window (R-102, M.1).
public final class CallLiveFeed: Sendable {
    public let track: TrackKind
    let chunks: AsyncStream<AudioChunk>, live: [any LiveRecognizer]
    private let windows = Mutex<[(start: UInt64, end: UInt64?)]>([])
    public init(track: TrackKind, chunks: AsyncStream<AudioChunk>, live: [any LiveRecognizer]) {
        (self.track, self.chunks, self.live) = (track, chunks, live)
    }
    public func start() {
        Task { [self] in
            for await chunk in chunks where !inDictation(chunk.hostTime) { live.forEach { $0.feed(chunk) } }
        }
    }
    public func dictationStarted(at host: UInt64) { windows.withLock { $0.append((host, nil)) } }
    public func dictationEnded(at host: UInt64) {
        windows.withLock { w in if let i = w.lastIndex(where: { $0.end == nil }) { w[i].end = host } }
    }
    func inDictation(_ t: UInt64) -> Bool { windows.withLock { $0.contains { t >= $0.start && t < ($0.end ?? .max) } } }
}

/// Level and silent-track guard of one live track (R-040, R-045), fed beside the recognizer.
public final class TrackMeter: Sendable {
    private let state: Mutex<(guard: TrackGuard, level: Float)>
    public init(_ kind: TrackKind) { state = Mutex((TrackGuard(kind: kind), 0)) }
    public func take(_ chunk: AudioChunk) {
        let peak = chunk.samples.reduce(Float(0)) { max($0, abs($1)) }
        state.withLock { s in _ = s.guard.ingest(chunk, peerHasTone: true); s.level = peak }
    }
    public var level: Float { state.withLock { $0.level } }
    public var silent: Bool { state.withLock { $0.guard.level > .none } }
}

/// Feeds a live session through `CallLiveFeed`, so dictation audio never reaches it (R-102).
public struct SessionFeed: LiveRecognizer {
    public let session: LiveSession, meter: TrackMeter
    public init(session: LiveSession, meter: TrackMeter) { (self.session, self.meter) = (session, meter) }
    public var engine: LiveEngine { .appleLocal }
    public var events: AsyncStream<LiveEvent> { AsyncStream { $0.finish() } }
    public func start(_ setup: LiveSetup) async throws {}
    public func feed(_ chunk: AudioChunk) { meter.take(chunk); session.feed(chunk) }
    public func finish() async {}
}
