// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 5: failed aftercare (R-062, Z-11, A.10 queue). Network gone, quota empty, key missing, server
// errors: each leaves an entry in the durable queue, a visible sign (pill or menu state plus `nachlauf:` in the
// file), and a retry on its own. Panotti gave up silently after three tries; no test here lets that happen.
import Foundation
import Testing
@testable import FlowIQCore  // COMPILE-FIX (P5 build): the file names PostFailure (Core, M.2) without importing its module
@testable import FlowIQStore  // COMPILE-FIX (P5 build): the file names LiveTranscript without importing its module

struct FailureQueueTests {
    static let t0 = localDate(2026, 11, 13, 10, 45)
    static let remote = [Line(seconds: 0, speaker: "Mara", text: "Dienstfassung.")]

    private func record(_ rig: Rig, seconds: Double = 60) async throws -> (LiveTranscript, URL) {
        let live = try await rig.begin(.call, at: Self.t0)
        for l in sampleLines { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: seconds)
        try await rig.finish(live, seconds: seconds, raw: item)
        return (live, item)
    }

    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let failure: PostFailure
        let nachlauf: String
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "network down", failure: .networkDown, nachlauf: "wartet"),
        Case(name: "server 500", failure: .server(status: 500), nachlauf: "wartet"),
        Case(name: "quota empty", failure: .quotaExhausted, nachlauf: "angehalten"),
        Case(name: "key missing", failure: .keyMissing, nachlauf: "angehalten"),
    ]

    /// R-062: entry in the queue, sign at pill or menu, `nachlauf:` in the file, local text intact (3 of 3 kinds, plus 500).
    @Test(arguments: cases)
    func failureIsQueuedVisibleAndKeepsTheLocalText(_ c: Case) async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(c.failure)))
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "live-lokal")
        #expect(doc.value("status") == "unverarbeitet")
        #expect(doc.value("nachlauf") == c.nachlauf)
        #expect(doc.lines == sampleLines)
        #expect(await rig.pending() == 1)
        let state = await rig.visible()
        #expect(state == (c.nachlauf == "wartet" ? .waiting(1) : .paused(1)))
        let queueText = try String(contentsOf: rig.queueFile, encoding: .utf8)
        #expect(queueText.split(separator: "\n").count == 1)  // the durable queue holds exactly this job
        let errors = await rig.errorEvents()
        #expect(!errors.isEmpty)  // logged, not swallowed
    }

    /// The failure itself must never carry text or paths into the file header beyond the fixed values.
    @Test(arguments: cases)
    func nachlaufValueIsOneOfTheDocumentedWords(_ c: Case) async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(c.failure)))
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        #expect(["wartet", "angehalten", "aus"].contains(try readDoc(live.url).value("nachlauf") ?? "-"))
    }

    // MARK: audio is never lost on failure

    /// Panotti kept the audio in raw/ until success and the file hung. Here the audio is in the archive at once
    /// and exists exactly once, so the job can still upload it later.
    @Test(arguments: cases)
    func audioMovesToTheArchiveEvenWhenTheServiceFails(_ c: Case) async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(c.failure)))
        defer { rig.remove() }
        let (live, item) = try await record(rig)
        let place = rig.locations(of: item)
        #expect(place.inArchive && !place.inRaw)  // ASSUMPTION: audio goes to the archive at stop whether or not the upload worked; the job reads it from there
        #expect(rig.names(in: rig.raw).isEmpty)
        let quelle = try #require(try readDoc(live.url).value("quelle"))
        #expect(FileManager.default.fileExists(atPath: quelle))  // ASSUMPTION: quelle is a plain path, also in live-lokal, and points at the audio's current place
    }

    @Test func retryUploadsFromTheArchivedFilesAndFinishesTheJob() async throws {
        let post = FakePost(script: [.fail(.networkDown), .success(Self.remote, speakers: 1)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, item) = try await record(rig)
        rig.clock.advance(61)
        await rig.trigger(.timer)
        let seen = await post.seen
        #expect(seen.count == 2)
        #expect(seen[1].audioExisted == [true, true])
        #expect(seen[1].audio.allSatisfy { $0.resolvingSymlinksInPath().path.hasPrefix(rig.archiveAudio.resolvingSymlinksInPath().path) })  // ASSUMPTION: the retry reads the archived copy
        #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
        #expect(rig.locations(of: item) == (inRaw: false, inArchive: true))
    }

    // MARK: schedule (A.10: 1, 5, 15, 60 minutes, then hourly)

    @Test func retriesFollowTheDocumentedWaitTimes() async throws {
        let post = FakePost(script: Array(repeating: .fail(.networkDown), count: 6), fallback: .success(Self.remote, speakers: 1))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        _ = try await record(rig)
        func calls() async -> Int { await post.callCount }
        #expect(await calls() == 1)  // the attempt at stop
        // Wait 1 minute.
        rig.clock.advance(59); await rig.trigger(.timer)
        #expect(await calls() == 1)
        rig.clock.advance(1); await rig.trigger(.timer)
        #expect(await calls() == 2)
        // Wait 5 minutes.
        rig.clock.advance(299); await rig.trigger(.timer)
        #expect(await calls() == 2)
        rig.clock.advance(1); await rig.trigger(.timer)
        #expect(await calls() == 3)
        // Wait 15 minutes.
        rig.clock.advance(899); await rig.trigger(.timer)
        #expect(await calls() == 3)
        rig.clock.advance(1); await rig.trigger(.timer)
        #expect(await calls() == 4)
        // Wait 60 minutes, then every hour.
        rig.clock.advance(3599); await rig.trigger(.timer)
        #expect(await calls() == 4)
        rig.clock.advance(1); await rig.trigger(.timer)
        #expect(await calls() == 5)
        rig.clock.advance(3599); await rig.trigger(.timer)
        #expect(await calls() == 5)
        rig.clock.advance(1); await rig.trigger(.timer)
        #expect(await calls() == 6)
        rig.clock.advance(3600); await rig.trigger(.timer)  // seventh try succeeds
        #expect(await calls() == 7)
        #expect(await rig.pending() == 0)
    }

    /// Never given up: after many failures the job is still there, still visible, the file still says wartet.
    @Test func manyFailuresNeverDropTheJob() async throws {
        let post = FakePost(script: [], fallback: .fail(.networkDown))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, item) = try await record(rig)
        for _ in 0..<40 {
            rig.clock.advance(3600)
            await rig.trigger(.timer)
        }
        #expect(await post.callCount >= 20)  // keeps trying (not stopping after 3, Panotti's bug)
        #expect(await rig.pending() == 1)
        #expect(await rig.visible() == .waiting(1))
        let doc = try readDoc(live.url)
        #expect(doc.value("nachlauf") == "wartet")
        #expect(doc.lines == sampleLines)
        #expect(rig.locations(of: item).inArchive)
    }

    /// After a long outage the first success finishes the file; no leftover marker.
    @Test func recoveryAfterLongOutageClearsTheMarker() async throws {
        let post = FakePost(script: Array(repeating: .fail(.networkDown), count: 12), fallback: .success(Self.remote, speakers: 1))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        for _ in 0..<12 {
            rig.clock.advance(3600)
            await rig.trigger(.timer)
        }
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(doc.value("nachlauf") == nil)
        #expect(await rig.pending() == 0)
        #expect(await rig.visible() == .idle)
    }

    // MARK: triggers

    @Test func networkBackRetriesAtOnce() async throws {
        let post = FakePost(script: [.fail(.networkDown)], fallback: .success(Self.remote, speakers: 1))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        rig.clock.advance(10)  // far inside the 1-minute wait
        await rig.trigger(.networkBack)  // ASSUMPTION: "network back" ignores the wait time, it is the point of the trigger
        #expect(await post.callCount == 2)
        #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
    }

    @Test func clickRetriesAtOnce() async throws {
        let post = FakePost(script: [.fail(.server(status: 503))], fallback: .success(Self.remote, speakers: 1))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        _ = try await record(rig)
        rig.clock.advance(1)
        await rig.trigger(.click)
        #expect(await post.callCount == 2)
        #expect(await rig.pending() == 0)
    }

    /// Without any trigger and without time passing, nothing is retried (no busy loop).
    @Test func noTriggerNoRetry() async throws {
        let post = FakePost(script: [], fallback: .fail(.networkDown))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        _ = try await record(rig)
        await rig.trigger(.timer)
        await rig.trigger(.timer)
        #expect(await post.callCount == 1)
    }

    // MARK: quota and key (paused)

    @Test(arguments: [PostFailure.quotaExhausted, PostFailure.keyMissing])
    func pausedJobsWaitForClickOrNextDay(_ failure: PostFailure) async throws {
        let post = FakePost(script: [.fail(failure)], fallback: .success(Self.remote, speakers: 1))
        let rig = try Rig.make(post: post, start: localDate(2026, 11, 13, 10, 0))
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        #expect(await post.callCount == 1)
        rig.clock.advance(3600); await rig.trigger(.timer)
        rig.clock.advance(4 * 3600); await rig.trigger(.timer)
        await rig.trigger(.networkBack)  // the network is not the problem
        #expect(await post.callCount == 1)
        #expect(try readDoc(live.url).value("nachlauf") == "angehalten")
        #expect(await rig.visible() == .paused(1))
        rig.clock.advance(20 * 3600)  // now more than a day after the stop
        await rig.trigger(.timer)
        #expect(await post.callCount == 2)  // ASSUMPTION: "next day" means within 25 h of the stop here, whatever the calendar rule
        #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
    }

    @Test(arguments: [PostFailure.quotaExhausted, PostFailure.keyMissing])
    func clickRetriesPausedJobAtOnce(_ failure: PostFailure) async throws {
        let post = FakePost(script: [.fail(failure)], fallback: .success(Self.remote, speakers: 1))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        _ = try await record(rig)
        await rig.trigger(.click)
        #expect(await post.callCount == 2)
        #expect(await rig.pending() == 0)
    }

    @Test func quotaStillEmptyOnClickStaysPausedAndVisible() async throws {
        let post = FakePost(script: [], fallback: .fail(.quotaExhausted))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        await rig.trigger(.click)
        await rig.trigger(.click)
        #expect(await rig.pending() == 1)
        #expect(await rig.visible() == .paused(1))
        #expect(try readDoc(live.url).value("nachlauf") == "angehalten")
    }

    /// A job that waits turns into a paused one when the failure kind changes, and the file follows.
    @Test func failureKindChangeUpdatesTheMarker() async throws {
        let post = FakePost(script: [.fail(.networkDown), .fail(.quotaExhausted)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        #expect(try readDoc(live.url).value("nachlauf") == "wartet")
        rig.clock.advance(61)
        await rig.trigger(.timer)
        #expect(try readDoc(live.url).value("nachlauf") == "angehalten")
    }

    // MARK: restart

    /// The queue survives a restart; the first trigger after launch finishes the job.
    @Test func jobResumesAfterRestart() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.networkDown)))
        defer { rig.remove() }
        let (live, item) = try await record(rig)
        #expect(FileManager.default.fileExists(atPath: rig.queueFile.path))
        let post2 = FakePost(script: [.success(Self.remote, speakers: 1)])
        let again = try rig.restarted(post: post2)
        #expect(await again.pending() == 1)
        #expect(await again.visible() == .waiting(1))  // visible right after launch, before any attempt
        rig.clock.advance(5)
        await again.trigger(.appStart)  // ASSUMPTION: app start retries at once, ignoring the wait time (A.10 trigger list)
        #expect(await post2.callCount == 1)
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(doc.value("nachlauf") == nil)
        #expect(doc.lines == Self.remote)
        #expect(await again.pending() == 0)
        #expect(again.locations(of: item) == (inRaw: false, inArchive: true))
        #expect(rig.transcriptFiles.count == 1)
    }

    @Test func pausedJobStaysPausedAndVisibleAfterRestart() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.quotaExhausted)))
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        let post2 = FakePost(script: [], fallback: .fail(.quotaExhausted))
        let again = try rig.restarted(post: post2)
        #expect(await again.visible() == .paused(1))
        #expect(try readDoc(live.url).value("nachlauf") == "angehalten")
    }

    /// Several jobs, restart, all of them come back and finish, in their own files.
    @Test func fiveJobsSurviveARestartAndFinishInPlace() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.networkDown)))
        defer { rig.remove() }
        var urls: [URL] = []
        for n in 0..<5 {
            let when = localDate(2026, 11, 13, 9, n * 7)
            let live = try await rig.begin(.room, at: when)
            await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Satz \(n)"))
            let item = try rig.makeRaw(.room, at: when, seconds: 30)
            try await rig.finish(live, seconds: 30, raw: item)
            urls.append(live.url)
        }
        let post2 = FakePost()
        let again = try rig.restarted(post: post2)
        #expect(await again.pending() == 5)
        await again.trigger(.appStart)  // ASSUMPTION: app start retries at once, ignoring the wait time
        #expect(await post2.callCount == 5)
        #expect(await again.pending() == 0)
        for url in urls { #expect(try readDoc(url).value("panotti_phase") == "final-elevenlabs") }
        #expect(rig.transcriptFiles.count == 5)
    }

    /// A damaged last queue line (crash while writing) does not take the other jobs with it.
    @Test func tornLastQueueLineDoesNotLoseOtherJobs() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.networkDown)))
        defer { rig.remove() }
        let (live, _) = try await record(rig)
        let handle = try FileHandle(forWritingTo: rig.queueFile)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
        try handle.close()
        let post2 = FakePost(script: [.success(Self.remote, speakers: 1)])
        let again = try rig.restarted(post: post2)
        #expect(await again.pending() == 1)
        await again.trigger(.appStart)
        #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
    }

    // MARK: nothing silent

    /// Z-11: whatever happens, a file below an end phase is visible in the queue (`nachlauf:` set and queue entry).
    @Test func noHangingFileWithoutAMarkerAndAnEntry() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.networkDown)))
        defer { rig.remove() }
        for n in 0..<4 {
            let when = localDate(2026, 11, 13, 9, n * 9)
            let live = try await rig.begin(n % 2 == 0 ? .call : .room, at: when)
            await rig.add(live, sampleLines[0])
            let item = try rig.makeRaw(n % 2 == 0 ? .call : .room, at: when, seconds: 20)
            try await rig.finish(live, seconds: 20, raw: item)
        }
        var hanging = 0
        for url in rig.transcriptFiles {
            let doc = try readDoc(url)
            if !(doc.value("panotti_phase") ?? "").hasPrefix("final-") {
                hanging += 1
                #expect(["wartet", "angehalten"].contains(doc.value("nachlauf") ?? "-"))
            }
        }
        #expect(hanging == 4)
        #expect(await rig.pending() == hanging)  // as many entries as hanging files
    }

    /// Errors reach the log with the failure kind, not text from the recording (A.2: no free text).
    @Test func failureIsLoggedWithoutTranscriptText() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.quotaExhausted)))
        defer { rig.remove() }
        _ = try await record(rig)
        let errors = await rig.errorEvents()
        #expect(!errors.isEmpty)
        let dump = String(decoding: try JSONSerialization.data(withJSONObject: errors), as: UTF8.self)
        for line in sampleLines { #expect(!dump.contains(line.text)) }
    }
}
