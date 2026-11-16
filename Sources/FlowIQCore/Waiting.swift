import Synchronization

/// Fires once with a value; every waiter before and after gets it, a cancelled waiter gets nil (Paket V, A1).
public final class Latch<Value: Sendable>: Sendable {
    private let state = Mutex<(value: Value?, waiters: [UUID: CheckedContinuation<Value?, Never>])>((nil, [:]))
    public init() {}
    public var value: Value? { state.withLock { $0.value } }
    @discardableResult public func fire(_ value: Value) -> Bool {
        let waiters = state.withLock { s -> [CheckedContinuation<Value?, Never>]? in
            guard s.value == nil else { return nil }
            defer { (s.value, s.waiters) = (value, [:]) }
            return Array(s.waiters.values)
        }
        waiters?.forEach { $0.resume(returning: value) }
        return waiters != nil
    }
    public func wait() async -> Value? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Value?, Never>) in
                let now = state.withLock { s -> Value?? in
                    if let v = s.value { return .some(v) }
                    if Task.isCancelled { return .some(nil) }
                    s.waiters[id] = waiter
                    return nil
                }
                if let now { waiter.resume(returning: now) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
        }
    }
}

/// First of `work` and `limit` on `clock`, nil when the limit came first (Paket V, A2). Unstructured on purpose:
/// the loser is cancelled, and work that ignores cancellation is left behind instead of holding the caller up.
public func within<T: Sendable, E: Error>(_ limit: Duration, clock: any Clock<Duration> = ContinuousClock(),
                                          _ work: @escaping @Sendable () async throws(E) -> T) async throws(E) -> T? {
    let (outcomes, sink) = AsyncStream.makeStream(of: Result<T, E>?.self)
    let job = Task {
        do throws(E) { sink.yield(.success(try await work())) } catch { sink.yield(.failure(error)) }
    }
    let timer = Task {
        do { try await clock.sleep(for: limit) } catch { return }
        sink.yield(nil)
    }
    defer { job.cancel(); timer.cancel() }
    for await outcome in outcomes { return try outcome?.get() }
    return nil
}

extension Clock where Duration == Swift.Duration {
    /// Sleeps for `span`; false when cancelled.
    public func pause(_ span: Duration) async -> Bool {
        do { try await sleep(for: span) } catch { return false }
        return true
    }
}
