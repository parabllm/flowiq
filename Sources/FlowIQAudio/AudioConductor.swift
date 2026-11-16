/// Sole owner of microphone and desktop audio (A.4, E1): one open per device, a lease per consumer, the last
/// release stops it; failures are logged, visible and replaced or filled, never silent (Leitsatz 5).
public actor AudioConductor {
    public typealias MicFactory = @Sendable (InputDevice) -> any CaptureSource
    public typealias DesktopFactory = @Sendable () -> any CaptureSource
    /// Desktop restart 1, 5 and 15 s after the end, then every minute (A.4).
    static let restartWaits: [Duration] = [.seconds(1), .seconds(4), .seconds(10)]
    static let restartEvery = Duration.seconds(60), restartMax = 30  // then the source stays down, visibly
    static let fillTick = Duration.milliseconds(100)
    private final class Channel {
        let kind: TrackKind, fanout: Fanout
        var source: (any CaptureSource)?, device: InputDevice?, generation: UInt64 = 0, leases: Set<UInt64> = []
        var down = false, opening: Task<Void, any Error>?, filler: Task<Void, Never>?, restart: Task<Void, Never>?
        var hold: Task<Void, Never>? = nil, filledUpTo: ContinuousClock.Instant?
        init(_ kind: TrackKind, log: EventLog) {
            self.kind = kind
            fanout = Fanout(kind: kind, log: log)
        }
    }
    public nonisolated let events: AsyncStream<AudioEvent>
    /// Every change of the system's inputs (AirPods test 16.11.): standard, built-in, lid; logged as `devices_changed`.
    public nonisolated let deviceChanges: AsyncStream<DeviceSetup>
    private let deviceInput: AsyncStream<DeviceSetup>.Continuation
    private let eventInput: AsyncStream<AudioEvent>.Continuation, makeMic: MicFactory, makeDesktop: DesktopFactory
    private let log: EventLog
    private var setup: DeviceSetup, nextID: UInt64 = 0
    private let mic: Channel, desktop: Channel
    public init(microphone: @escaping MicFactory, desktop: @escaping DesktopFactory, devices: DeviceSetup,
                log: EventLog) {
        makeMic = microphone
        makeDesktop = desktop
        setup = devices
        self.log = log
        mic = Channel(.microphone, log: log)
        self.desktop = Channel(.desktop, log: log)
        (events, eventInput) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (deviceChanges, deviceInput) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }
    public func acquireMic(for purpose: MicPurpose) async throws -> MicLease {
        let (id, stream) = subscribe(mic, label: purpose.rawValue)
        do {
            try await ensureOpen(mic, purpose: purpose)
            guard let device = mic.device else { throw AudioError.noDevice }
            return MicLease(id: id, chunks: stream, device: device, conductor: self)
        } catch {
            mic.leases.remove(id)
            mic.fanout.finish(id)
            throw error
        }
    }
    /// Never fails for a refused start: the call keeps recording, the desktop track is filled and restarted.
    public func acquireDesktop() async throws -> DesktopLease {
        let (id, stream) = subscribe(desktop, label: MicPurpose.call.rawValue)
        do { try await ensureOpen(desktop, purpose: .call) } catch { markDown(desktop) }
        return DesktopLease(id: id, chunks: stream, conductor: self)
    }
    func release(_ id: UInt64, of kind: TrackKind, hold: Duration) async {
        let ch = channel(kind)
        guard ch.leases.remove(id) != nil else { return }
        guard ch.leases.isEmpty else { return ch.fanout.finish(id) }
        if hold > .zero, ch.source != nil {
            ch.fanout.finish(id)
            ch.hold = Task { [weak self] in
                do { try await Task.sleep(for: hold) } catch { return }
                await self?.closeIfIdle(kind)
            }
            return
        }
        await shutDown(ch)
        ch.fanout.finish(id)  // after the stop: what the source delivered while stopping is in the stream
    }
    /// Menu action: applies to every running lease (E6); also the explicit choice for later leases.
    public func switchMic(to device: InputDevice) async {
        setup.explicit = device
        guard !mic.leases.isEmpty, mic.device != device || mic.down else { return }
        if let old = mic.source {
            mic.source = nil
            await old.stop()
        }
        guard mic.source == nil, mic.opening == nil else { return }  // an acquire opened the explicit choice meanwhile
        do {
            try await open(mic, device: device, fresh: false)
            noteSwitch(to: device, reason: "menu")
        } catch {
            mic.fanout.admit(nil)
            markDown(mic)
        }
    }
    /// New device list from the system, read only. A microphone that is down tries the device it gets now.
    public func updateDevices(_ devices: DeviceSetup) async {
        let old = setup
        setup = DeviceSetup(standard: devices.standard, fallback: devices.fallback,
                            explicit: devices.explicit ?? setup.explicit, lidOpen: devices.lidOpen)
        if setup != old {
            let change = old.standard == setup.standard ? "list" : setup.standard == nil ? "standard_gone"
                : old.standard == nil ? "standard_back" : "standard_changed"
            log.record(LogEvent("devices_changed", ["change": .string(change),
                "standard": .string(setup.standard?.logTag ?? "keins"),
                "bluetooth": .bool(setup.standard?.isBluetooth == true),
                "lid_open": .bool(setup.lidOpen), "running": .string(mic.device?.logTag ?? "keins")]))
            deviceInput.yield(setup)
        }
        guard mic.down, mic.source == nil, !mic.leases.isEmpty,
              let device = DevicePolicy.choose(for: .room, setup: setup, running: nil) else { return }
        do { try await open(mic, device: device, fresh: false) } catch { return }
        noteSwitch(to: device, reason: "returned")
    }
    /// The app calls this once: system changes (standard input, devices) reach `updateDevices` and the log.
    public nonisolated func followSystemDevices() {
        SystemDevices.watch { Task { await self.updateDevices(SystemDevices.current()) } }
    }
    public func isDown(_ kind: TrackKind) -> Bool { channel(kind).down }
    private func channel(_ kind: TrackKind) -> Channel { kind == .microphone ? mic : desktop }
    private func subscribe(_ ch: Channel, label: String) -> (UInt64, AsyncStream<AudioChunk>) {
        nextID += 1
        ch.leases.insert(nextID)
        return (nextID, ch.fanout.subscribe(nextID, label: label))
    }
    private func ensureOpen(_ ch: Channel, purpose: MicPurpose) async throws {
        ch.hold?.cancel()
        ch.hold = nil
        if let opening = ch.opening { return try await opening.value }
        guard ch.source == nil else { return }
        var device: InputDevice?
        if ch.kind == .microphone {
            device = DevicePolicy.choose(for: purpose, setup: setup, running: nil)
            if device == nil { throw AudioError.noDevice }
        }
        try await open(ch, device: device, fresh: !ch.down)
    }
    /// Every start is visible as `opening`, so a concurrent acquire waits instead of opening a second source.
    private func open(_ ch: Channel, device: InputDevice?, fresh: Bool) async throws {
        let kind = ch.kind
        let task = Task { try await self.start(self.channel(kind), device: device, fresh: fresh) }
        ch.opening = task
        defer { ch.opening = nil }
        try await task.value
        ch.opening = nil
        if ch.leases.isEmpty, ch.hold == nil { await shutDown(ch) }  // the last lease ended while it opened
    }
    private func start(_ ch: Channel, device: InputDevice?, fresh: Bool) async throws {
        let source = device.map(makeMic) ?? makeDesktop()
        ch.generation += 1
        let (generation, fanout, kind) = (ch.generation, ch.fanout, ch.kind)
        fanout.admit(generation, fresh: fresh)
        do {
            try await source.start(deliver: { fanout.deliver($0, from: generation) },
                                   onEnd: { end in Task { await self.ended(kind, generation: generation, end) } })
        } catch {
            fanout.admit(nil)
            log.record(.failure("capture_start_failed", error, fields(ch, device)))
            throw error
        }
        ch.source = source
        if let device { ch.device = device }
        log.record(LogEvent("capture_started", fields(ch, device)))
        guard ch.down else { return }
        log.record(LogEvent("source_up", fields(ch, device)))  // the warning of a down source ends here
        ch.filler?.cancel()
        fillRest(kind)  // up to the return, not only to the last tick
        (ch.filler, ch.filledUpTo, ch.down) = (nil, nil, false)
        fanout.endFill()
        eventInput.yield(.sourceRestored(kind))
    }
    /// A source ended by itself: microphone falls back to the built-in one, otherwise the channel is filled.
    private func ended(_ kind: TrackKind, generation: UInt64, _ end: CaptureEnd) async {
        let ch = channel(kind)
        guard generation == ch.generation, let old = ch.source else { return }
        ch.source = nil
        ch.fanout.admit(nil)
        log.record(LogEvent("capture_failed", level: .error, fields(ch, ch.device)))
        await old.stop()
        guard ch.source == nil, ch.opening == nil, !ch.leases.isEmpty else { return }
        if kind == .microphone, let fallback = setup.fallback {
            do {
                try await open(ch, device: fallback, fresh: false)
                return noteSwitch(to: fallback, reason: "lost")
            } catch {
                log.record(LogEvent("fallback_failed", level: .error, fields(ch, fallback)))
            }
        }
        markDown(ch)
    }
    /// No source: the timeline goes on with silence until the source is back or the last lease ends.
    private func markDown(_ ch: Channel) {
        guard !ch.down else { return }
        ch.down = true
        log.record(LogEvent("source_down", level: .error, ["track": .string(ch.kind.logName)]))
        if ch.kind == .microphone { eventInput.yield(.sourceDown(.microphone)) }
        let kind = ch.kind
        ch.filledUpTo = .now
        ch.filler = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.fillTick) } catch { return }
                await self?.fillRest(kind)
            }
        }
        if ch.kind == .desktop, ch.restart == nil {
            ch.restart = Task { [weak self] in
                for attempt in 1... {
                    let wait = attempt <= Self.restartWaits.count ? Self.restartWaits[attempt - 1] : Self.restartEvery
                    do { try await Task.sleep(for: wait) } catch { return }
                    guard let again = await self?.restartDesktop(attempt: attempt), again else { return }
                }
            }
        }
    }
    /// Returns true while further attempts are needed.
    private func restartDesktop(attempt: Int) async -> Bool {
        if attempt > Self.restartMax {  // bounded: the track stays filled and the warning stays
            log.record(LogEvent("desktop_restart_stopped", level: .error, ["attempts": .int(Int64(attempt - 1))]))
            desktop.restart = nil
            return false
        }
        guard desktop.down, desktop.source == nil, !desktop.leases.isEmpty else {
            desktop.restart = nil
            return false
        }
        do {
            try await open(desktop, device: nil, fresh: false)
            log.record(LogEvent("desktop_restart", ["attempt": .int(Int64(attempt)), "ok": true]))
            desktop.restart = nil
            return false
        } catch {
            log.record(.failure("desktop_restart", error, ["attempt": .int(Int64(attempt)), "ok": false]))
            if attempt == 1 { eventInput.yield(.sourceDown(.desktop)) }  // the pill shows it after the first failure
            return (error as? AudioError) != .permission  // without the permission a retry cannot help
        }
    }
    /// Silence for the time since the last fill while a source is down (A.4, B.5).
    private func fillRest(_ kind: TrackKind) {
        let ch = channel(kind), now = ContinuousClock.now
        guard ch.down, let from = ch.filledUpTo else { return }
        ch.fanout.fillSilence(seconds: (now - from).inSeconds)
        ch.filledUpTo = now
    }
    private func shutDown(_ ch: Channel) async {
        ch.restart?.cancel()
        ch.restart = nil
        ch.filler?.cancel()
        fillRest(ch.kind)
        (ch.filler, ch.filledUpTo) = (nil, nil)
        if ch.down {  // the down state ends with the last lease: the app's warning must end too
            ch.down = false
            ch.fanout.endFill()
            eventInput.yield(.sourceRestored(ch.kind))
        }
        guard let source = ch.source else { return ch.fanout.admit(nil) }
        ch.source = nil
        await source.stop()  // A.5 point 3: the source goes first, chunks of the stop phase still arrive
        if ch.source == nil, ch.opening == nil { ch.fanout.admit(nil) }
    }
    private func closeIfIdle(_ kind: TrackKind) async {
        let ch = channel(kind)
        guard ch.leases.isEmpty else { return }
        ch.hold = nil
        await shutDown(ch)
    }
    private func noteSwitch(to device: InputDevice, reason: String) {
        log.record(LogEvent("device_switch", ["reason": .string(reason), "device": .string(device.logTag)]))
        eventInput.yield(.deviceSwitched(device, lost: reason == "lost"))
    }
    private func fields(_ ch: Channel, _ device: InputDevice?) -> [String: LogValue] {
        ["track": .string(ch.kind.logName), "device": .string(device?.logTag ?? "system")]
    }
}

extension Duration {
    public var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
