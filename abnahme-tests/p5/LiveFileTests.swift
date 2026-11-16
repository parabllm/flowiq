// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 2: the live file only grows (R-053, E5, A.9 `actor LiveTranscript`). Finished lines never change;
// at most one volatile closing line ("spricht gerade") is replaced by cutting and appending. Panotti
// rewrote the whole file per segment; that is excluded here (same file object, same prefix bytes).
import Foundation
import Testing

struct LiveFileTests {
    static let start = localDate(2026, 11, 13, 10, 45)

    /// The bytes before the volatile closing line (or all bytes when there is none).
    private func stablePrefix(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        guard let newline = text.lastIndex(of: "\n") else { return data }
        guard isVolatileLine(String(text[text.index(after: newline)...])) else { return data }
        return Data(text[...newline].utf8)
    }

    /// Property: over random operation sequences, the stable text of every state starts every later state.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func stableTextIsAlwaysAPrefixOfTheNextState(seed: Int) async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        var rng = Lcg(state: UInt64(seed) &* 7919)
        var clockSeconds = 0
        var previousStable = try stablePrefix(live.url)
        var appended: [Line] = []
        for step in 0..<120 {
            clockSeconds += 1 + rng.next(9)
            let line = Line(seconds: clockSeconds, speaker: rng.next(2) == 0 ? "Mara" : "Gegenseite", text: "Satz \(step) mit Übung")
            switch rng.next(4) {
            case 0, 1:
                await rig.add(live, line)
                appended.append(line)
            case 2:
                await rig.volatile(live, line)
            default:
                await rig.clearVolatile(live)
            }
            await rig.sync(live)
            let now = try Data(contentsOf: live.url)
            #expect(now.starts(with: previousStable), "step \(step): finished text changed")
            previousStable = try stablePrefix(live.url)
            let volatileLines = String(decoding: now, as: UTF8.self).split(separator: "\n").filter { isVolatileLine(String($0)) }
            #expect(volatileLines.count <= 1)
            let doc = try readDoc(live.url)
            #expect(doc.lines == appended)  // finished contributions: all there, in order, none changed
            #expect(String(decoding: now, as: UTF8.self).hasSuffix("\n"))  // ASSUMPTION: every line, the volatile one too, is newline-terminated
        }
    }

    @Test func volatileLineIsLastAndReplacedNotDuplicated() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, sampleLines[0])
        await rig.volatile(live, Line(seconds: 7, speaker: "Mara", text: "halber Sa"))
        await rig.volatile(live, Line(seconds: 7, speaker: "Mara", text: "halber Satz der wächst"))
        await rig.sync(live)
        var lines = String(decoding: try Data(contentsOf: live.url), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.filter(isVolatileLine).count == 1)
        #expect(isVolatileLine(try #require(lines.last)))
        #expect(lines.last?.contains("halber Satz der wächst") == true)
        #expect(lines.last?.contains("(spricht gerade…)") == true)
        await rig.clearVolatile(live)
        await rig.sync(live)
        lines = String(decoding: try Data(contentsOf: live.url), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.filter(isVolatileLine).isEmpty)
        #expect(try readDoc(live.url).lines == [sampleLines[0]])
    }

    /// A finished contribution appended after a volatile line lands below the old stable text, never above it.
    @Test func finishedLineReplacesTheVolatileOneInPlace() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, sampleLines[0])
        await rig.volatile(live, Line(seconds: 20, speaker: "Gegenseite", text: "noch nicht fertig"))
        await rig.sync(live)
        let before = try stablePrefix(live.url)
        await rig.add(live, Line(seconds: 20, speaker: "Gegenseite", text: "jetzt fertig"))
        await rig.sync(live)
        let doc = try readDoc(live.url)
        #expect(try Data(contentsOf: live.url).starts(with: before))
        #expect(doc.lines.map(\.text) == [sampleLines[0].text, "jetzt fertig"])
    }

    /// Same file object and same header bytes throughout: no rewrite of the whole file per segment.
    @Test func fileIsNeverReplacedWhileLive() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        let number = try #require(inode(live.url))
        let header = try Data(contentsOf: live.url)
        for n in 0..<200 {
            await rig.add(live, Line(seconds: n, speaker: "Mara", text: "Zeile \(n)"), flush: false)
            if n % 7 == 0 { await rig.volatile(live, Line(seconds: n + 1, speaker: "Gegenseite", text: "läuft")) }
        }
        await rig.sync(live)
        #expect(inode(live.url) == number)  // ASSUMPTION: appending and cutting edit the same inode; an atomic whole-file replace changes it
        #expect(try Data(contentsOf: live.url).starts(with: header))
        // No sibling temp files left by a replace-style writer.
        #expect(rig.names(in: rig.transcripts).filter { $0 != "archive" } == [live.url.lastPathComponent])
    }

    /// R-053: a finished sentence is in the file within the 5 s bound once it was handed over.
    @Test func sentenceIsOnDiskWithinFiveSeconds() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: Self.start)
        let deadline = Date().addingTimeInterval(5)
        await rig.add(live, Line(seconds: 2, speaker: "Raum", text: "Messsatz"), flush: false)  // no flush: the 5 s bound is the contract
        var found = false
        while Date() < deadline && !found {
            found = (try? readDoc(live.url).lines.contains { $0.text == "Messsatz" }) == true
            if !found { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(found)
    }

    /// Stop right after the last append: nothing handed over is lost (no waiting for a timer).
    @Test func stopRightAfterAppendKeepsEverything() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        var expected: [Line] = []
        for n in 0..<50 {
            let l = Line(seconds: n * 3, speaker: n % 2 == 0 ? "Mara" : "Gegenseite", text: "Satz \(n)")
            await rig.add(live, l, flush: false)  // no flush: stop itself must write everything out
            expected.append(l)
        }
        let item = try rig.makeRaw(.call, at: Self.start, seconds: 150)
        try await rig.finish(live, seconds: 150, raw: item)
        #expect(try readDoc(live.url).lines == expected)
    }

    /// A partial sentence still pending at stop is promoted to a normal line, not dropped (no silent loss of text).
    @Test func volatileTextAtStopIsKeptAsAFinishedLine() async throws {
        let rig = try Rig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        await rig.add(live, sampleLines[0])
        await rig.volatile(live, Line(seconds: 30, speaker: "Gegenseite", text: "unfertiger letzter Satz"))
        let item = try rig.makeRaw(.call, at: Self.start, seconds: 40)
        try await rig.finish(live, seconds: 40, raw: item)  // ASSUMPTION: a pending partial text becomes a finished contribution at stop
        let doc = try readDoc(live.url)
        #expect(doc.lines.contains { $0.text == "unfertiger letzter Satz" })
        #expect(!doc.body.contains(where: isVolatileLine))
    }

    /// After stop the file holds no "spricht gerade" line in any end phase.
    @Test func noVolatileLineSurvivesAnyEndPhase() async throws {
        for enabled in [true, false] {
            let rig = try Rig.make(post: FakePost(script: [], fallback: .fail(.networkDown)), postEnabled: enabled)
            defer { rig.remove() }
            let live = try await rig.begin(.room, at: Self.start)
            await rig.volatile(live, Line(seconds: 3, speaker: "Raum", text: "offen"))
            let item = try rig.makeRaw(.room, at: Self.start, seconds: 10)
            try await rig.finish(live, seconds: 10, raw: item)
            #expect(!(try readDoc(live.url)).body.contains(where: isVolatileLine))
        }
    }

    /// Dictation during a call lands as one more contribution and does not disturb the neighbours (R-024).
    @Test func tenDictationsLandBetweenTheCallLines() async throws {
        let rig = try Rig.make()
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: Self.start)
        var expected: [String] = []
        for n in 0..<10 {
            let call = Line(seconds: n * 60, speaker: "Gegenseite", text: "Gesprächsteil \(n)")
            let dictated = Line(seconds: n * 60 + 30, speaker: "Mara", text: "Diktat \(n)")
            await rig.add(live, call)
            await rig.add(live, dictated, dictation: true)
            expected.append(formatLine(call))
            expected.append(formatLine(Line(seconds: dictated.seconds, speaker: "Mara (Diktat)", text: dictated.text)))
        }
        #expect(try readDoc(live.url).contributions == expected)
        #expect(try readDoc(live.url).contributions.filter { $0.contains("(Diktat)") }.count == 10)
    }
}
