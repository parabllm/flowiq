// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 4: aftercare on and off (R-059, R-060, R-061, R-033, R-064/65 as far as P5, B.2 point 8, A.9 "Stopp und
// Endphasen"). On: copy of the local version, then final-elevenlabs in the same file, then archive.
// Off: final-lokal, then archive, and not one call to the service. All against the scripted transcriber.
import Foundation
import Testing
@testable import FlowIQStore  // COMPILE-FIX (P5 build): the file names LiveTranscript without importing its module

struct AftercareTests {
    static let t0 = localDate(2026, 11, 13, 10, 45)
    static let remote = [
        Line(seconds: 0, speaker: "Mara", text: "Neufassung vom Dienst."),
        Line(seconds: 4, speaker: "Gegenseite (speaker_0)", text: "Antwort der Gegenseite."),
        Line(seconds: 9, speaker: "Gegenseite (speaker_1)", text: "Dritte Stimme."),
    ]

    private func recordCall(_ rig: Rig, lines: [Line] = sampleLines, at when: Date = t0, seconds: Double = 60) async throws -> (LiveTranscript, URL) {
        let live = try await rig.begin(.call, at: when)
        for l in lines { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: when, seconds: seconds)
        try await rig.finish(live, seconds: seconds, raw: item)
        return (live, item)
    }

    // MARK: on

    @Test func successReplacesTheSameFileWithTheServiceVersion() async throws {
        let post = FakePost(script: [.success(Self.remote, speakers: 3)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await recordCall(rig)
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(doc.value("sprecher_erkannt") == "3")
        #expect(doc.lines == Self.remote)
        #expect(rig.transcriptFiles.map(\.lastPathComponent) == [live.url.lastPathComponent])  // in place, no second file
        #expect(await post.callCount == 1)
        #expect(await rig.pending() == 0)
        #expect(await rig.visible() == .idle)
    }

    /// E5: before the local version is replaced, a copy of it exists, holds every local line and says live-lokal.
    @Test func localVersionIsCopiedBeforeItIsReplaced() async throws {
        let rig = try Rig.make(post: FakePost(script: [.success(Self.remote, speakers: 3)]))
        defer { rig.remove() }
        let (live, _) = try await recordCall(rig)
        let copies = rig.names(in: rig.fassungen)
        #expect(copies.count == 1)
        let copy = try readDoc(rig.fassungen.appending(path: try #require(copies.first)))
        #expect(copy.value("panotti_phase") == "live-lokal")
        #expect(copy.lines == sampleLines)
        #expect(try readDoc(live.url).lines != sampleLines)
    }

    /// If the copy cannot be written, the replacement does not happen at all (the proof of "copy first").
    @Test func noCopyMeansNoReplacement() async throws {
        let rig = try Rig.make(post: FakePost(script: [.success(Self.remote, speakers: 3)]))
        defer { rig.remove() }
        try FileManager.default.removeItem(at: rig.fassungen)
        try Data("blocker".utf8).write(to: rig.fassungen)  // a file where the copy folder should be
        let (live, _) = try await recordCall(rig)
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "live-lokal")
        #expect(doc.lines == sampleLines)  // the local text is untouched
        #expect(doc.value("nachlauf") == "wartet")  // and visibly waiting, not silent
        #expect(await rig.pending() == 1)
        let errors = await rig.errorEvents()
        #expect(!errors.isEmpty)
    }

    @Test func emptyServiceResultNeverReplacesTheLocalText() async throws {
        let post = FakePost(script: [.success([], speakers: 0)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await recordCall(rig)
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "live-lokal")  // Panotti: replaced only when not empty
        #expect(doc.lines == sampleLines)
        #expect(doc.value("nachlauf") == "wartet")
        #expect(await rig.pending() == 1)
        #expect(rig.names(in: rig.fassungen).isEmpty)  // nothing replaced, so no copy needed
    }

    @Test func requestUsesTheArchivedAudioAndTheRecordingLanguage() async throws {
        let post = FakePost(script: [.success(Self.remote, speakers: 3)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0, language: "en")
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 60)
        try await rig.finish(live, seconds: 60, raw: item)
        let seen = try #require(await post.seen.first)
        #expect(seen.language == "en")
        #expect(seen.audio.count == 2)  // call: two tracks
        #expect(seen.audioExisted == [true, true])  // the files were there when the upload asked for them
    }

    @Test func roomUploadsOneTrack() async throws {
        let post = FakePost(script: [.success([Line(seconds: 0, speaker: "speaker_0", text: "Vorlesung.")], speakers: 1)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 0, speaker: "Raum", text: "Vorlesung."))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 60)
        try await rig.finish(live, seconds: 60, raw: item)
        let seen = try #require(await post.seen.first)
        #expect(seen.audio.count == 1)
        #expect(seen.audioExisted == [true])
    }

    // MARK: terms (R-033)

    /// At most 100 confirmed terms go out; the header counts what was sent; the result never reaches the lexicon.
    @Test func termListIsCappedAndNothingFlowsBackIntoTheLexicon() async throws {
        let terms = (0..<250).map { "Begriff\($0)" }
        let post = FakePost(script: [.success(Self.remote, speakers: 3)])
        let rig = try Rig.make(post: post, terms: terms)
        defer { rig.remove() }
        let lexicon = rig.paths.support.appending(path: "lexikon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lexicon, withIntermediateDirectories: true)
        let sentinel = Data("{\"sentinel\":true}".utf8)
        for name in ["lexikon.json", "vorschlaege.json"] { try sentinel.write(to: lexicon.appending(path: name)) }
        let before = rig.names(in: lexicon)
        let (live, _) = try await recordCall(rig)
        let seen = try #require(await post.seen.first)
        #expect(seen.terms.count <= 100)
        #expect(Set(seen.terms).isSubset(of: Set(terms)))
        #expect(try readDoc(live.url).value("fachbegriffe") == String(seen.terms.count))
        #expect(rig.names(in: lexicon) == before)
        for name in before { #expect(try Data(contentsOf: lexicon.appending(path: name)) == sentinel) }
    }

    @Test func emptyTermListIsAllowed() async throws {
        let post = FakePost(script: [.success(Self.remote, speakers: 3)])
        let rig = try Rig.make(post: post, terms: [])
        defer { rig.remove() }
        _ = try await recordCall(rig)
        let seen = try #require(await post.seen.first)
        #expect(seen.terms.isEmpty)
    }

    // MARK: off

    /// R-060 and R-059: off gives final-lokal, audio in the archive, and zero calls; 10 of 10.
    @Test func switchOffEndsLocallyFinalTenOfTen() async throws {
        let post = FakePost()
        let rig = try Rig.make(post: post, postEnabled: false)
        defer { rig.remove() }
        for n in 0..<10 {
            let when = localDate(2026, 11, 13, 9, n * 5)
            let kind: Kind = n % 2 == 0 ? .call : .room
            let live = try await rig.begin(kind, at: when)
            await rig.add(live, sampleLines[0])
            let item = try rig.makeRaw(kind, at: when, seconds: 30)
            try await rig.finish(live, seconds: 30, raw: item)
            let doc = try readDoc(live.url)
            #expect(doc.value("panotti_phase") == "final-lokal", "recording \(n)")
            #expect(doc.value("status") == "unverarbeitet")
            let place = rig.locations(of: item)
            #expect(place.inArchive && !place.inRaw, "recording \(n)")
            #expect(samePath(doc.value("quelle"), rig.archiveAudio.appending(path: item.lastPathComponent)))  // ASSUMPTION: quelle points at the archived audio in final-lokal as in final-elevenlabs
        }
        #expect(await post.callCount == 0)
        #expect(await rig.pending() == 0)
        let queueText = (try? String(contentsOf: rig.queueFile, encoding: .utf8)) ?? ""
        #expect(queueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)  // never a job when the switch is off
        #expect(rig.names(in: rig.raw).isEmpty)
    }

    @Test func switchOffTimerAndClickNeverCallTheService() async throws {
        let post = FakePost()
        let rig = try Rig.make(post: post, postEnabled: false)
        defer { rig.remove() }
        _ = try await recordCall(rig)
        for t in [Trigger.appStart, .networkBack, .click, .timer] {
            rig.clock.advance(86_400)
            await rig.trigger(t)
        }
        #expect(await post.callCount == 0)
    }

    @Test func switchOffKeepsAllLocalLinesAndAddsNoCopy() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let (live, _) = try await recordCall(rig)
        #expect(try readDoc(live.url).lines == sampleLines)
        #expect(rig.names(in: rig.fassungen).isEmpty)  // nothing was replaced
    }

    /// Switching off while a job waits stops the retries; the job is neither dropped nor sent.
    @Test func switchingOffLaterPausesWaitingJobsWithoutDroppingThem() async throws {
        let post = FakePost(script: [], fallback: .fail(.networkDown))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let (live, _) = try await recordCall(rig)
        let calls = await post.callCount
        await rig.setPost(false)
        rig.clock.advance(7200)
        await rig.trigger(.timer)
        #expect(await post.callCount == calls)
        #expect(await rig.pending() == 1)  // ASSUMPTION: a waiting job survives the switch, only its sending stops
        #expect(try readDoc(live.url).value("panotti_phase") == "live-lokal")
    }

    // MARK: collective upgrade (R-061)

    /// Three local recordings are upgraded later in their own files, each with a copy; the list shows minutes.
    @Test(.disabled("R-061 gestrichen (K-33)")) func collectiveUpgradeUpgradesThreeInPlace() async throws {  // R-061 STRUCK (K-33, Anhang K Nr. 4): no collective upgrade in v1, test disabled by order of the lead
        let post = FakePost(script: [.success(Self.remote, speakers: 3), .success(Self.remote, speakers: 3), .success(Self.remote, speakers: 3)])
        let rig = try Rig.make(post: post, postEnabled: false)
        defer { rig.remove() }
        var urls: [URL] = []
        for n in 0..<3 {
            let when = localDate(2026, 11, 13, 9 + n, 0)
            let live = try await rig.begin(.call, at: when)
            await rig.add(live, sampleLines[0])
            let item = try rig.makeRaw(.call, at: when, seconds: 60)
            try await rig.finish(live, seconds: 600, raw: item)
            urls.append(live.url)
        }
        let list = await rig.localOnly()  // ASSUMPTION: localOnly() lists the final-lokal recordings with fields url and minutes
        #expect(list.count == 3)
        #expect(list.map(\.minutes).reduce(0, +) == 30)  // ASSUMPTION: minutes is the recorded duration rounded to whole minutes
        await rig.setPost(true)
        try await rig.upgrade(list.map(\.url))  // ASSUMPTION: upgrade(_ urls: [URL]) queues the chosen recordings for the same in-place aftercare
        await rig.settle()
        #expect(await post.callCount == 3)
        #expect(rig.transcriptFiles.count == 3)  // the same three files
        for url in urls {
            let doc = try readDoc(url)
            #expect(doc.value("panotti_phase") == "final-elevenlabs")
            #expect(doc.lines == Self.remote)
            #expect(doc.value("nachlauf") == nil)
        }
        #expect(rig.names(in: rig.fassungen).count == 3)  // one copy each, the local versions are kept
    }

    @Test(.disabled("R-061 gestrichen (K-33)")) func collectiveUpgradeFindsTheAudioInTheArchive() async throws {  // R-061 STRUCK (K-33, Anhang K Nr. 4): no collective upgrade in v1, test disabled by order of the lead
        let post = FakePost(script: [.success(Self.remote, speakers: 3)])
        let rig = try Rig.make(post: post, postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 0, speaker: "Raum", text: "Satz."))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 60)
        try await rig.finish(live, seconds: 60, raw: item)
        await rig.setPost(true)
        try await rig.upgrade([live.url])
        await rig.settle()
        let seen = try #require(await post.seen.first)
        #expect(seen.audioExisted == [true])
        #expect(seen.audio.first?.path.hasPrefix(rig.archiveAudio.path) == true || seen.audio.first?.resolvingSymlinksInPath().path.hasPrefix(rig.archiveAudio.resolvingSymlinksInPath().path) == true)
    }

    /// A file the skills already processed is not rewritten behind their back.
    @Test func processedFileIsNotUpgraded() async throws {
        let post = FakePost()
        let rig = try Rig.make(post: post, postEnabled: false)
        defer { rig.remove() }
        let (live, _) = try await recordCall(rig)
        var text = String(decoding: try Data(contentsOf: live.url), as: UTF8.self)
        text = text.replacingOccurrences(of: "status: unverarbeitet", with: "status: verarbeitet")
        try Data(text.utf8).write(to: live.url)  // what a skill does
        let before = try Data(contentsOf: live.url)
        await rig.setPost(true)
        _ = try? await rig.upgrade([live.url])  // ASSUMPTION: upgrade refuses such a file (throws or skips), it never rewrites it
        await rig.settle()
        #expect(try Data(contentsOf: live.url) == before)
        #expect(await post.callCount == 0)
    }
}
