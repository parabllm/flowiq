import FlowIQCore
import Foundation
import Synchronization
import Testing
@testable import FlowIQSpeech

/// Review M4: audio first. A live recognizer that fails at the start or mid-run never stops the session; the sink
/// gets one visible failure, and the session asks for the file run unless the cloud writes.
struct LiveTroubleTests {
    final class Sink: RouterSink {
        let troubles = Mutex<[LiveTrouble]>([]), words = Mutex<[String]>([])
        func accepted(_ segment: LiveSegment, from engine: LiveEngine) async {
            words.withLock { $0 += segment.words.map(\.text) }
        }
        func shadowed(_ segment: LiveSegment, from engine: LiveEngine) async {}
        func switched(at seconds: Double, to engine: LiveEngine, reason: SwitchReason) async {}
        func failed(at seconds: Double, _ trouble: LiveTrouble) async { troubles.withLock { $0.append(trouble) } }
    }

    /// Starts as asked and can fail later; `starts` false throws at the start like a broken analyzer.
    final class Fake: LiveRecognizer {
        let engine: LiveEngine, starts: Bool, events: AsyncStream<LiveEvent>
        let out: AsyncStream<LiveEvent>.Continuation
        init(_ engine: LiveEngine, starts: Bool = true) {
            (self.engine, self.starts) = (engine, starts)
            (events, out) = AsyncStream.makeStream()
        }
        func start(_ setup: LiveSetup) async throws { if !starts { throw CocoaError(.featureUnsupported) } }
        func feed(_ chunk: AudioChunk) {}
        func finish() async { out.finish() }
        func say(_ word: String, at t: Double) {
            out.yield(.committed(LiveSegment(words: [TimedWord(text: word, start: t, end: t + 0.3, confidence: nil)],
                                             speaker: nil)))
        }
    }

    static let setup = LiveSetup(language: .en, terms: [], track: .microphone, anchor: 0, previousText: nil,
                                 backlog: [])

    static func settle(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) { _ = await ContinuousClock().pause(.milliseconds(5)) }
    }

    @Test func aMissingModelOrAFailingStartNeverStopsTheSession() async throws {
        let apples: [any LiveRecognizer] = [UnavailableRecognizer(.modelMissing(.en)), Fake(.appleLocal, starts: false)]
        for apple in apples {
            let sink = Sink()
            let session = LiveSession(apple: apple, makeCloud: { Fake(.elevenLabsRealtime) }, sink: sink,
                                      clock: ContinuousClock(), usage: nil)
            try await session.start(Self.setup, engine: .appleLocal)
            session.feed(AudioChunk(hostTime: 0, sampleRate: 48_000, samples: [Float](repeating: 0, count: 480)))
            let expected: LiveTrouble = apple is UnavailableRecognizer ? .modelMissing(.en) : .recognizerFailed
            #expect(sink.troubles.withLock { $0 } == [expected], "one visible failure, never a German fallback")
            #expect(await session.trouble == expected)
            #expect(await session.needsFileRun)
            await session.finish()
        }
    }

    @Test func appleDyingMidRunIsReportedOnceAndAsksForTheFileRun() async throws {
        let sink = Sink(), apple = Fake(.appleLocal)
        let session = LiveSession(apple: apple, makeCloud: { Fake(.elevenLabsRealtime) }, sink: sink,
                                  clock: ContinuousClock(), usage: nil)
        try await session.start(Self.setup, engine: .appleLocal)
        apple.say("eins", at: 0)
        apple.out.yield(.failure(.transcriberError))
        apple.out.yield(.failure(.transcriberError))
        await Self.settle { await session.trouble != nil }
        #expect(sink.words.withLock { $0 } == ["eins"])
        #expect(sink.troubles.withLock { $0 } == [.recognizerFailed])
        #expect(await session.needsFileRun)
        await session.finish()
    }

    @Test func whileTheCloudWritesNoFileRunIsNeeded() async throws {
        let sink = Sink()
        let session = LiveSession(apple: UnavailableRecognizer(.modelMissing(.en)),
                                  makeCloud: { Fake(.elevenLabsRealtime) }, sink: sink, clock: ContinuousClock(),
                                  usage: nil)
        try await session.start(Self.setup, engine: .elevenLabsRealtime)
        #expect(await session.trouble == .modelMissing(.en))
        #expect(await session.needsFileRun == false)
        await session.finish()
    }
}
