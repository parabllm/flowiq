import Foundation
import Testing
@testable import FlowIQText

/// The P2 acceptance tests run with R3 on. These repeat their core claims with the default config (R3 off, as
/// the app runs today), plus the rules from the P2a review: no abbreviation inside an R3 source, capitals of a
/// known word stay protected, several protected words change only through a clicked variant, word for word only
/// with a click. Artificial words only.
struct DefaultConfigTests {
    static let words = ["wir", "haben", "heute", "das", "projekt", "und", "die", "zahlen", "sind", "gut", "ich",
                        "habe", "du", "musst", "kommen", "meine", "sachen", "möchte", "gern", "nein", "kalter", "der",
                        "dass", "es", "funktioniert", "aber", "vier", "nab", "labor", "flow", "haus", "tisch", "ist",
                        "da", "morgen", "testen", "dann", "weiter", "katze"]
    static let english = ["commit", "connect", "refund", "deploy", "develop"]

    static func forms(_ list: [String]) -> Set<String> {
        Set(list.flatMap { [$0, $0.prefix(1).uppercased() + $0.dropFirst()] })
    }

    static func entry(_ canonical: String, family: String? = nil, variants: [HearingVariant] = []) -> CanonEntry {
        CanonEntry(id: "e-" + canonical, canonical: canonical, kind: .name, family: family, spokenForms: [],
                   hearingVariants: variants, status: .confirmed, origin: .seed, compound: .hyphen,
                   counters: Counters(), createdAt: Date(timeIntervalSince1970: 0), confirmedAt: nil)
    }

    static func variant(_ heard: [String], origin: VariantOrigin, protected: Bool) -> HearingVariant {
        HearingVariant(id: "v", heard: heard, context: [], status: .active, origin: origin,
                       replacesProtectedWord: protected, counters: Counters())
    }

    static let iq = FamilyRule(id: "iq", anchorWritten: "IQ", anchorSpoken: [], join: .concatenated)
    static let names = [entry("NapIQ", family: "iq"), entry("VierbIQ", family: "iq"), entry("Kelrana")]

    static func stage(_ entries: [CanonEntry] = names, spoken: Bool = false) -> TextStage {
        TextStage(lexicon: LexiconSnapshot(entries: entries, families: [iq]),
                  protection: FrozenWordSet(german: forms(words), english: forms(english)),
                  config: TextStageConfig(spokenForm: spoken))
    }

    /// The fake dictionary knows exactly the word list; every other form is unknown.
    static func run(_ text: String, _ stage: TextStage = stage()) -> TextStageResult {
        let input = Recognition(text: text)
        var known: [OracleQuery: Bool] = [:]
        for q in stage.oracleQueries(for: input) { known[q] = forms(words + english).contains(q.form) }
        return stage.process(input, answers: OracleAnswers(known: known))
    }

    static func padded(_ s: String) -> String { "wir haben heute das projekt und " + s + " und dann weiter morgen" }

    @Test(arguments: ["", "Ich habe meine Sachen, aber du musst kommen!", "  zwei  Leerzeichen,\tTab\nUmbruch. ",
                      "Äpfel, Öl und Übung: größer.", "das zumpf und blorken sind seltsam", "also... ja, nein; na gut"])
    func passthroughByteForByte(text: String) {
        #expect(Self.run(text).text.utf8.elementsEqual(text.utf8))
        #expect(Self.run(text, Self.stage([])).text.utf8.elementsEqual(text.utf8))
    }

    @Test(arguments: ["developen", "committen", "connecten", "refunden", "deployt", "gedeployt", "committet",
                      "refundest"])
    func germanizedVerbsStay(word: String) {
        let text = Self.padded("wir " + word + " das")
        #expect(Self.run(text).text == text)
    }

    @Test(arguments: ["ich habe das", "du musst kommen", "meine Sachen", "ich möchte gern", "nein nein nein",
                      "die die Katze", "das das ist gut"])
    func noSmoothingNoStutterRemoval(phrase: String) {
        let text = Self.padded(phrase)
        #expect(Self.run(text).text == text)
    }

    @Test func namesStillWorkWithoutR3() {
        #expect(Self.run(Self.padded("Nab IQ und napiq")).text == Self.padded("NapIQ und NapIQ"))
        #expect(Self.run(Self.padded("4BQ")).text == Self.padded("4BQ"))
    }

    @Test func idempotentWithDefaultConfig() {
        let chunks = ["wir haben", "Nab IQ", "Nap I Q", "vierb iq", "napiq", "4BQ", "vier be ku", "Kelrane", "zumpf",
                      "developen", "nein nein", "IQ IQ", "Nab Nab IQ", "das Projekt,", "KLV", "vier BQ"]
        var state: UInt64 = 20_261_113
        for _ in 0..<300 {
            var parts: [String] = []
            for _ in 0..<12 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                parts.append(chunks[Int(state >> 33) % chunks.count])
            }
            let x = parts.joined(separator: " ")
            let once = Self.run(x).text
            #expect(Self.run(once).text == once)
        }
    }

    @Test func familyRuleIsGeneralNotIQ() {
        let hub = FamilyRule(id: "hub", anchorWritten: "Hub", anchorSpoken: [], join: .concatenated)
        let entries = [Self.entry("KelraHub", family: "hub"), Self.entry("ZorbHub", family: "hub")]
        let frozen = FrozenWordSet(german: Self.forms(Self.words), english: Self.forms(Self.english))
        let stage = TextStage(lexicon: LexiconSnapshot(entries: entries, families: [hub]), protection: frozen,
                              config: TextStageConfig())
        #expect(Self.run(Self.padded("Kelra Hub und Zorp hub und Kelra-Hub-Liste"), stage).text
            == Self.padded("KelraHub und ZorbHub und KelraHub-Liste"))
        #expect(Self.run(Self.padded("Blorp Hub und Nab IQ"), stage).text == Self.padded("Blorp Hub und Nab IQ"))
    }

    // MARK: review P2a (T1, T2, T3, T5)

    @Test func abbreviationNeverInsideAnR3SourceEvenMixed() {
        let text = Self.padded("wir testen vier BQ heute")
        let result = Self.run(text, Self.stage(spoken: true))
        #expect(result.text == text)
        #expect(result.nearMisses.contains { $0.reason == "abbreviation" && $0.before == "vier BQ" })
    }

    @Test func capitalsOfAKnownWordStayProtected() {
        let stage = Self.stage()
        let nein = Pieces.split("NEIN")[0]
        let known = OracleAnswers(known: [OracleQuery(form: "nein", kind: .word): true])
        #expect(stage.shield.classify(nein, known) == .system)
        let zq = Pieces.split("ZQX")[0]
        #expect(stage.shield.classify(zq, OracleAnswers(known: [OracleQuery(form: "zqx", kind: .word): false,
                                                                 OracleQuery(form: "Zqx", kind: .word): false]))
            == .abbreviation)
    }

    @Test func severalProtectedWordsOnlyThroughAClickedVariant() {
        let text = Self.padded("das haus tisch ist da")
        let plain = Self.run(text, Self.stage([Self.entry("HausTisch")]))
        #expect(plain.text == text)
        #expect(plain.nearMisses.contains { $0.rule == "R1" && $0.reason == "protected" })
        let corpus = Self.stage([Self.entry("HausTisch", variants: [Self.variant(["haus", "tisch"], origin: .corpus,
                                                                                 protected: true)])])
        #expect(Self.run(text, corpus).text == text)
        let click = Self.variant(["haus", "tisch"], origin: .userClick, protected: true)
        let clicked = Self.stage([Self.entry("HausTisch", variants: [click])])
        #expect(Self.run(text, clicked).text == Self.padded("das HausTisch ist da"))
    }

    @Test func wordForWordOnlyWithAClick() {
        let text = Self.padded("der kalter kommt")
        let corpus = Self.stage([Self.entry("Kalder", variants: [Self.variant(["kalter"], origin: .corpus,
                                                                             protected: true)])])
        #expect(Self.run(text, corpus).text == text)
        let clicked = Self.stage([Self.entry("Kalder", variants: [Self.variant(["kalter"], origin: .userClick,
                                                                              protected: true)])])
        #expect(Self.run(text, clicked).text == Self.padded("der Kalder kommt"))
    }
}
