// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Idempotenz (property) and Determinismus. (R-028, R-035)
import Testing
import Foundation
@testable import FlowIQText

@Suite("P2 properties")
struct P2PropertyTests {
    static let inputs = Fx.dictations(count: 600, chunksPerDictation: 1...40, seed: 20261113)

    @Test("process(process(x)) == process(x) over 600 generated dictations")
    func idempotent() {
        let stage = Fx.stage()
        var failures: [String] = []
        for x in Self.inputs {
            let once = Fx.run(x, stage).text
            let twice = Fx.run(once, stage).text
            if once != twice { failures.append(x) }
        }
        #expect(failures.isEmpty, "not idempotent for: \(failures.prefix(3))")
    }

    @Test("idempotence also holds with an empty lexicon and with a lexicon of only proposed entries")
    func idempotentOtherLexicons() {
        let proposedOnly = Fx.lexicon([Fx.entry("NapIQ", family: "iq", status: .proposed)])
        for lexicon in [Fx.emptyLexicon, proposedOnly] {
            let stage = Fx.stage(lexicon)
            for x in Self.inputs.prefix(100) {
                let once = Fx.run(x, stage).text
                #expect(Fx.run(once, stage).text == once)
                #expect(once == x)
            }
        }
    }

    @Test("same input, same answers, same text, trace and queries, also from a fresh stage")
    func deterministic() {
        let a = Fx.stage()
        let b = Fx.stage()
        for x in Self.inputs.prefix(200) {
            let input = Fx.recognition(x)
            #expect(a.oracleQueries(for: input) == b.oracleQueries(for: input))
            let answers = Fx.answers(a, input)
            let r1 = a.process(input, answers: answers)
            let r2 = a.process(input, answers: answers)
            let r3 = b.process(input, answers: answers)
            #expect(r1.text == r2.text)
            #expect(r1.text == r3.text)
            #expect(Fx.json(r1.interventions) == Fx.json(r2.interventions))
            #expect(Fx.json(r1.interventions) == Fx.json(r3.interventions))
            #expect(Fx.json(r1.nearMisses) == Fx.json(r3.nearMisses))
            #expect(r1.stageTexts == r3.stageTexts)
        }
    }

    @Test("the result does not depend on the order of the lexicon entries")
    func entryOrderIrrelevant() {
        let forward = Fx.stage(Fx.lexicon(Fx.iqEntries + [Fx.entry("Kelrana"), Fx.entry("Brimvolt")]))
        let backward = Fx.stage(Fx.lexicon((Fx.iqEntries + [Fx.entry("Kelrana"), Fx.entry("Brimvolt")]).reversed()))
        for x in Self.inputs.prefix(150) {
            #expect(Fx.run(x, forward).text == Fx.run(x, backward).text)
        }
    }
}
