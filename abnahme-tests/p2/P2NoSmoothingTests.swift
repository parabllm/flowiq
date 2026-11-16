// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: keine Grammatik-Glättung, keine Stotter-Entfernung. (R-028)
import Testing
@testable import FlowIQText

@Suite("P2 no smoothing")
struct P2NoSmoothingTests {
    static let sentences = [
        "ich habe das gemacht", "du musst kommen", "meine Sachen sind da", "ich möchte gern", "dass es funktioniert",
        "das ist gut", "habe", "musst", "meine", "möchte",
    ]

    @Test("grammar and colloquial forms are kept, lexicon full", arguments: sentences)
    func grammarKept(sentence: String) {
        let text = Fx.padded(sentence)
        #expect(Fx.out(text) == text)
    }

    @Test("grammar and colloquial forms are kept, lexicon empty", arguments: sentences)
    func grammarKeptEmptyLexicon(sentence: String) {
        let text = Fx.padded(sentence)
        #expect(Fx.out(text, lexicon: Fx.emptyLexicon) == text)
    }

    @Test("word repetitions are kept", arguments: ["nein nein nein", "die die Katze", "das das ist gut", "ja ja", "wir wir haben"])
    func repetitionsKept(phrase: String) {
        let text = Fx.padded(phrase)
        #expect(Fx.out(text) == text)
    }

    @Test("repetitions of a name are kept as said, only the name part is normalized")
    func nameRepetitionKept() {
        #expect(Fx.out(Fx.padded("Nab IQ Nab IQ")) == Fx.padded("NapIQ NapIQ"))
    }

    @Test("punctuation and filler words are not touched")
    func punctuationKept() {
        let text = Fx.padded("also... ja, nein; na gut - oder?")
        #expect(Fx.out(text).utf8.elementsEqual(text.utf8))
    }
}
