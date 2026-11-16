/// The real text stage for dictations (A.7, L-1, N.4): word oracle first, then the lexicon store's stage.
nonisolated struct StageProcessor: TextProcessing {
    let lexicon: LexiconStore, oracle: SystemWordOracle
    func process(_ recognition: Recognition) async -> ProcessedText {
        let stage = await lexicon.stage()
        let answers = await oracle.answer(stage.oracleQueries(for: recognition), since: .now)
        let result = stage.process(recognition, answers: answers)
        return ProcessedText(text: result.text, interventions: result.interventions.map(\.tRule), trace: [
            "stage_texts": .list(result.stageTexts.map(JSONValue.string)), "intervention_detail": .encoding(
                result.interventions), "near_misses": .number(Double(result.nearMisses.count)),
            "near_miss_detail": .encoding(result.nearMisses), "oracle_answers": .number(Double(answers.known.count)),
            "protected": .list(result.protectedForms.map(JSONValue.string)),  // L5: probation and candidates
        ], detail: result.interventions)
    }
}

/// Wires the dictation path (P4) and the correction loop (P2c); the app starts the tap right after (Z-05, M2).
nonisolated struct DictationStack: Sendable {
    let input: InputService, coordinator: FlowCoordinator, conductor: AudioConductor, correction: CorrectionSession
    let lexicon: LexiconStore, ledger: CorrectionLedger, busy: BusyState
    var journal: DictationJournal?, inserter: Inserter?  // the history window reads and inserts again
    @concurrent
    static func start(profile: Profile, keys: Profile, log: EventLog, pill: any PillSink, oracle: SystemWordOracle,
                      window: any CorrectionWindowPresenting, keepText: @escaping @Sendable () -> Bool = { true },
                      onLock: @escaping @Sendable () -> Void = {}) async -> DictationStack {
        let paths = Paths(profile: profile), fs = SafeFS(paths: paths), clock = ContinuousClock()
        let conductor = AudioConductor(microphone: { MicrophoneSource(device: $0) }, desktop: { DesktopSource() },
                                       devices: SystemDevices.current(), log: log)
        let input = InputService(source: EventTapSource(profile: keys, log: log), profile: keys, clock: clock,
                                 pill: pill, log: log)
        let system = SystemFocus(), field = SystemField(), pasteboard = SystemPasteboard()
        let inserter = Inserter(focus: system, pasteboard: pasteboard, keys: system, front: system, field: field,
                                clock: clock, log: log)  // R-117 is the coordinator's (`keep`), so it switches at once
        let journal = DictationJournal(paths: paths, fs: fs, log: log), history = RecentDictations()
        let lexicon = LexiconStore(folder: paths.support.appending(path: "lexikon", directoryHint: .isDirectory),
                                   fs: fs, log: log)
        let ledger = CorrectionLedger(lexicon: lexicon, fs: fs, log: log), busy = BusyState(paths: paths, fs: fs)
        await history.preload(journal)
        let probation: @Sendable () async -> Void = {  // probation and new names over the journal (A.7, N.3, R-030)
            do {
                try await lexicon.runProbation(over: journal.views())
                let candidates = CandidateDetector(lexicon: await lexicon.snapshot())
                try await ledger.propose(candidates.candidates(in: journal.views(classified: true)))
            } catch { log.record(.init("probation_failed")) }
        }
        let correction = CorrectionSession(
            history: history, inserter: inserter, lexicon: lexicon, ledger: ledger, journal: journal,
            protection: FrozenWordSet(german: [], english: []), window: window, activator: field, clock: clock,
            log: log, oracle: { await oracle.answer($0, since: .now) }, pasteboard: pasteboard, onLearned: probation,
            keySinceInsert: { input.keySinceInsert })
        let coordinator = FlowCoordinator(paths: paths, fs: fs, conductor: conductor, recognizer: AppleDictation(),
            text: StageProcessor(lexicon: lexicon, oracle: oracle), inserter: inserter, journal: journal,
            busy: busy, input: input, pill: pill, log: log, clock: clock, history: history)
        await coordinator.keep(on: keepText, pasteboard: pasteboard)
        Task.detached(priority: .background) { await idle(journal, probation) }
        Task.detached(priority: .userInitiated) {
            for await envelope in input.stream {
                if envelope.action == .lock { onLock() }
                await coordinator.handle(envelope)
            }
        }
        conductor.followSystemDevices()  // standard input and device list from CoreAudio (AirPods test 16.11.)
        let reserved = await FileTranscriber.reserve(Locale(identifier: "de-DE"))
        let installed = await SpeechModels.installed(.de)  // what counts for dictation; ok:false alone says little
        log.record(LogEvent("speech_reserved", ["ok": .bool(reserved == true), "timeout": .bool(reserved == nil),
                                                "installed": .bool(installed)]))
        return DictationStack(input: input, coordinator: coordinator, conductor: conductor, correction: correction,
                              lexicon: lexicon, ledger: ledger, busy: busy, journal: journal, inserter: inserter)
    }
    /// The idle loop (A.7, L2): probation at the start, after a quiet minute with new lines, at least every 6 h.
    static func idle(_ journal: DictationJournal, _ run: @Sendable () async -> Void) async {
        var (seen, last) = (-1, Date.distantPast)
        while !Task.isCancelled {
            let (lines, quiet) = (await journal.appended, await journal.lastAppend.timeIntervalSinceNow < -30)
            if quiet && lines != seen || last.timeIntervalSinceNow < -6 * 3_600 {
                (seen, last) = (lines, Date())
                await run()
            }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }
}
