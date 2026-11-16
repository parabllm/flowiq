// Group F3-3: the cloud badge (ARCHITEKTUR M.6, F3-5, R-099). A small outlined cloud sits on the recording pill and
// the menu bar icon exactly while audio is being sent: first packet to badge on and last packet to badge off at most
// 1 s each, 0 seconds of sending without a badge, 0 seconds of badge more than 1 s after the sending ended. The badge
// follows the sending, not the setting. For the after-run of a dictation it appears at the menu bar icon only.
import Foundation
import Testing
@testable import FlowIQCloud
@testable import FlowIQCore

@Suite(.timeLimit(.minutes(2)))
struct CloudBadgeTests {  // ASSUMPTION: assumed API, see the Support header
    private let t0 = localDate(2026, 11, 13, 10, 0)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func feedPackets(_ badge: CloudBadge, _ clock: TestClock, stream: String, from: Double, to: Double, surface: BadgeSurface = .pill) {  // ASSUMPTION: assumed API, see the Support header
        var t = from
        while t <= to {
            clock.set(at(t))  // ASSUMPTION: assumed API, see the Support header
            badge.packetSent(stream: stream)  // ASSUMPTION: CloudBadge.packetSent(stream:) is called for every audio packet that leaves (the `.sent` event)
            t += 0.2
        }
    }

    @Test func theBadgeFollowsALivePacketStreamWithinOneSecondEitherWay() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: CloudBadge(now:)
        #expect(!badge.isVisible(on: .pill))  // ASSUMPTION: assumed API, see the Support header
        var events: [(Double, String)] = []
        var t = 0.0
        while t <= 40 {
            clock.set(at(t))  // ASSUMPTION: assumed API, see the Support header
            if t >= 5 && t <= 25 { badge.packetSent(stream: "call-mic") }  // ASSUMPTION: assumed API, see the Support header
            if t == 25.2 { badge.streamClosed("call-mic") }  // ASSUMPTION: CloudBadge.streamClosed(_:) when a session ends cleanly
            events.append((t, badge.isVisible(on: .pill) ? "on" : "off"))  // ASSUMPTION: assumed API, see the Support header
            t = (t * 10 + 2).rounded() / 10
        }
        let firstOn = events.first { $0.1 == "on" }?.0 ?? .infinity
        let lastOn = events.last { $0.1 == "on" }?.0 ?? -.infinity
        #expect(firstOn - 5 <= 1.0, "badge came \(firstOn - 5) s after the first packet")
        #expect(lastOn - 25 <= 1.0 + 0.0001, "badge stayed \(lastOn - 25) s after the last packet")
        #expect(events.filter { $0.0 < 5 }.allSatisfy { $0.1 == "off" }, "badge before any packet")
    }

    @Test func zeroSecondsOfSendingWithoutBadgeAndNoLingeringBadge() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        let sessions: [ClosedRange<Double>] = [4...30, 40...60]  // two sessions with a gap
        var silent = 0.0, lingering = 0.0
        var t = 0.0
        while t <= 70 {
            clock.set(at(t))  // ASSUMPTION: assumed API, see the Support header
            let session = sessions.first { $0.contains(t) }
            if session != nil, Int((t * 10).rounded()) % 2 == 0 { badge.packetSent(stream: "room") }   // ASSUMPTION: assumed API, see the Support header; a packet every 200 ms; COMPILE-FIX (P5 build): `if let session` bound an unused value
            let shown = badge.isVisible(on: .pill)  // ASSUMPTION: assumed API, see the Support header
            if let session, !shown, t - session.lowerBound > 1.0 { silent += 0.1 }
            if session == nil, shown {
                let lastEnd = sessions.map(\.upperBound).filter { $0 < t }.max() ?? 0
                if t - lastEnd > 1.0 { lingering += 0.1 }
            }
            t += 0.1
        }
        #expect(silent == 0, "\(silent) s of sending without a badge")
        #expect(lingering == 0, "\(lingering) s of badge without sending")
    }

    @Test func aDroppedConnectionTurnsTheBadgeOffWithinOneSecondWithoutAClose() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        feedPackets(badge, clock, stream: "call-mic", from: 1, to: 10)
        clock.set(at(10.1))  // ASSUMPTION: assumed API, see the Support header
        #expect(badge.isVisible(on: .pill))  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(11.3))  // ASSUMPTION: assumed API, see the Support header
        #expect(!badge.isVisible(on: .pill), "no packet for more than 1 s: the badge must be off")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func twoStreamsKeepTheBadgeOnUntilBothAreSilent() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        feedPackets(badge, clock, stream: "call-mic", from: 1, to: 20)
        feedPackets(badge, clock, stream: "call-desktop", from: 1, to: 30)
        clock.set(at(25))  // ASSUMPTION: assumed API, see the Support header
        #expect(badge.isVisible(on: .pill), "the desktop stream still sends")  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(31.5))  // ASSUMPTION: assumed API, see the Support header
        #expect(!badge.isVisible(on: .pill))  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func fallingBackToAppleTurnsTheBadgeOffBecauseNothingIsSentAnyMore() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        feedPackets(badge, clock, stream: "call-mic", from: 1, to: 15)
        // From second 15 the router uses Apple: the cloud session is closed, packets stop.
        badge.streamClosed("call-mic")  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(16.5))  // ASSUMPTION: assumed API, see the Support header
        #expect(!badge.isVisible(on: .pill), "the setting still says ElevenLabs, but nothing is sent: no badge")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func theAfterRunUploadOfADictationShowsOnTheMenuBarIconOnly() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(2))  // ASSUMPTION: assumed API, see the Support header
        badge.uploadStarted(id: "dictation-1", mode: .dictation)  // ASSUMPTION: CloudBadge.uploadStarted(id:mode:) / uploadFinished(id:)
        clock.set(at(5))  // ASSUMPTION: assumed API, see the Support header
        #expect(badge.isVisible(on: .menuBar))  // ASSUMPTION: BadgeSurface { pill, menuBar }
        #expect(!badge.isVisible(on: .pill), "the pill is already gone after a dictation")  // ASSUMPTION: assumed API, see the Support header
        badge.uploadFinished(id: "dictation-1")  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(5.9))  // ASSUMPTION: assumed API, see the Support header
        #expect(!badge.isVisible(on: .menuBar), "off within 1 s of the end of the upload")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func aLongAfterRunUploadKeepsTheBadgeWithoutPackets() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(1))  // ASSUMPTION: assumed API, see the Support header
        badge.uploadStarted(id: "call-1", mode: .call)  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(90))  // ASSUMPTION: assumed API, see the Support header
        #expect(badge.isVisible(on: .menuBar), "a running upload is sending, even without packets")  // ASSUMPTION: assumed API, see the Support header
        badge.uploadFinished(id: "call-1")  // ASSUMPTION: assumed API, see the Support header
        clock.set(at(91.5))  // ASSUMPTION: assumed API, see the Support header
        #expect(!badge.isVisible(on: .menuBar))  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func liveSendingShowsOnPillAndMenuBar() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        feedPackets(badge, clock, stream: "room", from: 1, to: 5)
        #expect(badge.isVisible(on: .pill) && badge.isVisible(on: .menuBar))  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func appleLocalRecordingNeverShowsABadge() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        var t = 0.0
        while t < 60 {
            clock.set(at(t))  // ASSUMPTION: assumed API, see the Support header
            #expect(!badge.isVisible(on: .pill) && !badge.isVisible(on: .menuBar))  // ASSUMPTION: assumed API, see the Support header
            t += 1
        }
    }

    @Test func theMenuLineNamesStateAndCloudMinutesOfTheRunningRecording() {
        let clock = TestClock(t0)
        let badge = CloudBadge(now: { clock.now })  // ASSUMPTION: assumed API, see the Support header
        feedPackets(badge, clock, stream: "call-mic", from: 1, to: 61)
        let line = badge.menuLine(for: .sending, cloudSeconds: 60)  // ASSUMPTION: CloudBadge.menuLine(for:cloudSeconds:) with BadgeState { sending, fallback, waitingForNetwork } (M.6)
        #expect(line.contains("1"), "cloud minutes of this recording")
        #expect(badge.menuLine(for: .fallback, cloudSeconds: 60) != line)  // ASSUMPTION: assumed API, see the Support header
        #expect(badge.menuLine(for: .waitingForNetwork, cloudSeconds: 60) != badge.menuLine(for: .fallback, cloudSeconds: 60))  // ASSUMPTION: assumed API, see the Support header
    }
}
