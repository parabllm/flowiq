import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQStore
@testable import FlowIQText

/// P2c, store part: lexicon file, ledger, seeding run, journal views. Invented words, a scratch folder per test.
struct LexiconStoreTests {
    final class Rig: Sendable {
        let root: URL, fs: SafeFS, log: EventLog, lexicon: LexiconStore, ledger: CorrectionLedger

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p2c-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fs = SafeFS(confinedTo: root)
            log = EventLog(directory: root.appending(path: "protokoll"), fs: fs)
            lexicon = LexiconStore(folder: root.appending(path: "lexikon"), fs: fs, log: log)
            ledger = CorrectionLedger(lexicon: lexicon, fs: fs, log: log)
        }

        func remove() {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
    }

    static func entry(_ canonical: String, _ status: EntryStatus = .confirmed) -> CanonEntry {
        CanonEntry(id: "e-" + canonical.lowercased(), canonical: canonical, kind: .name, family: nil, spokenForms: [],
                   hearingVariants: [], status: status, origin: .seed, compound: .hyphen, counters: Counters(),
                   createdAt: Date(timeIntervalSince1970: 0), confirmedAt: nil)
    }

    static func view(_ text: String, day: Int, rejected: Int = 0) -> JournalView {
        JournalView(day: day, recognizerText: text, protectedForms: [], rejectedInterventions: rejected,
                    interventionCount: 1)
    }

    @Test func confirmThenVariantIsLoggedInOrderAndSurvivesAReload() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        guard case .applied(let id) = try await rig.lexicon.apply(.confirmEntry(canonical: "Sorbal")) else {
            Issue.record("confirm blocked")
            return
        }
        try await rig.lexicon.apply(.addVariant(entry: id, heard: ["Zorbal"], status: .probation))
        #expect(await rig.lexicon.changeLog().map(\.kind) == ["entry_confirmed", "variant_added"])
        let again = LexiconStore(folder: rig.lexicon.folder, fs: rig.fs, log: rig.log)
        let entry = try #require(await again.entries().first)
        #expect(entry.canonical == "Sorbal" && entry.status == .confirmed && entry.origin == .userClick)
        #expect(entry.hearingVariants.map(\.heard) == [["zorbal"]])
        #expect(try await again.apply(.confirmEntry(canonical: "Sorbal")) == .applied(id), "same key, same entry")
    }

    @Test func anUnreadableFileIsNeverOverwritten() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try FileManager.default.createDirectory(at: rig.lexicon.folder, withIntermediateDirectories: true)
        let file = rig.lexicon.folder.appending(path: "lexikon.json"), garbage = Data("{kaputt".utf8)
        try garbage.write(to: file)
        #expect(await rig.lexicon.entries().isEmpty)
        await #expect(throws: LexiconStore.Unreadable.self) {
            try await rig.lexicon.apply(.confirmEntry(canonical: "X"))
        }
        await #expect(throws: LexiconStore.Unreadable.self) { try await rig.lexicon.seed([Self.entry("Sorbal")]) }
        #expect(try Data(contentsOf: file) == garbage)
    }

    @Test func aChangeThatBreaksAPermanentCaseIsBlockedAndReported() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal")])
        try await rig.lexicon.addRegressionCase(input: "wir sehen uns dann", expected: "wir sehen uns dann")
        let before = await rig.lexicon.entries()
        let blocked = try await rig.lexicon.apply(.addVariant(entry: "e-sorbal", heard: ["dann"], status: .active))
        #expect(blocked == .blocked([RegressionCase(input: "wir sehen uns dann", expected: "wir sehen uns dann")]))
        #expect(await rig.lexicon.entries() == before)
        #expect(await rig.lexicon.pendingReports().count == 1)
        let harmless = try await rig.lexicon.apply(.addVariant(entry: "e-sorbal", heard: ["zorbal"], status: .active))
        if case .blocked = harmless { Issue.record("a harmless variant was blocked") }
    }

    @Test func probationPromotesRejectsAndStillsWithoutDeleting() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal"), Self.entry("Korbal")])
        try await rig.lexicon.apply(.addVariant(entry: "e-sorbal", heard: ["zorbal"], status: .probation))
        try await rig.lexicon.apply(.addVariant(entry: "e-korbal", heard: ["korb"], status: .probation,
                                                origin: .corpus))
        let history = [Self.view("wir sehen zorbal", day: 1), Self.view("zorbal kommt", day: 2),
                       JournalView(day: 3, recognizerText: "ein korb", protectedForms: ["korb"],
                                   rejectedInterventions: 0, interventionCount: 0)]
        try await rig.lexicon.runProbation(over: history)
        var status = Dictionary(uniqueKeysWithValues: await rig.lexicon.entries().flatMap(\.hearingVariants)
            .map { ($0.heard[0], $0.status) })
        #expect(status == ["zorbal": .active, "korb": .retired])
        try await rig.lexicon.runProbation(over: [Self.view("zorbal hier", day: 4, rejected: 1)])
        status = Dictionary(uniqueKeysWithValues: await rig.lexicon.entries().flatMap(\.hearingVariants)
            .map { ($0.heard[0], $0.status) })
        #expect(status["zorbal"] == .retired, "the first rejection of an active variant stills it")
        #expect((await rig.lexicon.entries()).flatMap(\.hearingVariants).count == 2, "nothing is deleted")
        #expect(await rig.lexicon.reviewList().count == 2)
        #expect(await rig.lexicon.lastProbation() != nil)
    }

    @Test func afterRunPairsNeedTwoRecordingsOnTwoDaysAndNoCounterEvidence() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal")])
        let stage = TextStage(lexicon: await rig.lexicon.snapshot(),
                              protection: FrozenWordSet(german: ["das", "ist", "gut", "wir", "dann", "denn"],
                                                        english: []),
                              config: TextStageConfig())
        for ref in ["a", "b"] {
            try await rig.ledger.observe(local: "das ist zorbal gut", postRun: "das ist Sorbal gut", ref: ref, day: 10,
                                         stage: stage)
        }
        #expect(await rig.ledger.suggestions().isEmpty, "two recordings on one day")
        try await rig.ledger.observe(local: "zorbal ist gut", postRun: "Sorbal ist gut", ref: "c", day: 11,
                                     stage: stage)
        let s = try #require(await rig.ledger.suggestions().first)
        #expect(s.heard == "zorbal" && s.target == "Sorbal" && s.label.contains("gesehen bei ElevenLabs"))
        try await rig.ledger.observe(local: "wir dann", postRun: "wir denn", ref: "d", day: 12, stage: stage)
        #expect(await rig.ledger.openPairs().count == 1, "two normal words without entry are not kept")
        let before = await rig.lexicon.entries()
        try await rig.ledger.accept(s)
        let variants = (await rig.lexicon.entries()).flatMap(\.hearingVariants)
        #expect(before.flatMap(\.hearingVariants).isEmpty && variants.map(\.status) == [.probation])
        #expect(await rig.ledger.suggestions().isEmpty)
    }

    @Test func counterEvidenceKeepsAPairFromBecomingAProposal() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        try await rig.lexicon.seed([Self.entry("Sorbal")])
        let stage = TextStage(lexicon: await rig.lexicon.snapshot(),
                              protection: FrozenWordSet(german: ["gut"], english: []), config: TextStageConfig())
        for (ref, day) in [("a", 1), ("b", 2)] {
            try await rig.ledger.observe(local: "zorbal gut", postRun: "Sorbal gut", ref: ref, day: day, stage: stage)
        }
        try await rig.ledger.observe(local: "zorbal gut", postRun: "zorbal gut", ref: "c", day: 3, stage: stage)
        #expect(await rig.ledger.suggestions().isEmpty)
        try await rig.ledger.countConfusion()
        #expect(await CorrectionLedger(lexicon: rig.lexicon, fs: rig.fs, log: rig.log).confusionCount() == 1)
    }

    @Test func journalViewsCarryRecognizerTextAndRawVersionRejections() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let paths = Paths(profile: .development, applicationSupport: rig.root)
        try rig.fs.makeFolder(paths.diktate)
        let journal = DictationJournal(paths: paths, fs: rig.fs, log: rig.log)
        try await journal.append(.recognized(id: "a", recognizerText: "zorbal kommt", finalText: "Sorbal kommt",
                                             interventions: ["variant"]))
        try await journal.append(JournalEntry("reject", id: "a", ["interventions_rejected": .number(1)]))
        try await journal.append(.recognized(id: "b", recognizerText: "wir sehen uns", finalText: "wir sehen uns",
                                             interventions: [String]()))
        let views = await journal.views()
        #expect(views.map(\.recognizerText) == ["zorbal kommt", "wir sehen uns"])
        #expect(views.map(\.rejectedInterventions) == [1, 0] && views.map(\.interventionCount) == [1, 0])
    }
}
