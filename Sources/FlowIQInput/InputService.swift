@_exported import FlowIQLog
@_exported import Synchronization

/// The event tap in the app, a synthetic source in tests; `start` throws when it cannot be installed.
public protocol KeyEventSource: Sendable {
    func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws
    func stop()
}

/// The pill shows states, never text (R-021, R-081).
public enum PillState: Sendable, Equatable { case hidden, dictating, notInserted, failed }

/// Callable from any thread; the app's pill makes exactly one hop to the main thread (E3).
public protocol PillSink: Sendable { func set(_ state: PillState) }

/// One action with its marks (appendix C): key nanoseconds, t1 and t2 ticks; `session` counts dictation starts.
public struct InputEnvelope: Sendable {
    public let action: InputAction, eventNanos: UInt64, callbackTicks: UInt64, pillTicks: UInt64?, session: UInt64
}

/// Runs the gesture machine on the source's thread (A.3, appendix C); nothing here waits, a tap resolves on the clock.
public final class InputService: Sendable {
    private struct State {
        var machine: GestureMachine, session: UInt64 = 0, tick: Task<Void, Never>? = nil, watching = false
    }
    public let stream: AsyncStream<InputEnvelope>
    private let output: AsyncStream<InputEnvelope>.Continuation
    private let source: any KeyEventSource, clock: any Clock<Duration>, pill: any PillSink, log: EventLog
    private let state: Mutex<State>
    public init(source: any KeyEventSource, profile: Profile, clock: any Clock<Duration>, pill: any PillSink,
                log: EventLog) {
        (stream, output) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (self.source, self.clock, self.pill, self.log) = (source, clock, pill, log)
        state = Mutex(State(machine: GestureMachine(profile: profile)))
    }
    public func start() throws {
        try source.start { [weak self] event in self?.step(event.at) { $0.handle(event) } }
        state.withLock { $0.watching = true }
    }
    public func stop() {
        source.stop()
        state.withLock { ($0.watching, _) = (false, $0.tick?.cancel()) }
    }
    /// A key since the last insertion; without a running tap nobody watches, so it counts as typed (Muss 3).
    public var keySinceInsert: Bool { state.withLock { !$0.watching || $0.machine.keySinceInsert } }
    public func noteInsert() { state.withLock { $0.machine.noteInsert() } }
    /// Dictation `session` ended before its stop (microphone refused): the gesture machine starts over.
    public func abandon(session: UInt64) { state.withLock { if $0.session == session { $0.machine.abandon() } } }
    /// The result of dictation `session` (nil: the current one) reaches the pill only while no newer one started.
    public func settlePill(_ pillState: PillState, session: UInt64? = nil) {
        state.withLock { s in
            guard session.map({ $0 == s.session }) ?? !s.machine.isRecording else { return }
            pill.set(pillState)
        }
    }
    /// A global shortcut (main thread in the app): only handed on.
    public func post(_ shortcut: Shortcut) {
        let now = MachTime.now(), session = state.withLock { $0.session }
        output.yield(InputEnvelope(action: .shortcut(shortcut), eventNanos: MachTime.nanos(ticks: now),
                                   callbackTicks: now, pillTicks: nil, session: session))
    }
    /// The pill changes under the same lock as the session count, so a late result never hides a newer pill.
    private func step(_ at: UInt64, _ change: (inout GestureMachine) -> [InputAction]) {
        let callback = MachTime.now()
        var pillTicks: UInt64?
        let (actions, session, pending) = state.withLock { s -> ([InputAction], UInt64, UInt64?) in
            s.tick?.cancel()
            let actions = change(&s.machine)
            for action in actions where [.start, .cancel, .chordAbort].contains(action) {
                if action == .start { s.session += 1 }
                pill.set(action == .start ? .dictating : .hidden)
                pillTicks = MachTime.now()
            }
            return (actions, s.session, s.machine.pendingStop)
        }
        for action in actions {
            if action == .chordAbort { log.record(LogEvent("chord_abort", ["session": .int(Int64(session))])) }
            output.yield(InputEnvelope(action: action, eventNanos: at, callbackTicks: callback, pillTicks: pillTicks,
                                       session: session))
        }
        guard let pending else { return }
        let wait = Duration.nanoseconds(Int64(pending > at ? pending - at : 0))
        let task = Task { [weak self, clock] in
            do { try await clock.sleep(for: wait) } catch { return }
            self?.step(pending) { $0.tick(now: pending) }
        }
        state.withLock { $0.tick = task }
    }
}
