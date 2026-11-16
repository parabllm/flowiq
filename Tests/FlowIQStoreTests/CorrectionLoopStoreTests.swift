import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQStore
@testable import FlowIQText

/// P2c rework after the review: a confirmed spelling is never overwritten (L1), probation per target with corpus
/// evidence and recognizer alternatives, the signals S4 to S8, the list "Zum Prüfen", the first import, new names from
/// the journal and a journal that survives a restart. Invented words only, a scratch folder per test.
struct CorrectionLoopStoreTests {
    typealias Rig = LexiconStoreTests.Rig

    static func entry(_ canonical: String, _ status: EntryStatus = .confirmed, variants: [HearingVariant] = [])
        -> CanonEntry {
        var e = LexiconStoreTests.entry(canonical, status)
        e.hearingVariants = variants
        return e
    }

    static func variant(_ heard: String, _ status: VariantStatus, origin: VariantOrigin = .userClick,
                        word: Bool = false, at: Date? = nil) -> HearingVariant {
        HearingVariant(id: "v-" + heard, heard: heard.split(separator: " ").map(String.init), context: [],
                       status: status, origin: origin, replacesProtectedWord: word,
                       counters: Counters(lastAppliedAt: at))
    }

    static func view(_ text: String, day: Int, protected: Set<String> = [], alternatives: [String] = [])
        -> JournalView {
        JournalView(day: day, recognizerText: text, protectedForms: protected, rejectedInterventions: 0,
                    interventionCount: 0, alternatives: alternatives)
    }

    static func status(_ rig: Rig) async -> [String: VariantStatus] {
        Dictionary(await rig.lexicon.entries().flatMap(\.hearingVariants).map { ($0.id, $0.status) }) { a, _ in a }
    }

    // MARK: L1

    /// Red against e75ccc6: the lower-case click renamed "Sorbal" to "sorbal" everywhere.
    @Test func aClickWithTheSameKeyNeverOverwritesAConfirmedSpelling() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal")])
        #expect(try await rig.lexicon.apply(.confirmEntry(canonical: "sorbal")) == .applied("e-sorbal"))
        #expect(try await rig.lexicon.apply(.confirmEntry(canonical: "Sor-bal")) == .applied("e-sorbal"))
        #expect(await rig.lexicon.entries().map(\.canonical) == ["Sorbal"])
        #expect(await rig.lexicon.changeLog().isEmpty, "nothing changed, nothing logged")
        _ = try await rig.ledger.learn(heard: "zorbal", meant: "sorbal", realWord: false, ref: "d1", day: 1)
        #expect(await rig.lexicon.entries().map(\.canonical) == ["Sorbal"])
        #expect(await rig.lexicon.changeLog().map(\.kind) == ["variant_added"])
        try await rig.lexicon.apply(.rename(entry: "e-sorbal", canonical: "SorBal"))
        #expect(await rig.lexicon.entries().map(\.canonical) == ["SorBal"], "only \"Ziel ändern\" renames")
        #expect(await rig.lexicon.changeLog().last?.kind == "entry_renamed")
    }

    @Test func aRealWordReplacesEverywhereOnlyWhenTheTargetSoundsNear() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal")])
        #expect(!(try await rig.ledger.learn(heard: "groben", meant: "Sorbal", realWord: true, ref: "d1", day: 1)))
        #expect(try await rig.ledger.learn(heard: "groben", meant: "Sorbal", realWord: true, context: ["mit"],
                                           ref: "d1", day: 1), "next to a word it may learn")
        #expect(try await rig.ledger.learn(heard: "sorbel", meant: "Sorbal", realWord: true, ref: "d2", day: 2))
    }

    @Test func aBlockedClickIsReportedNotLearned() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal")])
        try await rig.lexicon.addRegressionCase(input: "wir dann", expected: "wir dann")
        let learned = try await rig.ledger.learn(heard: "dann", meant: "Sorbal", realWord: true, context: ["wir"],
                                                 contextAfter: false, ref: "d1", day: 1)
        #expect(!learned)
        #expect(await rig.lexicon.pendingReports().count == 1)
        #expect(await rig.lexicon.entries().flatMap(\.hearingVariants).isEmpty)
    }

    // MARK: probation per target, corpus evidence, alternatives

    @Test func formsOfOneTargetPoolTheirEvidence() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal", variants: [Self.variant("zorbal", .probation),
                                                                     Self.variant("sorbel", .probation)]),
                                    Self.entry("Korbin", variants: [Self.variant("korbim", .probation)])])
        try await rig.lexicon.runProbation(over: [Self.view("das zorbal", day: 1), Self.view("sorbel hier", day: 2),
                                                  Self.view("ein korbim", day: 3)])
        let s = await Self.status(rig)
        #expect(s["v-zorbal"] == .active && s["v-sorbel"] == .active, "two forms, two dictations: target proven")
        #expect(s["v-korbim"] == .probation, "one sighting of one form is not enough")
        let one = Probation.evaluate(Self.variant("korbim", .probation), over: [Self.view("ein korbim", day: 3)])
        #expect(one == .keepProbation)
        #expect(Probation.evaluate(Self.variant("korbim", .probation), over: [Self.view("ein korbim", day: 3)],
                                   target: "Korbin", proven: true) == .promote)
    }

    @Test func theRecognizersOwnAlternativeCountsAsEvidence() {
        let v = Self.variant("korbim", .probation)
        let offered = [Self.view("ein korbim", day: 3, alternatives: ["ein Korbin", "ein Korb im"])]
        #expect(Probation.evaluate(v, over: offered, target: "Korbin") == .promote)
        #expect(Probation.evaluate(v, over: [Self.view("ein korbim", day: 3, alternatives: ["ein Korb"])],
                                   target: "Korbin") == .keepProbation)
        let word = Self.variant("korbim", .probation, word: true)
        #expect(Probation.evaluate(word, over: offered, target: "Korbin") == .keepProbation, "word for word: 2 of 2")
    }

    /// A start folder as `scripts/korpus/` writes it: lexicon file and ledger with corpus evidence.
    static func startFolder(_ rig: Rig, _ entries: [CanonEntry], _ pairs: [LedgerPair]) async throws -> URL {
        let folder = rig.root.appending(path: "start-\(UUID().uuidString)")
        try await LexiconStore(folder: folder, fs: rig.fs, log: rig.log).seed(entries)
        var file = CorrectionLedger.File()
        file.pairs = pairs
        try rig.fs.replace(folder.appending(path: "kontobuch.json"), with: JSONEncoder().encode(file))
        return folder
    }

    static func pair(_ heard: String, _ entry: String, word: Bool, benefit: Int?, context: [String]? = nil,
                     state: LedgerState = .proposed) -> LedgerPair {
        LedgerPair(id: "p-" + heard, heard: [heard], entryID: entry, sightings: [], counterEvidence: 0, state: state,
                   seen: nil, realWord: word, note: nil, benefit: benefit, harm: benefit.map { _ in 0 },
                   context: context)
    }

    @Test func aProvenPairIsActiveOnTheClickAndKeepsItsContext() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let folder = try await Self.startFolder(rig, [Self.entry("Sorbal"), Self.entry("Quendrik", .proposed)], [
            Self.pair("puls", "e-sorbal", word: true, benefit: 3, context: ["konsole"]),
            Self.pair("quendri", "e-quendrik", word: false, benefit: nil)])
        _ = try await rig.ledger.importStart(from: folder)
        let shown = await rig.ledger.suggestions()
        #expect(shown.map(\.heard) == ["puls"], "a disputed target waits for its decision")
        #expect(shown.first?.context == ["konsole"])
        try await rig.ledger.accept(try #require(shown.first))
        let v = try #require(await rig.lexicon.entries().first { $0.id == "e-sorbal" }?.hearingVariants.first)
        #expect(v.status == .active && v.context == ["konsole"] && v.replacesProtectedWord)
        try await rig.lexicon.apply(.confirmEntry(canonical: "Quendrik"))
        #expect(await rig.ledger.suggestions().map(\.heard) == ["quendri"], "after the decision the pair shows")
        try await rig.ledger.accept(try #require(await rig.ledger.suggestions().first))
        let all = await rig.lexicon.entries().flatMap(\.hearingVariants)
        #expect(all.first { $0.heard == ["quendri"] }?.status == .probation, "no corpus evidence: probation")
    }

    // MARK: signals

    @Test func activeVariantsAreSuspendedOnAProtectedHitAndRestAfterNinetyDays() async throws {
        let old = Date(timeIntervalSince1970: 0)
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal", variants: [Self.variant("zorbal", .active, at: old),
                                                                     Self.variant("korb", .active, at: old)])])
        try await rig.lexicon.runProbation(over: [Self.view("ein korb", day: 1, protected: ["korb"])])
        #expect(await Self.status(rig) == ["v-zorbal": .active, "v-korb": .suspended])
        let reasons = await rig.lexicon.reviewList().map(\.reason).sorted()
        #expect(reasons == ["geschuetzt", "ruhend"], "S5 suspends, S7 only puts it up for review")
    }

    @Test func oneFormForTwoTargetsSuspendsBoth() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal", variants: [Self.variant("zorbal", .active)]),
                                    Self.entry("Zorball")])
        try await rig.lexicon.apply(.addVariant(entry: "e-zorball", heard: ["zorbal"], status: .probation))
        #expect(Set(await Self.status(rig).values) == [.suspended])
        #expect(await rig.lexicon.reviewList().filter { $0.reason == "zielkonflikt" }.count == 2)
    }

    @Test func rejectionsStillTheVariantAndTheSecondPutsTheEntryUpForReview() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal", variants: [Self.variant("zorbal", .active),
                                                                     Self.variant("sorbel", .active)])])
        let i = { (v: String) in
            Intervention(tRule: "variant", tBefore: v, tAfter: "Sorbal", tReason: "heard", entryID: "e-sorbal",
                         variantID: "v-" + v, pieces: [0, 1], score: 1, margin: 1, sourceProtection: ["open"])
        }
        try await rig.lexicon.reject([i("zorbal")], of: 1, reason: "war richtig")
        try await rig.lexicon.reject([i("sorbel")], of: 2, reason: "rohfassung")
        #expect(await Self.status(rig) == ["v-zorbal": .retired, "v-sorbel": .suspended])
        #expect(await rig.lexicon.reviewList().contains { $0.reason == "zwei Ablehnungen" && $0.variantID == nil })
        #expect(await rig.lexicon.entries().count == 1, "nothing is deleted")
    }

    @Test func theAfterRunCountsCounterEvidenceForAnyOtherFormAndContradictions() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal", variants: [Self.variant("korbim", .active)])])
        let stage = TextStage(lexicon: await rig.lexicon.snapshot(),
                              protection: FrozenWordSet(german: ["das", "ist", "gut"], english: []),
                              config: TextStageConfig())
        for (ref, day) in [("a", 1), ("b", 2)] {
            try await rig.ledger.observe(local: "das ist zorbal gut", postRun: "das ist Sorbal gut", ref: ref,
                                         day: day, stage: stage)
        }
        try await rig.ledger.observe(local: "das ist zorbal gut", postRun: "das ist Zorbel gut", ref: "c", day: 3,
                                     stage: stage)
        #expect(await rig.ledger.suggestions().isEmpty, "the after-run wrote another form: counter evidence")
        for ref in ["d", "e"] {
            try await rig.ledger.observe(local: "das ist Sorbal gut", postRun: "das ist korbim gut", ref: ref,
                                         day: 4, stage: stage)  // the local text as the stage wrote it
        }
        #expect(await Self.status(rig)["v-korbim"] == .suspended, "S4 from two after-runs")
        #expect(await rig.lexicon.reviewList().contains { $0.reason == "nachlauf" })
    }

    // MARK: Zum Prüfen, import, candidates, journal

    @Test func theReviewListIsSettledByOneClickEach() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal", variants: [Self.variant("zorbal", .active),
                                                                     Self.variant("sorbel", .active)])])
        try await rig.lexicon.still(entry: "e-sorbal", variant: "v-zorbal", .suspended, reason: "gegenkorrektur")
        try await rig.lexicon.still(entry: "e-sorbal", variant: "v-sorbel", .suspended, reason: "gegenkorrektur")
        try await rig.lexicon.decide(0, .reactivate)
        try await rig.lexicon.decide(1, .retire)
        #expect(await Self.status(rig) == ["v-zorbal": .active, "v-sorbel": .retired])
        try await rig.lexicon.review(entry: "e-sorbal", variant: nil, reason: "zwei Ablehnungen")
        try await rig.lexicon.decide(2, .retarget("SorBal"))
        #expect(await rig.lexicon.entries().first?.canonical == "SorBal")
        #expect(await rig.lexicon.reviewList().map(\.settled) == ["aktiv", "aus", "ziel"])
        await #expect(throws: LexiconStore.Unreadable.self) { try await rig.lexicon.decide(0, .retire) }
    }

    @Test func theStartLexiconIsImportedOnceIntoAnUntouchedStore() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let folder = try await Self.startFolder(rig, [Self.entry("Sorbal", variants: [
            Self.variant("zorbal", .active, origin: .corpus)])], [
            Self.pair("puls", "e-sorbal", word: true, benefit: 2),
            Self.pair("sorbe", "e-sorbal", word: false, benefit: 1, state: .collecting)])
        let summary = try CorrectionLedger.preview(folder)
        #expect(summary == StartSummary(entries: 1, active: 1, proposals: 1, waiting: 1))
        #expect(try await rig.ledger.importStart(from: folder) == summary)
        #expect(await rig.lexicon.entries().first?.hearingVariants.first?.status == .active)
        let importable = await rig.lexicon.importable()
        #expect(await rig.ledger.pairs().count == 2 && !importable)
        await #expect(throws: LexiconStore.Refused.self) { try await rig.ledger.importStart(from: folder) }
        let clicked = try await Self.startFolder(rig, [Self.entry("Sorbal", variants: [
            Self.variant("zorbal", .active)])], [])
        let other = try Rig()
        defer { other.remove() }
        await #expect(throws: LexiconStore.Refused.self) { try await other.ledger.importStart(from: clicked) }
    }

    @Test func recurringNonWordsBecomeProposalsOnceAndNeverAfterADecline() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal")])
        let near = NearMiss(rule: "R3", before: "sorbul", target: "Sorbal", score: 0.8, reason: "threshold")
        let history = (1...3).map { JournalView(day: $0, recognizerText: "wir zumpf heute", protectedForms: ["wir",
            "heute"], rejectedInterventions: 0, interventionCount: 0, nearMisses: [near]) }
        let found = CandidateDetector(lexicon: await rig.lexicon.snapshot()).candidates(in: history)
        try await rig.ledger.propose(found)
        try await rig.ledger.propose(found)
        #expect(await rig.lexicon.entries().filter { $0.status == .proposed }.map(\.canonical) == ["zumpf"])
        #expect(await rig.ledger.suggestions().map(\.heard) == ["sorbul"])
        let id = try #require(await rig.lexicon.entries().first { $0.canonical == "zumpf" }?.id)
        try await rig.lexicon.apply(.retireEntry(entry: id, reason: "abgelehnt"))
        try await rig.ledger.propose(found)
        #expect(await rig.lexicon.entries().filter { $0.status == .proposed }.isEmpty, "\"nicht mehr fragen\" holds")
    }

    @Test func theJournalKeepsWhatProbationAndTheWindowNeedAcrossARestart() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let paths = Paths(profile: .development, applicationSupport: rig.root)
        try rig.fs.makeFolder(paths.diktate)
        let journal = DictationJournal(paths: paths, fs: rig.fs, log: rig.log)
        let i = Intervention(tRule: "variant", tBefore: "zorbal", tAfter: "Sorbal", tReason: "heard",
                             entryID: "e-sorbal", variantID: "v-zorbal", pieces: [0, 1], score: 1, margin: 1,
                             sourceProtection: ["open"])
        let j = Intervention(tRule: "variant", tBefore: "korbim", tAfter: "Korbin", tReason: "heard",
                             entryID: "e-korbin", variantID: "v-korbim", pieces: [2, 3], score: 1, margin: 1,
                             sourceProtection: ["open"])
        func json(_ any: Any) -> JSONValue {
            if let s = any as? String { return .string(s) }
            if let l = any as? [Any] { return .list(l.map(json)) }
            if let o = any as? [String: Any] { return .object(o.mapValues(json)) }
            return .number((any as? NSNumber)?.doubleValue ?? 0)
        }
        let detail = json(try JSONSerialization.jsonObject(with: JSONEncoder().encode([i, j])))
        try await journal.append(.recognized(id: "a", recognizerText: "zorbal und korbim",
                                             finalText: "Sorbal und Korbin", interventions: ["variant", "variant"], [
                                                "intervention_detail": detail, "protected": .list([.string("und")]),
                                                "alternatives": .list([.list([.string("Sorbal und")])])]))
        try await journal.append(JournalEntry("reject_intervention", id: "a", ["variant_id": .string("v-zorbal")]))
        try await journal.append(.inserted(id: "a", result: "landed"))
        let again = DictationJournal(paths: paths, fs: rig.fs, log: rig.log)
        let view = try #require(await again.views(classified: true).first)
        #expect(view.protectedForms == ["und"] && view.alternatives == ["Sorbal und"])
        #expect(view.rejectedInterventions == 1 && view.variants == ["v-zorbal"], "only the rejected variant")
        let record = try #require(await again.records(limit: 5).first)
        #expect(record.interventions == [i, j] && record.finalText == "Sorbal und Korbin")
        let counts = (await again.appended, await journal.appended)
        #expect(counts == (0, 3))
    }
}
