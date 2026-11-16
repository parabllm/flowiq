import Foundation
import Testing
@testable import FlowIQText

/// P2c, pure part of the correction loop: alignment, what a click teaches, the window's text model, permanent
/// cases, sound neighbours. Invented words only.
struct CorrectionLoopTests {
    static let known: Set<String> = ["wir", "sehen", "uns", "heute", "dann", "denn", "bitte", "kommt", "puls"]

    static func entry(_ canonical: String, _ variants: [HearingVariant] = []) -> CanonEntry {
        CanonEntry(id: "e-" + canonical.lowercased(), canonical: canonical, kind: .name, family: nil, spokenForms: [],
                   hearingVariants: variants, status: .confirmed, origin: .seed, compound: .hyphen,
                   counters: Counters(), createdAt: Date(timeIntervalSince1970: 0), confirmedAt: nil)
    }

    static func stage(_ entries: [CanonEntry], known: Set<String> = known) -> TextStage {
        TextStage(lexicon: LexiconSnapshot(entries: entries, families: []),
                  protection: FrozenWordSet(german: known, english: []), config: TextStageConfig())
    }

    static func unknown(_ stage: TextStage, _ text: String) -> OracleAnswers {
        OracleAnswers(known: Dictionary(uniqueKeysWithValues: stage.oracleQueries(for: Recognition(text: text))
            .map { ($0, false) }))
    }

    // MARK: alignment

    @Test func wordsDropTagsHesitationsAndEdgePunctuation() {
        let words = PairAligner.words("Äh, wir (lacht) sehen [Musik] uns, ähm heute.")
        #expect(words == ["wir", "sehen", "uns", "heute"])
    }

    @Test func alignmentCoversBothSidesWithExactEqualBlocks() {
        let a = ["wir", "sehen", "zorbal", "uns", "heute"], b = ["Wir", "sehen", "Sorbal", "Ventura", "uns"]
        let ops = PairAligner.align(a, b)
        #expect(ops.map(\.kind) == [.equal, .replace, .equal, .delete])
        #expect(ops[1].a == 2..<3 && ops[1].b == 2..<4)
        #expect(ops.flatMap { Array($0.a) } == Array(0..<5) && ops.flatMap { Array($0.b) } == Array(0..<5))
    }

    // MARK: what a click teaches (N.2 point 4)

    @Test func aClickTeachesByTheKindOfItsSource() {
        let stage = Self.stage([Self.entry("Pulsor")])
        let kind = { (heard: String, meant: String) in
            stage.classifyCorrection(heard: heard, meant: meant, answers: Self.unknown(stage, heard + " " + meant))
        }
        #expect(kind("zorbal", "Sorbal") == .learn)
        #expect(kind("puls", "Pulsor") == .askScope)
        #expect(kind("dann", "denn") == .confusion)
        #expect(kind("zorbal", "zorbal") == .none)
        let unanswered = stage.classifyCorrection(heard: "zorbal", meant: "Sorbal", answers: OracleAnswers(known: [:]))
        #expect(unanswered == .askScope, "an unanswered form counts as protected")
    }

    @Test func clickedStatusAndStilling() {
        let proven = Self.entry("Sorbal", [HearingVariant(id: "v", heard: ["zorbal"], context: [], status: .active,
                                                           origin: .userClick, replacesProtectedWord: false,
                                                           counters: Counters())])
        #expect(CorrectionRules.clickedStatus(target: proven, realWord: false) == .active)
        #expect(CorrectionRules.clickedStatus(target: Self.entry("Sorbal"), realWord: true) == .active,
                "a real word comes only with the explicit scope answer, which decides (3.3)")
        let wordOnly = Self.entry("Sorbal", [HearingVariant(id: "w", heard: ["puls"], context: [], status: .active,
                                                             origin: .userClick, replacesProtectedWord: true,
                                                             counters: Counters())])
        #expect(!CorrectionRules.proven(wordOnly), "a word-for-word variant proves no sound of the target")
        #expect(CorrectionRules.clickedStatus(target: Self.entry("Sorbal"), realWord: false) == .probation)
        #expect(CorrectionRules.clickedStatus(target: nil, realWord: false) == .probation)
        #expect(CorrectionRules.stilled(interventions: 1) == .retired)
        #expect(CorrectionRules.stilled(interventions: 3) == .suspended)
    }

    @Test func learnedVariantFixesTheRecurrenceOnlyAfterProbation() {
        var v = HearingVariant(id: "v", heard: ["zorbal"], context: [], status: .probation, origin: .userClick,
                               replacesProtectedWord: false, counters: Counters())
        let history = ["wir sehen zorbal", "zorbal kommt"].enumerated().map {
            JournalView(day: $0.offset, recognizerText: $0.element, protectedForms: [], rejectedInterventions: 0,
                        interventionCount: 0)
        }
        let run = { (variant: HearingVariant) -> String in
            let stage = Self.stage([Self.entry("Sorbal", [variant])])
            return stage.process(Recognition(text: "bitte zorbal heute"), answers: Self.unknown(stage, "zorbal")).text
        }
        #expect(run(v) == "bitte zorbal heute", "a variant in probation does not act")
        #expect(Probation.evaluate(v, over: Array(history.prefix(1))) == .keepProbation)
        #expect(Probation.evaluate(v, over: history) == .promote)
        v.status = .active
        #expect(run(v) == "bitte Sorbal heute")
    }

    // MARK: the window's text model

    @Test func correctionTextMapsWordsToTheRecognizerAndFlagsInterventions() throws {
        let i = Intervention(tRule: "variant", tBefore: "zorbal ventu", tAfter: "SorbalVentura", tReason: "heard",
                             entryID: "e-sv", variantID: "v-1", pieces: [2, 4], score: 1, margin: 1,
                             sourceProtection: [])
        var text = CorrectionText(recognized: "wir sehen zorbal ventu heute", final: "wir sehen SorbalVentura heute",
                                  interventions: [i])
        #expect(text.words == ["wir", "sehen", "SorbalVentura", "heute"])
        #expect(text.interventionSpans == [2..<3])
        let (covered, raw) = try #require(text.cover(1..<3))
        #expect(text.raw[raw] == ["sehen", "zorbal", "ventu"])
        text.replace(covered, with: ["sahen", "Sorbal"])
        #expect(text.words == ["wir", "sahen", "Sorbal", "heute"] && text.interventionSpans.isEmpty)
        #expect(text.cover(4..<5) == nil)
    }

    @Test func alternativesPerWordOrOppositeTheSpanInAWholeSegment() {
        let perWord = CorrectionText(recognized: "a b c", final: "a b c", interventions: [])
        #expect(perWord.alternatives(1..<2, from: [[], ["b1", "b2", "b3", "b4"], []]) == ["b1", "b2", "b3"])
        let segment = CorrectionText(recognized: "wir sehen zorbal heute", final: "wir sehen zorbal heute",
                                     interventions: [])
        let all = [["wir sehen sorbal heute", "wir sehen zorbal heute", "wir sehen korbal heute"]]
        #expect(segment.alternatives(2..<3, from: all) == ["sorbal", "korbal"])
        #expect(segment.alternatives(1..<3, from: all).isEmpty, "a span that is no single replacement has none")
    }

    // MARK: permanent cases, neighbours, harm probe

    @Test func aChangeThatBreaksAPermanentCaseIsFound() {
        let cases = [RegressionCase(input: "wir sehen uns dann", expected: "wir sehen uns dann"),
                     RegressionCase(input: "zorbal kommt", expected: "Sorbal kommt")]
        let variant = { (heard: String) in
            HearingVariant(id: heard, heard: [heard], context: [], status: .active, origin: .corpus,
                           replacesProtectedWord: false, counters: Counters())
        }
        let check = { (variants: [HearingVariant]) in
            Self.stage([Self.entry("Sorbal", variants)], known: []).failing(cases)
        }
        #expect(check([variant("zorbal")]).isEmpty)
        #expect(check([]) == [cases[1]])
        #expect(check([variant("zorbal"), variant("dann")]) == [cases[0]],
                "worst case: the check treats every form as unknown, so a variant on a normal word is caught")
    }

    @Test func soundNeighboursAreConfirmedEntriesBestFirst() {
        var proposed = Self.entry("Zorbal")
        proposed.status = .proposed
        let entries = ["Zorbahl", "Sorbal", "Korbal", "Quendrik"].map { Self.entry($0) } + [proposed]
        let near = Self.stage(entries, known: []).soundNeighbors(of: "zorbal", limit: 3)
        #expect(near == ["Zorbahl", "Sorbal", "Korbal"], "same folding first, unconfirmed and far entries never")
    }

    @Test func harmProbeReplacesEveryOccurrenceOnly() {
        let text = "Zorbal-ventu, und zorbal ventu."
        #expect(CorrectionRules.replacing(["zorbal", "ventu"], with: "SorbalVentura", in: text)
                == "SorbalVentura, und SorbalVentura.")
        #expect(CorrectionRules.replacing(["zorbal"], with: "Sorbal", in: "zorbalo zorbal") == "zorbalo Sorbal")
        #expect(CorrectionRules.replacing([], with: "X", in: "zorbal") == "zorbal")
    }
}
