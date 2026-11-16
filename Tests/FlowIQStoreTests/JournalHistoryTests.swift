import FlowIQCore
import Foundation
import Testing
@testable import FlowIQStore

/// The history window's reads (16.11.): pages, search, stats, deleting text and audio, keeping N days.
/// Invented text only, a scratch folder per test.
struct JournalHistoryTests {
    typealias Rig = AftercareReviewTests.Rig

    func journal(_ rig: Rig) throws -> (DictationJournal, Paths) {
        let paths = Paths(profile: .development, applicationSupport: rig.root)
        try rig.fs.makeFolder(paths.diktate)
        return (DictationJournal(paths: paths, fs: rig.fs, log: rig.log), paths)
    }

    func dictate(_ j: DictationJournal, _ id: String, _ text: String, app: String = "Notizen") async throws {
        try await j.append(.begin(id: id))
        try await j.append(JournalEntry("audio", id: id, ["seconds": .number(2)]))
        try await j.append(.recognized(id: id, recognizerText: text.lowercased(), finalText: text,
                                       interventions: [String](),
                                       ["recognize_ms": .number(40), "stage_ms": .number(2)]))
        try await j.append(.inserted(id: id, result: "landed", ["app": .string(app)]))
    }

    @Test func historyIsNewestFirstPagedAndSearchable() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let (j, _) = try journal(rig)
        for n in 1...5 { try await dictate(j, "d\(n)", "Satz Nummer \(n) über Kalmora") }
        let first = await j.history(limit: 2)
        #expect(first.map(\.id) == ["d5", "d4"])
        #expect(first[0].app == "Notizen" && first[0].result == "landed" && first[0].seconds == 2)
        #expect(first[0].rawText == "satz nummer 5 über kalmora" && first[0].msToText == 42)
        let next = await j.history(before: first.last?.date ?? .now, limit: 10)
        #expect(next.allSatisfy { $0.date <= first[1].date } && !next.contains { $0.id == "d5" })
        #expect(await j.history(matching: "nummer 3").map(\.id) == ["d3"])
        #expect(await j.history(matching: "Wipke").isEmpty)
        let stats = await j.stats()
        #expect(stats.dictations == 5 && stats.words == 25 && stats.wordsToday == 25 && stats.msToText == 42)
    }

    /// Lines from before 16.11. have no "app" (or a bare pid): they stay readable, a new line names the app.
    @Test func oldInsertedLinesWithoutAppStayReadable() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let (j, _) = try journal(rig)
        try await j.append(.begin(id: "alt"))
        try await j.append(.recognized(id: "alt", recognizerText: "alter satz", finalText: "Alter Satz",
                                       interventions: [String]()))
        try await j.append(.inserted(id: "alt", result: "landed"))
        try await dictate(j, "neu", "Neuer Satz", app: "Mail")
        let items = await j.history()
        #expect(items.map(\.id) == ["neu", "alt"])
        #expect(items[0].app == "Mail" && items[1].app == nil && items[1].result == "landed")
    }

    @Test func forgetRemovesTextAndAudioOfTheChosenOnly() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let (j, paths) = try journal(rig)
        for n in 1...3 { try await dictate(j, "d\(n)", "Geheimer Satz \(n)") }
        let audio = try await j.audioURL(for: "d2")
        try rig.fs.claimNew(audio, with: Data([1, 2, 3]))
        #expect(try await j.forget(["d2"]) == 4)
        #expect(await j.history().map(\.id) == ["d3", "d1"])
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.diktate.path)
            .filter { $0.hasSuffix(".jsonl") }
        let text = try files.map { try String(contentsOf: paths.diktate.appending(path: $0), encoding: .utf8) }
            .joined()
        #expect(!text.contains("Geheimer Satz 2") && text.contains("Geheimer Satz 3"))
        try await dictate(j, "d4", "Nach dem Löschen")  // the append handle opens again
        #expect(await j.history().first?.id == "d4")
    }

    @Test func pruneKeepsOnlyTheLastDays() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let (j, _) = try journal(rig)
        try await dictate(j, "alt", "Alter Satz")
        try await dictate(j, "neu", "Neuer Satz")
        #expect(try await j.prune(olderThan: 30, now: Date.now.addingTimeInterval(31 * 86_400)) == 8)
        #expect(await j.history().isEmpty)
        try await dictate(j, "heute", "Heutiger Satz")
        #expect(try await j.prune(olderThan: 30) == 0)
        #expect(await j.history().map(\.id) == ["heute"])
    }
}
