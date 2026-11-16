// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 2b, retry and resume (A.10, R-062, R-039, R-022, B.4): an after-run that fails (network, quota, empty result)
// is tried again exactly once when it can run; an app restart in the middle of a recording, of an after-run, of a
// dictation or of an import resumes without a double and without a loss. Panotti gave up silently after three
// tries; no test here lets a job disappear.
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQDevices
@testable import FlowIQRecording
@testable import FlowIQStore

/// An after-run service that never answers: the process dies while it waits.
private actor HangingPost: PostProcessor {
    nonisolated let name = "hanging"
    func process(_ job: PostJob) async throws -> PostTranscript {
        try await Task.sleep(for: .seconds(3_600))
        throw PostFailure.networkDown
    }
}

private actor Counter {
    private(set) var calls = 0
    func next() -> Int {
        calls += 1
        return calls
    }
}

@Suite(.timeLimit(.minutes(3)))
struct WiederholenTests {
    // MARK: Nachlauf scheitert

    /// R-062: the failure leaves the job in the durable queue, the sign at the pill and menu (`waiting`), the
    /// word `wartet` in the file and the local text intact; the return of the network runs it, once, and never
    /// again. Nothing unread is deleted, the log never carries a word of the call.
    @Test(arguments: [RecordingMode.call, .room], [PostFailure.networkDown, .server(status: 503)])
    func aFailedAftercareIsTriedAgainExactlyOnceWhenItCanRun(_ mode: RecordingMode, _ failure: PostFailure) async throws {
        let post = FakePost(script: [.fail(failure)])
        let rig = try PostRig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await rig.record(mode)

        var doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "live-lokal" && doc.value("nachlauf") == "wartet")
        #expect(doc.contributions.count == sampleLines.count, "the local text is intact")
        #expect(await rig.visible() == .waiting(count: 1))
        #expect(await rig.pending() == 1)
        #expect(try String(contentsOf: rig.queueFile, encoding: .utf8).split(separator: "\n").count == 1)
        #expect(await post.callCount == 1)

        rig.clock.advance(30)
        await rig.trigger(.timer)
        #expect(await post.callCount == 1, "30 s is before the first wait of 60 s")

        await rig.trigger(.networkBack)
        #expect(await post.callCount == 2)
        doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(await rig.visible() == .idle)
        #expect(await rig.pending() == 0)

        for trigger in [AftercareTrigger.networkBack, .click, .appStart, .timer] { await rig.trigger(trigger) }
        rig.clock.advance(7_200)
        await rig.trigger(.timer)
        #expect(await post.callCount == 2, "a finished job is never run a third time")

        let jobs = await post.seen
        #expect(jobs.count == 2 && jobs.allSatisfy { $0.audio.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } })
        #expect(jobs.allSatisfy { $0.mode == mode })
        for event in await rig.events() {
            #expect(!event.fields.values.contains { $0.contains("Guten Morgen") }, "a word of the call in the protocol")
        }
    }

    /// Quota empty or key missing: `angehalten`, a click or the next day tries again, the network coming back
    /// does not (the quota is the same).
    @Test(arguments: [PostFailure.quotaExhausted, .keyMissing])
    func quotaOrKeyPausesTheJobUntilAClickOrTheNextDay(_ failure: PostFailure) async throws {
        for byClick in [true, false] {
            let post = FakePost(script: [.fail(failure)])
            let rig = try PostRig.make(post: post)
            defer { rig.remove() }
            let (live, _) = try await rig.record(.call)
            #expect(await rig.visible() == .paused(count: 1))
            #expect(try readDoc(live.url).value("nachlauf") == "angehalten")

            await rig.trigger(.networkBack)
            #expect(await post.callCount == 1, "the network is not what a paused job waits for")
            if byClick {
                await rig.trigger(.click)
            } else {
                rig.clock.advance(86_401)
                await rig.trigger(.timer)
            }
            #expect(await post.callCount == 2)
            #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
            #expect(await rig.pending() == 0)
        }
    }

    /// An empty result three times in a row stops the automatic tries (1 min, 5 min, then the job waits for a
    /// click); the file keeps its local text until a try brings a real result.
    @Test func anEmptyResultThreeTimesWaitsForAClick() async throws {
        let empty = Outcome.success([], speakers: 0)
        let post = FakePost(script: [empty, empty, empty])
        let rig = try PostRig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await rig.record(.room)
        #expect(await post.callCount == 1)
        #expect(await rig.visible() == .waiting(count: 1))

        rig.clock.advance(61)
        await rig.trigger(.timer)
        #expect(await post.callCount == 2)
        rig.clock.advance(301)
        await rig.trigger(.timer)
        #expect(await post.callCount == 3)
        #expect(await rig.visible() == .paused(count: 1))
        #expect(try readDoc(live.url).value("nachlauf") == "angehalten")
        #expect(try readDoc(live.url).contributions.count == sampleLines.count)

        rig.clock.advance(10_000_000)
        await rig.trigger(.timer)
        #expect(await post.callCount == 3, "after three empty results only a click tries again")
        await rig.trigger(.click)
        #expect(await post.callCount == 4)
        #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
    }

    // MARK: App-Neustart mitten in Aufnahme, Nachlauf, Diktat, Import

    /// R-039, Z-11: a killed app leaves a call folder with torn tracks and a live file with an open sentence.
    /// At the next start the tracks are repacked and delivered (at most 2 s lost), the live file is rebuilt with
    /// the open sentence kept; a second start finds nothing and makes no copy.
    @Test func anAppRestartInTheMiddleOfACallRescuesTheAudioAndTheLiveFileOnce() async throws {
        let before = try PostRig.make()
        defer { before.remove() }
        let folder = try await writeTornCall(fs: before.fs, log: before.log, laufend: before.paths.laufend,
                                             stamp: "2026-11-13 10-00-00", seconds: 60)
        let live = try await before.store.beginLive(kind: .call, startedAt: before.clock.now, language: "de",
                                                    liveSource: .appleLocal, audio: folder)  // ASSUMPTION: beginLive(kind:startedAt:language:liveSource:audio:)
        for l in sampleLines { await live.append(seconds: l.seconds, speaker: l.speaker, text: l.text) }
        await live.setVolatile(seconds: 70, speaker: "Mara", text: "mitten im satz")  // ASSUMPTION: LiveTranscript.setVolatile(seconds:speaker:text:)
        // the process dies here: nothing is stopped, nothing is closed

        for run in 1...2 {
            let after = try before.restarted(post: FakePost())  // a fresh process on the same folders
            let report = try await Rescue.run(laufend: after.paths.laufend, deliverTo: after.archiveAudio, fs: after.fs, log: after.log)
            let rebuilt = try await after.store.recoverOrphans()
            if run == 1 {
                #expect(report.rescuedTracks.count == 2 && report.failed.isEmpty)
                for track in report.rescuedTracks {
                    let playable = try audioDuration(track.url)
                    #expect(playable >= 58 && playable <= 60.5)
                }
                let file = try #require(rebuilt.first)
                #expect(rebuilt.count == 1 && file.path == live.url.path)
                let doc = try readDoc(file)
                #expect(doc.value("panotti_phase") == "recovered-wal" && doc.value("status") == "unverarbeitet")
                #expect(doc.value("nachlauf") == "aus")
                #expect(doc.contributions.count == sampleLines.count + 1, "the open sentence is kept as a contribution")
                #expect(doc.value("quelle")?.contains(folder.lastPathComponent) == true)
            } else {
                #expect(report.rescuedTracks.isEmpty && rebuilt.isEmpty, "a second start makes no second rescue")
            }
            #expect(after.transcriptFiles.count == 1)
            #expect(names(in: after.archiveAudio) == [folder.lastPathComponent])
            #expect(names(in: after.paths.laufend).filter { $0.hasPrefix("live-") }.isEmpty)
        }
    }

    /// The app dies while the after-run waits for the service: the job is in the queue file, the next start
    /// finds it, runs it once, and the transcript is upgraded once, not twice.
    @Test func anAppRestartInTheMiddleOfTheAftercareRunsTheJobOnceAfterwards() async throws {
        let first = try PostRig.make(post: HangingPost())
        defer { first.remove() }
        let (live, _) = try await first.record(.call, settle: false)
        #expect(await eventually { await first.pending() == 1 })
        #expect(try String(contentsOf: first.queueFile, encoding: .utf8).split(separator: "\n").count == 1)
        #expect(try readDoc(live.url).value("nachlauf") == "wartet")

        let service = FakePost()
        let second = try first.restarted(post: service)
        #expect(await second.pending() == 1)
        #expect(await second.visible() == .waiting(count: 1))
        await second.trigger(.appStart)
        #expect(await service.callCount == 1)
        #expect(try readDoc(live.url).value("panotti_phase") == "final-elevenlabs")
        #expect(await second.pending() == 0 && second.transcriptFiles.count == 1)
        await second.trigger(.appStart)
        #expect(await service.callCount == 1)
    }

    /// R-022: a dictation cut off in the middle leaves audio that plays up to about a second before the end and
    /// a journal entry that says it began and never finished; the retry over the spool file brings text.
    @Test func aDictationCutOffInTheMiddleLeavesAudioAndAJournalEntryToRetryFrom() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.press()
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) })
        await rig.play(2.0)
        // the process dies here: the state on disk is what the next start finds
        let id = try #require(rig.scratch.dictationIDs().first)
        #expect(rig.scratch.journal(of: id).map(\.event) == ["begin"], "begun, never recognized, never inserted")
        let file = try #require(rig.scratch.audioFile(for: id))
        #expect(fileSize(file) >= 8_000)  // at 64 kbit/s one second is 8,000 bytes
        #expect(try audioDuration(file) >= 1.0, "at most a second of the dictation is lost")
        let again = await rig.recognizer.recognizeFile(file)
        #expect(again.recognition?.text == "aus der datei")  // ASSUMPTION: the retry at the next start is `recognizeFile` over the spool file; no code starts it yet (README)

        await rig.release()  // let the rig end properly
        await rig.play(0.11, step: 0.01)
        #expect(await rig.settle())
    }

    /// B.4: the app dies while a pen file is being copied: nothing counts as imported, the next start imports
    /// the file once, the archive holds exactly the device's bytes.
    @Test func anAppRestartInTheMiddleOfTheCopyImportsTheFileOnce() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let devices = try DeviceRig(scratch: scratch)
        let source = try devices.put("probe-1.wav", DeviceRig.wav(seconds: 40, seed: 3))  // about 1.2 MB: twenty blocks
        let hang = Counter()
        let gate = ThrottleGate(pause: .milliseconds(5)) { () -> Set<BusyState.Reason> in
            if await hang.next() > 4 { _ = try? await Task.sleep(for: .seconds(3_600)) }  // the third block never finishes
            return []
        }
        let first = try await devices.importer(gate: gate)
        let dying = Task { await first.scan() }
        defer { dying.cancel() }
        #expect(await eventually { await hang.calls > 4 })

        #expect(devices.archived().isEmpty, "a half copy is in the archive")
        #expect(await first.entries().isEmpty, "a half copy counts as imported")

        let second = try await devices.importer()
        let report = await second.scan()
        #expect(report.imported == 1 && report.failed == 0)
        let archived = devices.archived()
        #expect(archived.count == 1)
        #expect(try DeviceRig.sha(devices.archive.appending(path: archived[0])) == DeviceRig.sha(source))
        #expect(await second.entries().map(\.phase) == [.done])
        #expect(await devices.filing.state.filed.count == 1)
        #expect(await second.scan().imported == 0)
    }

    /// B.4 step 4: the app dies while the copy is being recognized: the next start recognizes the local copy,
    /// does not copy again and files once.
    @Test func anAppRestartInTheMiddleOfTheRecognitionDoesNotCopyAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let devices = try DeviceRig(scratch: scratch)
        try devices.put("probe-1.wav", DeviceRig.wav(seconds: 5, seed: 4))
        await devices.transcriber.state.onCall { _ in _ = try? await Task.sleep(for: .seconds(3_600)) }  // the first process hangs here
        let first = try await devices.importer()
        let dying = Task { await first.scan() }
        defer { dying.cancel() }
        #expect(await eventually { await devices.transcriber.state.calls.count == 1 })
        let archivedBefore = devices.archived()
        #expect(archivedBefore.count == 1)
        #expect(await first.entries().map(\.phase) == [.copied])

        await devices.transcriber.state.onCall(nil)
        let second = try await devices.importer()
        #expect(await second.scan().imported == 1)
        #expect(devices.archived() == archivedBefore, "the copy was made again")
        #expect(await second.entries().map(\.phase) == [.done])
        #expect(await devices.filing.state.filed.count == 1)
    }
}
