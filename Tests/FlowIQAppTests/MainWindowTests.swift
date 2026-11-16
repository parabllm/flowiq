import Foundation
import Testing
@testable import FlowIQ

/// The main window's models (16.11.): day titles, outcome words, name candidates, the recordings list.
struct MainWindowTests {
    @Test func daysAreTodayYesterdayThenTheDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HistoryModel.dayTitle(now, now: now) == "Heute")
        #expect(HistoryModel.dayTitle(now.addingTimeInterval(-86_400), now: now) == "Gestern")
        #expect(HistoryModel.dayTitle(now.addingTimeInterval(-3 * 86_400), now: now).contains("Januar"))
    }

    @Test func outcomeSaysWhereTheTextIs() {
        func item(_ result: String?) -> HistoryItem {
            HistoryItem(id: "a", date: .now, text: "x", rawText: "x", changed: [], app: nil, result: result,
                        seconds: nil, msToText: nil)
        }
        #expect(HistoryModel.outcome(item("landed"), keep: true) == .inserted)
        #expect(HistoryModel.outcome(item("noTextFocus"), keep: true) == .clipboard)
        #expect(HistoryModel.outcome(item("noTextFocus"), keep: false) == .notInserted)
        #expect(HistoryModel.outcome(item(nil), keep: true) == .failed)
        #expect(HistoryModel.outcomeText(.clipboard) == "in der Zwischenablage")
    }

    /// The journal's app name is shown as it is; an old bare pid or nothing shows no app.
    @Test func targetAppNameIsShownPidIsNot() {
        #expect(HistoryModel.appName("Notizen") == "Notizen" && HistoryModel.appName("Visual Studio Code")
                == "Visual Studio Code")
        #expect(HistoryModel.appName("pid-412") == nil && HistoryModel.appName(nil) == nil)
    }

    @Test func nameCandidatesAreCapitalizedOrNumberedWordsOnce() {
        #expect(HistoryModel.nameCandidates("Schick Kalmora bis Freitag die Zahlen, Kalmora und 4711.")
                == ["Schick", "Kalmora", "Freitag", "Zahlen", "4711"])
    }

    @Test @MainActor func selectionTogglesWithCommandAndActsOnAllSelected() {
        let m = HistoryModel(journal: nil) { _ in }
        m.items = ["a", "b", "c"].map {
            HistoryItem(id: $0, date: .now, text: $0, rawText: $0, changed: [], app: nil, result: "landed",
                        seconds: nil, msToText: nil)
        }
        m.click("a", extend: false)
        m.click("c", extend: true)
        #expect(m.selection == ["a", "c"] && m.targets("a").map(\.id) == ["a", "c"])
        #expect(m.targets("b").map(\.id) == ["b"])
        m.click("a", extend: false)
        #expect(m.selection == ["a"])
    }

    @Test func recordingRowsComeFromTheHeader() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "flowiq-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "archive"), withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record("cleanup: \(error)") } }
        let head = "---\ntype: transkript\npanotti_phase: live-lokal\nquelle: /x/Call\ndauer: 12:41\nsprache: en\n"
        try Data((head + "nachlauf: angehalten\nlive_quelle: elevenlabs-scribe-v3-live\n---\n").utf8)
            .write(to: dir.appending(path: "2026-11-16-0930-call.md"))
        try Data("---\npanotti_phase: final-lokal\ndauer: 03:00\n---\n".utf8)
            .write(to: dir.appending(path: "archive/2026-11-15-1200-raum.md"))
        let rows = RecordingsModel.scan(dir)
        #expect(rows.map(\.kind) == ["Call", "Raum"])
        #expect(rows[0].post == .paused && rows[0].language == "Englisch")
        #expect(rows[0].live == "Mitschrift über ElevenLabs")
        #expect(rows[0].audio?.path == "/x/Call/mikrofon.m4a" && rows[1].post == .local)
    }

    /// "Mit Claude prüfen": short places only, an answer file is a dry run until Übernehmen.
    @MainActor @Test func reviewExportKeepsExamplesShortAndReadingAnswersChangesNothing() throws {
        let long = String(repeating: "vorher ", count: 20) + "Kalmora" + String(repeating: " danach", count: 20)
        let s = ReviewExchange.snippet(long, around: "kalmora")
        #expect(s.count < 100 && s.contains("Kalmora") && s.hasPrefix("…") && s.hasSuffix("…"))
        let item = ReviewExchange.Item(id: "k", art: "name", gehoert: "Kal Mora", vorschlag: "Kalmora", beispiele: [s])
        #expect(ReviewExchange.markdown([item]).contains("## k (name)"))
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record(error) } }
        let url = dir.appending(path: "entscheidungen.json")
        try Data(#"[{"id":"k","aktion":"bestaetigen"},{"id":"w","aktion":"ablehnen"}]"#.utf8).write(to: url)
        let r = ReviewExchange()
        r.read(url)
        #expect(r.pending.count == 2 && r.summary == "1 ablehnen, 1 bestätigen. Übernehmen?")
        try Data("kaputt".utf8).write(to: url)
        r.read(url)
        #expect(r.pending.isEmpty && r.summary.hasPrefix("Datei nicht lesbar"))
    }
}
