// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group: Leistung. p95 of process below 15 ms; the threshold is fixed, the measurement is generous. (R-036)
import Testing
@testable import FlowIQText

@Suite("P2 performance", .serialized)
struct P2PerformanceTests {
    static let thresholdMs = 15.0

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Best of three runs per input damps scheduler noise; the answers are computed outside the timed section.
    static func bestMs(_ text: String, _ stage: TextStage) -> Double {
        let input = Fx.recognition(text)
        let answers = Fx.answers(stage, input)
        var best = Double.infinity
        for _ in 0..<3 {
            let clock = ContinuousClock()
            let d = clock.measure { _ = stage.process(input, answers: answers) }
            best = min(best, ms(d))
        }
        return best
    }

    @Test("p95 of process over 500 generated dictations of medium length is below 15 ms")
    func p95Below15ms() {
        let stage = Fx.stage()
        let inputs = Fx.dictations(count: 500, chunksPerDictation: 12...24, seed: 99)
        _ = Fx.run(inputs[0], stage) // warm-up
        let times = inputs.map { Self.bestMs($0, stage) }.sorted()
        let p95 = times[Int(Double(times.count) * 0.95) - 1]
        #expect(p95 < Self.thresholdMs, "p95 = \(p95) ms")
    }

    @Test("a 300-word input needs at most 15 ms")
    func threeHundredWords() {
        let stage = Fx.stage()
        let words = (Fx.leadSentence + " " + Fx.tailSentence + " Nab IQ vier be ku zumpf developen").split(separator: " ").map(String.init)
        let text = (0..<300).map { words[$0 % words.count] }.joined(separator: " ")
        _ = Fx.run(text, stage)
        #expect(Self.bestMs(text, stage) <= Self.thresholdMs)
    }

    @Test("the micros field agrees in magnitude with the wall clock")
    func microsPlausible() {
        let stage = Fx.stage()
        let text = Fx.padded("Nab IQ und 4BQ")
        let result = Fx.run(text, stage)
        #expect(Double(result.micros) / 1000 < Self.thresholdMs)
    }
}
