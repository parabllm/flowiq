import FlowIQCore
import Foundation
import Synchronization
import Testing
@testable import FlowIQSpeech

/// Review 15.11. (e): Apple and ElevenLabs stamp the same words a little apart. A switch either way at the mark B
/// must neither drop nor double a word while the offset stays under half a word (here up to 150 ms on 400 ms words).
struct RouterJitterTests {
    final class Sink: RouterSink {
        let words = Mutex<[String]>([])
        func accepted(_ segment: LiveSegment, from engine: LiveEngine) async {
            words.withLock { $0 += segment.words.map(\.text) }
        }
        func shadowed(_ segment: LiveSegment, from engine: LiveEngine) async {}
        func switched(at seconds: Double, to engine: LiveEngine, reason: SwitchReason) async {}
    }

    /// Words w0 to w19, 0.4 s each with 0.05 s pauses, shifted by `offset`, in segments of four.
    static func segments(_ offset: Double) -> [LiveSegment] {
        let words = (0..<20).map { i in
            TimedWord(text: "w\(i)", start: Double(i) * 0.45 + offset, end: Double(i) * 0.45 + 0.4 + offset,
                      confidence: nil)
        }
        return stride(from: 0, to: 20, by: 4).map { LiveSegment(words: Array(words[$0..<$0 + 4]), speaker: nil) }
    }

    @Test(arguments: [-0.15, -0.06, 0, 0.06, 0.15], [4, 8, 12])
    func aSwitchWithOffsetTimesNeitherDropsNorDoubles(offset: Double, at segment: Int) async {
        for (from, to) in [(LiveEngine.elevenLabsRealtime, LiveEngine.appleLocal), (.appleLocal, .elevenLabsRealtime)] {
            let sink = Sink(), router = LiveRouter(start: from, sink: sink)
            let active = Self.segments(0), shadow = Self.segments(offset)
            for i in 0..<5 {
                if i * 4 < segment { await router.feed(.committed(active[i]), from: from) }
                await router.feed(.committed(shadow[i]), from: to)
            }
            await router.switchTo(to, at: Double(segment) * 0.45, reason: .networkError)
            #expect(sink.words.withLock { $0 } == (0..<20).map { "w\($0)" }, "offset \(offset), \(from) to \(to)")
        }
    }
}
