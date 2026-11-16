import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQStore

/// Review 15.11. (c), priority 1 and 2: empty results, usage of failed uploads, the queue, the archive, recovery,
/// the switch and the version count. Invented text only, a scratch folder per test.
struct AftercareReviewTests {
    actor Post: PostProcessor {
        nonisolated let name = "test"
        var answers: [PostFailure?], calls = 0
        init(_ answers: [PostFailure?]) { self.answers = answers }
        func process(_ job: PostJob) async throws -> PostTranscript {
            calls += 1
            if let failure = answers.isEmpty ? PostFailure.empty : answers.removeFirst() { throw failure }
            return PostTranscript(segments: [PostSegment(start: 0, speaker: "A", text: "fertig")], speakersDetected: 1)
        }
    }

    actor Usage: CloudUsage {
        var seconds = 0.0
        func record(_ source: UsageSource, _ kind: UsageKind, seconds: Double) { self.seconds += seconds }
        var limitReached: Bool { false }
    }

    final class Clock: Sendable {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        func withLock(_ body: (inout Date) -> Void) { now.withLock { body(&$0) } }
        func withLock() -> Date { now.withLock { $0 } }
    }

    final class Rig: Sendable {
        let root: URL, fs: SafeFS, log: EventLog, locations: StoreLocations, store: TranscriptStore, queue: PostQueue
        let clock = Clock(), post: Post, usage = Usage(), aftercare: Aftercare
        init(_ answers: [PostFailure?] = [], post on: Bool = true, makeArchive: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "flowiq-review-\(UUID().uuidString)")
            locations = StoreLocations(transcripts: root.appending(path: "t"), raw: root.appending(path: "r"),
                                       archiveAudio: root.appending(path: "a"),
                                       liveLink: root.appending(path: "link.md"),
                                       dataFolder: root.appending(path: "d"))
            for f in [locations.transcripts, locations.raw, locations.dataFolder.appending(path: "laufend"),
                      locations.dataFolder.appending(path: "nachlauf"),
                      locations.dataFolder.appending(path: "fassungen"),
                      root.appending(path: "protokoll")] + (makeArchive ? [locations.archiveAudio] : []) {
                try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            }
            fs = SafeFS(confinedTo: root)
            log = EventLog(directory: root.appending(path: "protokoll"), fs: fs)
            let clock = clock
            store = TranscriptStore(locations: locations, fs: fs, log: log, speakerName: "Anna")
            queue = PostQueue(folder: locations.dataFolder.appending(path: "nachlauf"), fs: fs, log: log)
            post = Post(answers)
            aftercare = Aftercare(store: store, queue: queue, processor: post, postEnabled: [.room: on], usage: usage,
                                  confirmedTerms: { [] }, now: { clock.withLock() })
        }
        func remove() {  // the log task may still write its last line: try a few times
            for _ in 0..<10 {
                do { return try FileManager.default.removeItem(at: root) } catch { Thread.sleep(forTimeInterval: 0.02) }
            }
            Issue.record("cleanup failed")
        }
        func room(seconds: Double = 30) async throws -> URL {
            let live = try await store.beginLive(kind: .room, startedAt: clock.withLock(), language: "de")
            await live.append(seconds: 2, speaker: "Anna", text: "ein Satz")
            let raw = locations.raw.appending(path: "raum-\(UUID().uuidString.prefix(4)).m4a")
            try Data(repeating: 1, count: 64).write(to: raw)
            try await aftercare.finish(live, durationSeconds: seconds, rawAudio: raw)
            await aftercare.settle()
            return live.url
        }
        func field(_ url: URL, _ key: String) throws -> String? { VaultDoc(try Data(contentsOf: url)).fields[key] }
        func later(_ seconds: Double, _ trigger: AftercareTrigger = .timer) async {
            clock.withLock { $0 = $0.addingTimeInterval(seconds) }
            await aftercare.trigger(trigger)
            await aftercare.settle()
        }
    }

    @Test func anEmptyResultIsTriedThreeTimesThenWaitsVisiblyForAClick() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let file = try await rig.room()
        for _ in 0..<6 { await rig.later(4000) }
        #expect(await rig.post.calls == AftercareReviewTests.limit)
        #expect(await rig.aftercare.visibleState == .paused(count: 1))
        #expect(try rig.field(file, "nachlauf") == "angehalten")
        #expect(await rig.usage.seconds == 30 * Double(AftercareReviewTests.limit), "every sent run counts")
        await rig.later(1, .click)
        #expect(await rig.post.calls == AftercareReviewTests.limit + 1)
    }
    static var limit: Int { Aftercare.emptyLimit }

    @Test func aServerFailureCountsAsSentANetworkFailureDoesNot() async throws {
        let rig = try Rig([.server(status: 500), .networkDown, nil])
        defer { rig.remove() }
        let file = try await rig.room()
        #expect(await rig.usage.seconds == 30)
        await rig.later(61)
        #expect(await rig.usage.seconds == 30)
        await rig.later(301)
        #expect(await rig.usage.seconds == 60)
        #expect(await rig.post.calls == 3)
        #expect(try rig.field(file, "panotti_phase") == "final-elevenlabs")
    }

    /// 16.11.: every upload came back 400 and was tried again within minutes. A wrong request waits for a click,
    /// its reason stands in the queue, in the log and in `rejection` for the menu.
    @Test func aRefusedRequestWaitsForAClickWithItsReason() async throws {
        let why = "400 invalid_parameters keyterms zu lang"
        let rig = try Rig([.rejected(why), nil])
        defer { rig.remove() }
        let file = try await rig.room()
        #expect(await rig.aftercare.rejection == why)
        #expect(await rig.aftercare.visibleState == .paused(count: 1))
        #expect(try rig.field(file, "nachlauf") == "angehalten")
        for trigger in [AftercareTrigger.timer, .appStart, .networkBack] { await rig.later(90_000, trigger) }
        #expect(await rig.post.calls == 1, "no timer, start or network brings it back")
        await rig.log.flush()
        let log = try String(contentsOf: rig.root.appending(path: "protokoll/ereignisse.ndjson"), encoding: .utf8)
        #expect(log.contains("nachlauf_failed") && log.contains(why))
        let queue = try String(contentsOf: rig.locations.dataFolder.appending(path: "nachlauf/warteschlange.jsonl"),
                               encoding: .utf8)
        #expect(queue.contains(why))
        await rig.later(1, .click)
        #expect(await rig.post.calls == 2)
        #expect(await rig.aftercare.rejection == nil)
        #expect(try rig.field(file, "panotti_phase") == "final-elevenlabs")
    }

    static func entry(_ name: String, family: String? = nil, used daysAgo: Double? = nil, benefit: Int = 0,
                      status: EntryStatus = .confirmed) -> CanonEntry {
        let last = daysAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 86_400) }
        return CanonEntry(id: "e-" + name, canonical: name, kind: .name, family: family, spokenForms: [],
                          hearingVariants: [], status: status, origin: .seed, compound: .hyphen,
                          counters: Counters(benefit: benefit, lastAppliedAt: last),
                          createdAt: Date(timeIntervalSince1970: 0), confirmedAt: nil)
    }

    /// LEXIKON-KONZEPT 6: family members first, then by use in the last 30 days; the cut was alphabetical before,
    /// so with more entries than places the important names fell out.
    @Test func cloudTermsKeepFamilyAndRecentlyUsedNamesWhenTheListIsCut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var entries = (0..<120).map { Self.entry(String(format: "Aaa%03d", $0)) }  // would fill an alphabetical cut
        entries += [Self.entry("Zeta-Familie", family: "f1"), Self.entry("Yps-Familie", family: "f1"),
                    Self.entry("Wenig", used: 3, benefit: 1), Self.entry("Viel", used: 10, benefit: 9),
                    Self.entry("Alt", used: 45, benefit: 50), Self.entry("Vorschlag", family: "f1", status: .proposed),
                    Self.entry(String(repeating: "x", count: 51), family: "f1"), Self.entry("Viel", used: 1)]
        let post = CloudTerms.post(from: entries, now: now), live = CloudTerms.live(from: entries, now: now)
        #expect(post.count == 100 && live.count == 50 && Set(post).count == 100)
        #expect(Array(post.prefix(5)) == ["Yps-Familie", "Zeta-Familie", "Viel", "Wenig", "Aaa000"])
        #expect(Array(live.prefix(4)) == ["Yps-Familie", "Zeta-Familie", "Viel", "Wenig"])
        #expect(!post.contains("Alt") && !post.contains("Vorschlag"), "use older than 30 days ranks by name only")
        #expect(post.allSatisfy { $0.count <= 50 }, "the service takes at most 50 characters per term")
        #expect(post == CloudTerms.post(from: entries.reversed(), now: now), "independent of the entries' order")
    }

    @Test func anUnreadableQueueLineIsSetAsideAndReported() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let folder = rig.locations.dataFolder.appending(path: "nachlauf")
        try Data("{kaputt\n".utf8).write(to: folder.appending(path: "warteschlange.jsonl"))
        let queue = PostQueue(folder: folder, fs: rig.fs, log: rig.log)
        #expect(await queue.count == 0)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("unlesbar") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: folder.appending(path: aside[0])) == Data("{kaputt".utf8))
        await rig.log.flush()
        let errors = try String(contentsOf: rig.root.appending(path: "protokoll/fehler.ndjson"), encoding: .utf8)
        #expect(errors.contains("nachlauf_queue_line_unreadable"))
    }

    @Test func aFailedArchiveMoveIsShownAndTriedAgain() async throws {
        let rig = try Rig(post: false, makeArchive: false)
        defer { rig.remove() }
        let file = try await rig.room()
        #expect(await rig.aftercare.unarchived.count == 1)
        try FileManager.default.createDirectory(at: rig.locations.archiveAudio, withIntermediateDirectories: true)
        await rig.later(1, .appStart)
        #expect(await rig.aftercare.unarchived.isEmpty)
        let quelle = try #require(try rig.field(file, "quelle"))
        #expect(quelle.hasPrefix(rig.locations.archiveAudio.path))
        #expect(FileManager.default.fileExists(atPath: quelle))
    }

    @Test func switchingOffMarksTheWaitingFileHeldAndOnAgainWaiting() async throws {
        let rig = try Rig([.networkDown])
        defer { rig.remove() }
        let file = try await rig.room()
        #expect(try rig.field(file, "nachlauf") == "wartet")
        await rig.aftercare.setPostEnabled(false, for: .room)
        #expect(try rig.field(file, "nachlauf") == "angehalten")
        await rig.aftercare.setPostEnabled(true, for: .room)
        #expect(try rig.field(file, "nachlauf") == "wartet")
    }

    @Test func recoveryKeepsTheOpenSentenceAndSkipsABrokenJournal() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let live = try await rig.store.beginLive(kind: .room, startedAt: rig.clock.withLock(), language: "de")
        await live.append(seconds: 2, speaker: "Anna", text: "ein Satz")
        await live.setVolatile(seconds: 7, speaker: "Anna", text: "noch offen")
        let laufend = rig.locations.dataFolder.appending(path: "laufend")
        try Data("{kaputt".utf8).write(to: laufend.appending(path: "live-kaputt.jsonl"))
        let again = TranscriptStore(locations: rig.locations, fs: rig.fs, log: rig.log, speakerName: "Anna")
        #expect(try await again.recoverOrphans() == [live.url])
        let body = VaultDoc(try Data(contentsOf: live.url)).lines
        #expect(body == ["**[00:02] Anna:** ein Satz", "**[00:07] Anna:** noch offen"])
        #expect(try rig.field(live.url, "dauer") == "00:07")
    }

    @Test func everyUpgradeKeepsTheVersionBeforeIt() async throws {
        let rig = try Rig(post: false)
        defer { rig.remove() }
        let file = try await rig.room()
        let t = PostTranscript(segments: [PostSegment(start: 0, speaker: "A", text: "neu")], speakersDetected: 1)
        for _ in 0..<2 {
            try await rig.store.upgrade(file, with: t, mode: .room, terms: 0, source: "test", postSeconds: 1,
                                        stage: nil)
        }
        let name = file.deletingPathExtension().lastPathComponent
        let folder = rig.locations.dataFolder.appending(path: "fassungen")
        let versions = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(versions == ["\(name).1.md", "\(name).2.md"])
    }

    /// P6: a device file keeps its pipeline tag and recording name; only a room gets the speaker limit.
    @Test func aDeviceUpgradeKeepsItsPipelineAndRecordingName() async throws {
        let rig = try Rig(post: false)
        defer { rig.remove() }
        let file = rig.locations.transcripts.appending(path: "geraet.md")
        try VaultDoc(fields: ["pipeline": "dvt1600-import+lokal", "aufnahme": "2026-11-15 10:00 (REC_001.wav)"],
                     body: "\n# Transkript\n\n").data.write(to: file)
        let t = PostTranscript(segments: [PostSegment(start: 0, speaker: "A", text: "neu")], speakersDetected: 1)
        try await rig.store.upgrade(file, with: t, mode: .device, terms: 0, source: "test", postSeconds: 1, stage: nil)
        #expect(try rig.field(file, "pipeline") == "dvt1600-import+elevenlabs-scribe-v2")
        #expect(try rig.field(file, "aufnahme") == "2026-11-15 10:00 (REC_001.wav)")
        #expect(try rig.field(file, "sprecher_grenze") == nil && rig.field(file, "tracks") == nil)
    }

    /// Review P2: the journal knows the recording's audio, so the recovery archives it (or finds it where `Rescue`
    /// put it) and names it in `quelle`.
    @Test func recoveryArchivesTheAudioOfTheJournal() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let laufend = rig.locations.dataFolder.appending(path: "laufend")
        for (name, rescued) in [("2026-11-15T1000 Raum", false), ("2026-11-15T1100 Raum", true)] {
            let raw = laufend.appending(path: name)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: raw.appending(path: "mikrofon.m4a"))
            let live = try await rig.store.beginLive(kind: .room, startedAt: rig.clock.withLock(), language: "de",
                                                     audio: raw)
            await live.append(seconds: 2, speaker: "Anna", text: "ein Satz")
            let archived = rig.locations.archiveAudio.appending(path: name)
            if rescued { try FileManager.default.moveItem(at: raw, to: archived) }  // `Rescue` was first
            let again = TranscriptStore(locations: rig.locations, fs: rig.fs, log: rig.log, speakerName: "Anna")
            #expect(try await again.recoverOrphans() == [live.url])
            #expect(try rig.field(live.url, "quelle") == archived.path)
            #expect(FileManager.default.fileExists(atPath: archived.appending(path: "mikrofon.m4a").path))
            #expect(!FileManager.default.fileExists(atPath: raw.path))
        }
    }

    /// Review M4: a visible line when live is out, and the file run's text replaces the live one at the stop.
    @Test func theFileRunReplacesTheLiveTextAndKeepsTheNotes() async throws {
        let rig = try Rig(post: false)
        defer { rig.remove() }
        let live = try await rig.store.beginLive(kind: .room, startedAt: rig.clock.withLock(), language: "en")
        await live.append(seconds: 1, speaker: "Anna", text: "halb")
        await live.note(seconds: 3, "Live-Erkennung ausgefallen")
        await live.setVolatile(seconds: 4, speaker: "Anna", text: "offen")
        await live.replaceSaid(with: [(0, "Anna", "erster Satz"), (5, "Anna", "zweiter Satz")])
        let raw = rig.locations.raw.appending(path: "raum.m4a")
        try Data(repeating: 1, count: 64).write(to: raw)
        try await rig.aftercare.finish(live, durationSeconds: 6, rawAudio: raw)
        #expect(VaultDoc(try Data(contentsOf: live.url)).lines == ["**[00:00] Anna:** erster Satz",
                                                                   "_[00:03] Live-Erkennung ausgefallen_",
                                                                   "**[00:05] Anna:** zweiter Satz"])
    }

    /// 16.11.: sessions, after-runs and dictations leave counts in the log, never text.
    @Test func sessionsAfterRunsAndDictationsAreLogged() async throws {
        let rig = try Rig([nil])
        defer { rig.remove() }
        _ = try await rig.room()
        let paths = Paths(profile: .development, applicationSupport: rig.root)
        try rig.fs.makeFolder(paths.diktate)
        let journal = DictationJournal(paths: paths, fs: rig.fs, log: rig.log)
        try await journal.append(.recognized(id: "a", recognizerText: "zwei worte", finalText: "Zwei Worte",
                                             interventions: ["variant"]))
        await rig.log.flush()
        let text = try String(contentsOf: rig.root.appending(path: "protokoll/ereignisse.ndjson"), encoding: .utf8)
        for kind in ["live_session_started", "live_session_ended", "nachlauf_done", "dictation_counts"] {
            #expect(text.contains("\"kind\":\"\(kind)\""), "\(kind)")
        }
        #expect(text.contains("\"words\":2") && text.contains("\"interventions\":1") && !text.contains("Worte"))
    }
}
