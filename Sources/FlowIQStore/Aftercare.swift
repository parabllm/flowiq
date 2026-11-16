/// A dictation after its insertion (M.1, R-108); `seconds` is the audio length for the usage counter.
public struct DictationJob: Sendable {
    public let id: String, audio: URL, language: String, insertedText: String, seconds: Double
    public init(id: String, audio: URL, language: String, insertedText: String, seconds: Double = 0) {
        (self.id, self.audio, self.language) = (id, audio, language)
        (self.insertedText, self.seconds) = (insertedText, seconds)
    }
}

/// One waiting after-run: paths, numbers and states only, never text (the queue file stays text-free).
struct QueuedJob: Codable, Sendable {
    let id: String, file: String?, audio: [String], mode: RecordingMode, language: String, seconds: Double
    var attempts = 0, due: Date, paused = false, held = false, empties: Int? = nil
    var choice: PostService? = nil, model: String? = nil  // "Nachlauf jetzt" with its own service (main window)
    var reason: String? = nil  // the service refused the request (400): its own words, the job waits for a click
}

/// The durable queue `nachlauf/warteschlange.jsonl` (A.10); an unreadable line is set aside and reported.
public actor PostQueue {
    private let file: URL, fs: SafeFS, log: EventLog
    private(set) var jobs: [QueuedJob]
    public init(folder: URL, fs: SafeFS, log: EventLog, now: @escaping @Sendable () -> Date = { Date() }) {
        (file, self.fs, self.log) = (folder.appending(path: "warteschlange.jsonl"), fs, log)
        var torn: [Data] = []
        jobs = TranscriptStore.lines(file, fs: fs, log: log).compactMap { line in
            do { return try JSONDecoder().decode(QueuedJob.self, from: line) } catch { torn.append(line) }
            return nil
        }
        guard !torn.isEmpty else { return }
        let aside = folder.appending(path: "warteschlange.unlesbar-\(UUID().uuidString.prefix(8)).jsonl")
        log.attempt("nachlauf_queue_not_set_aside") { try fs.claimNew(aside, with: Data(torn.joined(separator: [10]))) }
        log.record(LogEvent("nachlauf_queue_line_unreadable", level: .error, ["lines": .int(Int64(torn.count))]))
    }
    public var count: Int { jobs.count }
    func put(_ job: QueuedJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.append(job) }
        save()
    }
    func remove(_ id: String) {
        jobs.removeAll { $0.id == id }
        save()
    }
    func release(paused: Bool, at now: Date) {
        for i in jobs.indices where paused || !jobs[i].paused { jobs[i].due = now }
    }
    /// A new key (16.11.): what the service refused or the key paused runs once more; empty results stay stuck.
    func rekey(at now: Date) {
        for i in jobs.indices where jobs[i].reason != nil || jobs[i].paused && jobs[i].empties == nil {
            (jobs[i].due, jobs[i].paused) = (now, false)
        }
    }
    func held(_ mode: RecordingMode) -> [QueuedJob] { jobs.filter { $0.mode == mode } }
    private func save() {
        do {
            let lines = try jobs.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n" }
            try fs.replace(file, with: Data(lines.joined().utf8))
        } catch { log.record(LogEvent("nachlauf_queue_unsaved", level: .error)) }
    }
}

public enum AftercareTrigger: Sendable { case appStart, networkBack, click, timer, newKey }
public enum AftercareState: Sendable, Equatable { case idle, waiting(count: Int), paused(count: Int) }

/// Stop and after-run of every mode (B.2 point 8, A.10, M.1): archive at every stop, then a job or `final-lokal`.
public actor Aftercare {
    static let sources: [RecordingMode: [UsageSource]] = [.call: [.callMic, .callDesktop], .room: [.room],
                                                          .dictation: [.dictation], .device: [.device]]
    let store: TranscriptStore, queue: PostQueue, processor: any PostProcessor, usage: (any CloudUsage)?
    let ledger: CorrectionLedger?, textStage: Stage?, terms: @Sendable () async -> [String]
    let now: @Sendable () -> Date, history: URL
    private var postEnabled: [RecordingMode: Bool], pump: Task<Void, Never>?, again = false
    private var dictations: [String: [String: String]] = [:]
    /// Audio whose move into the archive failed: it stays in the raw folder, shown and tried again on each trigger.
    public private(set) var unarchived: [(item: URL, file: URL, mode: RecordingMode, seconds: Double)] = []
    static let emptyLimit = 3  // empty results in a row, then the job waits for a click (review 15.11.)
    public typealias Stage = @Sendable () async -> TextStage
    public init(store: TranscriptStore, queue: PostQueue, processor: any PostProcessor,
                postEnabled: [RecordingMode: Bool], usage: (any CloudUsage)? = nil, ledger: CorrectionLedger? = nil,
                textStage: Stage? = nil, confirmedTerms: @escaping @Sendable () async -> [String],
                now: @escaping @Sendable () -> Date = { Date() }) {
        (self.store, self.queue, self.processor, self.postEnabled) = (store, queue, processor, postEnabled)
        self.usage = usage
        (self.ledger, self.textStage, terms, self.now) = (ledger, textStage ?? store.textStage, confirmedTerms, now)
        history = store.locations.dataFolder.appending(path: "nachlauf/diktat-nachlauf.jsonl")
        let lines = TranscriptStore.lines(history, fs: store.fs, log: store.log)
        for entry in JSON.decode(lines, as: [String: String].self) {
            dictations[entry["id"] ?? "", default: [:]].merge(entry) { $1 }
        }
    }
    public var visibleState: AftercareState {
        get async {
            let jobs = await queue.jobs, paused = jobs.filter { $0.paused || $0.held }.count
            return jobs.isEmpty ? .idle : paused > 0 ? .paused(count: paused) : .waiting(count: jobs.count)
        }
    }
    /// Why the service refused a waiting job's request (16.11.); such a job is only tried again on a click.
    public var rejection: String? { get async { await queue.jobs.lazy.compactMap(\.reason).first } }
    /// A first run of this mode's after-run is due or running (the ring at the pill); a retry shows in the menu.
    public func working(_ mode: RecordingMode) async -> Bool {
        await queue.held(mode).contains { !$0.paused && !$0.held && $0.attempts == 0 }
    }
    /// Switching a mode off marks its waiting files `angehalten`, on again `wartet` (review 15.11.).
    public func setPostEnabled(_ on: Bool, for mode: RecordingMode? = nil) async {
        for m in mode.map({ [$0] }) ?? RecordingMode.allCases {
            postEnabled[m] = on
            for job in await queue.held(m) { await mark(job, on && !job.paused ? "wartet" : "angehalten") }
        }
        kick()
    }
    /// Stop of a call or room: archive, `live-lokal`, then a job or `final-lokal`; the archive never throws.
    public func finish(_ live: LiveTranscript, durationSeconds: Double, rawAudio: URL,
                       cloudLiveSeconds: Double = 0) async throws {
        let mode = live.meta.kind, place = store.archive(rawAudio, seconds: durationSeconds, mode: mode)
        if place == rawAudio { unarchived.append((rawAudio, live.url, mode, durationSeconds)) }
        store.log.record(LogEvent("live_session_ended", ["mode": .string(mode.rawValue),
            "seconds": .double(durationSeconds), "tracks": .int(Int64(max(1, TranscriptStore.list(place).count))),
            "archived": .bool(place != rawAudio), "cloud_live_seconds": .double(cloudLiveSeconds),
            "nachlauf": .string(postEnabled[mode] == true ? "an" : "aus")]))
        try await live.stop(seconds: durationSeconds, cloudSeconds: cloudLiveSeconds, quelle: place.path)
        await store.ended(live.url)
        guard postEnabled[mode] == true else {
            return try await store.edit(live.url) { doc in
                (doc.fields["panotti_phase"], doc.fields["pipeline"]) = ("final-lokal", "panotti-live+lokal")
                doc.fields["nachlauf"] = "aus"
            }
        }
        var tracks = TranscriptStore.list(place).filter { !$0.hasPrefix(".") }.map { place.appending(path: $0).path }
        tracks = tracks.isEmpty ? [place.path] : tracks
        await queue.put(QueuedJob(id: UUID().uuidString, file: live.url.path, audio: tracks, mode: mode,
                                  language: live.meta.language, seconds: durationSeconds, due: now()))
        try await store.edit(live.url) { $0.fields["nachlauf"] = "wartet" }
        kick()
    }
    /// Called after the insertion, never before (R-108); the inserted text is kept as it was.
    public func dictationInserted(_ job: DictationJob) async {
        guard postEnabled[.dictation] == true else { return }
        note(["id": job.id, "inserted": job.insertedText])
        await queue.put(QueuedJob(id: job.id, file: nil, audio: [job.audio.path], mode: .dictation,
                                  language: job.language, seconds: job.seconds, due: now()))
        kick()
    }
    public func dictationResult(id: String) -> String? { dictations[id]?["result"] }
    public func insertedText(id: String) -> String? { dictations[id]?["inserted"] }
    public func trigger(_ trigger: AftercareTrigger) async {
        if trigger == .newKey { await queue.rekey(at: now()) }
        if trigger != .timer { await queue.release(paused: trigger == .click, at: now()) }
        for u in unarchived where !(await queue.jobs.contains { $0.audio.contains { $0.hasPrefix(u.item.path) } }) {
            let place = store.archive(u.item, seconds: u.seconds, mode: u.mode, check: false)
            guard place != u.item else { continue }
            unarchived.removeAll { $0.item == u.item }
            await store.log.attempt("archive_quelle_failed") {
                try await store.edit(u.file) { $0.fields["quelle"] = place.path }
            }
        }
        kick()
    }
    /// Returns when no attempt runs and nothing is due.
    public func settle() async {
        while let running = pump { await running.value }
    }
    private func kick() {
        again = true
        guard pump == nil else { return }
        pump = Task {
            while again {
                again = false
                while let job = await nextDue() { await attempt(job) }
            }
            pump = nil
        }
    }
    private func nextDue() async -> QueuedJob? {
        let limit = await usage?.limitReached ?? false, t = now()
        return await queue.jobs.first { (postEnabled[$0.mode] == true || $0.choice != nil) && ($0.held ? !limit
            : $0.due <= t) }
    }
    /// One try; at the month's limit the job is held (M.8); quota and key pause a day, else 1, 5, 15, 60 min;
    /// a request the service calls wrong (400) waits for a click, since the same request fails the same way.
    private func attempt(_ queued: QueuedJob) async {
        var job = queued
        if await usage?.limitReached == true {
            job.held = true
            await queue.put(job)
            return await mark(job, "angehalten")
        }
        do {
            let began = ContinuousClock.now, terms = Array(await self.terms().prefix(100)), stage = await textStage?()
            var post = PostJob(audio: job.audio.map { URL(filePath: $0) }, language: job.language, terms: terms,
                               mode: job.mode)
            (post.choice, post.model) = (job.choice, job.model)
            let result = try await processor.process(post)
            guard !result.segments.isEmpty else { throw PostFailure.empty }
            let raw = result.segments.map(\.text).joined(separator: " "), local: String
            if let file = job.file.map({ URL(filePath: $0) }) {
                local = VaultDoc(try Data(contentsOf: file)).texts.joined(separator: " ")
                let source = result.source.isEmpty ? processor.name : result.source  // auto names who delivered
                try await store.upgrade(file, with: result, mode: job.mode, terms: terms.count, source: source,
                                        postSeconds: job.seconds * Double(job.audio.count), stage: stage)
            } else {
                local = dictations[job.id]?["inserted"] ?? ""
                note(["id": job.id, "result": await store.staged(raw, stage)])
            }
            await count(job, result.source.hasPrefix("openrouter") ? .postOpenRouter : .post)
            store.log.record(LogEvent("nachlauf_done", ["mode": .string(job.mode.rawValue),
                "service": .string(result.source.isEmpty ? processor.name : result.source),
                "seconds": .double(job.seconds), "segments": .int(Int64(result.segments.count)),
                "ms": .double((ContinuousClock.now - began) / .milliseconds(1)),
                "attempt": .int(Int64(job.attempts + 1))]))
            await queue.remove(job.id)
            await learn(local, raw, ref: job.id, stage)
        } catch {
            let failure = error as? PostFailure, emptyRun = failure == .empty
            if failure?.sent == true { await count(job) }  // sent is sent, also when the answer fails (R-101)
            job.empties = emptyRun ? (job.empties ?? 0) + 1 : nil
            if case .rejected(let why) = failure { job.reason = why } else { job.reason = nil }
            let stuck = job.reason != nil || job.empties ?? 0 >= Self.emptyLimit
            (job.attempts, job.paused) = (job.attempts + 1,
                                          stuck || [.quotaExhausted, .keyMissing, .notAllowed].contains(failure))
            job.due = stuck ? .distantFuture
                : now().addingTimeInterval(job.paused ? 86_400 : [60, 300, 900, 3600][min(job.attempts, 4) - 1])
            await queue.put(job)
            await mark(job, job.paused ? "angehalten" : "wartet")
            let reason = failure.map { "\($0)" } ?? "local"
            store.log.record(LogEvent("nachlauf_failed", level: .error, ["reason": .string(reason)]))
        }
    }
    /// Deviations become proposals, never rules (N.3, R-113).
    private func learn(_ local: String, _ raw: String, ref: String, _ stage: TextStage?) async {
        guard let ledger, let stage else { return }
        let day = Int(now().timeIntervalSince1970 / 86_400)
        do { try await ledger.observe(local: local, postRun: raw, ref: ref, day: day, stage: stage) } catch {
            store.log.record(LogEvent("nachlauf_ledger_failed", level: .error))
        }
    }
    /// "Mit ElevenLabs neu erkennen" (Verlauf, 16.11.): a kept dictation through the after-run at once, on a click.
    /// The month's limit holds, the text stage runs over the result, the ledger learns as from any after-run.
    public func redo(_ d: DictationJob) async throws -> String {
        guard await usage?.limitReached != true else { throw PostFailure.notAllowed }
        let job = QueuedJob(id: d.id, file: nil, audio: [d.audio.path], mode: .dictation, language: d.language,
                            seconds: d.seconds, due: now())
        var post = PostJob(audio: [d.audio], language: d.language, terms: Array(await terms().prefix(100)),
                           mode: .dictation)
        post.choice = .elevenLabs
        let stage = await textStage?(), result: PostTranscript
        do { result = try await processor.process(post) } catch {
            if (error as? PostFailure)?.sent == true { await count(job) }
            throw error
        }
        await count(job)
        let raw = result.segments.map(\.text).joined(separator: " ")
        guard !raw.isEmpty else { throw PostFailure.empty }
        let text = await store.staged(raw, stage)
        note(["id": d.id, "result": text])
        store.log.record(LogEvent("nachlauf_done", ["mode": "dictation", "seconds": .double(d.seconds),
                                                    "redo": .bool(true)]))
        await learn(d.insertedText, raw, ref: d.id, stage)
        return text
    }
    private func count(_ job: QueuedJob, _ kind: UsageKind = .post) async {  // per service (OpenRouter, 16.11.)
        for source in Self.sources[job.mode] ?? [] { await usage?.record(source, kind, seconds: job.seconds) }
    }
    private func mark(_ job: QueuedJob, _ value: String) async {
        guard let file = job.file else { return }
        do { try await store.edit(URL(filePath: file)) { $0.fields["nachlauf"] = value } } catch {
            store.log.record(LogEvent("nachlauf_mark_failed", level: .error))
        }
    }
    private func note(_ entry: [String: String]) {
        dictations[entry["id"] ?? "", default: [:]].merge(entry) { $1 }
        do {
            let handle = try store.fs.appendHandle(history)
            try handle.write(contentsOf: JSON.line(entry))
            try handle.close()
        } catch { store.log.record(LogEvent("nachlauf_history_failed", level: .error)) }
    }
}
