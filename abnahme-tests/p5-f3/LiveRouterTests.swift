// Group F3-4: the LiveRouter (ARCHITEKTUR M.3, F3-3, R-097). Both recognizers deliver their events in the time grid of
// the recording; Apple runs along as a shadow while ElevenLabs is chosen. The router decides which words go into the
// live file. A handover happens at the time mark B = end of the last finished contribution of the old source; from the
// new source only words with start >= B pass; shadow contributions go to the session journal only. A switch in the
// middle of a recording is allowed (the language is not). Every word of the test recordings is its own marker "s<i>":
// 0 missing and 0 doubled markers, in order, one italic switch line per switch.
import Foundation
import Testing
@testable import FlowIQCore
@testable import FlowIQSpeech

@Suite(.timeLimit(.minutes(3)))
struct LiveRouterTests {  // ASSUMPTION: assumed API, see the Support header
    private let total = 1200  // 10 minutes at two words per second

    // MARK: the shadow

    @Test func withCloudChosenAppleRunsAsAShadowAndNeverReachesTheFile() async {
        let sink = RecordingSink()
        _ = await RouterScenario(start: .elevenLabsRealtime).run(into: sink)
        let seen = sink.check(count: total)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty)
        #expect(sink.accepted.allSatisfy { $0.engine == .elevenLabsRealtime }, "an Apple word reached the file while ElevenLabs was the source")
        #expect(sink.shadowed.count == total, "every Apple contribution belongs in the session journal")
        #expect(sink.shadowed.allSatisfy { $0.engine == .appleLocal })
        #expect(sink.switches.isEmpty)
    }

    @Test func withAppleChosenEverythingComesFromApple() async {
        let sink = RecordingSink()
        var scenario = RouterScenario(start: .appleLocal)
        scenario.cloudFrom = 10_000  // the cloud was never started
        _ = await scenario.run(into: sink)
        let seen = sink.check(count: total)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty)
        #expect(sink.accepted.allSatisfy { $0.engine == .appleLocal })
        #expect(sink.shadowed.isEmpty)
    }

    // MARK: the handover mark

    @Test func theMarkIsTheEndOfTheLastFinishedContributionOfTheOldSource() async throws {
        let sink = RecordingSink()
        var scenario = RouterScenario(start: .appleLocal, steps: [.init(at: 30.2, to: .elevenLabsRealtime, reason: .manual)])  // ASSUMPTION: assumed API, see the Support header
        scenario.cloudFrom = 25
        let router = await scenario.run(into: sink)
        let lastOld = try #require(sink.accepted.last { $0.engine == .appleLocal })
        let firstNew = try #require(sink.accepted.first { $0.engine == .elevenLabsRealtime })
        let mark = try #require(await router.handoverMark)  // ASSUMPTION: LiveRouter.handoverMark is B of the last switch, nil before any
        #expect(mark == lastOld.word.end)
        #expect(firstNew.word.start >= mark, "a word before the mark came from the new source")
        #expect(markID(firstNew.word) == markID(lastOld.word) + 1, "gap or doubling at the handover")
    }

    @Test func aNewSourceSegmentThatStraddlesTheMarkIsTrimmed() async {
        let sink = RecordingSink()
        var scenario = RouterScenario(start: .appleLocal, steps: [.init(at: 61.3, to: .elevenLabsRealtime, reason: .manual)])  // ASSUMPTION: assumed API, see the Support header
        scenario.cloudGroup = 7  // boundaries that match nothing in Apple's grouping
        scenario.cloudFrom = 55
        _ = await scenario.run(into: sink)
        let seen = sink.check(count: total)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty, "missing \(seen.missing.prefix(5)) doubled \(seen.doubled.prefix(5))")
        #expect(sink.inOrder)
    }

    @Test func wordsTheShadowDeliveredBeforeTheSwitchAreNotLost() async {
        // Cloud -> Apple: Apple's contributions after B were delivered while it was only a shadow; they must appear now.
        let sink = RecordingSink()
        var scenario = RouterScenario(start: .elevenLabsRealtime, steps: [.init(at: 100.1, to: .appleLocal, reason: .networkError)])  // ASSUMPTION: assumed API, see the Support header
        scenario.cloudDelay = 6  // the cloud lags: Apple is ahead of what was accepted
        _ = await scenario.run(into: sink)
        let seen = sink.check(count: total)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty)
        #expect(sink.engineChanges == 1)
        #expect(sink.inOrder)
    }

    @Test func aLateNewSourceFillsTheHoleLaterWithoutLoss() async {
        let sink = RecordingSink()
        var scenario = RouterScenario(start: .appleLocal, steps: [.init(at: 50.0, to: .elevenLabsRealtime, reason: .manual)])  // ASSUMPTION: assumed API, see the Support header
        scenario.cloudDelay = 20
        scenario.cloudFrom = 44
        _ = await scenario.run(into: sink)
        let seen = sink.check(count: total)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty)
        #expect(sink.inOrder)
    }

    @Test func switchingToTheActiveSourceDoesNothing() async {
        let sink = RecordingSink()
        let router = LiveRouter(start: .appleLocal, sink: sink)  // ASSUMPTION: assumed API, see the Support header
        await router.switchTo(.appleLocal, at: 12, reason: .manual)  // ASSUMPTION: assumed API, see the Support header
        #expect(sink.switches.isEmpty)
        #expect(await router.handoverMark == nil)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func switchReasonsAndTimesAreReportedInOrder() async {
        let sink = RecordingSink()
        var scenario = RouterScenario(start: .elevenLabsRealtime, steps: [
            .init(at: 60, to: .appleLocal, reason: .networkError), .init(at: 200, to: .elevenLabsRealtime, reason: .returnToCloud),  // ASSUMPTION: assumed API, see the Support header
            .init(at: 300, to: .appleLocal, reason: .manual)])  // ASSUMPTION: assumed API, see the Support header
        scenario.cloudFrom = 0
        _ = await scenario.run(into: sink)
        #expect(sink.switches == [.init(seconds: 60, engine: .appleLocal, reason: .networkError),  // ASSUMPTION: assumed API, see the Support header
                                  .init(seconds: 200, engine: .elevenLabsRealtime, reason: .returnToCloud),  // ASSUMPTION: assumed API, see the Support header
                                  .init(seconds: 300, engine: .appleLocal, reason: .manual)])  // ASSUMPTION: SwitchReason { manual, networkError, returnToCloud, limit }
        #expect(sink.check(count: total).missing.isEmpty)
    }

    // MARK: 20 switches in 10-minute recordings (R-097)

    @Test func twentySwitchesTenPerDirectionLoseAndDoubleNothing() async {
        var random = Lcg(state: 2026_11_13)
        var toCloud = 0, toApple = 0
        for run in 0..<10 {
            let first = 40 + Double(random.next(200))
            let second = first + 40 + Double(random.next(250))
            var scenario = RouterScenario(start: .appleLocal, steps: [
                .init(at: first, to: .elevenLabsRealtime, reason: .manual), .init(at: second, to: .appleLocal, reason: .manual)])  // ASSUMPTION: assumed API, see the Support header
            scenario.cloudFrom = first - 5
            let sink = RecordingSink()
            _ = await scenario.run(into: sink)
            let seen = sink.check(count: total)
            #expect(seen.missing.isEmpty, "run \(run): missing \(seen.missing.prefix(5)) (switches at \(first), \(second))")
            #expect(seen.doubled.isEmpty, "run \(run): doubled \(seen.doubled.prefix(5))")
            #expect(sink.inOrder, "run \(run)")
            #expect(sink.engineChanges == 2, "run \(run)")
            #expect(sink.switches.map(\.engine) == [.elevenLabsRealtime, .appleLocal], "run \(run): one switch line per switch")
            toCloud += sink.switches.filter { $0.engine == .elevenLabsRealtime }.count
            toApple += sink.switches.filter { $0.engine == .appleLocal }.count
        }
        #expect(toCloud == 10 && toApple == 10)
    }

    @Test func randomRecordingsWithOddGroupingsAndDelaysStayComplete() async {
        var random = Lcg(state: 42)
        for run in 0..<30 {
            var scenario = RouterScenario(start: random.next(2) == 0 ? .appleLocal : .elevenLabsRealtime)
            scenario.appleGroup = 3 + random.next(4)
            scenario.cloudGroup = 5 + random.next(5)
            scenario.appleDelay = 0.2 + Double(random.next(10)) / 10
            scenario.cloudDelay = 0.5 + Double(random.next(40)) / 10
            var engine = scenario.start
            var at = 30.0
            for _ in 0..<(3 + random.next(4)) {
                engine = engine == .appleLocal ? .elevenLabsRealtime : .appleLocal
                at += 20 + Double(random.next(90))
                scenario.steps.append(.init(at: at, to: engine, reason: .manual))  // ASSUMPTION: assumed API, see the Support header
            }
            let sink = RecordingSink()
            _ = await scenario.run(into: sink)
            let seen = sink.check(count: total)
            #expect(seen.missing.isEmpty && seen.doubled.isEmpty, "run \(run): missing \(seen.missing.prefix(3)) doubled \(seen.doubled.prefix(3))")
            #expect(sink.inOrder, "run \(run)")
            #expect(sink.switches.count == scenario.steps.count, "run \(run)")
        }
    }

    @Test func aSwitchRightAtTheEndOfTheRecordingStillFlushesEverything() async {
        let sink = RecordingSink()
        var scenario = RouterScenario(start: .elevenLabsRealtime, steps: [.init(at: 599.0, to: .appleLocal, reason: .manual)])  // ASSUMPTION: assumed API, see the Support header
        scenario.cloudFrom = 0
        _ = await scenario.run(into: sink)
        let seen = sink.check(count: total)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty)
    }
}
