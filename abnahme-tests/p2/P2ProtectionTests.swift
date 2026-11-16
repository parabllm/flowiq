// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Schutz. Protected words and English stem plus German ending are never replaced. (R-026, R-028)
import Testing
@testable import FlowIQText

@Suite("P2 protection")
struct P2ProtectionTests {
    static let germanizedVerbs = ["developen", "committen", "connecten", "refunden", "deployen", "deployt", "gedeployt", "committet", "refundest", "connectest"]

    @Test("English stem plus German ending stays, with an empty lexicon", arguments: germanizedVerbs)
    func germanizedVerbStaysEmptyLexicon(word: String) {
        let text = Fx.padded("wir müssen das " + word + " und dann weiter")
        #expect(Fx.out(text, lexicon: Fx.emptyLexicon) == text)
    }

    @Test("English stem plus German ending stays, even with a confirmed look-alike entry", arguments: germanizedVerbs)
    func germanizedVerbStaysWithEntry(word: String) {
        let lexicon = Fx.lexicon(Fx.iqEntries + [Fx.entry("Deployr", kind: .term), Fx.entry("Kommitt", kind: .term), Fx.entry("Kelrana")])
        let text = Fx.padded("wir " + word + " das heute")
        #expect(Fx.out(text, lexicon: lexicon) == text)
    }

    @Test("the verb 'developen' stays although its stem is known only to the oracle")
    func developenViaOracleStem() {
        let text = Fx.padded("wir developen das Projekt")
        let result = Fx.run(text)
        #expect(result.text == text)
        #expect(result.interventions.isEmpty)
    }

    @Test("when the oracle cannot answer, the form counts as protected")
    func noAnswerMeansProtected() {
        let stage = Fx.stage()
        let text = Fx.padded("vier be ku und zumpf")
        let input = Fx.recognition(text)
        let result = stage.process(input, answers: OracleAnswers(known: [:])) // ASSUMPTION: an empty OracleAnswers means "no answer received"
        #expect(result.text == text)
    }

    @Test("a word known to the system dictionary is never a fuzzy source", arguments: ["vier Bahnen", "vier bar", "nab labor"])
    func knownWordsNeverFuzzySource(phrase: String) {
        let text = Fx.padded(phrase)
        #expect(Fx.out(text) == text)
    }

    @Test("protected single words stay when they equal an entry only by case")
    func protectedWordCaseOnly() {
        let lexicon = Fx.lexicon([Fx.entry("Labor", kind: .term), Fx.entry("Flow", kind: .term)] + Fx.iqEntries)
        let text = Fx.padded("im labor läuft der flow")
        #expect(Fx.out(text, lexicon: lexicon) == text)
    }

    @Test("a hearing variant with replacesProtectedWord is the only way to touch a protected word, and only when active")
    func protectedWordOnlyViaActiveClickedVariant() {
        let probation = Fx.variant(heard: ["kalter"], status: .probation, origin: .userClick, replacesProtectedWord: true)
        let active = Fx.variant(heard: ["kalter"], status: .active, origin: .userClick, replacesProtectedWord: true)
        let text = Fx.padded("der kalter kommt morgen")
        let withProbation = Fx.lexicon(Fx.iqEntries + [Fx.entry("Kalder", variants: [probation])])
        let withActive = Fx.lexicon(Fx.iqEntries + [Fx.entry("Kalder", variants: [active])])
        #expect(Fx.out(text, lexicon: withProbation) == text)
        #expect(Fx.out(Fx.padded("der Kalter kommt morgen"), lexicon: withProbation) == Fx.padded("der Kalter kommt morgen"))
        #expect(Fx.out(text, lexicon: withActive).contains("Kalder"))
    }
}
