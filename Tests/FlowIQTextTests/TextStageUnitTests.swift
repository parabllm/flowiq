import Foundation
import Testing
@testable import FlowIQText

/// Unit tests for behaviour the P2 acceptance tests leave open. Artificial words only.
struct TextStageUnitTests {
    static let known: Set<String> = ["ist", "da", "und", "heute", "wir", "testen", "Ist", "Wir"]

    static func entry(_ canonical: String, family: String? = nil) -> CanonEntry {
        CanonEntry(id: "e-" + canonical, canonical: canonical, kind: .name, family: family, spokenForms: [],
                   hearingVariants: [], status: .confirmed, origin: .seed, compound: .hyphen, counters: Counters(),
                   createdAt: Date(timeIntervalSince1970: 0), confirmedAt: nil)
    }

    static func stage(_ entries: [CanonEntry], spoken: Bool = false) -> TextStage {
        let iq = FamilyRule(id: "iq", anchorWritten: "IQ", anchorSpoken: [], join: .concatenated)
        return TextStage(lexicon: LexiconSnapshot(entries: entries, families: [iq]),
                         protection: FrozenWordSet(german: known, english: []),
                         config: TextStageConfig(spokenForm: spoken))
    }

    /// Answers every query with "unknown", so only the frozen set protects.
    static func run(_ text: String, _ stage: TextStage) -> TextStageResult {
        let input = Recognition(text: text)
        let answers = OracleAnswers(known: Dictionary(uniqueKeysWithValues: stage.oracleQueries(for: input)
            .map { ($0, false) }))
        return stage.process(input, answers: answers)
    }

    @Test func controlResidueIsRemovedAndNothingElse() {
        #expect(Pieces.clean("K\\letter und L\\letter") == "K und L")
        #expect(Pieces.clean("wir \\komma heute") == "wir heute")
        #expect(Pieces.clean("ohne Rest, äh, so") == "ohne Rest, äh, so")
        let result = Self.run("heute K\\letter", Self.stage([]))
        #expect(result.text == "heute K")
        #expect(result.stageTexts == ["heute K\\letter", "heute K"])
    }

    @Test func pluralSOfTheSourceIsKept() {
        #expect(Self.run("wir testen kelranas heute", Self.stage([Self.entry("Kelrana")])).text
            == "wir testen Kelranas heute")
        #expect(Self.run("Kelranas ist da", Self.stage([Self.entry("Kelrana")])).interventions.isEmpty)
    }

    @Test func lowerCaseCanonicalStaysCapitalizedAtSentenceStart() {
        let stage = Self.stage([Self.entry("zorbelnet")])
        #expect(Self.run("Zorbelnet ist da", stage).text == "Zorbelnet ist da")
        #expect(Self.run("ZorbelNet ist da", stage).text == "zorbelnet ist da")
    }

    @Test func spokenFormIsOffByDefault() {
        let entries = [Self.entry("VierbIQ", family: "iq")]
        let text = "wir testen 4BQ heute und da ist da und wir"
        #expect(Self.run(text, Self.stage(entries)).text == text)
        #expect(Self.run(text, Self.stage(entries, spoken: true)).text
            == "wir testen VierbIQ heute und da ist da und wir")
        // Four pieces: the share counts against 20 pieces, so the short dictation is corrected.
        #expect(Self.run("wir testen 4BQ heute", Self.stage(entries, spoken: true)).text == "wir testen VierbIQ heute")
    }

    @Test func aDictationOfOnlyANameIsCorrected() {
        let stage = Self.stage([Self.entry("VierbIQ", family: "iq")], spoken: true)
        #expect(Self.run("vier be ku", stage).text == "VierbIQ")
        #expect(Self.run("4BQ", stage).droppedByBrake == 0)
        // Six R3 pieces among 9 stay too many: 6 > 0.15 * 20.
        #expect(Self.run("4BQ und vier be ku und 4B Q heute", stage).droppedByBrake == 3)
    }

    @Test func unknownFamilyStemBecomesNearMissAndCandidate() {
        let result = Self.run("wir testen Zumpf IQ heute", Self.stage([Self.entry("NapIQ", family: "iq")]))
        #expect(result.text == "wir testen Zumpf IQ heute")
        #expect(result.nearMisses.contains { $0.reason == "stem" && $0.target == "ZumpfIQ" })
        let history = [1, 2].map {
            JournalView(day: $0, recognizerText: "Zumpf IQ", protectedForms: [], rejectedInterventions: 0,
                        interventionCount: 0, nearMisses: result.nearMisses)
        }
        let found = CandidateDetector().candidates(in: history)
        #expect(found.contains { $0.source == .familyPattern && $0.target == "ZumpfIQ" && $0.dictations == 2 })
    }

    @Test func brakeIsRecordedInTheTrace() {
        let text = (0..<7).map { _ in "wir testen 4BQ heute und da ist es" }.joined(separator: " ")
        let result = Self.run(text, Self.stage([Self.entry("VierbIQ", family: "iq")], spoken: true))
        #expect(result.text == text)
        #expect(result.droppedByBrake == 7)
        #expect(result.nearMisses.filter { $0.reason == "brake" }.count == 7)
    }

    @Test func frozenAnswersAreNotAskedAgain() {
        let stage = Self.stage([])
        let input = Recognition(text: "wir testen zumpf")
        let queries = stage.oracleQueries(for: input)
        #expect(queries.contains(OracleQuery(form: "zumpf", kind: .word)))
        let frozen = stage.protection.adding(OracleAnswers(known: Dictionary(uniqueKeysWithValues: queries.map {
            ($0, false)
        })))
        let again = TextStage(lexicon: stage.lexicon, protection: frozen, config: stage.config)
        #expect(again.oracleQueries(for: input).isEmpty)
        #expect(frozen.version == stage.protection.version + 1)
    }

    /// A.7: an acronym is reached only through the spelled reading. R1 never glues a word and a letter into one
    /// (Nichtanfassen 1 of 685, P2c: "Form" pair of a known word plus a single letter); a name still joins.
    @Test func severalPiecesNeverBecomeAnAcronymByForm() {
        var acronym = Self.entry("DAQ")
        acronym.kind = .acronym
        let stage = Self.stage([acronym, Self.entry("KelraQ")])
        let joined = Self.run("wir testen DA Q heute", stage)
        #expect(joined.text == "wir testen DA Q heute")
        #expect(joined.nearMisses.contains { $0.reason == "acronym" && $0.target == "DAQ" })
        #expect(Self.run("wir testen Daq heute", stage).text == "wir testen DAQ heute", "one piece is a case form")
        #expect(Self.run("wir testen Kelra Q heute", stage).text == "wir testen KelraQ heute")
    }

    @Test func compoundOfTwoGermanPartsIsProtected() {
        let stage = Self.stage([])
        var known: [OracleQuery: Bool] = [:]
        for q in stage.oracleQueries(for: Recognition(text: "Kelranhaus")) {
            known[q] = ["Kelran", "Haus"].contains(q.form)
        }
        let piece = Pieces.split("Kelranhaus")[0]
        #expect(stage.shield.classify(piece, OracleAnswers(known: known)) == .formed)
        #expect(stage.shield.classify(piece, OracleAnswers(known: known.mapValues { _ in false })) == .open)
        #expect(stage.shield.classify(piece, OracleAnswers(known: [:])) == .noAnswer)
    }
}
