/// Where a pair was seen (LEXIKON-KONZEPT 11.1): click, after-run, seeding run, near miss of the journal (K3).
public enum SightingSource: String, Sendable, Codable { case click, postRun, seed, journal }

public struct Sighting: Sendable, Codable, Equatable {
    public let ref: String, day: Int, source: SightingSource
}

public enum LedgerState: String, Sendable, Codable { case collecting, proposed, accepted, rejected, protected }

/// One ledger pair by target (11.2): heard form, entry id, sightings, counter evidence, state, corpus evidence.
public struct LedgerPair: Sendable, Codable, Equatable {
    public let id: String, heard: [String], entryID: String
    public var sightings: [Sighting], counterEvidence: Int, state: LedgerState, seen: String?, realWord: Bool
    public var note: String?, benefit: Int?, harm: Int?, context: [String]?
    /// Proven over the corpus: benefit in 2 dictations, no counter evidence, no harm ("Korpus-Beleg", N.3).
    public var proven: Bool { (benefit ?? 0) >= Probation.minDictations && counterEvidence == 0 && (harm ?? 0) == 0 }
}

/// A proposal in the list "Wörter" (A.12): one click accepts the hearing variant for the target.
public struct Suggestion: Sendable, Equatable, Identifiable {
    public let id: String, heard: String, target: String, entryID: String, label: String, realWord: Bool
    /// The neighbour word the evidence found ("nur neben", preselected), empty when none.
    public var context: [String] = []
}

/// What the first import brings (the dry run of "Panotti-Daten übernehmen").
public struct StartSummary: Sendable, Equatable {
    public let entries: Int, active: Int, proposals: Int, waiting: Int
}

/// The ledger of the correction loop (N.3, 11.2): pairs, confusions and the proposals they lead to (R-033).
public actor CorrectionLedger {
    struct File: Codable {
        var pairs: [LedgerPair] = [], confusions = 0
        var contradictions: [String: [String]]?  // S4: variant id, after-runs that wrote the heard form
    }
    public let lexicon: LexiconStore
    private let fs: SafeFS, log: EventLog
    private var file = File(), state: Bool?
    public init(lexicon: LexiconStore, fs: SafeFS, log: EventLog) {
        (self.lexicon, self.fs, self.log) = (lexicon, fs, log)
    }
    var url: URL { lexicon.folder.appending(path: "kontobuch.json") }
    private func loaded() -> Bool {
        if let state { return state }
        let read = JSON.read(url, or: File())
        if read == nil { log.record(LogEvent("ledger_unreadable", level: .error)) }
        (file, state) = (read ?? file, read != nil)
        return read != nil
    }
    private func save() throws {
        guard loaded() else { throw LexiconStore.Unreadable() }
        try fs.replace(url, json: file)
    }
    public func confusionCount() -> Int { loaded() ? file.confusions : 0 }
    public func pairs() -> [LedgerPair] { loaded() ? file.pairs : [] }
    public func openPairs() -> [LedgerPair] { pairs().filter { $0.state == .collecting } }
    public func countConfusion() throws {
        guard loaded() else { throw LexiconStore.Unreadable() }
        file.confusions += 1
        try save()
    }
    /// Records a sighting of `heard` for an entry; a click is accepted at once (the session has learned it).
    public func record(heard: [String], entry: String, source: SightingSource, ref: String, day: Int,
                       realWord: Bool, seen: String? = nil, note: String? = nil, state: LedgerState? = nil) throws {
        guard loaded() else { throw LexiconStore.Unreadable() }
        let sighting = Sighting(ref: ref, day: day, source: source)
        if let i = file.pairs.firstIndex(where: { $0.heard == heard && $0.entryID == entry }) {
            if !file.pairs[i].sightings.contains(sighting) { file.pairs[i].sightings.append(sighting) }
            if let state = state ?? (source == .click ? .accepted : nil) { file.pairs[i].state = state }
            if let note { file.pairs[i].note = note }
        } else {
            file.pairs.append(LedgerPair(id: "p-" + UUID().uuidString.prefix(8).lowercased(), heard: heard,
                                         entryID: entry, sightings: [sighting], counterEvidence: 0,
                                         state: state ?? (source == .click ? .accepted : .collecting), seen: seen,
                                         realWord: realWord, note: note))
        }
        try save()
    }
    /// After-run of a recording (N.3): pairs become sightings or counter evidence; S4 suspends from 2 recordings.
    public func observe(local: String, postRun: String, ref: String, day: Int, stage: TextStage) async throws {
        let none = OracleAnswers(known: [:]), mine = stage.process(Recognition(text: local), answers: none).text
        let theirs = stage.process(Recognition(text: postRun), answers: none).text
        for c in stage.candidates(heard: mine, against: theirs, exact: stage) {
            try record(heard: c.heard, entry: c.entryID, source: .postRun, ref: ref, day: day,
                       realWord: stage.isRealWord(c.heard), seen: "gesehen bei ElevenLabs")
        }
        // Counter evidence: the after-run does not write the entry where the local side has the heard form (L6).
        let names = Dictionary((await lexicon.entries()).map { ($0.id, $0.canonical) }) { a, _ in a }
        let mineWords = PairAligner.words(mine), theirWords = PairAligner.words(theirs)
        for op in PairAligner.align(mineWords, theirWords) {
            let here = CorrectionRules.pieces(of: mineWords[op.a].joined(separator: " "))
            let there = theirWords[op.b].joined(separator: " ")
            for (i, p) in file.pairs.enumerated() where [.collecting, .proposed].contains(p.state)
                && Self.contains(here, p.heard) && !there.contains(names[p.entryID] ?? "\u{0}") {
                file.pairs[i].counterEvidence += 1
            }
        }
        let a = PairAligner.words(mine), b = PairAligner.words(postRun)
        for op in PairAligner.align(a, b) where op.kind == .replace {
            let heard = CorrectionRules.pieces(of: b[op.b].joined(separator: " "))
            for e in stage.lexicon.entries where e.canonical == a[op.a].joined(separator: " ") {
                for v in e.hearingVariants where v.heard == heard {
                    var refs = Set(file.contradictions?[v.id] ?? [])
                    refs.insert(ref)
                    file.contradictions = (file.contradictions ?? [:]).merging([v.id: refs.sorted()]) { $1 }
                    try await lexicon.count(entry: e.id, variant: v.id, harm: 1)
                    guard refs.count >= 2 else { continue }
                    try await lexicon.still(entry: e.id, variant: v.id, .suspended, reason: "nachlauf")
                }
            }
        }
        try save()
    }
    static func contains(_ words: [String], _ heard: [String]) -> Bool {
        !heard.isEmpty && words.count >= heard.count
            && (0...(words.count - heard.count)).contains { words[$0..<$0 + heard.count].elementsEqual(heard) }
    }
    /// Open proposals: seeded or after-run pairs that reached the threshold, best supported first.
    public func suggestions() async -> [Suggestion] {
        let entries = await lexicon.entries()
        return pairs().filter(Self.isDue).sorted { ($1.sightings.count, $0.id) < ($0.sightings.count, $1.id) }
            .compactMap { p in
                // a disputed target waits for its decision (the spelling first), then its pairs show
                guard let e = entries.first(where: { $0.id == p.entryID && $0.status == .confirmed }),
                      !e.hearingVariants.contains(where: { $0.heard == p.heard }) else { return nil }
                let label = [p.seen, p.note, p.proven ? "im Korpus belegt" : nil].compactMap { $0 }
                return Suggestion(id: p.id, heard: p.heard.joined(separator: " "), target: e.canonical, entryID: e.id,
                                  label: label.joined(separator: ", "), realWord: p.realWord, context: p.context ?? [])
            }
    }
    /// Threshold (11.2 point 3): seeded at once, after-run pairs from 2 recordings on 2 days without counter evidence.
    static func isDue(_ p: LedgerPair) -> Bool {
        if p.state == .proposed { return p.counterEvidence == 0 }
        let runs = p.sightings.filter { $0.source == .postRun }
        return p.state == .collecting && p.counterEvidence == 0 && Set(runs.map(\.ref)).count >= 2
            && Set(runs.map(\.day)).count >= 2
    }
    /// The click on a proposal: proven pairs active at once, others in probation (R-031); a real word only here.
    public func accept(_ s: Suggestion, context: [String]? = nil) async throws {
        guard let p = pairs().first(where: { $0.id == s.id }) else { return }
        let status: VariantStatus = p.proven ? .active : .probation
        _ = try await lexicon.apply(.addVariant(entry: p.entryID, heard: p.heard, status: status, origin: .userClick,
                                                protectedWord: p.realWord, context: context ?? p.context ?? []))
        try settle(s.id, .accepted)
    }
    /// "nicht mehr fragen".
    public func reject(_ s: Suggestion) throws { try settle(s.id, .rejected) }
    /// "richtiges Wort": the heard form is protected from now on.
    public func protect(_ s: Suggestion) async throws {
        _ = try await lexicon.apply(.protect(form: s.heard))
        try settle(s.id, .protected)
    }
    /// A click in the correction window (N.2, I1, L1, L7): target, heard form, case, sighting; false if blocked.
    public func learn(heard: String, meant: String, realWord: Bool, context: [String] = [], contextAfter: Bool = true,
                      ref: String, day: Int) async throws -> Bool {
        guard case .applied(let id) = try await lexicon.apply(.confirmEntry(canonical: meant)),
              let entry = await lexicon.entries().first(where: { $0.id == id }) else { return false }
        let pieces = CorrectionRules.pieces(of: heard)
        if realWord, context.isEmpty, !(await lexicon.stage()).mayReplaceEverywhere(heard, by: entry.canonical) {
            return false
        }
        if LexiconSnapshot.key(heard) != LexiconSnapshot.key(entry.canonical) {
            let status = CorrectionRules.clickedStatus(target: entry, realWord: realWord)
            guard case .applied = try await lexicon.apply(.addVariant(entry: id, heard: pieces, status: status,
                                                                      protectedWord: realWord, context: context))
            else { return false }
        }
        let (pre, post) = context.first.map { contextAfter ? ("", " " + $0) : ($0 + " ", "") } ?? ("", "")
        try await lexicon.addRegressionCase(input: pre + heard + post, expected: pre + entry.canonical + post)
        try record(heard: pieces, entry: id, source: .click, ref: ref, day: day, realWord: realWord)
        return true
    }
    /// New names from the journal (K1 to K3, R-030) as proposals; never twice, never after "nicht mehr fragen".
    public func propose(_ candidates: [Candidate]) async throws {
        let entries = await lexicon.entries()
        for c in candidates {
            guard c.source == .nearMiss else {
                let origin: EntryOrigin = c.source == .familyPattern ? .familyPattern : .recurringNonWord
                try await lexicon.apply(.propose(canonical: c.target ?? c.form, origin: origin))
                continue
            }
            let heard = CorrectionRules.pieces(of: c.form)
            guard let e = entries.first(where: { $0.canonical == c.target && $0.status == .confirmed }),
                  !pairs().contains(where: { $0.heard == heard && $0.entryID == e.id }) else { continue }
            try record(heard: heard, entry: e.id, source: .journal, ref: "beinahe", day: 0, realWord: false,
                       note: "Beinahe-Treffer in \(c.dictations) Diktaten", state: .proposed)
        }
    }
    /// The dry run of the first import: what `lexikon.json` and `kontobuch.json` in `folder` would bring.
    public static func preview(_ folder: URL) throws -> StartSummary {
        let (lexicon, ledger) = try read(folder)
        return StartSummary(entries: lexicon.entries.filter { $0.status == .confirmed }.count,
                            active: lexicon.entries.flatMap(\.hearingVariants).filter { $0.status == .active }.count,
                            proposals: ledger.pairs.filter { $0.state == .proposed }.count,
                            waiting: ledger.pairs.filter { $0.state == .collecting }.count)
    }
    static func read(_ folder: URL) throws -> (LexiconStore.File, File) {
        let decode = { (name: String) in try Data(contentsOf: folder.appending(path: name)) }
        return try (JSONDecoder().decode(LexiconStore.File.self, from: decode("lexikon.json")),
                    JSONDecoder().decode(File.self, from: decode("kontobuch.json")))
    }
    /// "Panotti-Daten übernehmen" (A.11, L3): the finished start lexicon and ledger into an untouched store.
    public func importStart(from folder: URL) async throws -> StartSummary {
        let summary = try Self.preview(folder), start = try Self.read(folder).1
        guard loaded(), file.pairs.isEmpty, start.pairs.allSatisfy({ [.collecting, .proposed].contains($0.state) })
        else { throw LexiconStore.Refused() }
        try await lexicon.importStart(folder.appending(path: "lexikon.json"))
        file.pairs = start.pairs
        try save()
        return summary
    }
    private func settle(_ id: String, _ state: LedgerState) throws {
        guard loaded(), let i = file.pairs.firstIndex(where: { $0.id == id }) else { return }
        file.pairs[i].state = state
        try save()
        log.record(LogEvent("ledger_decision", ["state": .string(state.rawValue)]))
    }
}
