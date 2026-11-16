/// Where transcripts and audio go: the writer allowed there, the vault side, the after-run (A.9, A.10).
nonisolated struct Filing: Sendable { let fs: SafeFS, store: TranscriptStore, aftercare: Aftercare }
/// Everything that may leave the Mac (M.9): without a key nothing is sent, development needs an order (appendix D).
nonisolated struct CloudParts: Sendable {
    let keys: CloudKeys, usage: MonthUsage, badge: CloudBadge, live: Bool, post: (any PostProcessor)?, profile: Profile
    let log: EventLog, policy: CloudGate.Policy
    var order: CloudOrder? = nil  // development: the explicit order behind the switch (review W3)
}
/// The live file side of the router (M.3): accepted words go into the transcript, the shadow stays out.
nonisolated struct TranscriptSink: RouterSink {
    let transcript: LiveTranscript, speaker: String, started: Date, lost: FallbackFlag
    func accepted(_ s: LiveSegment, from engine: LiveEngine) async {
        await transcript.append(seconds: Int(s.words.first?.start ?? 0), speaker: speaker, text: s.text, from: engine)
    }
    func shadowed(_ segment: LiveSegment, from engine: LiveEngine) async {}
    func switched(at seconds: Double, to engine: LiveEngine, reason: SwitchReason) async {
        await transcript.noteSwitch(seconds: Int(seconds), to: engine, reason: reason)
        lost.reason.withLock { $0 = engine == .appleLocal && reason != .manual ? reason : nil }
    }
    func partial(_ text: String, from engine: LiveEngine) async {
        await transcript.setVolatile(seconds: Int(Date().timeIntervalSince(started)), speaker: speaker, text: text)
    }
    func failed(at seconds: Double, _ trouble: LiveTrouble) async {  // Review M4: visible in the file, audio goes on
        await transcript.note(seconds: Int(seconds), trouble.text)
    }
}
/// Why the cloud handed over to Apple (M.5 stage 2), nil while it writes or after a manual switch.
nonisolated final class FallbackFlag: Sendable { let reason = Mutex<SwitchReason?>(nil) }
/// Call and room (B.2, B.3, M.1 to M.6): files in `laufend/`, Apple live per track, ElevenLabs on top when chosen.
actor Recorder {
    private typealias Track = (feed: CallLiveFeed, live: LiveSession, meter: TrackMeter,
                               release: @Sendable () async -> Void)
    private struct Active {
        let session: RecordingSession, transcript: LiveTranscript, started: Date, language: RecordingLanguage
        let tracks: [Track], device: String, lost: FallbackFlag
    }
    let paths: Paths, conductor: AudioConductor, log: EventLog, cloud: CloudParts, busy: BusyState
    let terms: @Sendable () async -> [String]
    private(set) var filing: Filing
    private var active: [SessionKind: Active] = [:], lock: RecordingLock?
    private var starting: Set<SessionKind> = [], stopWanted: Set<SessionKind> = []  // re-entrancy across awaits
    init(paths: Paths, conductor: AudioConductor, log: EventLog, filing: Filing, cloud: CloudParts, busy: BusyState,
         terms: @escaping @Sendable () async -> [String]) {
        (self.paths, self.conductor, self.log, self.filing) = (paths, conductor, log, filing)
        (self.cloud, self.busy, self.terms) = (cloud, busy, terms)
    }
    /// A new storage place takes effect at once while nothing records (task 3).
    func use(_ next: Filing) -> Bool {
        guard active.isEmpty else { return false }
        filing = next
        return true
    }
    func inserted(_ job: DictationJob) async { await filing.aftercare.dictationInserted(job) }
    /// At launch (R-039): what a dead instance left in `laufend/` is repacked and archived, live files rebuilt.
    func rescue() async {
        do {
            let lock = try held()
            _ = try await Rescue.run(laufend: paths.laufend, deliverTo: filing.store.locations.archiveAudio,
                fs: filing.fs, log: log, lock: lock)
            _ = try await filing.store.recoverOrphans()
        } catch { log.record(.failure("rescue_failed", error)) }
    }
    var isRecording: Bool { !active.isEmpty }
    func start(_ kind: SessionKind, language: RecordingLanguage, engine: LiveEngine) async throws {
        guard active[kind] == nil, starting.insert(kind).inserted else { return }  // a second press is no second start
        defer { (_, _) = (starting.remove(kind), stopWanted.remove(kind)) }
        for folder in [filing.store.locations.transcripts,
            filing.store.locations.archiveAudio] { try filing.fs.makeFolder(folder) }
        let started = Date(), mode: RecordingMode = kind == .call ? .call : .room
        let stamp = started.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false)
            .timeSeparator(.omitted))
        let session = try await RecordingSession.start(kind: kind, conductor: conductor, folder: paths.laufend,
                                                       stamp: stamp, fs: filing.fs, log: log, lock: try held())
        let transcript: LiveTranscript, mic: MicLease
        do {  // the microphone first, so the live file's start line names its device (16.11.)
            mic = try await conductor.acquireMic(for: kind == .call ? .call : .room)
        } catch {
            _ = await session.stop(reason: .normal)
            throw error
        }
        do {
            transcript = try await filing.store.beginLive(kind: mode, startedAt: started,
                language: String(language.rawValue.prefix(2)), liveSource: engine, audio: session.folder,
                device: mic.device.logTag)
        } catch {
            await mic.release()
            _ = await session.stop(reason: .normal)
            throw error
        }
        let me = Self.speaker, words = await terms(), lost = FallbackFlag()
        let ready = await SpeechModels.installed(language)  // a missing model never falls back to German
        var tracks: [Track] = [], device = ""
        do {  // a refused track gives back what the earlier ones took; the live file is rebuilt at the next start
            for track in kind == .call ? [TrackKind.microphone, .desktop] : [.microphone] {
                let chunks: AsyncStream<AudioChunk>, release: @Sendable () async -> Void
                if track == .microphone {
                    (chunks, release, device) = (mic.chunks, { await mic.release() }, mic.device.uid)
                } else {
                    let lease = try await conductor.acquireDesktop()
                    (chunks, release) = (lease.chunks, { await lease.release() })
                }
                let sink = TranscriptSink(transcript: transcript, speaker: track == .microphone ? me : "Gegenseite",
                                          started: started, lost: lost)
                let apple: any LiveRecognizer = ready ? AppleLiveRecognizer()
                    : UnavailableRecognizer(.modelMissing(language))
                let live = LiveSession(apple: apple, makeCloud: makeCloud(mode), sink: sink,
                                       clock: ContinuousClock(), usage: cloud.usage, room: kind == .room)
                let meter = TrackMeter(track), feed = CallLiveFeed(track: track, chunks: chunks,
                                                                   live: [SessionFeed(session: live, meter: meter)])
                tracks.append((feed, live, meter, release))
                try await live.start(LiveSetup(language: language, terms: words, track: track, anchor: 0,
                                               previousText: nil, backlog: []), engine: engine)
                feed.start()
            }
        } catch {
            if tracks.isEmpty { await mic.release() }  // the lease taken before the loop
            for t in tracks { await t.release(); await t.live.finish() }
            _ = await session.stop(reason: .normal)
            throw error
        }
        active[kind] = Active(session: session, transcript: transcript, started: started, language: language,
                              tracks: tracks, device: device, lost: lost)
        do { try await busy.begin(.recording) } catch { log.record(.failure("busy_failed", error)) }
        starting.remove(kind)
        if stopWanted.remove(kind) != nil { await stop(kind) }  // the stop came while the start was running
    }
    func stop(_ kind: SessionKind) async {
        if starting.contains(kind) { stopWanted.insert(kind) }
        guard let a = active.removeValue(forKey: kind) else { return }
        let report = await a.session.stop(reason: .normal)
        var fileRun = false
        for t in a.tracks {
            await t.release()
            await t.live.finish()
            if await t.live.needsFileRun { fileRun = true }
        }
        if fileRun {  // Review M4: live was out, the text comes from the file run over the closed tracks
            let tracks = report.tracks.compactMap { t in (t.m4aURL ?? t.aacURL).map {
                ($0, t.name == .microphone ? Self.speaker : "Gegenseite", t.seconds) } }
            if let said = await FileTranscriber.contributions(tracks, a.language, log: log) {
                await a.transcript.replaceSaid(with: said)
            } else { await a.transcript.note(seconds: Int(a.started.distance(to: .now)), "Datei-Lauf gescheitert") }
        }
        let seconds = report.tracks.map(\.seconds).max() ?? 0
        let sent = await cloud.usage.seconds(kind == .call ? [.callMic, .callDesktop] : [.room])
        do { try await filing.aftercare.finish(a.transcript, durationSeconds: seconds, rawAudio: report.folder,
                                        cloudLiveSeconds: sent) } catch {
            log.record(.failure("aftercare_finish_failed", error, ["kind": .string(kind.rawValue)]))
        }
        do { try await busy.end(.recording) } catch { log.record(.failure("busy_failed", error)) }
    }
    func stopAll() async { for kind in Array(active.keys) { await stop(kind) } }
    /// What the pill and the menu show while live recognition is out, per running recording (review M4).
    func troubles() async -> [SessionKind: LiveTrouble] {
        var out: [SessionKind: LiveTrouble] = [:]
        for (kind, a) in active { for t in a.tracks { if let x = await t.live.trouble { out[kind] = x } } }
        return out
    }
    /// "Sprachmodell laden": only on a click (review M4); true once the model is there.
    func installModel(_ language: RecordingLanguage) async -> Bool {
        await log.attempt("model_install_failed") { try await SpeechModels.install(language) }
        return await SpeechModels.installed(language)
    }
    /// Menu only since 16.11. (E with ⌘⌥ now means English): the writing source changes at once,
    /// Apple keeps running underneath (M.3).
    func toggleLive(_ kind: SessionKind) async {
        guard let a = active[kind], let first = a.tracks.first else { return }
        let next: LiveEngine = await first.live.activeEngine == .appleLocal ? .elevenLabsRealtime : .appleLocal
        for t in a.tracks { await t.live.switchTo(next, reason: .manual) }
    }
    /// A dictation inside a running recording (R-102): its audio stays out of every live stream.
    func dictation(started: Bool, host: UInt64) {
        for t in active.values.flatMap(\.tracks) {
            if started { t.feed.dictationStarted(at: host) } else { t.feed.dictationEnded(at: host) }
        }
    }
    func dictated(_ text: String, speaker: String) async {
        for a in active.values {
            await a.transcript.append(seconds: Int(Date().timeIntervalSince(a.started)), speaker: speaker, text: text,
                                      dictation: true)
        }
    }
    /// Kinds a full disk ended since the last call (A.5): cleaned up here, shown once by the app.
    func diskFullEnded() async -> [SessionKind] {
        var ended: [SessionKind] = []
        for (kind, a) in active where await a.session.endedBy == .diskFull { ended.append(kind) }
        for kind in ended { await stop(kind) }
        return ended
    }
    func snapshot() async -> [Running] {
        var out: [Running] = []
        for (kind, a) in active.sorted(by: { $0.key == .call && $1.key != .call }) {
            var r = Running(kind: kind, language: a.language, started: a.started)
            r.engine = await a.tracks.first?.live.activeEngine ?? .appleLocal
            for t in a.tracks { if await t.live.sendingToCloud { r.sending = true } }
            r.offersSwitch = await a.tracks.first?.live.offersManualSwitch ?? false
            r.fallback = a.lost.reason.withLock { $0 }
            r.silent = a.tracks.first?.meter.silent ?? false  // the microphone is always the first track
            r.desktopSilent = a.tracks.dropFirst().contains { $0.meter.silent }
            (r.levels, r.device) = (a.tracks.map(\.meter.level), a.device)
            r.cloudSeconds = await cloud.usage.seconds(kind == .call ? [.callMic, .callDesktop] : [.room])
            out.append(r)
        }
        return out
    }
    func liveFile(_ kind: SessionKind) -> URL? { active[kind]?.transcript.url }
    /// The microphone track's speaker: the first word of the account name (A.1), as the after-run names it.
    static var speaker: String { String(NSFullUserName().split(separator: " ").first ?? "Ich") }
    private func held() throws -> RecordingLock {
        if let lock { return lock }
        let lock = try RecordingLock.acquire(in: paths.laufend)
        self.lock = lock
        return lock
    }
    private func makeCloud(_ mode: RecordingMode) -> @Sendable () -> any LiveRecognizer {
        let c = cloud
        return {  // never chosen without a live service; a refusal leaves Apple writing
            do { return try CloudGate.liveRecognizer(mode: mode, policy: c.policy, profile: c.profile, order: c.order,
                                                     keys: c.keys, log: c.log) } catch { return AppleLiveRecognizer() }
        }
    }
}
