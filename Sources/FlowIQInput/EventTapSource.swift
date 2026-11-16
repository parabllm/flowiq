import CoreGraphics

/// The real key source (A.3): listen-only `CGEventTap` on its own thread, revived every 30 s; needs Input Monitoring.
/// `start` is idempotent: one tap, one thread (1 MB stack, a second guard only), one safety net; `stop` ends all.
public final class EventTapSource: KeyEventSource {
    public enum Failure: Error { case notPermitted, tapRefused }
    static let safetyNet = Duration.seconds(30), lateAfter: UInt64 = 500_000_000
    private let context: TapContext, net = Mutex<Task<Void, Never>?>(nil)
    public init(profile: Profile, log: EventLog) { context = TapContext(profile: profile, log: log) }
    public func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws {
        guard CGPreflightListenEventAccess() else { throw Failure.notPermitted }
        guard context.tap.withLock({ $0 }) == nil else { return }
        context.handler.withLock { $0 = Handler(call: handler) }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [context] in context.run(ready) }
        (thread.name, thread.qualityOfService, thread.stackSize) = ("flowiq.input.tap", .userInteractive, 1 << 20)
        thread.start()
        ready.wait()
        guard context.tap.withLock({ $0 }) != nil else { throw Failure.tapRefused }
        let task = Task { [context] in
            repeat {
                do { try await Task.sleep(for: Self.safetyNet) } catch { return }
            } while context.enableIfNeeded("safety_net")
        }
        net.withLock { $0?.cancel(); $0 = task }
    }
    public func stop() {
        net.withLock { $0?.cancel(); $0 = nil }
        context.stop()
    }
}

/// A bare closure (or a tuple with one) in a `Mutex` gains two thunks at every `withLock`: each key ran one level
/// deeper until the tap thread's stack overflowed (16.11., 2 h 20 min, 12 369 frames). Forbidden in check.sh.
struct Handler: Sendable { let call: @Sendable (KeyEvent) -> Void }

final class TapContext: Sendable {
    let handler = Mutex<Handler?>(nil), tap = Mutex<(port: CFMachPort, loop: CFRunLoop)?>(nil)
    private let mapper: Mutex<KeyMapper>, log: EventLog
    init(profile: Profile, log: EventLog) {
        mapper = Mutex(KeyMapper(profile: profile))
        self.log = log
    }
    func run(_ ready: DispatchSemaphore) {
        Census.add("taps", 1)  // the thread holds the context, so the tap borrows it unretained
        defer { Census.add("taps", -1) }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        let installed = tap.withLock { slot -> Bool in
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: mask, callback: tapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            slot = (port, CFRunLoopGetCurrent())
            return true
        }
        ready.signal()
        if installed { CFRunLoopRun() }
    }
    func stop() {
        handler.withLock { $0 = nil }
        tap.withLock { tap in
            if let tap { CFMachPortInvalidate(tap.port); CFRunLoopStop(tap.loop) }  // the tap thread ends
            tap = nil
        }
    }
    /// False once the tap is gone.
    func enableIfNeeded(_ reason: String) -> Bool {
        let (exists, switched) = tap.withLock { slot -> (Bool, Bool) in
            guard let port = slot?.port, !CGEvent.tapIsEnabled(tap: port) else { return (slot != nil, false) }
            CGEvent.tapEnable(tap: port, enable: true)
            return (true, true)
        }
        if switched { log.record(LogEvent("tap_reenabled", level: .error, ["reason": .string(reason)])) }
        return exists
    }
    func receive(_ type: CGEventType, _ event: CGEvent) {
        guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else {
            _ = enableIfNeeded(type == .tapDisabledByTimeout ? "timeout" : "user_input")
            return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != PostedEvents.tag,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let now = MachTime.nanos(ticks: MachTime.now())
        // Event stamps are uptime nanoseconds [E, T2]; implausible ones (future, over 60 s old) use the callback time.
        let shifted = event.timestamp &+ (now &- clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let at = shifted <= now && now - shifted < 60_000_000_000 ? shifted : now
        let mapped = mapper.withLock {
            $0.map(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flagsRaw: event.flags.rawValue,
                   isFlagsChanged: type == .flagsChanged, isKeyDown: type == .keyDown, at: at)
        }
        guard let mapped else { return }
        if now - at > EventTapSource.lateAfter {  // R-015: 0 queued key presses
            log.record(LogEvent("key_late", level: .error, ["ms": .double(Double(now - at) / 1_000_000)]))
        }
        handler.withLock { $0 }?.call(mapped)
    }
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue().receive(type, event) }
    return Unmanaged.passUnretained(event)
}
