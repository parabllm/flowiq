// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Familie IQ (R2), Formvariante (R1), Zusammensetzung (Z1). (R-029, R-011)
import Testing
@testable import FlowIQText

@Suite("P2 family IQ")
struct P2FamilyTests {
    static let cases: [(String, String)] = [
        ("Nab IQ", "NapIQ"), ("Nap I Q", "NapIQ"), ("Labor I Q", "LaborIQ"), ("vierb iq", "VierbIQ"),
        ("Nap IQ", "NapIQ"), ("Flow IQ", "FlowIQ"), ("Nab I Q", "NapIQ"),
    ]

    @Test("spoken or split family forms become the confirmed spelling", arguments: cases)
    func familyBecomesCanonical(source: String, target: String) {
        #expect(Fx.out(Fx.padded("wir testen " + source + " morgen")) == Fx.padded("wir testen " + target + " morgen"))
    }

    @Test("punctuation next to the name is kept", arguments: [("Nab IQ.", "NapIQ."), ("Nab IQ,", "NapIQ,"), ("(Nab IQ)", "(NapIQ)")])
    func punctuationKept(source: String, target: String) {
        #expect(Fx.out(Fx.padded(source)) == Fx.padded(target))
    }

    @Test("form variants of a confirmed entry (R1)", arguments: ["Nap-IQ", "NapiQ", "napiq", "Nap IQ"])
    func formVariants(source: String) {
        #expect(Fx.out(Fx.padded("wir nutzen " + source + " heute")) == Fx.padded("wir nutzen NapIQ heute"))
    }

    @Test("an unconfirmed entry never changes the text, the confirmed one does")
    func unconfirmedStaysConfirmedChanges() {
        let text = Fx.padded("wir testen Zorbel IQ morgen")
        let proposed = Fx.lexicon(Fx.iqEntries + [Fx.entry("ZorbelIQ", family: "iq", status: .proposed)])
        let confirmed = Fx.lexicon(Fx.iqEntries + [Fx.entry("ZorbelIQ", family: "iq", status: .confirmed)])
        #expect(Fx.out(text, lexicon: proposed) == text)
        #expect(Fx.out(text, lexicon: confirmed) == Fx.padded("wir testen ZorbelIQ morgen"))
    }

    @Test("an unknown stem with the IQ anchor stays unchanged", arguments: ["Nacht IQ", "Zumpf IQ", "Kelrana IQ"])
    func unknownStemStays(phrase: String) {
        let text = Fx.padded("wir testen " + phrase + " morgen")
        #expect(Fx.out(text) == text)
    }

    @Test("a family without any confirmed member changes nothing")
    func noMembersNoChange() {
        let text = Fx.padded("Nab IQ und vierb iq und Labor I Q")
        #expect(Fx.out(text, lexicon: Fx.emptyLexicon) == text)
    }

    @Test("Z1: a recognizer-bound compound keeps its tail and gets the canonical name part", arguments: [("Nab IQ-Design", "NapIQ-Design"), ("Nap-IQ-Design", "NapIQ-Design")])
    func compoundZ1(source: String, target: String) {
        #expect(Fx.out(Fx.padded("das " + source + " ist neu")) == Fx.padded("das " + target + " ist neu"))
    }

    @Test("Z2 is off: a separately written noun after a name gets no hyphen")
    func compoundZ2Off() {
        let text = Fx.padded("wir wollen mit NapIQ Geld verdienen")
        #expect(Fx.out(text) == text)
    }

    @Test("the family anchor alone never produces an intervention")
    func anchorAloneStays() {
        let text = Fx.padded("der IQ ist wichtig und IQ IQ")
        #expect(Fx.out(text) == text)
    }
}
