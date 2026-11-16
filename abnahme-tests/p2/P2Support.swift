// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// P2 acceptance tests, shared fixtures. Artificial data only.
// All assumptions about the not-yet-built FlowIQText interface live in THIS file, one per line,
// marked with "// ASSUMPTION:". The build agent may adapt only those lines, never an expected value.
import Foundation
import Testing
@testable import FlowIQText

enum Fx {
    // MARK: word material

    static let leadSentence = "Wir haben heute das Projekt besprochen und die Zahlen sind gut"
    static let tailSentence = "Morgen machen wir das noch einmal und denken dann weiter"
    static let baseWords: [String] = [
        "wir", "haben", "heute", "das", "projekt", "besprochen", "und", "die", "zahlen", "sind", "gut",
        "morgen", "machen", "noch", "einmal", "denken", "dann", "weiter", "ich", "habe", "du", "musst",
        "kommen", "meine", "sachen", "mitgebracht", "möchte", "gern", "nein", "kalter", "der", "kunde", "ist",
        "zufrieden", "dass", "es", "funktioniert", "aber", "vier", "bar", "bahnen", "design", "nap", "nab",
        "labor", "flow", "nacht", "vierb", "idee", "katze", "ja", "mit", "dem", "geld", "verdienen",
        "wenn", "wir", "da", "sind", "bei", "für", "auf", "in", "zu", "nicht", "sehr", "viel",
        "commit", "connect", "refund", "deploy", "baum", "haus", "tisch", "arbeit", "woche", "ende",
    ]
    // The fake system dictionary knows one more English stem than the frozen set, so "develop" is an oracle case.
    static let oracleOnlyWords: [String] = ["develop"]

    static func caseForms(_ words: [String]) -> Set<String> {
        var out = Set<String>()
        for w in words { out.insert(w.lowercased()); out.insert(w.prefix(1).uppercased() + w.dropFirst()) }
        return out
    }

    static var frozen: FrozenWordSet {
        FrozenWordSet(german: caseForms(baseWords), english: caseForms(["commit", "connect", "refund", "deploy", "design", "flow", "labor"])) // ASSUMPTION: FrozenWordSet(german:english:) with plain word sets, case forms listed explicitly
    }
    static var systemWords: Set<String> { caseForms(baseWords + oracleOnlyWords) }

    // MARK: lexicon

    static func entry(_ canonical: String, kind: EntryKind = .name, family: String? = nil, status: EntryStatus = .confirmed, variants: [HearingVariant] = []) -> CanonEntry {
        CanonEntry(id: "e-" + canonical.lowercased(), canonical: canonical, kind: kind, family: family, spokenForms: [], hearingVariants: variants, status: status, origin: .seed, compound: .hyphen, counters: Counters(benefit: 0, harm: 0, lastAppliedAt: nil, lastCorpusRun: nil), createdAt: Date(timeIntervalSince1970: 0), confirmedAt: status == .confirmed ? Date(timeIntervalSince1970: 1) : nil) // ASSUMPTION: memberwise inits exactly as in LEXIKON-KONZEPT 1.1
    }

    static func variant(heard: [String], status: VariantStatus, origin: VariantOrigin = .corpus, replacesProtectedWord: Bool = false) -> HearingVariant {
        HearingVariant(id: "v-" + heard.joined(separator: "-"), heard: heard, context: [], status: status, origin: origin, replacesProtectedWord: replacesProtectedWord, counters: Counters(benefit: 0, harm: 0, lastAppliedAt: nil, lastCorpusRun: nil)) // ASSUMPTION: memberwise init as in LEXIKON-KONZEPT 1.1
    }

    static var iqFamily: FamilyRule {
        FamilyRule(id: "iq", anchorWritten: "IQ", anchorSpoken: [SpokenForm(language: .de, text: "i ku", origin: .derived), SpokenForm(language: .en, text: "ai kju", origin: .derived)], join: .concatenated) // ASSUMPTION: memberwise inits as in LEXIKON-KONZEPT 1.1
    }

    static func lexicon(_ entries: [CanonEntry]) -> LexiconSnapshot {
        LexiconSnapshot(entries: entries, families: [iqFamily]) // ASSUMPTION: LexiconSnapshot(entries:families:), keeps only confirmed entries and active variants
    }

    static var iqEntries: [CanonEntry] {
        ["NapIQ", "VierbIQ", "LaborIQ", "FlowIQ"].map { entry($0, family: "iq") }
    }
    static var fullLexicon: LexiconSnapshot { lexicon(iqEntries + [entry("Kelrana"), entry("Brimvolt")]) }
    static var emptyLexicon: LexiconSnapshot { lexicon([]) }

    // MARK: running the stage

    static func stage(_ lexicon: LexiconSnapshot = fullLexicon, protection: FrozenWordSet = frozen) -> TextStage {
        TextStage(lexicon: lexicon, protection: protection, config: TextStageConfig(spokenForm: true)) // ASSUMPTION: TextStageConfig() default init carries the preliminary thresholds; R3 sits behind the switch spokenForm (default off, A.7 and appendix K 3), the tests check it switched on
    }

    static func recognition(_ text: String) -> Recognition {
        Recognition(text: text) // ASSUMPTION: Recognition(text:) is enough, tokens and alternatives default to empty
    }

    static func answers(_ stage: TextStage, _ input: Recognition) -> OracleAnswers {
        var map: [OracleQuery: Bool] = [:]
        for q in stage.oracleQueries(for: input) { map[q] = systemWords.contains(q.form) } // ASSUMPTION: OracleQuery is Hashable and has `form: String`
        return OracleAnswers(known: map) // ASSUMPTION: OracleAnswers(known:) maps a query to "known to the system dictionary"
    }

    static func run(_ text: String, _ stage: TextStage) -> TextStageResult {
        let input = recognition(text)
        return stage.process(input, answers: answers(stage, input))
    }

    static func run(_ text: String, lexicon: LexiconSnapshot = fullLexicon) -> TextStageResult {
        run(text, stage(lexicon))
    }

    static func out(_ text: String, lexicon: LexiconSnapshot = fullLexicon) -> String {
        run(text, lexicon: lexicon).text
    }

    /// Wraps a phrase in neutral known words so that the share of R3 tokens stays far below 15 percent.
    static func padded(_ phrase: String) -> String { leadSentence + " " + phrase + " " + tailSentence }

    static func json<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? String(data: e.encode(v), encoding: .utf8)) ?? "" // ASSUMPTION: Intervention, NearMiss are Encodable (TextStageResult is Codable)
    }

    // MARK: journal and probation

    static func journal(day: Int, text: String, protectedForms: Set<String> = [], rejectedInterventions: Int = 0, interventions: Int = 0) -> JournalView {
        JournalView(day: day, recognizerText: text, protectedForms: protectedForms, rejectedInterventions: rejectedInterventions, interventionCount: interventions) // ASSUMPTION: JournalView carries day, recognizer text, the protected forms known at the time, and the feedback counts
    }

    static func verdict(_ v: HearingVariant, _ history: [JournalView]) -> String {
        let d = String(describing: Probation.evaluate(v, over: history))
        return String(d.prefix { $0 != "(" })
    }
    static let promote = "promote" // ASSUMPTION: ProbationVerdict case name
    static let keepProbation = "keepProbation" // ASSUMPTION: ProbationVerdict case name
    static let reject = "reject" // ASSUMPTION: ProbationVerdict case name
    static let retire = "retire" // ASSUMPTION: ProbationVerdict case name (first undo, single intervention)
    static let suspend = "suspend" // ASSUMPTION: ProbationVerdict case name (undo with several interventions)

    // MARK: generated input

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let chunks: [String] = [
        "wir haben heute", "das Projekt", "besprochen", "und die Zahlen", "sind gut,", "aber morgen",
        "ich habe", "du musst kommen", "meine Sachen", "ich möchte gern", "nein nein", "die die Katze",
        "das das ist gut", "dass es funktioniert.", "Nab IQ", "Nap I Q", "Labor I Q", "vierb iq", "Flow-IQ",
        "NapiQ", "napiq", "Nacht IQ", "IQ IQ", "Nab Nab IQ", "NapIQ,", "vier be ku", "4BQ", "4B Q", "vier BQ",
        "BQ", "NAQ", "KLV", "XQZT", "developen", "gedeployt", "committen", "connecten", "refunden", "deployen",
        "Kelrana", "Kelrane", "Brimvolt", "zumpf", "blorken", "Zumpf.", "vier Zumpf", "Nab IQ-Design",
        "Äpfel und Öl", "wenn wir da sind", "mit dem Geld verdienen",
    ]

    static func dictations(count: Int, chunksPerDictation: ClosedRange<Int>, seed: UInt64) -> [String] {
        var rng = SplitMix64(state: seed)
        return (0..<count).map { _ in
            let n = Int.random(in: chunksPerDictation, using: &rng)
            return (0..<n).map { _ in chunks[Int.random(in: 0..<chunks.count, using: &rng)] }.joined(separator: " ")
        }
    }
}
