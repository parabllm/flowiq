// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-7: the usage counter (ARCHITEKTUR M.8, F3-7, R-101 which overrules R-063). Seconds of audio SENT, per source
// (dictation, call microphone, call desktop, room, device) and kind (live, after-run), per month, in
// `cloud/verbrauch.json`; deviation from the sent audio duration at most 1 %; a menu line with the month total; an
// optional monthly limit in minutes (default off): at 100 % live moves seamlessly to Apple and the after-run stops,
// both visible, the after-run resumes with the next month. Minutes only, never amounts of money.
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio  // COMPILE-FIX (P5 build): LiveSetup sits next to AudioChunk in FlowIQAudio (Core cannot see AudioChunk)
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQSpeech
@testable import FlowIQStore

@Suite(.timeLimit(.minutes(3)))
struct UsageMeterTests {  // ASSUMPTION: assumed API, see the Support header
    private let t0 = localDate(2026, 11, 13, 10, 0)

    private func meter(_ clock: TestClock, limit: Int? = nil, in scratch: Scratch) -> UsageMeter {  // ASSUMPTION: assumed API, see the Support header
        UsageMeter(folder: scratch.paths.support, fs: scratch.fs, now: { clock.now }, monthLimitMinutes: limit)  // ASSUMPTION: UsageMeter(folder:fs:now:monthLimitMinutes:) writes <folder>/verbrauch.json
    }

    // MARK: counting

    @Test func everySourceAndKindIsCountedSeparatelyWithin1Percent() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let clock = TestClock(t0)
        let usage = meter(clock, in: scratch)
        var truth: [String: Double] = [:]
        var random = Lcg(state: 7)
        let sources: [UsageSource] = [.dictation, .callMic, .callDesktop, .room, .device]  // ASSUMPTION: UsageSource and UsageKind { live, post }
        for source in sources {
            for kind in [UsageKind.live, .post] {  // ASSUMPTION: assumed API, see the Support header
                for _ in 0..<3000 {  // thousands of small packets: rounding per packet would show
                    let seconds = 0.2 + Double(random.next(3)) * 0.01
                    await usage.record(source, kind, seconds: seconds)  // ASSUMPTION: UsageMeter.record(_:_:seconds:)
                    truth["\(source)/\(kind)", default: 0] += seconds
                }
            }
        }
        for source in sources {
            for kind in [UsageKind.live, .post] {  // ASSUMPTION: assumed API, see the Support header
                let expected = truth["\(source)/\(kind)"] ?? 0
                let counted = await usage.seconds(source, kind)  // ASSUMPTION: UsageMeter.seconds(_:_:) for the current month
                #expect(abs(counted - expected) <= expected * 0.01, "\(source)/\(kind): counted \(counted) of \(expected)")
            }
        }
    }

    @Test func aCallCountsTwoTracks() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let usage = meter(TestClock(t0), in: scratch)
        for _ in 0..<300 {
            await usage.record(.callMic, .live, seconds: 0.2)  // ASSUMPTION: assumed API, see the Support header
            await usage.record(.callDesktop, .live, seconds: 0.2)  // ASSUMPTION: assumed API, see the Support header
        }
        #expect(abs(await usage.monthTotalSeconds() - 120) <= 1.2, "60 s of call audio are 120 s of cloud audio")  // ASSUMPTION: UsageMeter.monthTotalSeconds() sums every source and kind of the current month
    }

    @Test func theCounterIsStoredInTheDocumentedFileAndSurvivesARestart() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let clock = TestClock(t0)
        let usage = meter(clock, in: scratch)
        await usage.record(.room, .live, seconds: 90)  // ASSUMPTION: assumed API, see the Support header
        await usage.flush()  // ASSUMPTION: UsageMeter.flush() writes what was counted
        let file = scratch.paths.support.appending(path: "verbrauch.json")
        let data = try Data(contentsOf: file)
        #expect(!data.isEmpty)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("2026-11"), "the month is part of the file")  // ASSUMPTION: month key "YYYY-MM"
        let again = meter(clock, in: scratch)
        #expect(abs(await again.seconds(.room, .live) - 90) < 0.5, "a restart lost the counter")
    }

    @Test func theFileHoldsNeitherAKeyNorAnyText() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let usage = meter(TestClock(t0), in: scratch)
        await usage.record(.dictation, .post, seconds: 12)  // ASSUMPTION: assumed API, see the Support header
        await usage.flush()  // ASSUMPTION: assumed API, see the Support header
        let text = String(decoding: try Data(contentsOf: scratch.paths.support.appending(path: "verbrauch.json")), as: UTF8.self)
        #expect(!text.lowercased().contains("key") && !text.contains("sk_"))
    }

    // MARK: month boundary

    @Test func theMonthChangeStartsFromZeroAndKeepsTheOldMonth() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let clock = TestClock(localDate(2026, 11, 30, 23, 59, 50))
        let usage = meter(clock, in: scratch)
        await usage.record(.callMic, .live, seconds: 30)  // ASSUMPTION: assumed API, see the Support header
        clock.set(localDate(2026, 12, 1, 0, 0, 10))  // ASSUMPTION: assumed API, see the Support header
        await usage.record(.callMic, .live, seconds: 10)  // ASSUMPTION: assumed API, see the Support header
        #expect(abs(await usage.seconds(.callMic, .live) - 10) < 0.5, "December must start from zero")  // ASSUMPTION: assumed API, see the Support header
        #expect(abs(await usage.seconds(.callMic, .live, month: "2026-11") - 30) < 0.5)  // ASSUMPTION: seconds(_:_:month:) reads an earlier month
    }

    // MARK: the optional limit

    @Test func withoutALimitNothingIsEverReached() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let usage = meter(TestClock(t0), in: scratch)
        await usage.record(.room, .live, seconds: 10_000_000)  // ASSUMPTION: assumed API, see the Support header
        #expect(!(await usage.limitReached))  // ASSUMPTION: UsageMeter.limitReached
    }

    @Test func theLimitIsReachedAtOneHundredPercent() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let usage = meter(TestClock(t0), limit: 1, in: scratch)
        await usage.record(.room, .live, seconds: 59)  // ASSUMPTION: assumed API, see the Support header
        #expect(!(await usage.limitReached))  // ASSUMPTION: assumed API, see the Support header
        await usage.record(.room, .post, seconds: 1)  // ASSUMPTION: assumed API, see the Support header
        #expect(await usage.limitReached, "60 s of a 1-minute limit across live and after-run")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func atTheLimitLiveMovesToAppleWithoutGapAndTheCloudIsNotAskedAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let clock = ManualClock()
        let usage = meter(TestClock(t0), limit: 1, in: scratch)
        let sink = RecordingSink()
        let apple = ScriptedLive(engine: .appleLocal, clock: clock)
        let factory = CloudFactory(clock: clock)
        let session = LiveSession(apple: apple, makeCloud: { factory.make() }, sink: sink, clock: clock, usage: usage)  // ASSUMPTION: LiveSession(apple:makeCloud:sink:clock:usage:), counts the cloud's `.sent` events into `usage` as call microphone live
        try await session.start(LiveSetup(language: .de, terms: [], track: .microphone, anchor: 0, previousText: nil, backlog: []), engine: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        var host: UInt64 = 1_000_000_000
        var cloudPacketsAtSwitch: Int?
        for _ in 0..<400 {  // 80 s in 200 ms steps; the cloud reports each packet it sent
            session.feed(audio(at: host, seconds: 0.2))  // ASSUMPTION: assumed API, see the Support header
            host += 200_000_000
            if await session.activeEngine == .elevenLabsRealtime { factory.started.last?.emit(.sent(seconds: 0.2)) }  // ASSUMPTION: assumed API, see the Support header
            await clock.run(for: .milliseconds(200))
            if cloudPacketsAtSwitch == nil, await session.activeEngine == .appleLocal { cloudPacketsAtSwitch = factory.started.last?.fed.count ?? 0 }  // ASSUMPTION: assumed API, see the Support header
        }
        #expect(await session.activeEngine == .appleLocal, "live must leave the cloud at 100 %")  // ASSUMPTION: assumed API, see the Support header
        #expect(sink.switches.map(\.reason) == [.limit], "one switch, with its own reason")  // ASSUMPTION: assumed API, see the Support header
        #expect(await session.sendingToCloud == false)  // ASSUMPTION: assumed API, see the Support header
        let afterSwitch = factory.started.last?.fed.count ?? 0
        #expect(afterSwitch == cloudPacketsAtSwitch, "the cloud kept receiving audio after the limit")
        #expect(factory.attempts <= 1, "no new cloud attempt while the limit holds")
        #expect(abs(await usage.monthTotalSeconds() - 60) <= 1.0, "the counter stops at the limit")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func theAfterRunWaitsAtTheLimitIsVisibleAndRunsInTheNextMonth() async throws {
        let rig = try await StoreRig.make(monthLimitMinutes: 1)
        defer { rig.remove() }
        await rig.usage.record(.room, .live, seconds: 61)   // ASSUMPTION: assumed API, see the Support header; the limit is used up
        let when = localDate(2026, 11, 13, 10, 45)
        let live = try await rig.begin(.call, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 1, speaker: "Mara", text: "Ein Satz."))
        try await rig.finish(live, seconds: 60, raw: try rig.makeRaw(.call, at: when, seconds: 60))
        #expect(await rig.batch.callCount == 0, "an after-run was started above the limit")
        #expect(await rig.visible() == .paused(1))
        let held = try readDoc(live.url)
        #expect(held.value("nachlauf") == "angehalten")
        #expect(held.value("panotti_phase") == "live-lokal")
        rig.clock.set(localDate(2026, 12, 1, 8, 0))  // ASSUMPTION: assumed API, see the Support header
        await rig.trigger(.timer)
        #expect(await rig.batch.callCount == 1, "the next month must release the job")
        #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
        #expect(await rig.visible() == .idle)
    }

    // MARK: the menu

    @Test func theMenuLineNamesTheMonthTotalInMinutesAndNoMoney() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let usage = meter(TestClock(t0), in: scratch)
        await usage.record(.callMic, .live, seconds: 600)  // ASSUMPTION: assumed API, see the Support header
        await usage.record(.callDesktop, .live, seconds: 600)  // ASSUMPTION: assumed API, see the Support header
        await usage.record(.room, .post, seconds: 300)  // ASSUMPTION: assumed API, see the Support header
        let line = await usage.menuLine()  // ASSUMPTION: UsageMeter.menuLine() -> String, the collapsed menu line
        #expect(line.contains("Cloud diesen Monat"))
        #expect(line.contains("25"), "1500 s are 25 minutes: \(line)")
        for symbol in ["€", "$", "USD", "EUR"] { #expect(!line.contains(symbol), "amounts of money are not shown") }
        let detail = await usage.detailLines()  // ASSUMPTION: detailLines() -> [String], the expanded lines, one per source and kind with a count
        #expect(detail.count == 3)
        #expect(detail.allSatisfy { line in !["€", "$", "USD", "EUR"].contains { line.contains($0) } })
    }

    @Test func theLimitStateIsVisibleInTheMenuLine() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let usage = meter(TestClock(t0), limit: 1, in: scratch)
        let before = await usage.menuLine()  // ASSUMPTION: assumed API, see the Support header
        await usage.record(.room, .live, seconds: 60)  // ASSUMPTION: assumed API, see the Support header
        let after = await usage.menuLine()  // ASSUMPTION: assumed API, see the Support header
        #expect(after != before)
        #expect(after.localizedCaseInsensitiveContains("grenze"), "the menu names the monthly limit once it is reached: \(after)")
    }
}
