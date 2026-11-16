// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Sprechform (R3). Only on strong match, only to a confirmed entry. (R-011, R-028, R-029)
import Testing
@testable import FlowIQText

@Suite("P2 spoken form")
struct P2SpokenFormTests {
    @Test("strong spoken-form matches become the confirmed entry", arguments: ["vier be ku", "4BQ", "4B Q"])
    func strongMatch(source: String) {
        #expect(Fx.out(Fx.padded("wir testen " + source + " morgen")) == Fx.padded("wir testen VierbIQ morgen"))
    }

    @Test("weak matches stay", arguments: ["vier Zumpf", "vier blorken", "4Z", "vier"])
    func weakMatchStays(source: String) {
        let text = Fx.padded("wir testen " + source + " morgen")
        #expect(Fx.out(text) == text)
    }

    @Test("without a confirmed target the spoken form stays", arguments: ["vier be ku", "4BQ"])
    func noConfirmedTarget(source: String) {
        let lexicon = Fx.lexicon([Fx.entry("NapIQ", family: "iq"), Fx.entry("VierbIQ", family: "iq", status: .proposed)])
        let text = Fx.padded("wir testen " + source + " morgen")
        #expect(Fx.out(text, lexicon: lexicon) == text)
    }

    @Test("a spoken form never replaces a span whose every token is protected")
    func protectedSpanStays() {
        let text = Fx.padded("wir sehen vier bar oder vier bahnen")
        #expect(Fx.out(text) == text)
    }

    @Test("R3 interventions record their rule and the confirmed target")
    func spokenInterventionRecorded() {
        let result = Fx.run(Fx.padded("wir testen 4BQ morgen"))
        #expect(result.interventions.count == 1)
        #expect(result.interventions.first?.tAfter == "VierbIQ")
        #expect(result.interventions.first?.tBefore == "4BQ")
    }
}
