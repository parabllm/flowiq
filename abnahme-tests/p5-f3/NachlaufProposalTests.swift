// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-8: deviations of the after-run become PROPOSALS, never rules (ARCHITEKTUR N.3, R-113; Anhang I addition to
// `AftercareTests`: "Textstufe auf dem Nachlauf-Ergebnis; Nachlauf-Abweichungen nur als Vorschlag"). After every
// upgrade the local version is aligned against the after-run version, both brought to the canon first. A pair becomes a
// proposal only after 2 recordings on 2 days without counter-evidence, marked "gesehen bei ElevenLabs"; pairs of two
// normal words without an entry are dropped; nothing in the lexicon changes without a click. The text stage also runs
// on the after-run result before it replaces the live text (N.4).
import Foundation
import Testing
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQStore
@testable import FlowIQText

@Suite(.timeLimit(.minutes(4)))
struct NachlaufProposalTests {
    private let napiq = entry("NapIQ")

    /// One recording on its own day: the local live text, the after-run answer, upgraded in place.
    private func recording(_ rig: StoreRig, day: Int, minute: Int = 0, local: String, mode: RecordingMode = .call) async throws -> URL {
        let when = localDate(2026, 11, day, 10, minute)
        rig.clock.set(when)  // ASSUMPTION: assumed API, see the Support header
        let live = try await rig.begin(mode, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 1, speaker: "Mara", text: local))
        try await rig.finish(live, seconds: 60, raw: try rig.makeRaw(mode, at: when, seconds: 60))
        return live.url
    }

    private func batch(_ answers: [String]) -> FakeBatch {
        FakeBatch(script: answers.map { .success([Line(seconds: 1, speaker: "Mara", text: $0)], speakers: 1) })
    }

    // MARK: when a pair becomes a proposal

    @Test func oneRecordingMakesNoProposal() async throws {
        let rig = try await StoreRig.make(batch: batch(["das ist NapIQ gut"]), lexicon: [napiq])
        defer { rig.remove() }
        _ = try await recording(rig, day: 10, local: "das ist napik gut")
        #expect(await rig.ledger.suggestions().isEmpty)  // ASSUMPTION: CorrectionLedger.suggestions() async -> [Suggestion]
    }

    @Test func twoRecordingsOnOneDayMakeNoProposal() async throws {
        let rig = try await StoreRig.make(batch: batch(["das ist NapIQ gut", "das ist NapIQ gut"]), lexicon: [napiq])
        defer { rig.remove() }
        _ = try await recording(rig, day: 10, minute: 0, local: "das ist napik gut")
        _ = try await recording(rig, day: 10, minute: 30, local: "das ist napik gut")
        #expect(await rig.ledger.suggestions().isEmpty, "2 recordings on 1 day are not enough")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func twoRecordingsOnTwoDaysMakeAMarkedProposalAndChangeNothing() async throws {
        let rig = try await StoreRig.make(batch: batch(["das ist NapIQ gut", "das ist NapIQ gut"]), lexicon: [napiq])
        defer { rig.remove() }
        let before = await rig.lexicon.entries()  // ASSUMPTION: assumed API, see the Support header
        _ = try await recording(rig, day: 10, local: "das ist napik gut")
        _ = try await recording(rig, day: 11, local: "das ist napik gut")
        let proposals = await rig.ledger.suggestions()  // ASSUMPTION: assumed API, see the Support header
        let proposal = try #require(proposals.first)
        #expect(proposals.count == 1)
        #expect(proposal.heard == "napik" && proposal.target == "NapIQ")  // ASSUMPTION: Suggestion.heard, .target, .label
        #expect(proposal.label.contains("gesehen bei ElevenLabs"), "the after-run spelling is marked as such")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.lexicon.entries() == before, "the lexicon changed without a click")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func counterEvidenceKeepsThePairBack() async throws {
        let rig = try await StoreRig.make(batch: batch(["das ist NapIQ gut", "das ist NapIQ gut", "das ist Nabik gut"]), lexicon: [napiq])
        defer { rig.remove() }
        _ = try await recording(rig, day: 10, local: "das ist napik gut")
        _ = try await recording(rig, day: 11, local: "das ist napik gut")
        _ = try await recording(rig, day: 12, local: "das ist napik gut")  // the service wrote something else this time
        #expect(await rig.ledger.suggestions().filter { $0.heard == "napik" }.isEmpty)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func pairsOfTwoNormalWordsWithoutAnEntryAreDropped() async throws {
        let rig = try await StoreRig.make(batch: batch(Array(repeating: "wir treffen uns denn heute", count: 3)))
        defer { rig.remove() }
        for day in 10...12 { _ = try await recording(rig, day: day, local: "wir treffen uns dann heute") }
        #expect(await rig.ledger.suggestions().isEmpty)  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.ledger.openPairs().isEmpty, "a confusion of two normal words is not even kept")  // ASSUMPTION: openPairs() lists pairs still collecting evidence
    }

    @Test func punctuationAndCaseDifferencesAreNoPairs() async throws {
        let rig = try await StoreRig.make(batch: batch(Array(repeating: "Das ist NapIQ.", count: 3)), lexicon: [napiq])
        defer { rig.remove() }
        for day in 10...12 { _ = try await recording(rig, day: day, local: "das ist napik") }
        let proposals = await rig.ledger.suggestions()  // ASSUMPTION: assumed API, see the Support header
        #expect(proposals.map(\.heard) == ["napik"], "only the real difference: \(proposals.map(\.heard))")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func aClickMakesTheProposalARealButCautiousVariant() async throws {
        let rig = try await StoreRig.make(batch: batch(Array(repeating: "das ist NapIQ gut", count: 2)), lexicon: [napiq])
        defer { rig.remove() }
        _ = try await recording(rig, day: 10, local: "das ist napik gut")
        _ = try await recording(rig, day: 11, local: "das ist napik gut")
        let proposal = try #require(await rig.ledger.suggestions().first)  // ASSUMPTION: assumed API, see the Support header
        try await rig.ledger.accept(proposal)  // ASSUMPTION: accept(_:) is the click on a proposal
        let variants = await rig.lexicon.entries().first { $0.canonical == "NapIQ" }?.hearingVariants ?? []  // ASSUMPTION: assumed API, see the Support header
        #expect(variants.map(\.heard) == [["napik"]])  // ASSUMPTION: assumed API, see the Support header
        #expect(variants.first?.status == .probation, "even a clicked proposal goes through probation")
    }

    @Test func tenRecordingsNeverChangeTheLexiconWithoutAClick() async throws {
        let rig = try await StoreRig.make(batch: batch(Array(repeating: "das ist NapIQ gut", count: 10)), lexicon: [napiq])
        defer { rig.remove() }
        let before = await rig.lexicon.entries()  // ASSUMPTION: assumed API, see the Support header
        for day in 1...10 { _ = try await recording(rig, day: day, minute: 5, local: "das ist napik gut") }
        #expect(await rig.lexicon.entries() == before)  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.ledger.suggestions().count == 1, "the pair is collected as ONE proposal, not repeated")  // ASSUMPTION: assumed API, see the Support header
    }

    // MARK: both sides are brought to the canon first

    @Test func whenBothSidesAgreeAfterTheStageThereIsNoPair() async throws {
        let known = entry("NapIQ", variants: [variant("napik", status: .active)])
        let rig = try await StoreRig.make(batch: batch(Array(repeating: "das ist napik gut", count: 3)), lexicon: [known])
        defer { rig.remove() }
        for day in 10...12 { _ = try await recording(rig, day: day, local: "das ist napik gut") }
        #expect(await rig.ledger.openPairs().isEmpty, "both sides read NapIQ after the stage: no deviation")  // ASSUMPTION: assumed API, see the Support header
    }

    // MARK: the stage runs on the after-run result

    @Test func theAfterRunTextPassesTheStageBeforeItReplacesTheLiveText() async throws {
        let known = entry("NapIQ", variants: [variant("napik", status: .active)])
        let rig = try await StoreRig.make(batch: batch(["das ist napik gut"]), lexicon: [known])
        defer { rig.remove() }
        let url = try await recording(rig, day: 10, local: "etwas ganz anderes")
        let doc = try readDoc(url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(doc.contributions.contains { $0.hasSuffix("das ist NapIQ gut") }, "the after-run text was not corrected by the stage: \(doc.contributions)")
    }

    @Test func theLocalVersionIsKeptInACopyBeforeTheReplacement() async throws {
        let rig = try await StoreRig.make(batch: batch(["Neufassung."]), lexicon: [napiq])
        defer { rig.remove() }
        _ = try await recording(rig, day: 10, local: "das ist napik gut")
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: rig.paths.support.appending(path: "fassungen").path)) ?? []
        #expect(copies.filter { !$0.hasPrefix(".") }.count == 1)
    }
}
