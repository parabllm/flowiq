// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 7: no silent loss of text (E5, R-062, Panotti findings: replaced without a copy, failed quietly).
// Every transition keeps each local line either in the file itself or in a copy beside it, and a failed
// attempt leaves the body of the file exactly as it was.
import Foundation
import Testing

struct NoSilentLossTests {
    static let t0 = localDate(2026, 11, 13, 10, 45)

    /// Every contribution text of `before` is in `after` or in one of the copies.
    private func lostTexts(before: [Line], after: Doc, copies: [Doc]) -> [String] {
        let kept = Set(after.lines.map(\.text)).union(copies.flatMap { $0.lines.map(\.text) })
        return before.map(\.text).filter { !kept.contains($0) }
    }

    private func copies(_ rig: Rig) throws -> [Doc] {
        try rig.names(in: rig.fassungen).map { try readDoc(rig.fassungen.appending(path: $0)) }
    }

    @Test func stopKeepsEveryLocalLineInTheFileItself() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.networkDown)))
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        for l in sampleLines { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        #expect(try readDoc(live.url).lines == sampleLines)  // live-lokal is the same text, in the same order
    }

    @Test func replacementLeavesTheLocalTextRecoverable() async throws {
        let remote = [Line(seconds: 0, speaker: "Mara", text: "ganz andere Worte")]
        let rig = try Rig.make(post: FakePost(script: [.success(remote, speakers: 1)]))
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        for l in sampleLines { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        let after = try readDoc(live.url)
        #expect(after.value("panotti_phase") == "final-elevenlabs")
        #expect(lostTexts(before: sampleLines, after: after, copies: try copies(rig)).isEmpty)
    }

    /// Text with umlauts, long lines, quotes and markdown-looking content survives the copy unchanged.
    @Test func awkwardTextSurvivesCopyAndReplacement() async throws {
        let awkward = [
            Line(seconds: 1, speaker: "Mara", text: "Größe, Übung, Straße, äöü ÄÖÜ ß — Gedankenstrich bleibt, wie er ist."),
            Line(seconds: 2, speaker: "Gegenseite", text: "---"),
            Line(seconds: 3, speaker: "Gegenseite", text: "**[00:09] fake:** looks like a line"),
            Line(seconds: 4, speaker: "Mara", text: String(repeating: "lang ", count: 4000)),
            Line(seconds: 5, speaker: "Mara", text: "Emoji 🎙️ und \"Anführungszeichen\" und 'Apostrophe' und: Doppelpunkt"),
        ]
        let rig = try Rig.make(post: FakePost(script: [.success([Line(seconds: 0, speaker: "Mara", text: "neu")], speakers: 1)]))
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        for l in awkward { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        let copy = try #require(try copies(rig).first)
        #expect(copy.lines.map(\.text) == awkward.map(\.text))
        let header = copy.fields
        #expect(header["panotti_phase"] == "live-lokal")
    }

    /// A long recording: 3,000 lines, all kept through stop, copy and replacement.
    @Test func longRecordingLosesNothing() async throws {
        let many = (0..<3000).map { Line(seconds: $0 * 2, speaker: $0 % 2 == 0 ? "Mara" : "Gegenseite", text: "Satz Nummer \($0) mit Übung") }
        let rig = try Rig.make(post: FakePost(script: [.success([Line(seconds: 0, speaker: "Mara", text: "kurz")], speakers: 1)]))
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        for l in many { await rig.add(live, l, flush: false) }
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 6000, raw: item)
        let copy = try #require(try copies(rig).first)
        #expect(copy.lines == many)
    }

    /// Failed attempts change the header marker at most; the body stays byte for byte as it was.
    @Test func failedAttemptsLeaveTheBodyUntouched() async throws {
        let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.networkDown)))
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        for l in sampleLines { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        let first = try readDoc(live.url)
        for _ in 0..<5 {
            rig.clock.advance(3600)
            await rig.trigger(.timer)
        }
        let later = try readDoc(live.url)
        #expect(later.body == first.body)
        #expect(later.keys == first.keys)
        #expect(later.fields.filter { $0.key != "nachlauf" } == first.fields.filter { $0.key != "nachlauf" })
        #expect(rig.names(in: rig.fassungen).isEmpty)
    }

    /// Quota empty, empty result, network down: none of them touches the local text, in any order.
    @Test func mixedFailuresNeverReplaceAnything() async throws {
        let script: [Outcome] = [.fail(.networkDown), .success([], speakers: 0), .fail(.server(status: 500)), .fail(.quotaExhausted)]
        let rig = try Rig.make(post: FakePost(script: script, fallback: .fail(.networkDown)))
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        for l in sampleLines { await rig.add(live, l) }
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        for _ in 0..<6 {
            rig.clock.advance(3600)
            await rig.trigger(.timer)
            await rig.trigger(.click)
        }
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "live-lokal")
        #expect(doc.lines == sampleLines)
        #expect(await rig.pending() == 1)
    }

    /// A second upgrade of the same file keeps the first service version too.
    @Test(.disabled("R-061 gestrichen (K-33)")) func secondUpgradeKeepsBothEarlierVersions() async throws {  // R-061 STRUCK (K-33, Anhang K Nr. 4): no collective upgrade in v1, test disabled by order of the lead
        let v1 = [Line(seconds: 0, speaker: "Mara", text: "erste Dienstfassung")]
        let v2 = [Line(seconds: 0, speaker: "Mara", text: "zweite Dienstfassung")]
        let post = FakePost(script: [.success(v1, speakers: 1), .success(v2, speakers: 1)])
        let rig = try Rig.make(post: post)
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.t0)
        await rig.add(live, Line(seconds: 1, speaker: "Raum", text: "lokale Fassung"))
        let item = try rig.makeRaw(.room, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        try await rig.upgrade([live.url])  // ASSUMPTION: upgrade also accepts an already upgraded file (a repeat run); the older service version is then copied as well
        await rig.settle()
        let after = try readDoc(live.url)
        #expect(after.lines.map(\.text) == ["zweite Dienstfassung"])
        let allCopies = try copies(rig)
        let texts = Set(allCopies.flatMap { $0.lines.map(\.text) })
        #expect(texts.contains("lokale Fassung") && texts.contains("erste Dienstfassung"))
        #expect(allCopies.count == 2)
    }

    /// The copies carry the local version only in `fassungen/`, and never leak into the vault folders.
    @Test func copiesLiveOutsideTheVault() async throws {
        let rig = try Rig.make(post: FakePost(script: [.success([Line(seconds: 0, speaker: "Mara", text: "neu")], speakers: 1)]))
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.t0)
        await rig.add(live, sampleLines[0])
        let item = try rig.makeRaw(.call, at: Self.t0, seconds: 30)
        try await rig.finish(live, seconds: 30, raw: item)
        #expect(rig.transcriptFiles.map(\.lastPathComponent) == [live.url.lastPathComponent])
        #expect(!rig.names(in: rig.fassungen).isEmpty)
        #expect(rig.fassungen.path.hasPrefix(rig.paths.support.path))
    }
}
