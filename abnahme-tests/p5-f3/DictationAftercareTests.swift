// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-9: the after-run of a dictation (ARCHITEKTUR M.1, F3-13, R-108, R-067 new wording; Anhang I additions to
// `AftercareTests` and `FailureQueueTests`). Default ON (leadership decision, as in Panotti). Exactly one upload per
// dictation, not before the insertion; the result goes only to the history and to the proposal source; the inserted
// text is never changed. Switch off: 0 uploads. A failing service puts the job into the same queue as every other job;
// the queue never holds dictation text.
import Foundation
import Testing
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQStore

@Suite(.timeLimit(.minutes(4)))
struct DictationAftercareTests {
    private func answer(_ text: String) -> Outcome { .success([Line(seconds: 0, speaker: "Mara", text: text)], speakers: 1) }

    @Test func withTheSwitchOnEveryDictationIsUploadedExactlyOnceAfterTheInsertion() async throws {
        let batch = FakeBatch(fallback: answer("Ergebnis des Nachlaufs."))
        let rig = try await StoreRig.make(batch: batch)
        defer { rig.remove() }
        for i in 0..<100 {
            #expect(await batch.callCount == i, "an upload started before dictation \(i) was inserted")
            _ = try await rig.dictationInserted(id: "d-\(i)", text: "Eingefügter Satz \(i).")  // ASSUMPTION: assumed API, see the Support header
        }
        #expect(await batch.callCount == 100, "100 of 100 dictations: one upload each")
        #expect(await batch.seen.allSatisfy { $0.mode == .dictation && $0.language == "de" && $0.audio.count == 1 })
    }

    @Test func withTheSwitchOffNothingIsEverUploaded() async throws {
        let batch = FakeBatch()
        let rig = try await StoreRig.make(batch: batch, post: [.dictation: false, .call: true, .room: true, .device: true])
        defer { rig.remove() }
        for i in 0..<100 { _ = try await rig.dictationInserted(id: "d-\(i)", text: "Satz \(i).") }  // ASSUMPTION: assumed API, see the Support header
        #expect(await batch.callCount == 0)
        #expect(await rig.queue.count == 0)
        #expect(await rig.visible() == .idle)
        #expect(!(await rig.usage.hasAnyUsage), "nothing was sent, so nothing is counted")  // ASSUMPTION: UsageMeter.hasAnyUsage
    }

    @Test func theSwitchCanBeChangedAtRunTime() async throws {
        let batch = FakeBatch(fallback: answer("x"))
        let rig = try await StoreRig.make(batch: batch)
        defer { rig.remove() }
        _ = try await rig.dictationInserted(id: "a", text: "Eins.")  // ASSUMPTION: assumed API, see the Support header
        await rig.aftercare.setPostEnabled(false, for: .dictation)  // ASSUMPTION: setPostEnabled(_:for:) per mode (the Settings table)
        _ = try await rig.dictationInserted(id: "b", text: "Zwei.")  // ASSUMPTION: assumed API, see the Support header
        await rig.aftercare.setPostEnabled(true, for: .dictation)  // ASSUMPTION: assumed API, see the Support header
        _ = try await rig.dictationInserted(id: "c", text: "Drei.")  // ASSUMPTION: assumed API, see the Support header
        #expect(await batch.callCount == 2)
    }

    @Test func theResultGoesToTheHistoryOnlyAndNeverTouchesTheInsertedText() async throws {
        let batch = FakeBatch(fallback: answer("Besser erkannter Satz."))
        let rig = try await StoreRig.make(batch: batch)
        defer { rig.remove() }
        _ = try await rig.dictationInserted(id: "d-1", text: "Eingefügter Satz.")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.aftercare.dictationResult(id: "d-1") == "Besser erkannter Satz.")  // ASSUMPTION: dictationResult(id:) is the history entry of the after-run text
        #expect(rig.transcriptFiles.isEmpty, "a dictation never becomes a vault transcript")
        #expect(await rig.aftercare.insertedText(id: "d-1") == "Eingefügter Satz.", "the text that was inserted stays on record, unchanged")  // ASSUMPTION: insertedText(id:)
    }

    @Test func theAfterRunTextPassesTheStageButTheInsertedTextIsNotReplaced() async throws {
        let known = entry("NapIQ", variants: [variant("napik", status: .active)])
        let batch = FakeBatch(fallback: answer("das ist napik"))
        let rig = try await StoreRig.make(batch: batch, lexicon: [known])
        defer { rig.remove() }
        _ = try await rig.dictationInserted(id: "d-2", text: "das ist napik")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.aftercare.dictationResult(id: "d-2") == "das ist NapIQ", "the stage runs on the after-run result too")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.aftercare.insertedText(id: "d-2") == "das ist napik")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func dictationsFeedTheProposalSourceLikeEveryOtherAfterRun() async throws {
        let batch = FakeBatch(script: [answer("das ist NapIQ gut"), answer("das ist NapIQ gut")])
        let rig = try await StoreRig.make(batch: batch, lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        rig.clock.set(localDate(2026, 11, 10, 9, 0))  // ASSUMPTION: assumed API, see the Support header
        _ = try await rig.dictationInserted(id: "d-3", text: "das ist napik gut")  // ASSUMPTION: assumed API, see the Support header
        rig.clock.set(localDate(2026, 11, 11, 9, 0))  // ASSUMPTION: assumed API, see the Support header
        _ = try await rig.dictationInserted(id: "d-4", text: "das ist napik gut")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.ledger.suggestions().map(\.heard) == ["napik"])  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.lexicon.entries().first?.hearingVariants.isEmpty == true, "still no rule without a click")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func theAudioIsReadFromTheDictationFolderAndKept() async throws {
        let batch = FakeBatch(fallback: answer("x"))
        let rig = try await StoreRig.make(batch: batch)
        defer { rig.remove() }
        let audio = try await rig.dictationInserted(id: "d-5", text: "Satz.")  // ASSUMPTION: assumed API, see the Support header
        #expect(await batch.seen.first?.audio == [audio])
        #expect(FileManager.default.fileExists(atPath: audio.path), "the dictation audio stays where it is (R-022, no deletion)")
    }

    // MARK: failures use the same queue

    @Test func aFailingServiceQueuesTheDictationJobAndTheNetworkReturnRunsIt() async throws {
        let batch = FakeBatch(script: [.fail(.networkDown)], fallback: answer("Nachlauf."))  // ASSUMPTION: assumed API, see the Support header
        let rig = try await StoreRig.make(batch: batch)
        defer { rig.remove() }
        _ = try await rig.dictationInserted(id: "d-6", text: "Satz sechs.")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.queue.count == 1)
        #expect(await rig.visible() == .waiting(1))
        await rig.trigger(.networkBack)
        #expect(await rig.queue.count == 0)
        #expect(await batch.callCount == 2)
        #expect(await rig.visible() == .idle)
    }

    @Test func quotaOrKeyProblemsPauseTheDictationQueueWithoutLosingTheJob() async throws {
        for failure in [PostFailure.quotaExhausted, .keyMissing] {
            let batch = FakeBatch(script: [.fail(failure)], fallback: answer("ok"))
            let rig = try await StoreRig.make(batch: batch)
            defer { rig.remove() }
            _ = try await rig.dictationInserted(id: "d-7", text: "Satz sieben.")  // ASSUMPTION: assumed API, see the Support header
            #expect(await rig.visible() == .paused(1), "\(failure)")
            await rig.trigger(.click)
            #expect(await rig.queue.count == 0, "\(failure): the click must run the job")
        }
    }

    @Test func theQueueNeverHoldsDictationTextAndTheProtocolIsTextFree() async throws {
        let batch = FakeBatch(script: [.fail(.networkDown)], fallback: answer("ok"))  // ASSUMPTION: assumed API, see the Support header
        let rig = try await StoreRig.make(batch: batch)
        defer { rig.remove() }
        _ = try await rig.dictationInserted(id: "d-8", text: "Zitronenfalter im Schnee.")  // ASSUMPTION: assumed API, see the Support header
        let queue = (try? String(contentsOf: rig.queueFile, encoding: .utf8)) ?? ""
        #expect(!queue.isEmpty, "the job must be on disk")
        #expect(!queue.contains("Zitronenfalter"), "dictation text in the queue file")
        #expect(!(await rig.logText()).contains("Zitronenfalter"))
    }

    @Test func aJobWaitingInTheQueueSurvivesARestart() async throws {
        let batch = FakeBatch(script: [.fail(.networkDown)])  // ASSUMPTION: assumed API, see the Support header
        let rig = try await StoreRig.make(batch: batch)
        defer { rig.remove() }
        _ = try await rig.dictationInserted(id: "d-9", text: "Satz neun.")  // ASSUMPTION: assumed API, see the Support header
        let reopened = try await StoreRig.reopen(rig, batch: FakeBatch(fallback: answer("jetzt")))  // ASSUMPTION: a fresh process on the same folders: new queue, new aftercare, new transcriber
        #expect(await reopened.queue.count == 1)
        await reopened.trigger(.appStart)
        #expect(await reopened.queue.count == 0)
        #expect(await reopened.batch.callCount == 1)
    }
}
