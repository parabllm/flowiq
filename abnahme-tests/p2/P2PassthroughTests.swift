// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Durchreichen. Text without unknown words stays byte for byte identical. (R-028, R-011)
import Testing
@testable import FlowIQText

@Suite("P2 passthrough")
struct P2PassthroughTests {
    static let plainTexts: [String] = [
        "",
        "Wir haben heute das Projekt besprochen und die Zahlen sind gut.",
        "Ich habe meine Sachen mitgebracht, aber du musst kommen!",
        "Zwei  Leerzeichen,\tein Tab\nund ein Zeilenumbruch.\n\nNoch ein Absatz. ",
        "Äpfel, Öl und Übung: größer, schöner, weiß.",
        "  führende und folgende Leerzeichen  ",
    ]

    @Test("text with only known words is returned byte for byte", arguments: plainTexts)
    func knownWordsUnchanged(text: String) {
        #expect(Fx.out(text).utf8.elementsEqual(text.utf8))
        #expect(Fx.run(text).interventions.isEmpty)
    }

    @Test("an empty lexicon changes nothing, whatever the text")
    func emptyLexiconChangesNothing() {
        for text in ["Nab IQ und vierb iq", "vier be ku", "4BQ", "developen wir das", "Kelrana und Brimvolt", "Nap I Q"] {
            #expect(Fx.out(text, lexicon: Fx.emptyLexicon).utf8.elementsEqual(text.utf8))
        }
    }

    @Test("unknown words without a matching entry stay untouched")
    func unknownWithoutMatchUnchanged() {
        let text = Fx.padded("das zumpf und blorken sind seltsam")
        #expect(Fx.out(text) == text)
    }

    @Test("a confirmed name written correctly is not touched")
    func correctNameUnchanged() {
        let text = Fx.padded("NapIQ und VierbIQ und LaborIQ und FlowIQ und Kelrana und Brimvolt")
        #expect(Fx.out(text) == text)
    }

    @Test("passthrough also holds for the full generated pool without any marked phrase")
    func plainGeneratedPassthrough() {
        let plainChunks = ["wir haben heute", "das Projekt", "besprochen", "und die Zahlen", "sind gut,", "aber morgen", "ich habe", "du musst kommen", "meine Sachen", "dass es funktioniert."]
        var rng = Fx.SplitMix64(state: 7)
        for _ in 0..<100 {
            let n = Int.random(in: 3...12, using: &rng)
            let text = (0..<n).map { _ in plainChunks[Int.random(in: 0..<plainChunks.count, using: &rng)] }.joined(separator: " ")
            #expect(Fx.out(text) == text)
        }
    }
}
