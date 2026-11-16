/// Dictation coordinator (A.12, B.1, appendix C): microphone, journal, recognition, text stage, insertion in order.
public actor FlowCoordinator {
    static let tail = Duration.milliseconds(110)
    /// Chunks the recognizer may lag behind before the file run takes over (A.4: about 30 s and more).
    static let recognizerBacklog = 3_000
    private nonisolated final class Dictation {
        let id: String, session: UInt64, turn = Latch<Void>(), before: Latch<Void>?
        var timeline: FnTimeline
        var opened: Task<Opened?, Never>?, eventNanos: UInt64
        init(id: String, session: UInt64, before: Latch<Void>?, eventNanos: UInt64) {
            (self.id, self.session, self.before, self.eventNanos) = (id, session, before, eventNanos)
            timeline = FnTimeline(dictationID: id)
        }
    }
    private nonisolated struct Opened: Sendable {
        let lease: MicLease, url: URL?, writer: TrackWriter?
        let pump: Task<PumpResult, Never>
        let recognition: Task<DictationRun, Never>
    }
    private nonisolated struct Last: Sendable {
        let id: String, recognizerText: String, finalText: String, interventions: Int
        var app: String?, landed: Bool, rawDone = false
    }
    private nonisolated enum Ending: String { case normal, escape, chordAbort }
    private let paths: Paths, fs: SafeFS, conductor: AudioConductor, recognizer: any DictationRecognizer
    private let text: any TextProcessing, inserter: Inserter, journal: DictationJournal, busy: BusyState
    private let input: InputService, pill: any PillSink, log: EventLog, clock: any Clock<Duration>
    private var active: Dictation?, running = 0, lastTurn: Latch<Void>?, last: Last?
    private let history: RecentDictations?
    private var observer: (any DictationObserver)?
    private var keeper: (pasteboard: any PasteboardPort, on: @Sendable () -> Bool)?
    func observe(_ observer: any DictationObserver) { self.observer = observer }
    /// R-117: with the setting on, every finished dictation ends on the clipboard, whatever the inserter did.
    func keep(on: @escaping @Sendable () -> Bool, pasteboard: any PasteboardPort) { keeper = (pasteboard, on) }
    init(paths: Paths, fs: SafeFS, conductor: AudioConductor, recognizer: any DictationRecognizer,
         text: any TextProcessing, inserter: Inserter, journal: DictationJournal, busy: BusyState,
         input: InputService, pill: any PillSink, log: EventLog, clock: any Clock<Duration>,
         history: RecentDictations? = nil) {
        (self.paths, self.fs, self.conductor, self.recognizer, self.text) = (paths, fs, conductor, recognizer, text)
        (self.inserter, self.journal, self.busy, self.input) = (inserter, journal, busy, input)
        (self.pill, self.log, self.clock, self.history) = (pill, log, clock, history)
    }
    /// No dictation records, finishes or inserts.
    public var isIdle: Bool { active == nil && running == 0 }
    /// Returns at once; the work runs in tasks, so the next key event is never held up.
    public func handle(_ envelope: InputEnvelope) {
        switch envelope.action {
        case .start: start(envelope)
        case .stop: end(.normal, envelope)
        case .cancel: end(.escape, envelope)
        case .chordAbort: end(.chordAbort, envelope)
        case .lock: break
        case .reinsert: track { _ = await self.reinsertLast() }
        case .shortcut(.rawVersion): track { _ = await self.insertRawVersion() }
        case .shortcut(let other):  // call, room and live source come with P5; correction goes to the window (N.2)
            log.record(LogEvent("shortcut_unwired", ["shortcut": .string(other.rawValue)]))
        }
    }
    private func start(_ envelope: InputEnvelope) {
        guard active == nil else { return }
        let d = Dictation(id: Self.newID(), session: envelope.session, before: lastTurn,
                          eventNanos: envelope.eventNanos)
        lastTurn = d.turn
        d.timeline.mark(.keyDown, at: MachTime.ticks(nanos: envelope.eventNanos))
        d.timeline.mark(.callback, at: envelope.callbackTicks)
        if let pillTicks = envelope.pillTicks { d.timeline.mark(.pillShown, at: pillTicks) }
        active = d
        running += 1
        d.opened = Task { await self.open(d) }
    }
    private func open(_ d: Dictation) async -> Opened? {
        d.timeline.mark(.micStart)
        let lease: MicLease
        do { lease = try await conductor.acquireMic(for: .dictation) } catch {
            log.record(LogEvent("dictation_mic_failed", level: .error, ["id": .string(d.id)]))
            await write(.begin(id: d.id, ["mic": .string("refused")]))
            input.settlePill(.failed, session: d.session)
            input.abandon(session: d.session)
            if active === d { active = nil }
            done(d)
            return nil
        }
        let recording = await busy.reasons.contains(.recording)
        if recording { await observer?.window(started: true, host: Self.hostNanos(d.eventNanos)) }
        await write(.begin(id: d.id, ["device": .string(lease.device.logTag),
                                "situation": .string(recording ? "with_recording" : "alone")]))
        do { try await busy.begin(.dictation) } catch { log.record(.failure("busy_failed", error)) }
        var url: URL?, writer: TrackWriter?
        do {
            url = try await journal.audioURL(for: d.id)
            if let url {
                writer = try await TrackWriter.create(url: url, purpose: .dictation, sampleRate: AudioChunk.channelRate,
                                                      fs: fs, log: log)
            }
        } catch {
            log.record(LogEvent("dictation_audio_failed", level: .error, ["id": .string(d.id)]))
        }
        let (stream, sink) = AsyncStream.makeStream(of: AudioChunk.self,
                                                    bufferingPolicy: .bufferingOldest(Self.recognizerBacklog))
        let recognizer = recognizer
        let recognition = Task.detached(priority: .userInitiated) { await recognizer.dictate(stream) }
        let pump = Task.detached(priority: .userInitiated) { await Self.pump(lease.chunks, sink, writer) }
        return Opened(lease: lease, url: writer == nil ? nil : url, writer: writer, pump: pump,
                      recognition: recognition)
    }
    /// Off the actor: every chunk to the recognizer stream and the file, in order, until the lease ends.
    private nonisolated static func pump(_ chunks: AsyncStream<AudioChunk>,
                                         _ sink: AsyncStream<AudioChunk>.Continuation,
                                         _ writer: TrackWriter?) async -> PumpResult {
        var out = PumpResult()
        for await chunk in chunks {
            if out.firstTicks == nil { (out.firstTicks, out.firstHost) = (MachTime.now(), chunk.hostTime) }
            if case .dropped = sink.yield(chunk) { out.overflowed = true }
            await writer?.append(chunk)
            for sample in chunk.samples {
                out.peak = max(out.peak, abs(sample))
                out.energy += Double(sample * sample)
            }
            out.frames += chunk.samples.count
        }
        sink.finish()
        out.closedTicks = MachTime.now()
        return out
    }
    private func end(_ ending: Ending, _ envelope: InputEnvelope) {
        guard let d = active, d.session == envelope.session else { return }
        active = nil
        d.timeline.mark(.keyUp, at: MachTime.ticks(nanos: envelope.eventNanos))
        Task { await self.finish(d, ending) }
    }
    private func finish(_ d: Dictation, _ ending: Ending) async {
        if ending == .normal { _ = await clock.pause(Self.tail) }
        guard let opened = await d.opened?.value else { return }  // a refused microphone is done already
        await opened.lease.release()
        await observer?.window(started: false, host: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        var pumped = await opened.pump.value
        pumped.report = await opened.writer?.close(reason: ending == .normal ? .normal : .escape, elapsed: nil)
        d.timeline.mark(.firstBuffer, at: pumped.firstTicks ?? pumped.closedTicks)
        d.timeline.mark(.streamClosed, at: pumped.closedTicks)
        await audioLine(d, pumped, ending)
        do { try await busy.end(.dictation) } catch { log.record(.failure("busy_failed", error)) }
        guard ending == .normal else {
            opened.recognition.cancel()
            input.settlePill(.hidden, session: d.session)
            return done(d, ending: ending.rawValue)
        }
        var run = await opened.recognition.value
        if run.recognition == nil || pumped.overflowed, let url = opened.url {
            log.record(LogEvent("dictation_file_run", ["reason": .string(run.failure ?? "overflow")]))
            let file = await recognizer.recognizeFile(url)
            if file.recognition != nil { run = file }
        }
        d.timeline.mark(.recognized)
        guard let recognition = run.recognition else {
            log.record(LogEvent("dictation_failed", level: .error, ["reason": .string(run.failure ?? "none")]))
            await write(JournalEntry("recognized", id: d.id, ["failure": .string(run.failure ?? "none")]))
            input.settlePill(.failed, session: d.session)
            return done(d, ending: "recognizer_failed")
        }
        let processed = await text.process(recognition)
        d.timeline.mark(.textStage)
        let ms = { (a: FnMark, b: FnMark) in JSONValue.number(d.timeline.milliseconds(from: a, to: b) ?? -1) }
        await write(.recognized(id: d.id, recognizerText: recognition.text, finalText: processed.text,
                          interventions: processed.interventions, processed.trace.merging([
                              "confidences": .list(recognition.tokens.map { .number($0.confidence ?? -1) }),
                              "alternatives": .list(recognition.segmentAlternatives.map {
                                  .list($0.map(JSONValue.string))
                              }), "recognizer": .string(recognition.recognizerProfile),
                              "recognize_ms": ms(.streamClosed, .recognized), "stage_ms": ms(.recognized, .textStage),
                          ]) { a, _ in a }))
        d.timeline.mark(.journal)
        _ = await d.before?.wait()
        let outcome = await inserter.insertTimed(processed.text)
        if let t = outcome.pastedTicks { d.timeline.mark(.pasted, at: t) }
        if let t = outcome.fetchedTicks { d.timeline.mark(.confirmed, at: t) }
        last = Last(id: d.id, recognizerText: recognition.text, finalText: processed.text,
                    interventions: processed.interventions.count, app: outcome.frontApp,
                    landed: outcome.result == .landed)
        await landed(outcome.result, id: d.id, session: d.session, app: outcome.appName)
        if let url = opened.url {
            await observer?.inserted(DictationJob(id: d.id, audio: url, language: "de", insertedText: processed.text,
                                                  seconds: pumped.report?.seconds ?? 0))
        }
        await history?.add(DictationRecord(id: d.id, recognition: recognition, finalText: processed.text,
                                           interventions: processed.detail, targetApp: outcome.frontApp,
                                           landed: outcome.result == .landed))
        await inserter.settled()
        keepOnClipboard(processed.text)
        done(d, ending: outcome.result.rawValue)
    }
    private func audioLine(_ d: Dictation, _ pumped: PumpResult, _ ending: Ending) async {
        var fields = pumped.level
        if let r = pumped.report {
            fields.merge(["bytes": .number(Double(r.bytes)), "seconds": .number(r.seconds),
                          "verdict": .string(r.verdict.rawValue)]) { a, _ in a }
        }
        fields["end_reason"] = .string(ending == .normal ? EndReason.normal.rawValue : ending == .escape
                                       ? EndReason.escape.rawValue : ending.rawValue)
        if let host = pumped.firstHost {  // start loss t4a minus t0: host clock without sleep, shifted [E, T2]
            let loss = Double(Int64(host) - Int64(Self.hostNanos(d.eventNanos))) / 1_000_000
            if abs(loss) < 10_000 { fields["start_loss_ms"] = .number(loss) }
        }
        await write(JournalEntry(pumped.report?.verdict == .lost ? "audio_lost" : "audio", id: d.id, fields))
    }
    /// `app` is the target app's name, never its pid or a window title (16.11.: Ziel-App im Verlauf).
    private func landed(_ result: InsertResult, id: String, session: UInt64?, app: String? = nil) async {
        await write(.inserted(id: id, result: result.rawValue, app.map { ["app": .string($0)] } ?? [:]))  // history
        if result == .landed { input.noteInsert() }
        input.settlePill(result == .landed ? .hidden : .notInserted, session: session)
    }
    private func done(_ d: Dictation, ending: String = "mic_refused") {
        d.turn.fire(())
        var event = d.timeline.event()
        event = LogEvent(event.kind, event.fields.merging(["end": .string(ending)]) { a, _ in a })
        log.record(event)
        running -= 1
        Task { await journal.sync() }
    }
    /// Ctrl-Cmd-V: the final text of the last dictation once more (R-014, R-019).
    public func reinsertLast() async -> InsertResult {
        _ = await lastTurn?.wait()
        guard let current = last else { return .failed }
        let outcome = await inserter.insertTimed(current.finalText)
        if outcome.result == .landed {
            last?.landed = true
            last?.app = outcome.frontApp
            last?.rawDone = false
        }
        await landed(outcome.result, id: current.id, session: nil, app: outcome.appName)
        await inserter.settled()
        keepOnClipboard(current.finalText)
        return outcome.result
    }
    /// Replaces the last insertion by the recognizer text (R-034): landed, same app in front, no key since, once.
    public func insertRawVersion() async -> RawResult {
        _ = await lastTurn?.wait()
        guard let current = last, current.landed, !current.rawDone else { return .refused(.nothingToReplace) }
        if input.keySinceInsert { return .refused(.keyTyped) }
        guard inserter.frontmost() == current.app else { return .refused(.appChanged) }
        last?.rawDone = true
        let outcome = await inserter.undoAndInsert(current.recognizerText)
        await write(JournalEntry("reject", id: current.id, [
            "interventions_rejected": .number(Double(current.interventions)),
            "result": .string(outcome.result.rawValue),
        ]))
        if outcome.result == .landed { input.noteInsert() }
        await inserter.settled()
        Task { await journal.sync() }
        return outcome.result == .landed ? .inserted : .failed(outcome.result)
    }
    private func track(_ work: @escaping @Sendable () async -> Void) {
        running += 1
        Task {
            await work()
            self.untrack()
        }
    }
    private func untrack() { running -= 1 }
    private func write(_ entry: JournalEntry) async {
        do { try await journal.append(entry) } catch {
            log.record(LogEvent("journal_write_failed", level: .error, ["event": .string(entry.event)]))
        }
    }
    private func keepOnClipboard(_ text: String) {
        guard let keeper, keeper.on() else { return }
        log.attempt("keep_text_failed") { _ = try keeper.pasteboard.writePlain(text) }
    }
    /// Key event nanoseconds (continuous clock) on the chunk clock (uptime, without sleep).
    private static func hostNanos(_ eventNanos: UInt64) -> UInt64 {
        let shift = Int64(MachTime.nanos(ticks: MachTime.now())) - Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        return UInt64(max(0, Int64(eventNanos) - shift))
    }
    private static func newID() -> String {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        return stamp.filter(\.isNumber) + "-" + UUID().uuidString.prefix(8).lowercased()
    }
}
