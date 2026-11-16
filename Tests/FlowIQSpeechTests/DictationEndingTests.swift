// The ending of a dictation run (A.6, G.1): every chunk in order, then 160 ms of silence at the chunk rate, then
// finalizing within the deadline; past it the analyzer is cancelled and the run says `deadline`, never a text.
// A fake analyzer stands in for Apple's; nothing here touches the Speech framework.
import FlowIQAudio
import FlowIQText
import Foundation
import Synchronization
import Testing
@testable import FlowIQSpeech

private final class FakeAnalyzer: DictationAnalyzer {
    struct Script: Sendable {
        var finishTakes = Duration.zero
        var finishFails = false
        var feedFails = false
    }

    let script: Script
    let fed = Mutex<[AudioChunk]>([])
    let cancelled = Mutex(false)

    init(_ script: Script = Script()) { self.script = script }

    func feed(_ chunk: AudioChunk) throws {
        if script.feedFails { throw CancellationError() }
        fed.withLock { $0.append(chunk) }
    }

    func finish() async throws -> Recognition {
        try await Task.sleep(for: script.finishTakes)
        if script.finishFails { throw CancellationError() }
        return Recognition(text: "ein künstlicher satz", recognizerProfile: "fake")
    }

    func cancel() async { cancelled.withLock { $0 = true } }
}

private func chunks(_ count: Int, rate: Double = AudioChunk.channelRate) -> [AudioChunk] {
    (0..<count).map { AudioChunk(hostTime: UInt64($0) * 10_000_000, sampleRate: rate,
                                 samples: [Float](repeating: 0.25, count: Int(rate / 100))) }
}

private func stream(_ list: [AudioChunk]) -> AsyncStream<AudioChunk> {
    let (out, input) = AsyncStream.makeStream(of: AudioChunk.self)
    list.forEach { input.yield($0) }
    input.finish()
    return out
}

struct DictationEndingTests {
    /// AirPods test 16.11.: a locked dictation of 3 minutes reaches the analyzer whole; the live path has no
    /// 60 s cap (that run ended with a key event at 59.96 s).
    @Test func aLongLockedDictationIsNeverCut() async {
        let fake = FakeAnalyzer(), sent = chunks(18_000)  // 180 s in 10 ms chunks
        let run = await DictationEnding.run(stream(sent)) { fake }
        #expect(run.failure == nil && fake.fed.withLock { $0.count } == sent.count + 1)
    }
    @Test(arguments: [AudioChunk.channelRate, 24_000.0])
    func everyChunkThenExactly160msOfSilence(_ rate: Double) async {
        let fake = FakeAnalyzer()
        let sent = chunks(30, rate: rate)
        let run = await DictationEnding.run(stream(sent)) { fake }
        #expect(run.recognition?.text == "ein künstlicher satz")
        #expect(run.failure == nil)
        let fed = fake.fed.withLock { $0 }
        #expect(Array(fed.prefix(sent.count)) == sent)
        #expect(fed.count == sent.count + 1)
        let tail = fed.count == sent.count + 1 ? fed.last : nil
        #expect(tail?.samples.count == Int(rate * 0.16))
        #expect(tail?.samples.allSatisfy { $0 == 0 } == true)
        #expect(tail?.hostTime == sent.last?.endTime)
        #expect(!fake.cancelled.withLock { $0 })
    }

    @Test func aFinalizeBeyondTheDeadlineIsCancelledAndReportsDeadline() async {
        let fake = FakeAnalyzer(.init(finishTakes: .seconds(30)))
        let started = ContinuousClock.now
        let run = await DictationEnding.run(stream(chunks(5)), deadline: .milliseconds(50)) { fake }
        #expect(ContinuousClock.now - started < .seconds(5), "the deadline did not hold")
        #expect(run.recognition == nil)
        #expect(run.failure == "deadline")
        #expect(fake.cancelled.withLock { $0 })
    }

    @Test func failuresNameTheStepAndCarryNoText() async {
        let failing = FakeAnalyzer(.init(finishFails: true))
        let finish = await DictationEnding.run(stream(chunks(3))) { failing }
        #expect(finish.recognition == nil && finish.failure == "finish")
        #expect(failing.cancelled.withLock { $0 })

        let feeding = FakeAnalyzer(.init(feedFails: true))
        let feed = await DictationEnding.run(stream(chunks(3))) { feeding }
        #expect(feed.recognition == nil && feed.failure == "feed")

        let prepare = await DictationEnding.run(stream(chunks(3))) { throw CancellationError() }
        #expect(prepare.recognition == nil && prepare.failure == "prepare")
    }

    @Test func aDictationWithoutAudioStillEndsWithSilence() async {
        let fake = FakeAnalyzer()
        let run = await DictationEnding.run(stream([])) { fake }
        #expect(run.failure == nil)
        #expect(fake.fed.withLock { $0 }.map(\.samples.count) == [Int(AudioChunk.channelRate * 0.16)])
    }
}
