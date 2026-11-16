// Group F3-5: fallback without a gap in two stages (ARCHITEKTUR M.5, F3-4, R-098, R-103 language part, Anhang I
// `NoSilentLossTests` addition "0 missing, 0 doubled markers"). The cloud recognizer is an artificial one with a forced
// abort. Stage 1 (short abort: connection closed, session limit, rate limit, resource, transcriber, queue overflow):
// a new session within 1 s, first packet with `previous_text` (at most the last 50 characters) and the audio since the
// last commit, then live again. Stage 2 (longer outage: reconnect fails within 5 s, auth error, quota, terms, network
// gone): handover to the Apple shadow at the mark B within 5 s, badge off, switch line, a new cloud attempt every
// minute while network and key are valid, return at a pause, at most 3 automatic switches per recording.
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQSpeech

/// Hands out artificial cloud recognizers, one per (re)connect attempt, and counts attempts.
final class CloudFactory: Sendable {
    private struct State {
        var made: [ScriptedLive] = []
        var attempts = 0
        var failure: (any Error)?
    }

    let clock: ManualClock
    private let state = Mutex(State())
    init(clock: ManualClock) { self.clock = clock }

    var made: [ScriptedLive] { state.withLock { $0.made } }
    var attempts: Int { state.withLock { $0.attempts } }
    var started: [ScriptedLive] { made.filter { !$0.starts.isEmpty } }
    func setOutage(_ error: (any Error)?) { state.withLock { $0.failure = error } }

    func make() -> ScriptedLive {
        let cloud = ScriptedLive(engine: .elevenLabsRealtime, clock: clock)
        state.withLock { s in
            s.attempts += 1
            if let error = s.failure { cloud.failNextStart(with: error) }
            s.made.append(cloud)
        }
        return cloud
    }
}

@Suite(.timeLimit(.minutes(4)))
struct CloudFallbackTests {
    private struct Rig {
        let clock = ManualClock()
        let sink = RecordingSink()
        let apple: ScriptedLive
        let factory: CloudFactory
        let session: LiveSession  // ASSUMPTION: assumed API, see the Support header

        init() {
            apple = ScriptedLive(engine: .appleLocal, clock: clock)
            factory = CloudFactory(clock: clock)
            let factory = factory
            session = LiveSession(apple: apple, makeCloud: { factory.make() }, sink: sink, clock: clock, usage: nil)  // ASSUMPTION: LiveSession(apple:makeCloud:sink:clock:usage:)
        }

        func start(_ engine: LiveEngine = .elevenLabsRealtime, language: RecordingLanguage = .de) async throws {
            try await session.start(LiveSetup(language: language, terms: [], track: .microphone, anchor: 0, previousText: nil, backlog: []), engine: engine)  // ASSUMPTION: LiveSession.start(_:engine:) throws
        }

        var hostTime: UInt64 = 1_000_000_000

        /// Feeds `seconds` of audio in 100 ms pieces while the clock runs; `loud` false is a pause.
        mutating func play(_ seconds: Double, loud: Bool = true) async {
            for _ in 0..<Int((seconds * 10).rounded()) {
                session.feed(audio(at: hostTime, seconds: 0.1, loud: loud))  // ASSUMPTION: LiveSession.feed(_:) never blocks; it fans out to Apple (always) and the cloud (while sending), and keeps the 40 s ring
                hostTime += 100_000_000
                await clock.run(for: .milliseconds(100))
            }
        }
    }

    // MARK: the six cases of R-098

    enum Expect: Sendable { case reconnect, handover }

    @Test(arguments: [
        (LiveFailure.connectionClosed, Expect.reconnect), (.sessionTimeLimit, .reconnect), (.rateLimited, .reconnect),  // ASSUMPTION: assumed API, see the Support header
        (.networkDown, .handover), (.quotaExceeded, .handover), (.authError, .handover),  // ASSUMPTION: assumed API, see the Support header
    ] as [(LiveFailure, Expect)])  // ASSUMPTION: assumed API, see the Support header
    func eachFailureEndsInReconnectOrHandoverWithinTheLimits(_ failure: LiveFailure, _ expect: Expect) async throws {  // ASSUMPTION: assumed API, see the Support header
        var rig = Rig()
        try await rig.start()
        await rig.play(10)
        if failure == .networkDown { rig.factory.setOutage(failure) }   // ASSUMPTION: assumed API, see the Support header; the network is gone: reconnects fail as well
        rig.factory.made.last?.abort(failure)  // ASSUMPTION: assumed API, see the Support header
        switch expect {
        case .reconnect:
            await rig.play(1.0)
            #expect(rig.factory.started.count == 2, "\(failure): no new session within 1 s")
            #expect(await rig.session.activeEngine == .elevenLabsRealtime)  // ASSUMPTION: LiveSession.activeEngine
            #expect(rig.sink.switches.isEmpty, "\(failure): the short abort must not hand over")
            let again = try #require(rig.factory.started.last)
            let previous = try #require(again.starts.first?.previousText)  // ASSUMPTION: assumed API, see the Support header
            #expect(previous.count <= 50)
            #expect(await rig.session.sendingToCloud)  // ASSUMPTION: LiveSession.sendingToCloud is what the badge follows
        case .handover:
            await rig.play(5.0)
            #expect(await rig.session.activeEngine == .appleLocal, "\(failure): no handover within 5 s")  // ASSUMPTION: assumed API, see the Support header
            #expect(rig.sink.switches.map(\.engine) == [.appleLocal])
            #expect(rig.sink.switches.first?.reason == .networkError)  // ASSUMPTION: assumed API, see the Support header
            #expect(!(await rig.session.sendingToCloud))  // ASSUMPTION: assumed API, see the Support header
        }
        #expect(rig.apple.fed.count == (expect == .reconnect ? 110 : 150), "Apple (the shadow) must hear every chunk")
    }

    @Test func handoverNeverWaitsLongerThanFiveSecondsEvenWhenReconnectsKeepFailing() async throws {
        var rig = Rig()
        try await rig.start()
        await rig.play(5)
        rig.factory.setOutage(LiveFailure.networkDown)  // ASSUMPTION: assumed API, see the Support header
        rig.factory.made.last?.abort(.connectionClosed)  // ASSUMPTION: assumed API, see the Support header
        await rig.play(5.0)
        #expect(await rig.session.activeEngine == .appleLocal)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.sink.switches.count == 1)
    }

    // MARK: nothing is lost or doubled around an abort

    /// One scripted recording of `seconds`; every 0.5 s of audio is fed, both recognizers speak the whole timeline in
    /// their own grouping and delay. The cloud instance that is current speaks from the anchor it was started with.
    private func record(_ rig: inout Rig, seconds: Double, abortAt: Double?, failure: LiveFailure, outage: Bool) async throws -> Int {  // ASSUMPTION: assumed API, see the Support header
        let all = marks(seconds: seconds)
        var appleNext = 0, spoken: [ObjectIdentifier: Int] = [:]
        var aborted = false
        var t = 0.0
        while t < seconds + 3 {  // three more seconds drain what the recognizers still owe
            await rig.play(0.5)
            t += 0.5
            // Apple: groups of 4 words, 0.5 s late.
            while appleNext + 4 <= all.count, all[appleNext + 3].end + 0.5 <= t {
                rig.apple.commit(all[appleNext..<(appleNext + 4)])
                appleNext += 4
            }
            // The current cloud instance: groups of 6 words from its anchor, 1.5 s late.
            if let cloud = rig.factory.started.last, !(aborted && outage) {
                let key = ObjectIdentifier(cloud)
                let anchor = cloud.starts.first?.anchor ?? 0  // ASSUMPTION: assumed API, see the Support header
                var next = spoken[key] ?? Int((anchor * 2).rounded(.up))
                while next + 6 <= all.count, all[next + 5].end + 1.5 <= t {
                    cloud.commit(all[next..<(next + 6)])
                    next += 6
                }
                spoken[key] = next
            }
            if let abortAt, !aborted, t >= abortAt {
                aborted = true
                if outage { rig.factory.setOutage(LiveFailure.networkDown) }  // ASSUMPTION: assumed API, see the Support header
                rig.factory.started.last?.abort(failure)  // ASSUMPTION: assumed API, see the Support header
            }
        }
        await rig.clock.run(for: .seconds(5))
        return all.count
    }

    @Test func aShortAbortLosesAndDoublesNothing() async throws {
        var rig = Rig()
        try await rig.start()
        let count = try await record(&rig, seconds: 120, abortAt: 61.3, failure: .connectionClosed, outage: false)  // ASSUMPTION: assumed API, see the Support header
        let seen = rig.sink.check(count: count - count % 12)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty, "missing \(seen.missing.prefix(5)) doubled \(seen.doubled.prefix(5))")
        #expect(rig.sink.inOrder)
        #expect(rig.sink.switches.isEmpty)
        #expect(rig.factory.started.count == 2)
    }

    @Test func aLongOutageLosesAndDoublesNothing() async throws {
        var rig = Rig()
        try await rig.start()
        let count = try await record(&rig, seconds: 120, abortAt: 61.3, failure: .networkDown, outage: true)  // ASSUMPTION: assumed API, see the Support header
        let seen = rig.sink.check(count: count - count % 12)
        #expect(seen.missing.isEmpty && seen.doubled.isEmpty, "missing \(seen.missing.prefix(5)) doubled \(seen.doubled.prefix(5))")
        #expect(rig.sink.inOrder)
        #expect(rig.sink.switches.map(\.engine) == [.appleLocal])
    }

    @Test func aReconnectResendsTheAudioSinceTheLastCommit() async throws {
        var rig = Rig()
        try await rig.start()
        await rig.play(4)
        rig.factory.made.last?.commit(marks(seconds: 4))  // the service committed everything up to second 4
        await rig.play(3)  // three seconds heard after the last commit
        rig.factory.made.last?.abort(.connectionClosed)  // ASSUMPTION: assumed API, see the Support header
        await rig.play(1.0)
        let again = try #require(rig.factory.started.last)
        let setup = try #require(again.starts.first)
        let backlogSeconds = setup.backlog.reduce(0) { $0 + $1.seconds }  // ASSUMPTION: assumed API, see the Support header
        #expect(abs(backlogSeconds - 3.0) < 0.15, "backlog holds \(backlogSeconds) s, expected the 3 s since the last commit")  // ASSUMPTION: LiveSetup.backlog carries the AudioChunks since the last commit (ring of at most 40 s)
        #expect(abs(setup.anchor - 4.0) < 0.15)  // ASSUMPTION: assumed API, see the Support header
        #expect(setup.previousText?.hasSuffix("s7") == true, "previous_text is the end of what the service committed")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func theRingKeepsAtMostFortySeconds() async throws {
        var rig = Rig()
        try await rig.start()
        await rig.play(70)  // the scripted cloud never commits
        rig.factory.made.last?.abort(.sessionTimeLimit)  // ASSUMPTION: assumed API, see the Support header
        await rig.play(1.0)
        let setup = try #require(rig.factory.started.last?.starts.first)
        #expect(setup.backlog.reduce(0) { $0 + $1.seconds } <= 40.05)  // ASSUMPTION: assumed API, see the Support header
    }

    // MARK: the way back

    @Test func aNewCloudAttemptEveryMinuteAndReturnAtAPause() async throws {
        var rig = Rig()
        try await rig.start()
        await rig.play(5)
        rig.factory.setOutage(LiveFailure.networkDown)  // ASSUMPTION: assumed API, see the Support header
        rig.factory.made.last?.abort(.networkDown)  // ASSUMPTION: assumed API, see the Support header
        await rig.play(6)
        #expect(await rig.session.activeEngine == .appleLocal)  // ASSUMPTION: assumed API, see the Support header
        let attemptsAtHandover = rig.factory.attempts
        await rig.play(180)  // three minutes of outage
        let retries = rig.factory.attempts - attemptsAtHandover
        #expect((2...4).contains(retries), "\(retries) cloud attempts in 3 minutes, expected one per minute")
        rig.factory.setOutage(nil)  // the network is back
        await rig.play(65)
        #expect(await rig.session.activeEngine == .appleLocal, "the return must wait for a pause while speech goes on")  // ASSUMPTION: assumed API, see the Support header
        await rig.play(0.6, loud: false)
        await rig.play(1.0)
        #expect(await rig.session.activeEngine == .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.sink.switches.last?.reason == .returnToCloud)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func anInvalidKeyIsNeverRetried() async throws {
        var rig = Rig()
        try await rig.start()
        await rig.play(5)
        rig.factory.setOutage(LiveFailure.authError)  // ASSUMPTION: assumed API, see the Support header
        rig.factory.made.last?.abort(.authError)  // ASSUMPTION: assumed API, see the Support header
        await rig.play(6)
        let attempts = rig.factory.attempts
        await rig.play(240)
        #expect(rig.factory.attempts == attempts, "a rejected key was tried again")
        #expect(await rig.session.activeEngine == .appleLocal)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func atMostThreeAutomaticSwitchesThenAppleStays() async throws {
        var rig = Rig()
        try await rig.start()
        for round in 0..<3 {  // abort, handover, return, abort, handover, return ...
            await rig.play(5)
            rig.factory.setOutage(LiveFailure.networkDown)  // ASSUMPTION: assumed API, see the Support header
            rig.factory.started.last?.abort(.networkDown)  // ASSUMPTION: assumed API, see the Support header
            await rig.play(6)
            rig.factory.setOutage(nil)
            if round < 1 {
                await rig.play(65)
                await rig.play(0.6, loud: false)
                await rig.play(1.0)
            }
        }
        await rig.play(200, loud: true)
        await rig.play(0.6, loud: false)
        await rig.play(1.0)
        #expect(await rig.session.automaticSwitches == 3)  // ASSUMPTION: LiveSession.automaticSwitches counts handovers and returns together
        #expect(await rig.session.activeEngine == .appleLocal, "after the third automatic switch Apple stays")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.session.offersManualSwitch, "the menu offers the switch back")  // ASSUMPTION: LiveSession.offersManualSwitch
    }

    @Test func aManualSwitchDoesNotCountAgainstTheThreeAutomaticOnes() async throws {
        var rig = Rig()
        try await rig.start()
        await rig.play(5)
        await rig.session.switchTo(.appleLocal, reason: .manual)  // ASSUMPTION: LiveSession.switchTo(_:reason:)
        await rig.play(2)
        await rig.session.switchTo(.elevenLabsRealtime, reason: .manual)  // ASSUMPTION: assumed API, see the Support header
        await rig.play(2)
        #expect(await rig.session.automaticSwitches == 0)  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.session.activeEngine == .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.sink.switches.map(\.reason) == [.manual, .manual])  // ASSUMPTION: assumed API, see the Support header
    }

    // MARK: language (R-103)

    @Test(arguments: [RecordingLanguage.de, .en])
    func cloudSessionAppleShadowAndFallbackSessionAllCarryTheRecordingsLanguage(_ language: RecordingLanguage) async throws {
        var rig = Rig()
        try await rig.start(language: language)
        await rig.play(2)
        #expect(rig.factory.started.first?.starts.first?.language == language)
        #expect(rig.apple.starts.first?.language == language, "the Apple shadow runs in the language of the recording")
        rig.factory.made.last?.abort(.connectionClosed)  // ASSUMPTION: assumed API, see the Support header
        await rig.play(1.0)
        #expect(rig.factory.started.last?.starts.first?.language == language, "a reconnected session keeps the language")
    }

    @Test func theLanguageCannotBeChangedAfterTheStart() async throws {
        var rig = Rig()
        try await rig.start(language: .de)
        await rig.play(1)
        await #expect(throws: LiveSessionError.self) { try await rig.session.changeLanguage(to: .en) }  // ASSUMPTION: LiveSession.changeLanguage(to:) always throws LiveSessionError.languageFixed after the start
        #expect(rig.apple.starts.count == 1 && rig.factory.started.count == 1)
    }
}
