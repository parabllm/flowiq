public enum LiveSessionError: Error, Sendable { case languageFixed }

/// One live track (M.3, M.5): Apple always, ElevenLabs as chosen, reconnect, hand-over at B, at most 3 switches.
public actor LiveSession {
    let apple: any LiveRecognizer, makeCloud: @Sendable () -> any LiveRecognizer, sink: any RouterSink
    let clock: any Clock<Duration>, usage: (any CloudUsage)?, room: Bool
    nonisolated let input: AsyncStream<AudioChunk>.Continuation
    private let stream: AsyncStream<AudioChunk>
    private var router: LiveRouter, setup: LiveSetup? = nil, cloud: (any LiveRecognizer)? = nil, generation = 0
    private var retry: Task<Void, Never>? = nil
    private var ring: [(start: Double, chunk: AudioChunk)] = [], position = 0.0, firstHost: UInt64? = nil, quiet = 0.0
    private var standby = false, stopped = false
    public private(set) var automaticSwitches = 0, offersManualSwitch = false, trouble: LiveTrouble? = nil
    /// `room` counts the sent seconds as room, otherwise as the call track of the setup (M.8).
    public init(apple: any LiveRecognizer, makeCloud: @escaping @Sendable () -> any LiveRecognizer,
                sink: any RouterSink,
                clock: any Clock<Duration>, usage: (any CloudUsage)?, room: Bool = false) {
        (self.apple, self.makeCloud, self.sink, self.clock) = (apple, makeCloud, sink, clock)
        (self.usage, self.room) = (usage, room)
        router = LiveRouter(start: .appleLocal, sink: sink)
        (stream, input) = AsyncStream.makeStream()
    }
    public var activeEngine: LiveEngine { get async { await router.active } }
    public var sendingToCloud: Bool { cloud != nil }
    /// The language is fixed for the whole recording (R-103): Apple, cloud and every reconnect use the setup's.
    public func start(_ setup: LiveSetup, engine: LiveEngine) async throws {
        (self.setup, router) = (setup, LiveRouter(start: engine, sink: sink))
        do {  // audio first (review M4): a failing Apple start never stops the recording
            try await apple.start(setup)
            listen(apple, generation: nil)
        } catch { await fail(error as? LiveTrouble ?? .recognizerFailed) }
        Task { [stream] in for await chunk in stream { await self.take(chunk) } }
        if engine == .elevenLabsRealtime, !(await connect()) { await handOver(.networkError, final: false) }
    }
    public func changeLanguage(to language: RecordingLanguage) throws { throw LiveSessionError.languageFixed }
    /// Never blocks.
    public nonisolated func feed(_ chunk: AudioChunk) { input.yield(chunk) }
    public func switchTo(_ engine: LiveEngine, reason: SwitchReason) async {
        guard engine != (await router.active) else { return }
        if engine == .elevenLabsRealtime, cloud == nil, !(await connect()) { return }
        if engine == .appleLocal { await dropCloud() }
        retry?.cancel()
        standby = false
        await router.switchTo(engine, at: position, reason: reason)
    }
    public func finish() async {
        (stopped, standby) = (true, false)
        retry?.cancel()
        input.finish()
        await apple.finish()
        await dropCloud()
        await router.finish()
    }
    private func take(_ chunk: AudioChunk) async {
        let start = (Double(chunk.hostTime) - Double(firstHost ?? chunk.hostTime)) / 1e9
        firstHost = firstHost ?? chunk.hostTime
        let loud = chunk.samples.contains { abs($0) > 0.02 }
        (position, quiet) = (start + chunk.seconds, loud ? 0 : quiet + chunk.seconds)
        ring.append((start, chunk))
        ring.removeAll { $0.start < position - 40 }
        apple.feed(chunk)
        cloud?.feed(chunk)
        guard standby, quiet >= 0.4, cloud != nil else { return }
        retry?.cancel()  // the minute loop ends with the return
        standby = false
        await router.switchTo(.elevenLabsRealtime, at: position, reason: .returnToCloud)
        count()
    }
    private func listen(_ recognizer: any LiveRecognizer, generation: Int?) {
        Task { [weak self] in
            for await event in recognizer.events {
                await self?.handle(event, from: recognizer.engine, generation: generation)
            }
        }
    }
    private func handle(_ event: LiveEvent, from engine: LiveEngine, generation g: Int?) async {
        if let g, g != generation { return }  // an earlier cloud session
        switch event {
        case .failure where g == nil: await fail(.recognizerFailed)  // Apple died mid-run
        case .failure(let failure) where g != nil:
            await dropCloud()
            let active = await router.active
            if standby || active == .appleLocal { return standby = false }
            if failure.isShort, await connect() { return }
            await handOver(failure == .limit ? .limit : .networkError, final: failure.isFinal)
        case .sent(let seconds):
            let source: UsageSource = room ? .room : setup?.track == .desktop ? .callDesktop : .callMic
            await usage?.record(source, .live, seconds: seconds)
            if await usage?.limitReached == true { await handOver(.limit, final: true) }
        default: await router.feed(event, from: engine)
        }
    }
    /// A new cloud session from the last accepted word on (M.5 stage 1); audio arriving meanwhile follows.
    private func connect() async -> Bool {
        guard let setup, !stopped, await usage?.limitReached != true else { return false }
        let mark = await router.lastEnd, backlog = ring.filter { $0.start + $0.chunk.seconds > mark }
        let recognizer = makeCloud(), known = ring.last?.start ?? -1
        generation += 1
        let g = generation
        do {
            try await recognizer.start(LiveSetup(language: setup.language, terms: setup.terms, track: setup.track,
                                                 anchor: backlog.first?.start ?? position,
                                                 previousText: await router.tail,
                                                 backlog: backlog.map(\.chunk)))
        } catch { return false }
        guard g == generation, !stopped else { return false }
        ring.filter { $0.start > known }.forEach { recognizer.feed($0.chunk) }
        cloud = recognizer
        listen(recognizer, generation: g)
        return true
    }
    private func dropCloud() async {
        generation += 1
        let old = cloud
        cloud = nil
        await old?.finish()
    }
    /// M.5 stage 2: Apple from B on, a cloud attempt every minute unless key, terms, limit or three switches stop it.
    private func handOver(_ reason: SwitchReason, final: Bool) async {
        await dropCloud()
        guard (await router.active) == .elevenLabsRealtime else { return }
        await router.switchTo(.appleLocal, at: position, reason: reason)
        count()
        retry?.cancel()
        guard !final, automaticSwitches < 3 else { return offersManualSwitch = true }
        retry = Task { [clock] in
            while await self.awaitsReturn() {
                do { try await clock.sleep(for: .seconds(60)) } catch { return }
                await self.attemptReturn()
            }
        }
    }
    private func awaitsReturn() async -> Bool {
        let active = await router.active
        return !stopped && active == .appleLocal
    }
    private func attemptReturn() async { if cloud == nil, automaticSwitches < 3 { standby = await connect() } }
    private func fail(_ t: LiveTrouble) async {
        guard trouble == nil else { return }
        trouble = t
        await sink.failed(at: position, t)
    }
    /// Nothing writes live any more: Apple is out and the cloud does not write (or was never chosen).
    public var needsFileRun: Bool {
        get async {
            let active = await router.active
            return trouble != nil && active == .appleLocal
        }
    }
    private func count() {
        automaticSwitches += 1
        offersManualSwitch = automaticSwitches >= 3
    }
}
