// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 3: the live link (A.9 "Live-Verweis", R-053, Prüfbericht G-12). The link points at the running
// live file, is replaced atomically, falls back to the still running file when the newer one ends, and
// stays on the finished file after the last one ends (the souffleur reads the status change through it).
// The tests use a link path inside the temp folder; the real production link is never written.
import Foundation
import Synchronization
import Testing
@testable import FlowIQStore  // COMPILE-FIX (P5 build): the file names LiveTranscript without importing its module

final class Poll: Sendable {
    let stop = Mutex(false)
    let misses = Mutex(0)
    let reads = Mutex(0)
}

struct LiveLinkTests {
    static let t0 = localDate(2026, 11, 13, 10, 45)

    private func finish(_ rig: Rig, _ live: LiveTranscript, _ kind: Kind, at when: Date) async throws {
        let item = try rig.makeRaw(kind, at: when, seconds: 20)
        try await rig.finish(live, seconds: 20, raw: item)
    }

    @Test func linkPointsAtTheRunningFileAfterStart() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        await rig.add(live, sampleLines[0])
        #expect(samePath(linkDestination(rig.liveLink), live.url))
        // Reading through the link gives the file's own text.
        #expect(try Data(contentsOf: rig.liveLink) == Data(contentsOf: live.url))
    }

    @Test func twoLiveFilesLinkToTheLatestStarted() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let call = try await rig.begin(.call, at: Self.t0)
        let room = try await rig.begin(.room, at: localDate(2026, 11, 13, 10, 50))
        #expect(samePath(linkDestination(rig.liveLink), room.url))
        #expect(!samePath(linkDestination(rig.liveLink), call.url))
    }

    @Test func endingTheOlderOneKeepsTheLinkOnTheNewer() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let call = try await rig.begin(.call, at: Self.t0)
        let room = try await rig.begin(.room, at: localDate(2026, 11, 13, 10, 50))
        try await finish(rig, call, .call, at: Self.t0)
        #expect(samePath(linkDestination(rig.liveLink), room.url))
    }

    @Test func endingTheNewerOneFallsBackToTheStillRunningOne() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let call = try await rig.begin(.call, at: Self.t0)
        let roomStart = localDate(2026, 11, 13, 10, 50)
        let room = try await rig.begin(.room, at: roomStart)
        try await finish(rig, room, .room, at: roomStart)
        #expect(samePath(linkDestination(rig.liveLink), call.url))
        #expect(try readDoc(URL(filePath: linkDestination(rig.liveLink) ?? "")).value("status") == "live")  // COMPILE-FIX (P5 build): #require on a non-optional URL is a warning, warnings are errors
    }

    /// Last live file ends: the link stays and shows the end through the status change.
    @Test func linkStaysOnTheFinishedFileAfterTheLastOneEnds() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        await rig.add(live, sampleLines[0])
        try await finish(rig, live, .call, at: Self.t0)
        #expect(samePath(linkDestination(rig.liveLink), live.url))
        let through = try readDoc(rig.liveLink)  // reading through the link must work, never dangle
        #expect(through.value("status") == "unverarbeitet")
        #expect(through.value("panotti_phase") == "final-lokal")
    }

    /// In-place upgrade: the link target is still valid and now shows the new phase.
    @Test func linkSurvivesTheInPlaceUpgrade() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Ein Satz."))
        try await finish(rig, live, .room, at: Self.t0)
        #expect(samePath(linkDestination(rig.liveLink), live.url))
        #expect(try readDoc(rig.liveLink).value("panotti_phase") == "final-elevenlabs")
    }

    /// A new recording after a finished one moves the link to the new file.
    @Test func nextRecordingMovesTheLink() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let first = try await rig.begin(.call, at: Self.t0)
        try await finish(rig, first, .call, at: Self.t0)
        let second = try await rig.begin(.call, at: localDate(2026, 11, 13, 11, 30))
        #expect(samePath(linkDestination(rig.liveLink), second.url))
    }

    /// The link is replaced by a fresh link and an atomic rename: a reader polling all the time never
    /// finds it missing once it exists.
    @Test func linkIsNeverMissingWhileItMoves() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let first = try await rig.begin(.call, at: Self.t0)
        let linkPath = rig.liveLink.path
        let poll = Poll()
        let poller = Task.detached {
            while !poll.stop.withLock({ $0 }) {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == nil {
                    poll.misses.withLock { $0 += 1 }
                }
                poll.reads.withLock { $0 += 1 }
                try? await Task.sleep(for: .microseconds(200))
            }
        }
        while poll.reads.withLock({ $0 }) == 0 { await Task.yield() }  // TEST-FIX (geprüft, Prüfnotiz Nr. 3): wait for the poller's first read before the link moves
        var previous = first
        let before = poll.reads.withLock { $0 }
        for n in 1...12 {
            let when = localDate(2026, 11, 13, 11, n), seen = poll.reads.withLock { $0 }
            let next = try await rig.begin(n % 2 == 0 ? .call : .room, at: when)
            try await finish(rig, previous, .call, at: Self.t0.addingTimeInterval(Double(n)))
            previous = next
            while poll.reads.withLock({ $0 }) == seen { await Task.yield() }  // TEST-FIX Nr. 3, neu nach der Prüfung vom 15.11.: at least one read per move, so the reads happen while the link moves
        }
        poll.stop.withLock { $0 = true }
        await poller.value
        #expect(poll.reads.withLock { $0 } - before >= 12)  // TEST-FIX Nr. 3 (15.11.): replaces the tautology "> 20"; misses == 0 stays the expectation
        #expect(poll.misses.withLock { $0 } == 0)
    }

    /// A recording that never gets a link (link folder unwritable) must not lose the transcript.
    @Test func linkFailureDoesNotStopTheTranscript() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        // A regular file where the link folder should be: creating the link fails.
        try FileManager.default.removeItem(at: rig.liveLink.deletingLastPathComponent())
        try Data("blocker".utf8).write(to: rig.liveLink.deletingLastPathComponent())
        let live = try await rig.begin(.call, at: Self.t0)  // ASSUMPTION: a failed link is logged and skipped, beginLive still returns the file
        await rig.add(live, sampleLines[0])
        #expect(try readDoc(live.url).lines == [sampleLines[0]])
        let errors = await rig.errorEvents()
        #expect(!errors.isEmpty)
    }
}
