import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQStore
@testable import FlowIQText

/// Paket G (16.11.): a new key starts refused after-runs again, a kept dictation and a finished recording go
/// through ElevenLabs once more on a click. Invented text only, an artificial service, a scratch folder per test.
struct RenewTests {
    typealias Rig = AftercareReviewTests.Rig

    /// The artificial service: one text or one failure, and what it was asked.
    actor Scribe: PostProcessor {
        nonisolated let name = "test"
        let text: String, failure: PostFailure?
        var jobs: [PostJob] = []
        init(_ text: String, failure: PostFailure? = nil) { (self.text, self.failure) = (text, failure) }
        func process(_ job: PostJob) async throws -> PostTranscript {
            jobs.append(job)
            if let failure { throw failure }
            return PostTranscript(segments: [PostSegment(start: 0, speaker: "Ich", text: text)], speakersDetected: 1)
        }
    }
    actor Usage: CloudUsage {
        let full: Bool
        var seconds = 0.0
        init(full: Bool = false) { self.full = full }
        func record(_ source: UsageSource, _ kind: UsageKind, seconds: Double) { self.seconds += seconds }
        var limitReached: Bool { full }
    }
    struct Bench {
        let rig: Rig, lexicon: LexiconStore, ledger: CorrectionLedger, scribe: Scribe, usage: Usage, after: Aftercare
        let audio: URL
        var job: DictationJob {
            DictationJob(id: "d1", audio: audio, language: "de", insertedText: "das ist zorbal gut", seconds: 4)
        }
    }
    func bench(_ text: String, failure: PostFailure? = nil, full: Bool = false,
               variants: [HearingVariant] = []) async throws -> Bench {
        let rig = try Rig()
        let lexicon = LexiconStore(folder: rig.root.appending(path: "lexikon"), fs: rig.fs, log: rig.log)
        let ledger = CorrectionLedger(lexicon: lexicon, fs: rig.fs, log: rig.log)
        try await lexicon.seed([CorrectionLoopStoreTests.entry("Sorbal", variants: variants)])
        let scribe = Scribe(text, failure: failure), usage = Usage(full: full)
        let words = FrozenWordSet(german: ["das", "ist", "gut"], english: [])
        let after = Aftercare(store: rig.store, queue: rig.queue, processor: scribe, postEnabled: [:], usage: usage,
                              ledger: ledger, textStage: {
                                  TextStage(lexicon: await lexicon.snapshot(), protection: words,
                                            config: TextStageConfig())
                              }, confirmedTerms: { ["Sorbal"] })
        let audio = rig.root.appending(path: "d1.aac")
        try Data(repeating: 1, count: 32).write(to: audio)
        return Bench(rig: rig, lexicon: lexicon, ledger: ledger, scribe: scribe, usage: usage, after: after,
                     audio: audio)
    }

    // MARK: 4, the queue after a new key

    @Test func aNewKeyStartsARefusedJobOnceWithoutAClick() async throws {
        let why = "400 invalid_api_key"
        let rig = try Rig([.rejected(why), .rejected(why), nil])
        defer { rig.remove() }
        let file = try await rig.room()
        #expect(await rig.post.calls == 1)
        #expect(await rig.aftercare.rejection == why)
        await rig.later(1, .newKey)
        #expect(await rig.post.calls == 2, "the new key starts it, no click")
        #expect(await rig.aftercare.rejection == why)
        #expect(await rig.aftercare.visibleState == .paused(count: 1))
        for trigger in [AftercareTrigger.timer, .appStart, .networkBack] { await rig.later(90_000, trigger) }
        #expect(await rig.post.calls == 2, "once per job and key: refused again, it waits again")
        await rig.later(1, .newKey)
        #expect(await rig.post.calls == 3)
        #expect(await rig.aftercare.rejection == nil)
        #expect(try rig.field(file, "panotti_phase") == "final-elevenlabs")
    }

    @Test func aNewKeyAlsoStartsWhatAMissingKeyPausedButNotAJobStuckOnEmptyResults() async throws {
        let rig = try Rig([.keyMissing, nil])
        defer { rig.remove() }
        let file = try await rig.room()
        await rig.later(60, .timer)
        #expect(await rig.post.calls == 1)
        #expect(await rig.aftercare.visibleState == .paused(count: 1))
        await rig.later(1, .newKey)
        #expect(try rig.field(file, "panotti_phase") == "final-elevenlabs")
        let empty = try Rig()  // answers nothing but empty results
        defer { empty.remove() }
        _ = try await empty.room()
        for _ in 0..<6 { await empty.later(4000) }
        let stuck = await empty.post.calls
        await empty.later(1, .newKey)
        #expect(await empty.post.calls == stuck)
        #expect(stuck == Aftercare.emptyLimit)
    }

    // MARK: 2, one dictation once more

    @Test func aDictationIsRecognizedAgainWithLanguageTermsAndUsageAndTheLedgerOnlyCollects() async throws {
        let b = try await bench("das ist Sorbal gut")
        defer { b.rig.remove() }
        let text = try await b.after.redo(b.job)
        #expect(text == "das ist Sorbal gut")
        let asked = try #require(await b.scribe.jobs.first)
        #expect(asked.choice == .elevenLabs && asked.mode == .dictation && asked.language == "de")
        #expect(asked.audio == [b.audio] && asked.terms == ["Sorbal"])
        #expect(await b.usage.seconds == 4)
        #expect(await b.after.dictationResult(id: "d1") == text)
        #expect(await b.rig.queue.count == 0, "nothing waits in the queue")
        // learning as from any after-run: one sighting is a collecting pair, no proposal and no rule yet
        #expect(await b.ledger.openPairs().count == 1)
        #expect(await b.ledger.suggestions().isEmpty)
        #expect((await b.lexicon.entries()).flatMap(\.hearingVariants).isEmpty)
    }

    @Test func theTextStageRunsOverTheNewVersion() async throws {
        let b = try await bench("das ist zorbal gut", variants: [CorrectionLoopStoreTests.variant("zorbal", .active)])
        defer { b.rig.remove() }
        #expect(try await b.after.redo(b.job) == "das ist Sorbal gut")
    }

    @Test func theMonthsLimitHoldsAndAFailedUploadStillCounts() async throws {
        let full = try await bench("egal", full: true)
        defer { full.rig.remove() }
        await #expect(throws: PostFailure.notAllowed) { try await full.after.redo(full.job) }
        #expect(await full.scribe.jobs.isEmpty, "nothing is sent at the limit")
        let down = try await bench("egal", failure: .server(status: 500))
        defer { down.rig.remove() }
        await #expect(throws: PostFailure.server(status: 500)) { try await down.after.redo(down.job) }
        #expect(await down.usage.seconds == 4)
        #expect(await down.after.dictationResult(id: "d1") == nil)
        let key = try await bench("egal", failure: .keyMissing)
        defer { key.rig.remove() }
        await #expect(throws: PostFailure.keyMissing) { try await key.after.redo(key.job) }
        #expect(await key.usage.seconds == 0)
    }

    /// The journal keeps everything: a "renewed" line replaces the shown text, the raw version stays.
    @Test func aRenewedLineReplacesTheShownTextAndKeepsTheRawVersion() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let paths = Paths(profile: .development, applicationSupport: rig.root)
        try rig.fs.makeFolder(paths.diktate)
        let j = DictationJournal(paths: paths, fs: rig.fs, log: rig.log)
        for id in ["d1", "d2"] {
            try await j.append(.recognized(id: id, recognizerText: "das ist zorbal gut",
                                           finalText: "Das ist zorbal gut", interventions: [String]()))
        }
        try await j.append(JournalEntry("renewed", id: "d1", ["final_text": .string("Das ist Sorbal gut.")]))
        let items = await j.history()
        #expect(items.map(\.id) == ["d2", "d1"], "still one row per dictation")
        #expect(items[1].text == "Das ist Sorbal gut." && items[1].rawText == "das ist zorbal gut")
        #expect(items[1].renewed)
        #expect(items[0].text == "Das ist zorbal gut" && !items[0].renewed)
        #expect(await j.history(matching: "Sorbal").map(\.id) == ["d1"])
        #expect(await j.records(limit: 5).count == 2)
        #expect(await j.views().map(\.recognizerText) == ["das ist zorbal gut", "das ist zorbal gut"])
        try await j.forget(["d1"])
        #expect(await j.history().map(\.id) == ["d2"])
    }

    // MARK: 3, a finished recording once more

    @Test func aFinishedPreciseVersionIsReplacedInPlaceOnceMore() async throws {
        let rig = try Rig([nil, nil])
        defer { rig.remove() }
        let url = try await rig.room()
        #expect(try rig.field(url, "panotti_phase") == "final-elevenlabs")
        let first = try Data(contentsOf: url)
        try await rig.aftercare.postNow(url, mode: .room, choice: .elevenLabs, model: nil)
        await rig.aftercare.settle()
        #expect(await rig.post.calls == 2)
        #expect(await rig.queue.count == 0)
        #expect(try rig.field(url, "panotti_phase") == "final-elevenlabs" && rig.field(url, "nachlauf") == nil)
        #expect(try rig.field(url, "pipeline") == "panotti-live+elevenlabs-scribe-v2")
        let folder = rig.locations.dataFolder.appending(path: "fassungen")
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(copies.count == 2, "the local version and the first precise one are both kept")
        let kept = VaultDoc(try Data(contentsOf: folder.appending(path: copies[1])))  // marked waiting, then copied
        #expect(kept.fields["panotti_phase"] == "final-elevenlabs" && kept.texts == VaultDoc(first).texts)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fertig"))
    }
}
