// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Abkürzungen. Pure uppercase runs up to 5 characters without a digit are never an R3 source. (R-028)
import Testing
@testable import FlowIQText

@Suite("P2 abbreviation guard")
struct P2AbbreviationTests {
    @Test("uppercase runs up to 5 characters stay", arguments: ["BQ", "NAQ", "TQ", "XQZT", "KLV", "ABCDE", "BKU"])
    func uppercaseRunsStay(abbr: String) {
        let text = Fx.padded("die " + abbr + " ist wichtig")
        let result = Fx.run(text)
        #expect(result.text == text)
        #expect(result.interventions.isEmpty)
    }

    @Test("an abbreviation next to a number word is not turned into a name by the abbreviation guard alone", arguments: ["BQ", "NAQ"])
    func lowercaseContextWithoutNumber(abbr: String) {
        let text = Fx.padded("wir sehen die " + abbr + " und die " + abbr + " noch einmal")
        #expect(Fx.out(text) == text)
    }

    @Test("the abbreviation guard also holds when the lexicon has only the matching entry")
    func guardWithMinimalLexicon() {
        let lexicon = Fx.lexicon([Fx.entry("VierbIQ", family: "iq")])
        let text = Fx.padded("das BQ und das NAQ")
        #expect(Fx.out(text, lexicon: lexicon) == text)
    }

    @Test("an acronym entry is reachable only through its spelled-out reading")
    func acronymEntryOnlyViaSpelling() {
        let lexicon = Fx.lexicon([Fx.entry("KLV", kind: .acronym)])
        let text = Fx.padded("das Kalv und das Klaff")
        #expect(Fx.out(text, lexicon: lexicon) == text)
    }
}
