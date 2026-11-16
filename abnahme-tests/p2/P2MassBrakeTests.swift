// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Mengenbremse. Counts only R3 candidates: more than 6, or R3 spans above 15 percent of the tokens,
// then ALL R3 of that dictation are dropped. R1 and R2 stay. (R-028, L-6)
import Testing
@testable import FlowIQText

@Suite("P2 mass brake")
struct P2MassBrakeTests {
    static func repeated(_ phrase: String, times n: Int) -> String {
        (0..<n).map { _ in Fx.padded(phrase) }.joined(separator: " ")
    }

    @Test("up to 6 R3 candidates in a long dictation are all applied")
    func sixAreApplied() {
        let text = Self.repeated("4BQ", times: 6)
        #expect(Fx.out(text) == Self.repeated("VierbIQ", times: 6))
    }

    @Test("7 R3 candidates: every R3 of the dictation is dropped")
    func sevenAreDropped() {
        let text = Self.repeated("4BQ", times: 7)
        #expect(Fx.out(text) == text)
        #expect(Fx.run(text).interventions.isEmpty)
    }

    @Test("R3 spans above 15 percent of the tokens: all R3 dropped")
    func shareAbove15Percent() {
        let text = "4BQ und vier be ku und 4B Q heute"
        #expect(Fx.out(text) == text)
    }

    @Test("the brake drops only R3, R1 and R2 stay in the same dictation")
    func brakeKeepsR1R2() {
        let text = Self.repeated("4BQ", times: 7) + " " + Fx.padded("Nab IQ und napiq")
        let expected = Self.repeated("4BQ", times: 7) + " " + Fx.padded("NapIQ und NapIQ")
        #expect(Fx.out(text) == expected)
    }

    @Test("idempotence with the brake: many R1 plus many R3")
    func idempotentWithBrake() {
        let text = Self.repeated("4BQ", times: 8) + " " + Self.repeated("Nab IQ", times: 5)
        let stage = Fx.stage()
        let once = Fx.run(text, stage).text
        let twice = Fx.run(once, stage).text
        #expect(once == twice)
        #expect(once.contains("4BQ"))
        #expect(!once.contains("Nab IQ"))
    }

    @Test("idempotence at the boundary: exactly 6 and exactly 7 candidates")
    func idempotentAtBoundary() {
        let stage = Fx.stage()
        for n in [6, 7] {
            let text = Self.repeated("4BQ", times: n)
            let once = Fx.run(text, stage).text
            #expect(Fx.run(once, stage).text == once)
        }
    }
}
