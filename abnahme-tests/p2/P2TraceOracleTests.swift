// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Spur and Orakel. (R-028, L-1; LEXIKON-KONZEPT section 5 and A.7)
import Testing
@testable import FlowIQText

@Suite("P2 trace")
struct P2TraceTests {
    @Test("every intervention carries rule, source, target and reason")
    func interventionComplete() {
        let text = Fx.padded("Nab IQ und vierb iq und napiq und 4BQ")
        let result = Fx.run(text)
        #expect(result.interventions.count == 4)
        for i in result.interventions {
            #expect(!i.tRule.isEmpty)
            #expect(!i.tBefore.isEmpty)
            #expect(!i.tAfter.isEmpty)
            #expect(!i.tReason.isEmpty)
            #expect(i.tBefore != i.tAfter)
        }
    }

    @Test("source and target match the text change")
    func sourceTargetMatch() {
        let result = Fx.run(Fx.padded("wir testen Nab IQ morgen"))
        #expect(result.interventions.count == 1)
        #expect(result.interventions.first?.tBefore == "Nab IQ")
        #expect(result.interventions.first?.tAfter == "NapIQ")
    }

    @Test("different rule kinds carry different rule names")
    func ruleKindsDiffer() {
        let r2 = Fx.run(Fx.padded("Nab IQ")).interventions.first?.tRule
        let r1 = Fx.run(Fx.padded("napiq")).interventions.first?.tRule
        let r3 = Fx.run(Fx.padded("4BQ")).interventions.first?.tRule
        #expect(r1 != nil && r2 != nil && r3 != nil)
        #expect(Set([r1, r2, r3].compactMap { $0 }).count == 3)
    }

    @Test("stageTexts contains the unchanged recognizer text, with and without interventions", arguments: ["Nab IQ ist da", "nur bekannte Wörter hier", ""])
    func stageTextsKeepRecognizerText(text: String) {
        let input = Fx.padded(text)
        #expect(Fx.run(input).stageTexts.contains(input))
    }

    @Test("no intervention means no trace entries")
    func noInterventionNoTrace() {
        let result = Fx.run(Fx.padded("alles bekannt und gut"))
        #expect(result.interventions.isEmpty)
    }

    @Test("a guard-stopped near hit produces no intervention")
    func abbreviationGuardNoIntervention() {
        let text = Fx.padded("das BQ ist da und das NAQ auch")
        let result = Fx.run(text)
        #expect(result.interventions.isEmpty)
        #expect(result.text == text)
    }

    @Test("the micros field is filled and not negative")
    func microsFilled() {
        #expect(Fx.run(Fx.padded("Nab IQ")).micros >= 0)
    }
}

@Suite("P2 oracle")
struct P2OracleTests {
    @Test("oracleQueries never names an uppercase form")
    func neverUppercase() {
        let texts = ["Labor I Q und Nap I Q", "das BQ und NAQ und XQZT und KLV", "4BQ und vier BQ", "Ich GmbH NASA", Fx.padded("Nab IQ Kelrane Zumpf BLORKEN")]
        let stage = Fx.stage()
        for t in texts {
            for q in stage.oracleQueries(for: Fx.recognition(t)) {
                let isUpper = q.form == q.form.uppercased() && q.form != q.form.lowercased()
                #expect(!isUpper, "uppercase query: \(q.form)")
            }
        }
    }

    @Test("frozen word forms are never asked again")
    func frozenNotAsked() {
        let queries = Fx.stage().oracleQueries(for: Fx.recognition(Fx.padded("wir haben das Projekt besprochen")))
        #expect(queries.isEmpty)
    }

    @Test("an unseen word form is asked in lowercase or capitalized form")
    func unseenAsked() {
        let queries = Fx.stage().oracleQueries(for: Fx.recognition("wir sehen das Zumpf"))
        let forms = Set(queries.map(\.form))
        #expect(forms.contains("zumpf") || forms.contains("Zumpf"))
    }

    @Test("the English stem of an unseen German-ending form is asked too")
    func stemAsked() {
        let queries = Fx.stage().oracleQueries(for: Fx.recognition("wir developen das"))
        #expect(queries.contains { $0.form.lowercased() == "develop" })
    }

    @Test("asking is stable: the same input gives the same set")
    func queriesStable() {
        let stage = Fx.stage()
        let input = Fx.recognition("wir developen Zumpf und Kelrane")
        #expect(stage.oracleQueries(for: input) == stage.oracleQueries(for: input))
    }
}
