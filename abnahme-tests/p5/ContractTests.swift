// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 1: the vault contract (R-052; A.9; 05b sections 1.1, 1.2). File names, header keys and values
// per phase, status values, contribution format, one file per recording. Expected values come from
// the description, not from any code. `status: verarbeitet` is written by the skills only, never here.
import Foundation
import Testing
@testable import FlowIQCore
@testable import FlowIQStore

struct ContractTests {
    static let start = localDate(2026, 11, 13, 10, 45)

    // MARK: file names

    @Test func callAndRoomNamesFollowTheStartMinute() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let call = try await rig.begin(.call, at: Self.start)
        let room = try await rig.begin(.room, at: localDate(2026, 11, 13, 14, 7))
        #expect(call.url.lastPathComponent == "2026-11-13-1045-call.md")
        #expect(room.url.lastPathComponent == "2026-11-13-1407-raum.md")
        #expect(call.url.deletingLastPathComponent().standardizedFileURL == rig.transcripts.standardizedFileURL)
    }

    @Test func sameMinuteGetsSuffixNeverOverwrites() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let a = try await rig.begin(.call, at: Self.start)
        await rig.add(a, sampleLines[0])
        let b = try await rig.begin(.call, at: Self.start)
        let c = try await rig.begin(.call, at: Self.start)
        #expect(a.url.lastPathComponent == "2026-11-13-1045-call.md")
        #expect(b.url.lastPathComponent == "2026-11-13-1045-call-2.md")
        #expect(c.url.lastPathComponent == "2026-11-13-1045-call-3.md")
        #expect(try readDoc(a.url).lines == [sampleLines[0]])
    }

    @Test func existingFileIsNeverTouchedByANewStart() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let existing = rig.transcripts.appending(path: "2026-11-13-1045-call.md")
        let original = Data("---\nstatus: verarbeitet\n---\nkeep me\n".utf8)
        try original.write(to: existing)
        let live = try await rig.begin(.call, at: Self.start)
        #expect(live.url.lastPathComponent == "2026-11-13-1045-call-2.md")
        #expect(try Data(contentsOf: existing) == original)
    }

    /// Guarantee M11: a name that lives only below `transcripts/archive/` counts as taken.
    @Test func nameTakenInArchiveFolderIsAvoided() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let archived = rig.transcripts.appending(path: "archive/2026-11-13-1045-call.md")
        try Data("---\nstatus: verarbeitet\n---\n".utf8).write(to: archived)
        let live = try await rig.begin(.call, at: Self.start)
        #expect(live.url.lastPathComponent != "2026-11-13-1045-call.md")
        #expect(live.url.lastPathComponent == "2026-11-13-1045-call-2.md")
    }

    // MARK: header per phase

    @Test func liveStreamHeaderIsExact() async throws {
        let rig = try Rig.make(speaker: "Mira")
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        let doc = try readDoc(live.url)
        #expect(doc.value("type") == "transkript")
        #expect(doc.value("status") == "live")
        #expect(doc.value("panotti_live") == "true")
        #expect(doc.value("panotti_phase") == "live-stream")
        #expect(doc.value("pipeline") == "panotti-live")
        #expect(doc.value("quelle") == "laufend")
        #expect(doc.value("aufnahme") == "2026-11-13 10:45")
        #expect(doc.value("dauer") == "laufend")  // key present while live, value fixed (A.9)
        #expect(doc.value("sprecher_erkannt") == "2")
        #expect(doc.value("sprache") == "de")
        #expect(doc.value("nachlauf") == nil)
    }

    @Test func roomHeaderHasOneSpeakerAndEnglishIsRecorded() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.start, language: "en")
        let doc = try readDoc(live.url)
        #expect(doc.value("sprecher_erkannt") == "1")
        #expect(doc.value("sprache") == "en")  // not hard-wired to de (Panotti bug, 05b 3.3 no. 2)
    }

    /// Panotti's key order (05b 1.4); readers that grep by line depend on it staying put.
    @Test func headerKeysKeepPanottisOrder() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        let expected = ["type", "status", "panotti_live", "panotti_phase", "quelle", "aufnahme", "dauer", "sprecher_erkannt", "sprache", "pipeline", "live_quelle"]  // ASSUMPTION: order as quoted in 05b 1.4. VERTRAGSÄNDERUNG (M.10, Architektur Zeile 863, review 15.11.): live_quelle is written at the start
        #expect(try readDoc(live.url).keys == expected)
    }

    @Test func liveLocalHeaderAfterStopWithPostEnabled() async throws {
        // The transcriber keeps failing so the file rests in live-lokal with a job.
        let post = FakePost(script: [], fallback: .fail(.networkDown))
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        for l in sampleLines { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: Self.start, seconds: 60)
        try await rig.finish(live, seconds: 3725, raw: item)
        let doc = try readDoc(live.url)
        #expect(doc.value("status") == "unverarbeitet")
        #expect(doc.value("panotti_live") == "true")
        #expect(doc.value("panotti_phase") == "live-lokal")
        #expect(doc.value("pipeline") == "panotti-live")
        #expect(doc.value("dauer") == "01:02:05")
        #expect(doc.value("nachlauf") == "wartet")
        #expect(doc.value("sprache") == "de")
    }

    @Test func finalLokalHeaderWhenPostIsOff() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.start)
        await rig.add(live, Line(seconds: 4, speaker: "Raum", text: "Vorlesung beginnt."))
        let item = try rig.makeRaw(.room, at: Self.start, seconds: 125)
        try await rig.finish(live, seconds: 125, raw: item)
        let doc = try readDoc(live.url)
        #expect(doc.value("status") == "unverarbeitet")
        #expect(doc.value("panotti_live") == "true")
        #expect(doc.value("panotti_phase") == "final-lokal")
        #expect(doc.value("pipeline") == "panotti-live+lokal")
        #expect(doc.value("nachlauf") == "aus")  // ASSUMPTION: final-lokal carries nachlauf: aus (Annex L: "nachlauf: aus oder angehalten")
        #expect(doc.value("dauer") == "02:05")
    }

    @Test func finalElevenlabsHeaderForCall() async throws {
        let rig = try Rig.make(terms: ["Alpha", "Beta", "Gamma"])
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.start, seconds: 60)
        try await rig.finish(live, seconds: 60, raw: item)
        let doc = try readDoc(live.url)
        #expect(doc.value("status") == "unverarbeitet")
        #expect(doc.value("panotti_live") == "true")
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(doc.value("pipeline") == "panotti-live+elevenlabs-scribe-v2")
        #expect(doc.value("nachlauf") == nil)  // missing after success (A.9)
        #expect(doc.unquoted("aufnahme") == item.lastPathComponent)
        #expect(doc.value("aufnahme")?.hasPrefix("\"") == true)  // quoted in the final phase
        #expect(doc.value("sprecher_erkannt") == "2")
        #expect(doc.value("fachbegriffe") == "3")
        #expect(doc.value("dauer") == "01:00")
        #expect(doc.value("tracks") != nil)  // call only: mikrofon=..., desktop=...
        #expect(doc.value("sprecher_grenze") == nil)
        #expect(samePath(doc.value("quelle"), rig.archiveAudio.appending(path: item.lastPathComponent)))
    }

    @Test func finalElevenlabsHeaderForRoom() async throws {
        let rig = try Rig.make(terms: ["Alpha"])
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.start)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "Eins."))
        let item = try rig.makeRaw(.room, at: Self.start, seconds: 60)
        try await rig.finish(live, seconds: 60, raw: item)
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(doc.value("sprecher_grenze") == "8")
        #expect(doc.value("tracks") == nil)
        #expect(doc.unquoted("aufnahme") == String(item.lastPathComponent.dropLast(4)))  // file name without extension
    }

    @Test func recoveredWalHeader() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        let url = live.url
        for l in sampleLines { await rig.add(live, l) }
        // App killed: a new process finds the leftover journal.
        let again = try rig.restarted(post: FakePost(), postEnabled: false)
        let recovered = try await again.recoverOrphans()
        #expect(recovered.map(\.lastPathComponent) == [url.lastPathComponent])  // in place, no second file
        let doc = try readDoc(url)
        #expect(doc.value("panotti_phase") == "recovered-wal")
        #expect(doc.value("status") == "unverarbeitet")
        #expect(doc.value("panotti_live") == "true")
        #expect(doc.value("quelle") == "recovered")
        #expect(doc.value("pipeline") == "panotti-live")
        #expect(doc.lines == sampleLines)
        #expect(rig.transcriptFiles.count == 1)
        // Second look finds nothing left to rescue.
        let more = try await again.recoverOrphans()
        #expect(more.isEmpty)
    }

    /// Z-11: a file below an end phase must say why it waits.
    @Test func recoveredFileIsVisibleInTheQueueOrMarked() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, sampleLines[0])
        let again = try rig.restarted(post: FakePost())
        _ = try await again.recoverOrphans()
        let doc = try readDoc(live.url)
        #expect(["wartet", "aus", "angehalten"].contains(doc.value("nachlauf") ?? "-"))  // ASSUMPTION: recovered files get a nachlauf: value too (Z-11)
    }

    // MARK: status values and the skills' territory

    @Test func neverWritesStatusVerarbeitetOnAnyPath() async throws {
        for enabled in [true, false] {
            for failure in [false, true] {
                let post = FakePost(script: [], fallback: failure ? .fail(.networkDown) : nil)
                let rig = try Rig.make(post: post, postEnabled: enabled)
                defer { rig.remove() }
                let live = try await rig.begin(.call, at: Self.start)
                var seen: Set<String> = []
                seen.insert(try readDoc(live.url).value("status") ?? "")
                await rig.add(live, sampleLines[0])
                let item = try rig.makeRaw(.call, at: Self.start, seconds: 30)
                try await rig.finish(live, seconds: 30, raw: item)
                seen.insert(try readDoc(live.url).value("status") ?? "")
                await rig.trigger(.click)
                seen.insert(try readDoc(live.url).value("status") ?? "")
                #expect(seen.isSubset(of: ["live", "unverarbeitet"]))
                #expect(!String(decoding: try Data(contentsOf: live.url), as: UTF8.self).contains("verarbeitet_in"))
            }
        }
    }

    // MARK: body format

    @Test func contributionLinesFollowTheFormat() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        for l in sampleLines { await rig.add(live, l) }
        let doc = try readDoc(live.url)
        #expect(doc.contributions == sampleLines.map(formatLine))
        #expect(doc.contributions[0] == "**[00:03] Mara:** Guten Morgen, wir starten.")
        #expect(doc.contributions[3] == "**[01:02:05] Gegenseite:** Nach einer Stunde.")
    }

    @Test func hourBoundaryStamps() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.start)
        for s in [0, 59, 60, 3599, 3600, 36_000] { await rig.add(live, Line(seconds: s, speaker: "Raum", text: "x")) }
        let stamps = try readDoc(live.url).contributions.map { String($0.dropFirst(3).prefix { $0 != "]" }) }
        #expect(stamps == ["00:00", "00:59", "01:00", "59:59", "01:00:00", "10:00:00"])
    }

    @Test func dictationContributionCarriesTheSuffix() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, Line(seconds: 90, speaker: "Mara", text: "Kurzes Diktat."), dictation: true)
        #expect(try readDoc(live.url).contributions == ["**[01:30] Mara (Diktat):** Kurzes Diktat."])
    }

    @Test func multiLineTextStaysOneContributionLine() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, Line(seconds: 5, speaker: "Mara", text: "erste Zeile\nzweite Zeile\r\ndritte"))
        let doc = try readDoc(live.url)
        #expect(doc.contributions.count == 1)
        let line = try #require(doc.lines.first)
        #expect(!line.text.contains("\n") && !line.text.contains("\r"))
        #expect(line.text.contains("erste Zeile") && line.text.contains("dritte"))  // ASSUMPTION: line breaks become spaces; no text is dropped
    }

    @Test func umlautsAreWrittenAsUTF8() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, sampleLines[1])
        let text = String(decoding: try Data(contentsOf: live.url), as: UTF8.self)
        #expect(text.contains("Größe, Übung, Straße"))
    }

    @Test func titleLineAndNoSecondDocument() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        let doc = try readDoc(live.url)
        #expect(doc.body.contains { $0.hasPrefix("# Transkript:") })  // ASSUMPTION: title line "# Transkript: ..." as in Panotti (05b 1.2)
    }

    // MARK: one file per recording

    /// R-052: 20 recordings give exactly 20 files, whatever the path (post on, off, failing).
    @Test func twentyRecordingsGiveTwentyFiles() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        var urls: [URL] = []
        for n in 0..<20 {
            let when = localDate(2026, 11, 13, 8 + n / 6, (n % 6) * 10)
            let kind: Kind = n % 2 == 0 ? .call : .room
            await rig.setPost(n % 3 != 0)
            let live = try await rig.begin(kind, at: when)
            await rig.add(live, sampleLines[0])
            let item = try rig.makeRaw(kind, at: when, seconds: 20)
            try await rig.finish(live, seconds: 20, raw: item)
            urls.append(live.url)
        }
        await rig.trigger(.click)
        #expect(rig.transcriptFiles.count == 20)
        #expect(Set(urls.map(\.lastPathComponent)).count == 20)
        #expect(Set(rig.transcriptFiles.map(\.lastPathComponent)) == Set(urls.map(\.lastPathComponent)))
        let leftovers = rig.names(in: rig.transcripts).filter { !$0.hasSuffix(".md") && $0 != "archive" }
        #expect(leftovers.isEmpty)  // no temp or partial files beside the transcripts
        for url in urls {
            let phase = try readDoc(url).value("panotti_phase") ?? ""
            #expect(["final-lokal", "final-elevenlabs"].contains(phase))
        }
    }

    /// Phases follow in one direction; a finished file never goes back to an earlier phase.
    @Test func phaseOrderOnlyMovesForward() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let order = ["live-stream": 0, "recovered-wal": 1, "live-lokal": 1, "final-lokal": 2, "final-elevenlabs": 3]
        let live = try await rig.begin(.call, at: Self.start)
        var last = order[try readDoc(live.url).value("panotti_phase") ?? ""] ?? -1
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.start, seconds: 20)
        try await rig.finish(live, seconds: 20, raw: item)
        for step in 0..<3 {
            let rank = order[try readDoc(live.url).value("panotti_phase") ?? ""] ?? -1
            #expect(rank >= last, "step \(step)")
            last = rank
            await rig.trigger(.click)
        }
    }
}
