/// One change of the lexicon, in order (R-031: every rule has a history). Text-free apart from the ids.
public struct LexiconChange: Sendable, Codable, Equatable {
    public let kind: String, entryID: String, variantID: String?, at: Date
}

/// A line of "Zum Prüfen" (N.5) or a blocked change; `settled` is the click ("aktiv", "aus", "ziel").
public struct ReviewItem: Sendable, Codable, Equatable {
    public let entryID: String, variantID: String?, reason: String, at: Date
    public var settled: String?
}

/// The three clicks of the list "Zum Prüfen" (N.5): "wieder aktiv", "endgültig aus", "Ziel ändern".
public enum ReviewDecision: Sendable, Equatable { case reactivate, retire, retarget(String) }

public enum LexiconChangeRequest: Sendable {
    /// Confirms an entry with this spelling; a new one when no entry has the same key.
    case confirmEntry(canonical: String, kind: EntryKind = .name, origin: EntryOrigin = .userClick)
    case addVariant(entry: String, heard: [String], status: VariantStatus, origin: VariantOrigin = .userClick,
                    protectedWord: Bool = false, context: [String] = [])
    case setVariant(entry: String, variant: String, status: VariantStatus, reason: String)
    /// "nicht mehr fragen" on a proposed entry; nothing is deleted (I5).
    case retireEntry(entry: String, reason: String)
    /// "richtiges Wort": the form joins the familiar forms of the protection list (P2).
    case protect(form: String)
    /// "Ziel ändern": the spelling changes once, every variant points at the id and follows (N.5).
    case rename(entry: String, canonical: String)
    /// A new name from the journal (K1 to K3) or the seed list; never a second entry with the same key.
    case propose(canonical: String, origin: EntryOrigin)
}

public enum ChangeResult: Sendable, Equatable {
    /// Applied; the id of the entry or variant it made or touched.
    case applied(String)
    /// Not applied: it would break these permanent cases (N.4), reported for the menu.
    case blocked([RegressionCase])
}

/// The lexicon file (A.9, N.3 to N.5), written atomically after every change; unreadable is never overwritten.
public actor LexiconStore {
    public struct Unreadable: Error {}
    /// An import into a changed store or of a file that is not a start lexicon.
    public struct Refused: Error {}
    struct File: Codable {
        var version = 0, entries: [CanonEntry] = [], families: [FamilyRule] = [], familiar: [String] = []
        var changes: [LexiconChange] = [], review: [ReviewItem] = [], cases: [RegressionCase] = []
        var reports: [ReviewItem] = [], probationAt: Date?
    }
    public nonisolated let folder: URL
    private let fs: SafeFS, log: EventLog, now: @Sendable () -> Date
    private var file = File()
    private var state: Bool?  // nil: not loaded yet, false: unreadable
    private var cached: TextStage?
    public init(folder: URL, fs: SafeFS, log: EventLog, now: @escaping @Sendable () -> Date = { Date() }) {
        (self.folder, self.fs, self.log, self.now) = (folder, fs, log, now)
    }
    var url: URL { folder.appending(path: "lexikon.json") }
    /// Reads a lexicon file of this store (corpus runs, `flowiq-tool replay`): what the stage sees, familiar forms.
    public static func load(file url: URL) throws -> (LexiconSnapshot, Set<String>) {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return (LexiconSnapshot(entries: file.entries, families: file.families, version: file.version),
                Set(file.familiar))
    }
    private func loaded() -> Bool {
        if let state { return state }
        let read = JSON.read(url, or: File())
        if read == nil { log.record(LogEvent("lexicon_unreadable", level: .error)) }
        (file, state) = (read ?? file, read != nil)
        return read != nil
    }
    private func save() throws {
        guard loaded() else { throw Unreadable() }
        file.version += 1
        try fs.replace(url, json: file)
    }
    /// Replaces the whole content with starting entries and families (first run, tests, seeding run).
    public func seed(_ entries: [CanonEntry], families: [FamilyRule] = []) throws {
        guard loaded() else { throw Unreadable() }
        file = File(version: file.version, entries: entries, families: families)
        try save()
    }
    /// The first import of a start lexicon (A.11): only into an untouched store, only seed entries and corpus variants.
    public func importStart(_ url: URL) throws {
        guard importable() else { throw Refused() }
        let start = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let variants = start.entries.flatMap(\.hearingVariants)
        guard start.entries.allSatisfy({ $0.origin == .seed }), variants.allSatisfy({ $0.origin == .corpus }),
              start.changes.isEmpty, start.cases.isEmpty else { throw Refused() }
        file = File(version: file.version, entries: start.entries, families: start.families, familiar: start.familiar,
                    changes: [LexiconChange(kind: "start_imported", entryID: "", variantID: nil, at: now())])
        try save()
        log.record(LogEvent("lexicon_imported", ["entries": .int(Int64(file.entries.count))]))
    }
    public func importable() -> Bool { loaded() && file.changes.isEmpty && file.cases.isEmpty }
    /// The stage on the current lexicon and the familiar forms, rebuilt only when the version changed (N.4).
    public func stage(_ config: TextStageConfig = TextStageConfig()) -> TextStage {
        guard loaded() else { return stage(File(), config: config) }
        if let cached, cached.lexicon.version == file.version, cached.config == config { return cached }
        let fresh = stage(file, config: config)
        cached = fresh
        return fresh
    }
    /// Every entry with every status and every variant.
    public func entries() -> [CanonEntry] { loaded() ? file.entries : [] }
    public func snapshot() -> LexiconSnapshot {
        LexiconSnapshot(entries: entries(), families: file.families, version: file.version)
    }
    public func familiarForms() -> Set<String> { Set(file.familiar) }
    public func changeLog() -> [LexiconChange] { file.changes }
    public func reviewList() -> [ReviewItem] { file.review }
    public func pendingReports() -> [ReviewItem] { file.reports }
    public func lastProbation() -> Date? { file.probationAt }
    public func addRegressionCase(input: String, expected: String) throws {
        guard loaded() else { throw Unreadable() }
        let c = RegressionCase(input: input, expected: expected)
        guard !file.cases.contains(c) else { return }
        file.cases.append(c)
        try save()
    }
    /// Applies one change unless it breaks a permanent case that passes today (N.4); then it is reported instead.
    @discardableResult
    public func apply(_ request: LexiconChangeRequest) throws -> ChangeResult {
        guard loaded() else { throw Unreadable() }
        var next = file
        let id = Self.change(&next, request, at: now()), broken = file.cases.isEmpty ? []
            : Set(stage(next).failing(file.cases)).subtracting(stage(file).failing(file.cases))
        guard broken.isEmpty else {
            file.reports.append(ReviewItem(entryID: id, variantID: nil, reason: "dauerfall", at: now()))
            try save()
            log.record(LogEvent("lexicon_blocked", ["cases": .int(Int64(broken.count))]))
            return .blocked(file.cases.filter(broken.contains))
        }
        file = next
        try save()
        log.record(LogEvent("lexicon_change", ["change": .string(file.changes.last?.kind ?? "none")]))
        return .applied(id)
    }
    /// Puts an entry or variant on the list "Zum Prüfen" (N.5) with the signal as reason, once while open.
    public func review(entry: String, variant: String?, reason: String) throws {
        guard loaded() else { throw Unreadable() }
        guard !file.review.contains(where: { $0.entryID == entry && $0.variantID == variant && $0.reason == reason
            && $0.settled == nil }) else { return }
        file.review.append(ReviewItem(entryID: entry, variantID: variant, reason: reason, at: now()))
        try save()
    }
    /// One click on line `index` of "Zum Prüfen" (N.5). Nothing is deleted; the line stays with its decision.
    @discardableResult
    public func decide(_ index: Int, _ decision: ReviewDecision) throws -> ChangeResult {
        guard loaded(), file.review.indices.contains(index), file.review[index].settled == nil else {
            throw Unreadable()
        }
        let item = file.review[index], result: ChangeResult
        switch (decision, item.variantID) {
        case (.reactivate, let v?): result = try apply(.setVariant(entry: item.entryID, variant: v, status: .active,
                                                                   reason: "wieder"))
        case (.retire, let v?): result = try apply(.setVariant(entry: item.entryID, variant: v, status: .retired,
                                                               reason: "aus"))
        case (.retire, nil): result = try apply(.retireEntry(entry: item.entryID, reason: "aus"))
        case (.retarget(let spelling), _): result = try apply(.rename(entry: item.entryID, canonical: spelling))
        case (.reactivate, nil): result = .applied(item.entryID)
        }
        guard case .applied = result else { return result }
        file.review[index].settled = decision == .reactivate ? "aktiv" : decision == .retire ? "aus" : "ziel"
        try save()
        return result
    }
    /// "gehört zu <Eintrag>" (A.12): the proposed name becomes a heard form of the target, the proposal retires.
    public func belongs(_ proposed: String, to target: String) throws {
        guard loaded(), let p = file.entries.first(where: { $0.id == proposed }),
              let t = file.entries.first(where: { $0.id == target }) else { return }
        try apply(.addVariant(entry: target, heard: CorrectionRules.pieces(of: p.canonical),
                              status: CorrectionRules.clickedStatus(target: t, realWord: false)))
        try apply(.retireEntry(entry: proposed, reason: "gehoert-zu"))
    }
    /// Counts a hit or a harm on a variant (N.5: hits and harm are shown per rule).
    public func count(entry: String, variant: String, benefit: Int = 0, harm: Int = 0) throws {
        guard loaded(), let e = file.entries.firstIndex(where: { $0.id == entry }),
              let v = file.entries[e].hearingVariants.firstIndex(where: { $0.id == variant }) else { return }
        file.entries[e].hearingVariants[v].counters.benefit += benefit
        file.entries[e].hearingVariants[v].counters.harm += harm
        try save()
    }
    /// A signal stills a rule at once and puts it on "Zum Prüfen" (S1 to S6): suspended or retired, never deleted.
    public func still(entry: String, variant: String, _ status: VariantStatus, reason: String) throws {
        try apply(.setVariant(entry: entry, variant: variant, status: status, reason: reason))
        try review(entry: entry, variant: variant, reason: reason)
    }
    /// Rejected interventions (S1, S2, 4.4, S8): variants stilled with harm, "war richtig" protects; two go to review.
    public func reject(_ rejected: [Intervention], of total: Int, reason: String) throws {
        for i in rejected {
            if let v = i.variantID {
                try still(entry: i.entryID, variant: v, CorrectionRules.stilled(interventions: total), reason: reason)
                try count(entry: i.entryID, variant: v, harm: 1)
            } else if reason == "war richtig" {
                try apply(.protect(form: i.tBefore))
            }
            guard let e = file.entries.firstIndex(where: { $0.id == i.entryID }) else { continue }
            file.entries[e].counters.harm += 1
            try save()
            if file.entries[e].counters.harm == 2 {
                try review(entry: i.entryID, variant: nil, reason: "zwei Ablehnungen")
            }
        }
    }
    /// The probation run (A.7, N.3): evidence per target; promotes, retires, stills (S5), "ruhend" after 90 days (S7).
    public func runProbation(over history: [JournalView]) throws {
        guard loaded() else { throw Unreadable() }
        let today = Int(now().timeIntervalSince1970 / 86_400)
        for entry in file.entries where entry.status == .confirmed {
            let seen = Dictionary(entry.hearingVariants.map { v in
                (v.id, history.indices.filter { Probation.fits(v, history[$0]) > 0 })
            }) { a, _ in a }
            let pooled = entry.hearingVariants.filter { !$0.replacesProtectedWord && $0.status != .suspended
                && $0.status != .retired }.flatMap { seen[$0.id] ?? [] }
            let proven = CorrectionRules.proven(entry)
                || pooled.count >= Probation.minHits && Set(pooled).count >= Probation.minDictations
            for v in entry.hearingVariants {
                let mine = seen[v.id, default: []].map { history[$0] }  // evaluate only sees records where v fits
                switch (v.status, Probation.evaluate(v, over: mine, target: entry.canonical, proven: proven)) {
                case (.probation, .promote):
                    try apply(.setVariant(entry: entry.id, variant: v.id, status: .active, reason: "bewaehrt"))
                case (.probation, .reject): try still(entry: entry.id, variant: v.id, .retired, reason: "geschuetzt")
                case (.active, .reject): try still(entry: entry.id, variant: v.id, .suspended, reason: "geschuetzt")
                case (.active, .retire): try still(entry: entry.id, variant: v.id, .retired, reason: "abgelehnt")
                case (.active, .suspend): try still(entry: entry.id, variant: v.id, .suspended, reason: "abgelehnt")
                case (.active, _): try touch(entry.id, v, days: mine.map(\.day), today)
                default: continue
                }
            }
        }
        file.probationAt = now()
        try save()
    }
    /// Last hit and hit count of an active variant; 90 days without a hit: "ruhend" on "Zum Prüfen" (S7).
    private func touch(_ entry: String, _ variant: HearingVariant, days: [Int], _ today: Int) throws {
        let since = variant.counters.lastAppliedAt.map { Int($0.timeIntervalSince1970 / 86_400) } ?? today
        let last = max(days.max() ?? since, since)
        if let e = file.entries.firstIndex(where: { $0.id == entry }),
           let v = file.entries[e].hearingVariants.firstIndex(where: { $0.id == variant.id }) {
            var counters = variant.counters
            (counters.lastAppliedAt, counters.benefit) = (Date(timeIntervalSince1970: Double(last) * 86_400),
                                                          max(counters.benefit, days.count))
            file.entries[e].hearingVariants[v].counters = counters
        }
        if today - last > 90 { try review(entry: entry, variant: variant.id, reason: "ruhend") }
    }
    func stage(_ f: File, config: TextStageConfig = TextStageConfig()) -> TextStage {
        TextStage(lexicon: LexiconSnapshot(entries: f.entries, families: f.families, version: f.version),
                  protection: FrozenWordSet(german: [], english: [], familiar: Set(f.familiar)), config: config)
    }
    /// Pure change on a copy; returns the id it made or touched.
    static func change(_ f: inout File, _ request: LexiconChangeRequest, at date: Date) -> String {
        func log(_ kind: String, _ entry: String, _ variant: String? = nil) -> String {
            f.changes.append(LexiconChange(kind: kind, entryID: entry, variantID: variant, at: date))
            return variant ?? entry
        }
        let entries = f.entries
        let same = { (key: String) in
            entries.firstIndex { LexiconSnapshot.key($0.canonical) == key && $0.status != .retired }
        }
        switch request {
        case .confirmEntry(let canonical, let kind, let origin):
            if let i = same(LexiconSnapshot.key(canonical)) {
                // L1: a confirmed spelling is never overwritten by a click; it changes only through "Ziel ändern"
                guard f.entries[i].status != .confirmed else { return f.entries[i].id }
                (f.entries[i].canonical, f.entries[i].status, f.entries[i].confirmedAt) = (canonical, .confirmed, date)
                return log("entry_confirmed", f.entries[i].id)
            }
            let id = "u-" + UUID().uuidString.prefix(8).lowercased()
            f.entries.append(CanonEntry(id: id, canonical: canonical, kind: kind, family: nil, spokenForms: [],
                                        hearingVariants: [], status: .confirmed, origin: origin, compound: .hyphen,
                                        counters: Counters(), createdAt: date, confirmedAt: date))
            return log("entry_confirmed", id)
        case .propose(let canonical, let origin):
            let key = LexiconSnapshot.key(canonical)
            if let e = f.entries.first(where: { LexiconSnapshot.key($0.canonical) == key }) { return e.id }
            let id = "k-" + UUID().uuidString.prefix(8).lowercased()
            f.entries.append(CanonEntry(id: id, canonical: canonical, kind: .name, family: nil, spokenForms: [],
                                        hearingVariants: [], status: .proposed, origin: origin, compound: .hyphen,
                                        counters: Counters(), createdAt: date, confirmedAt: nil))
            return log("entry_proposed", id)
        case .addVariant(let entry, let heard, let status, let origin, let protectedWord, let context):
            guard let i = f.entries.firstIndex(where: { $0.id == entry }) else { return entry }
            let lower = heard.map { $0.lowercased() }, near = context.map { $0.lowercased() }
            if let v = f.entries[i].hearingVariants.first(where: { $0.heard == lower && $0.context == near }) {
                return v.id
            }
            let id = "v-" + UUID().uuidString.prefix(8).lowercased()
            var status = status
            for (n, e) in f.entries.enumerated() where n != i && e.status != .retired {  // S6: one form, two targets
                for (m, v) in e.hearingVariants.enumerated() where v.heard == lower && v.status != .suspended
                    && v.status != .retired && (v.context.isEmpty || near.isEmpty || v.context == near) {
                    f.entries[n].hearingVariants[m].status = .suspended
                    f.review += [ReviewItem(entryID: e.id, variantID: v.id, reason: "zielkonflikt", at: date),
                                 ReviewItem(entryID: entry, variantID: id, reason: "zielkonflikt", at: date)]
                    status = .suspended
                }
            }
            f.entries[i].hearingVariants.append(HearingVariant(id: id, heard: lower, context: near, status: status,
                                                               origin: origin, replacesProtectedWord: protectedWord,
                                                               counters: Counters(lastAppliedAt: date)))
            return log("variant_added", entry, id)
        case .setVariant(let entry, let variant, let status, let reason):
            guard let i = f.entries.firstIndex(where: { $0.id == entry }),
                  let v = f.entries[i].hearingVariants.firstIndex(where: { $0.id == variant }),
                  f.entries[i].hearingVariants[v].status != status else { return variant }
            f.entries[i].hearingVariants[v].status = status
            return log("variant_" + status.rawValue + "_" + reason, entry, variant)
        case .retireEntry(let entry, let reason):
            guard let i = f.entries.firstIndex(where: { $0.id == entry }), f.entries[i].status != .retired else {
                return entry
            }
            f.entries[i].status = .retired
            return log("entry_retired_" + reason, entry)
        case .protect(let form):
            if !f.familiar.contains(form) { f.familiar.append(form) }
            return log("form_protected", "")
        case .rename(let entry, let canonical):
            guard let i = f.entries.firstIndex(where: { $0.id == entry }),
                  same(LexiconSnapshot.key(canonical)).map({ $0 == i }) ?? true else { return entry }
            f.entries[i].canonical = canonical
            return log("entry_renamed", entry)
        }
    }
}
