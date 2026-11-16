// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-3: learning from a correction (ARCHITEKTUR N.2 point 4, N.3, N.5; R-111). The click is the confirmation of
// the TARGET (rule I1); a wrong form that is no real word becomes a hearing variant in probation; a real word as the
// source asks once ("immer", "nur neben <Nachbarwort>", "nur dieses Mal"); the confusion of two normal words is counted
// and never becomes a rule; the first undo of an active variant stills it at once (nothing is deleted, it moves to the
// list "Zum Prüfen"). The probation arithmetic itself is the real `Probation.evaluate` (public, P2).
import Foundation
import Testing
@testable import FlowIQ
@testable import FlowIQCore
@testable import FlowIQStore
@testable import FlowIQText

@Suite(.timeLimit(.minutes(3)))
struct CorrectionLearningTests {
    private let spoken = ["bitte", "brimvold", "kommt"]
    private let plain = ["bitte", "brimvold", "kommt"]

    private func dictation(_ id: String, _ words: [String]? = nil, _ final: [String]? = nil) -> Scripted {
        Scripted(id: id, spoken: words ?? spoken, final: final ?? words ?? plain)
    }

    /// Runs the real text stage over one künstliche dictation with the entries of the store as they are now.
    private func stageOutput(_ text: String, _ entries: [CanonEntry]) -> String {
        let stage = TextStage(lexicon: LexiconSnapshot(entries: entries, families: []), protection: Words.frozen, config: TextStageConfig())
        let input = Recognition(text: text)
        let answers = OracleAnswers(known: Dictionary(uniqueKeysWithValues: stage.oracleQueries(for: input).map { ($0, false) }))
        return stage.process(input, answers: answers).text
    }

    private func journalView(_ text: String, day: Int, rejected: Int = 0, interventions: Int = 1) -> JournalView {
        JournalView(day: day, recognizerText: text, protectedForms: [], rejectedInterventions: rejected, interventionCount: interventions)
    }

    // MARK: the target is confirmed first, then the hearing variant lives in probation

    @Test func nonWordSourceConfirmsTheTargetThenAddsAProbationVariant() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        try await rig.dictate(dictation("l-1"))
        _ = await rig.open()
        let outcome = await rig.apply(.typed("Brimvolt"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        #expect(outcome?.replace == .fieldReplaced)  // ASSUMPTION: assumed API, see the Support header
        let target = try #require(await rig.entry("Brimvolt"))
        #expect(target.status == .confirmed)
        #expect(target.origin == .userClick)
        let heard = try #require(target.hearingVariants.first)
        #expect(heard.heard == ["brimvold"])
        #expect(heard.status == .probation)
        #expect(heard.origin == .userClick)
        let kinds = await rig.lexicon.changeLog().map(\.kind)  // ASSUMPTION: LexiconStore.changeLog() async -> [LexiconChange] in order, LexiconChange.kind is a string
        #expect(kinds == ["entry_confirmed", "variant_added"], "the target must be confirmed before any variant exists: \(kinds)")
    }

    @Test func aVariantInProbationDoesNotActYet() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        try await rig.dictate(dictation("l-2"))
        _ = await rig.open()
        _ = await rig.apply(.typed("Brimvolt"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        let after = stageOutput("bitte brimvold kommt", await rig.entries())
        #expect(after == "bitte brimvold kommt", "a variant in probation changed a text: \(after)")
    }

    @Test func afterProbationTheSameWrongFormIsFixedTenOfTen() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        try await rig.dictate(dictation("l-3"))
        _ = await rig.open()
        _ = await rig.apply(.typed("Brimvolt"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        let probationVariant = try #require(await rig.entry("Brimvolt")?.hearingVariants.first)
        let history = [journalView("bitte brimvold kommt", day: 1), journalView("das ist brimvold hier", day: 2)]
        #expect(Probation.evaluate(probationVariant, over: history) == .promote)
        try await rig.lexicon.runProbation(over: history)  // ASSUMPTION: LexiconStore.runProbation(over:) applies Probation.evaluate verdicts to all variants
        let entries = await rig.entries()
        #expect(entries.first { $0.canonical == "Brimvolt" }?.hearingVariants.first?.status == .active)
        var fixed = 0
        for i in 0..<10 where stageOutput("bitte brimvold kommt heute \(i)", entries).contains("Brimvolt") { fixed += 1 }
        #expect(fixed == 10, "only \(fixed) of 10 recurrences were fixed")
    }

    @Test func aNewWrongFormOfAConfirmedTargetWithPassedProbationIsActiveWithoutFurtherProbation() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("Brimvolt", variants: [variant("brimvold", status: .active)])])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "l-4", spoken: ["bitte", "brimfold", "kommt"], final: ["bitte", "brimfold", "kommt"]))
        _ = await rig.open()
        _ = await rig.apply(.lexicon("Brimvolt"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        let target = try #require(await rig.entry("Brimvolt"))
        #expect(target.hearingVariants.first { $0.heard == ["brimfold"] }?.status == .active)
        #expect(target.hearingVariants.count == 2)
    }

    @Test func aNewWrongFormOfATargetStillInProbationStaysInProbation() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("Brimvolt", variants: [variant("brimvold", status: .probation)])])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "l-5", spoken: ["bitte", "brimfold", "kommt"], final: ["bitte", "brimfold", "kommt"]))
        _ = await rig.open()
        _ = await rig.apply(.lexicon("Brimvolt"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        let target = try #require(await rig.entry("Brimvolt"))
        #expect(target.hearingVariants.first { $0.heard == ["brimfold"] }?.status == .probation)
    }

    // MARK: a real word as the source asks once

    @Test func realWordSourceAsksOnceAndNothingIsLearnedBeforeTheAnswer() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("Pulsar")])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "r-1", spoken: ["bitte", "pulse", "kommt"], final: ["bitte", "pulse", "kommt"]))
        _ = await rig.open()
        let before = await rig.entries()
        let outcome = await rig.apply(.lexicon("Pulsar"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        #expect(outcome?.replace == .fieldReplaced, "the text itself is corrected at once")  // ASSUMPTION: assumed API, see the Support header
        #expect(outcome?.learning == .askScope)  // ASSUMPTION: CorrectionOutcome.learning is a LearningOutcome { learned, askScope, countedConfusion, none }
        #expect(await rig.entries() == before, "a variant appeared before the user answered")
    }

    @Test func scopeAlwaysAddsAVariantForTheProtectedWord() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("Pulsar")])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "r-2", spoken: ["bitte", "pulse", "kommt"], final: ["bitte", "pulse", "kommt"]))
        _ = await rig.open()
        _ = await rig.apply(.lexicon("Pulsar"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        await rig.session.resolve(.always)  // ASSUMPTION: CorrectionSession.resolve(_:) with ScopeChoice { always, nextTo(String), once }
        let added = try #require(await rig.entry("Pulsar")?.hearingVariants.first)
        #expect(added.heard == ["pulse"])
        #expect(added.replacesProtectedWord)
        #expect(added.context.isEmpty)
        #expect(added.origin == .userClick)
    }

    @Test func scopeNextToAddsAVariantBoundToTheNeighbourWord() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("Pulsar")])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "r-3", spoken: ["bitte", "pulse", "kommt"], final: ["bitte", "pulse", "kommt"]))
        _ = await rig.open()
        _ = await rig.apply(.lexicon("Pulsar"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        await rig.session.resolve(.nextTo("kommt"))  // ASSUMPTION: assumed API, see the Support header
        let added = try #require(await rig.entry("Pulsar")?.hearingVariants.first)
        #expect(added.heard == ["pulse"])
        #expect(added.context == ["kommt"])
        #expect(added.replacesProtectedWord)
    }

    @Test func scopeOnceChangesTheTextAndLearnsNothing() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("Pulsar")])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "r-4", spoken: ["bitte", "pulse", "kommt"], final: ["bitte", "pulse", "kommt"]))
        _ = await rig.open()
        let before = await rig.entries()
        _ = await rig.apply(.lexicon("Pulsar"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
        await rig.session.resolve(.once)  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.entries() == before)
        #expect(rig.target.field == "bitte Pulsar kommt")
    }

    // MARK: confusion of two normal words

    @Test func confusionOfTwoNormalWordsIsCountedAndNeverBecomesARule() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        let before = await rig.entries()
        for i in 0..<3 {
            try await rig.dictate(Scripted(id: "k-\(i)", spoken: ["wir", "kommen", "dann"], final: ["wir", "kommen", "dann"]))
            _ = await rig.open()
            let outcome = await rig.apply(.typed("denn"), to: 2..<3)  // ASSUMPTION: assumed API, see the Support header
            #expect(outcome?.replace == .fieldReplaced, "the correction itself still works")  // ASSUMPTION: assumed API, see the Support header
            #expect(outcome?.learning == .countedConfusion)  // ASSUMPTION: assumed API, see the Support header
            await rig.session.close()  // ASSUMPTION: assumed API, see the Support header
        }
        #expect(await rig.entries() == before, "a confusion of two real words created an entry or a variant")
        #expect(await rig.ledger.confusionCount() == 3)  // ASSUMPTION: CorrectionLedger.confusionCount() async -> Int
    }

    // MARK: the first undo stills an active variant

    @Test func pureProbationStillsAnActiveVariantOnTheFirstRejection() {
        let active = variant("napik", status: .active)
        #expect(Probation.evaluate(active, over: [journalView("das ist napik", day: 1, rejected: 1, interventions: 1)]) == .retire)
        #expect(Probation.evaluate(active, over: [journalView("das ist napik und kelrana", day: 1, rejected: 1, interventions: 2)]) == .suspend)
        #expect(Probation.evaluate(variant("napik", status: .suspended), over: []) == .suspend, "stilled stays stilled")
    }

    @Test func wasRightOnTheOnlyInterventionRetiresTheVariantAndKeepsEverything() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ", variants: [variant("napik", status: .active)])])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "u-1", spoken: ["das", "ist", "napik"], final: ["das", "ist", "NapIQ"]))
        _ = await rig.open()
        let entriesBefore = await rig.entries().count
        let outcome = await rig.drive { [session = rig.session] in await session.markWasRight(2..<3) }  // ASSUMPTION: CorrectionSession.markWasRight(_:) async -> CorrectionOutcome, rejects exactly that intervention
        #expect(outcome?.replace == .fieldReplaced, "the recognizer form comes back at that place")  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.field == "das ist napik")
        let variant = try #require(await rig.entry("NapIQ")?.hearingVariants.first)
        #expect(variant.status == .retired)
        #expect(await rig.entries().count == entriesBefore, "nothing is ever deleted")
        #expect(await rig.entry("NapIQ")?.hearingVariants.count == 1)
        let review = await rig.lexicon.reviewList()  // ASSUMPTION: LexiconStore.reviewList() async -> [ReviewItem] (the list "Zum Prüfen")
        #expect(review.contains { $0.variantID == "v-napik" })  // ASSUMPTION: ReviewItem.variantID
        #expect(stageOutput("das ist napik", await rig.entries()) == "das ist napik", "a stilled variant must not act again")
    }

    @Test func wasRightInADictationWithSeveralInterventionsSuspendsInsteadOfRetiring() async throws {
        let rig = try await CorrectionRig(lexicon: [
            entry("NapIQ", variants: [variant("napik", status: .active)]),
            entry("Brimvolt", variants: [variant("brimvold", status: .active)])])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "u-2", spoken: ["napik", "und", "brimvold"], final: ["NapIQ", "und", "Brimvolt"]))
        _ = await rig.open()
        _ = await rig.drive { [session = rig.session] in await session.markWasRight(0..<1) }  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.entry("NapIQ")?.hearingVariants.first?.status == .suspended)
        #expect(await rig.entry("Brimvolt")?.hearingVariants.first?.status == .active, "only the rejected intervention is affected")
    }
}
