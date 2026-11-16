import Synchronization

/// Memory and CPU of this process (A.2, R-088).
public struct ResourceSample: Sendable, Equatable {
    /// `phys_footprint`, the value Activity Monitor shows as memory.
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    /// User plus system time of all threads, finished ones included.
    public let cpuNanos: UInt64
    public var fields: [String: LogValue] {
        ["footprint_mb": .double(Double(footprintBytes) / 1_048_576),
         "resident_mb": .double(Double(residentBytes) / 1_048_576),
         "cpu_ms": .double(Double(cpuNanos) / 1_000_000)]
    }
}

/// Reads `task_info` off the main thread. No timer: callers sample on events (A.2: idle has no timer).
public enum ResourceProbe {
    public struct Failure: Error, Equatable {
        public let call: String
        public let code: Int32
    }
    @concurrent
    public static func sample() async throws(Failure) -> ResourceSample {
        assert(pthread_main_np() == 0, "ResourceProbe must not run on the main thread")
        let vm: task_vm_info_data_t = try info(TASK_VM_INFO, "TASK_VM_INFO")
        let time: task_absolutetime_info_data_t = try info(TASK_ABSOLUTETIME_INFO, "TASK_ABSOLUTETIME_INFO")
        let ticks = Double(time.total_user + time.total_system)
        return ResourceSample(footprintBytes: vm.phys_footprint, residentBytes: vm.resident_size,
                              cpuNanos: UInt64(ticks * MachTime.nanosPerTick))
    }
    private static func info<T>(_ flavor: Int32, _ name: String) throws(Failure) -> T {
        let words = MemoryLayout<T>.size / MemoryLayout<natural_t>.size
        var count = mach_msg_type_number_t(words)
        let buffer = UnsafeMutablePointer<integer_t>.allocate(capacity: words)
        buffer.initialize(repeating: 0, count: words) // fields the kernel does not fill read as 0
        defer { buffer.deallocate() }
        let result = task_info(mach_task_self(), task_flavor_t(flavor), buffer, &count)
        guard result == KERN_SUCCESS else { throw Failure(call: name, code: result) }
        return UnsafeRawPointer(buffer).loadUnaligned(as: T.self)
    }
}

/// The C macro `mach_task_self()` is not imported into Swift (SDK 27.2); this restores the name.
func mach_task_self() -> mach_port_t { mach_task_self_ }

/// Periodic memory and CPU line for performance reviews (16.11., beyond A.2's event-only sampling): every
/// 60 s idle, every 10 s while `recording` says so; `cpu_pct` over the interval.
public final class ResourceMonitor: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    public init() {}
    public func start(log: EventLog, recording: @escaping @Sendable () async -> Bool) {
        let loop = Task.detached(priority: .utility) {
            var last: (cpu: UInt64, at: ContinuousClock.Instant)?
            while !Task.isCancelled {
                let busy = await recording()
                do {
                    let s = try await ResourceProbe.sample(), now = ContinuousClock.now
                    let pct = last.map { Double(s.cpuNanos - $0.cpu) / ((now - $0.at) / .nanoseconds(1)) * 100 } ?? 0
                    log.record(LogEvent("resources", s.fields.merging(["reason": "periodic", "recording": .bool(busy),
                                                                        "cpu_pct": .double(pct)]) { a, _ in a }))
                    last = (s.cpuNanos, now)
                } catch { log.record(.failure("resources_failed", error)) }
                guard await ContinuousClock().pause(busy ? .seconds(10) : .seconds(60)) else { return }
            }
        }
        task.withLock { $0?.cancel(); $0 = loop }
    }
    public func stop() { task.withLock { $0?.cancel() } }
}
