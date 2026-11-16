/// "Letztes Diktat korrigieren" without drawing (N.2, R-109 to R-111); text never reaches the log.
actor CorrectionSession {
    private nonisolated struct Current {
        let record: DictationRecord
        var text: CorrectionText
    }
    typealias Oracle = @Sendable (Set<OracleQuery>) async -> OracleAnswers
    static let nothing = CorrectionOutcome(replace: .nothingToReplace, learning: .none)
    private let history: any DictationHistory, inserter: Inserter, lexicon: LexiconStore, ledger: CorrectionLedger
    private let journal: DictationJournal, protection: FrozenWordSet, window: any CorrectionWindowPresenting
    private let activator: any FrontAppActivating, log: EventLog, oracle: Oracle?, keys: (@Sendable () -> Bool)?
    private let pasteboard: (any PasteboardPort)?, onLearned: (@Sendable () async -> Void)?
    private var current: Current?, shown: [String: CorrectionText] = [:], rawDone = Set<String>()
    private var previousApp: String?, isOpen = false
    private var pending: (heard: String, meant: String, after: String?, record: String)?
    /// The scope question (N.2 point 4): earlier dictations with the heard word, and the neighbour word.
    private(set) var question: (earlier: Int, nextTo: String?, always: Bool) = (0, nil, false)
    init(history: any DictationHistory, inserter: Inserter, lexicon: LexiconStore, ledger: CorrectionLedger,
         journal: DictationJournal, protection: FrozenWordSet, window: any CorrectionWindowPresenting,
         activator: any FrontAppActivating, clock: any Clock<Duration>, log: EventLog, oracle: Oracle? = nil,
         pasteboard: (any PasteboardPort)? = nil, onLearned: (@Sendable () async -> Void)? = nil,
         keySinceInsert: (@Sendable () -> Bool)? = nil) {
        (self.history, self.inserter, self.lexicon, self.ledger, self.log) = (history, inserter, lexicon, ledger, log)
        (self.journal, self.protection, self.window, self.activator) = (journal, protection, window, activator)
        (self.oracle, self.pasteboard, self.onLearned, self.keys) = (oracle, pasteboard, onLearned, keySinceInsert)
    }
    /// Cmd-Z only when no key came since the insertion: the caller's answer, else the key watch of the Fn tap
    /// (wired in the app, it says "typed" while the tap is not running); a bare session (tests) passes none.
    nonisolated static func typed(_ e: Bool?, _ keys: (@Sendable () -> Bool)?) -> Bool { e ?? keys?() ?? false }
    /// Shows the newest dictation (shortcut and menu alike) or the chosen older one and remembers the app in front.
    func open(from source: OpenSource = .shortcut, dictation id: String? = nil) async -> CorrectionView {
        let recent = await history.recent(limit: 20)
        if !isOpen { previousApp = activator.frontmost() }
        isOpen = true
        current = (recent.first { $0.id == id } ?? recent.first).map { r in
            var record = r  // only the newest insertion may be edited in the field; an older one goes to the clipboard
            record.landed = r.landed && r.id == recent.first?.id
            return Current(record: record, text: shown[r.id] ?? CorrectionText(
                recognized: r.recognition.text, final: r.finalText, interventions: r.interventions))
        }
        let view = CorrectionView(dictationID: current?.record.id ?? "", words: current?.text.words ?? [],
                                  interventionSpans: current?.text.interventionSpans ?? [], recent: recent)
        await window.present(view)
        log.record(LogEvent("correction_open", ["source": .string(source.rawValue),
                                                "words": .int(Int64(view.words.count))]))
        return view
    }
    func keepOpen() { isOpen = true }  // the scope question shows after the field edit; closing gives focus back
    func close() async { pending = nil; await leave() }
    func options(for range: Range<Int>) async -> CorrectionOptions {
        guard let c = current, let (covered, raw) = c.text.cover(range) else { return CorrectionOptions() }
        var options = CorrectionOptions(rawForm: c.text.raw[raw].joined(separator: " "),
                                        offersWasRight: c.text.segments[covered].contains { $0.intervention != nil })
        options.recognizerAlternatives = c.text.alternatives(raw, from: c.record.recognition.segmentAlternatives)
        options.lexiconNeighbors = await stage().soundNeighbors(of: options.rawForm, limit: 3)
        return options
    }
    func apply(_ choice: CorrectionChoice, to range: Range<Int>, keySinceInsert: Bool? = nil) async
        -> CorrectionOutcome {
        guard let c = current, let (covered, raw) = c.text.cover(range) else { return Self.nothing }
        let heard = c.text.raw[raw].joined(separator: " "), meant: String
        switch choice {
        case .alternative(let s), .lexicon(let s), .typed(let s): meant = s
        case .raw: meant = heard
        }
        let result = await replace(range, with: meant, keySinceInsert: keySinceInsert)
        await write("correction", c.record.id, ["choice": .string(choice.name),
                                                "replace_result": .string(result.rawValue)])
        var learning = LearningOutcome.none
        do { learning = try await learn(heard, meant, c, covered, range) } catch { failed() }
        log.record(LogEvent("correction", ["choice": .string(choice.name), "result": .string(result.rawValue),
                                           "learning": .string(learning.rawValue)]))
        if learning != .none && learning != .askScope { await onLearned?() }
        return CorrectionOutcome(replace: result, learning: learning)
    }
    /// The one question after a real word as the source (N.2 point 4); "nur dieses Mal" learns nothing.
    @discardableResult
    func resolve(_ scope: ScopeChoice) async -> LearningOutcome {
        guard let p = pending else { return .none }
        pending = nil
        let context: [String]
        switch scope {
        case .once: return .none
        case .always:  // a word that stood uncorrected before is never replaced everywhere (11.1, measured)
            guard question.always else { return .none }
            context = []
        case .nextTo(let word): context = [word]
        }
        var learned = false
        do {
            learned = try await ledger.learn(heard: p.heard, meant: p.meant, realWord: true, context: context,
                                             contextAfter: context.first == p.after, ref: p.record, day: Self.today)
        } catch { failed() }
        await onLearned?()
        return learned ? .learned : .blocked
    }
    /// "war richtig" (S2): the recognizer form comes back, that intervention is rejected, its variant stilled.
    func markWasRight(_ range: Range<Int>) async -> CorrectionOutcome {
        guard let c = current, let (covered, _) = c.text.cover(range),
              let n = covered.first(where: { c.text.segments[$0].intervention != nil }),
              let i = c.text.segments[n].intervention else { return Self.nothing }
        let start = c.text.segments[..<n].reduce(0) { $0 + $1.words.count }
        let heard = c.text.raw[c.text.segments[n].raw].joined(separator: " ")
        let result = await replace(start..<start + c.text.segments[n].words.count, with: heard, keySinceInsert: nil)
        var fields: [String: JSONValue] = ["entry_id": .string(i.entryID), "replace_result": .string(result.rawValue)]
        if let v = i.variantID { fields["variant_id"] = .string(v) }
        await write("reject_intervention", c.record.id, fields)
        do {
            try await lexicon.reject([i], of: c.record.interventions.count, reason: "war richtig")
            try await lexicon.addRegressionCase(input: heard, expected: heard)
        } catch { failed() }
        await onLearned?()
        log.record(LogEvent("correction", ["choice": "was_right", "result": .string(result.rawValue)]))
        return CorrectionOutcome(replace: result, learning: .learned)
    }
    /// "Rohfassung" (R-034): the recognizer text once per insertion, journaled as rejection of all interventions (S1).
    func rawVersion(keySinceInsert: Bool? = nil) async -> CorrectionOutcome {
        guard let c = current, !rawDone.contains(c.record.id) else {
            await leave()
            return Self.nothing
        }
        rawDone.insert(c.record.id)
        let count = c.record.interventions.count
        let result = await replace(0..<c.text.words.count, with: c.record.recognition.text,
                                   keySinceInsert: keySinceInsert)
        await write("reject", c.record.id, ["interventions_rejected": .number(Double(count)),
                                            "result": .string(result.rawValue)])
        do { try await lexicon.reject(c.record.interventions, of: count, reason: "rohfassung") } catch { failed() }
        await onLearned?()
        log.record(LogEvent("correction", ["choice": "raw_version", "result": .string(result.rawValue)]))
        return CorrectionOutcome(replace: result, learning: .none)
    }
    private func learn(_ heard: String, _ meant: String, _ c: Current, _ covered: Range<Int>,
                       _ range: Range<Int>) async throws -> LearningOutcome {
        for s in c.text.segments[covered] {  // S3: a change of FlowIQ corrected to something else
            guard let i = s.intervention, let v = i.variantID, i.tAfter != meant else { continue }
            try await lexicon.still(entry: i.entryID, variant: v, .suspended, reason: "gegenkorrektur")
        }
        let stage = await stage(), queries = stage.oracleQueries(for: Recognition(text: heard + " " + meant))
        let unknown = OracleAnswers(known: Dictionary(uniqueKeysWithValues: queries.map { ($0, false) }))
        switch stage.classifyCorrection(heard: heard, meant: meant, answers: await oracle?(queries) ?? unknown) {
        case .none: return .none
        case .confusion:
            try await ledger.countConfusion()
            return .countedConfusion
        case .askScope:
            let words = c.text.words, pieces = CorrectionRules.pieces(of: heard)
            pending = (heard, meant, range.upperBound < words.count ? words[range.upperBound] : nil, c.record.id)
            let earlier = await journal.views().filter { CorrectionRules.pieces(of: $0.recognizerText)
                .contains(pieces) }.count
            question = (max(0, earlier - 1), pending?.after,
                        earlier <= 1 && stage.mayReplaceEverywhere(heard, by: meant))
            return .askScope
        case .learn:
            let learned = try await ledger.learn(heard: heard, meant: meant, realWord: false, ref: c.record.id,
                                                 day: Self.today)
            return learned ? .learned : .blocked
        }
    }
    private static var today: Int { Int(Date().timeIntervalSince1970 / 86_400) }
    private func stage() async -> TextStage {
        var shield = protection
        shield.familiar.formUnion(await lexicon.familiarForms())
        return TextStage(lexicon: await lexicon.snapshot(), protection: shield, config: TextStageConfig())
    }
    /// Closes the window and gives the focus back before anything touches the field.
    private func leave() async {
        guard isOpen else { return }
        isOpen = false
        await window.dismiss()
        if let previousApp { activator.activate(previousApp) }
    }
    /// Words `range` in the target field when the dictation landed, else the corrected text to the clipboard.
    private func replace(_ range: Range<Int>, with text: String, keySinceInsert: Bool?) async -> ReplaceResult {
        await leave()
        guard var c = current, let (covered, _) = c.text.cover(range) else { return .nothingToReplace }
        let words = c.text.words, edge = { (ch: Character) in !ch.isLetter && !ch.isNumber }
        let replacement = String(words[range.lowerBound].prefix(while: edge)) + text
            + String(words[range.upperBound - 1].reversed().prefix(while: edge).reversed())
        let start = words[..<range.lowerBound].reduce(0) { $0 + $1.count + 1 }
        let end = start + words[range].joined(separator: " ").count
        var result = ReplaceResult.nothingToReplace
        if c.record.landed {
            result = await inserter.replaceInLastInsertion(range: start..<end, with: replacement,
                                                           keySinceInsert: Self.typed(keySinceInsert, keys))
        } else if let pasteboard {
            var chars = Array(words.joined(separator: " "))
            chars.replaceSubrange(start..<end, with: Array(replacement))
            do { _ = try pasteboard.writePlain(String(chars)); result = .clipboardHint } catch { failed() }
        }
        guard result == .fieldReplaced || result == .undoReinserted else { return result }
        c.text.replace(covered, with: replacement.split(separator: " ").map(String.init))
        (shown[c.record.id], current) = (c.text, c)
        return result
    }
    private func write(_ event: String, _ id: String, _ fields: [String: JSONValue]) async {
        do {
            try await journal.append(JournalEntry(event, id: id, fields))
            await journal.sync()
        } catch { log.record(LogEvent("journal_write_failed", level: .error, ["event": .string(event)])) }
    }
    private func failed() { log.record(LogEvent("correction_learn_failed", level: .error)) }
}
