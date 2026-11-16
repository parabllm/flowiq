import AppKit
import SwiftUI

/// The history of the main window (16.11.): journal dictations, newest first, paged; nothing leaves the Mac.
@MainActor @Observable
final class HistoryModel {
    nonisolated enum Outcome: Hashable { case inserted, clipboard, notInserted, failed }
    @ObservationIgnored var journal: DictationJournal?
    @ObservationIgnored var inserter: Inserter?
    @ObservationIgnored var lexicon: LexiconStore?
    @ObservationIgnored var log: EventLog?
    @ObservationIgnored let correct: (String) -> Void
    var items: [HistoryItem] = []
    var stats = HistoryStats()
    var query = ""
    var selection: Set<String> = []
    var raw: Set<String> = []
    var open: Set<String> = []  // long dictations shown whole
    var again: [String: String] = [:]
    var asking: Set<String>?
    var renewing: (list: [HistoryItem], ask: (title: String, text: String))?  // the question before a large batch
    /// One dictation through the ElevenLabs after-run, set when the window opens: the new text, lexicon applied.
    @ObservationIgnored var redo: ((DictationJob) async throws -> String)?
    var hasMore = false
    var busy: Set<String> = []
    var note = ""
    @ObservationIgnored private var player: NSSound?
    init(journal: DictationJournal?, correct: @escaping (String) -> Void) {
        (self.journal, self.correct) = (journal, correct)
    }
    /// Reloads from the top (search changed, window opened); `more` pages on below the last row.
    func load(more: Bool = false) async {
        guard let journal else { return }
        let page = FlowIQTheme.Main.page
        let next = await journal.history(before: more ? items.last?.date : nil, limit: page, matching: query)
        (items, hasMore) = (more ? items + next : next, next.count == page)
        if !more { stats = await journal.stats() }
    }
    /// Days, newest first, each with its rows: "Heute", "Gestern", then the date.
    var days: [(title: String, items: [HistoryItem])] {
        let groups = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { (Self.dayTitle($0), groups[$0] ?? []) }
    }
    nonisolated static func dayTitle(_ day: Date, now: Date = .now) -> String {
        let c = Calendar.current
        guard !c.isDate(day, inSameDayAs: now) else { return "Heute" }
        if let y = c.date(byAdding: .day, value: -1, to: now), c.isDate(day, inSameDayAs: y) { return "Gestern" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "de_DE")))
    }
    nonisolated static func outcome(_ item: HistoryItem, keep: Bool) -> Outcome {
        switch item.result {
        case "landed": .inserted
        case nil: .failed
        default: keep ? .clipboard : .notInserted
        }
    }
    nonisolated static func outcomeText(_ o: Outcome) -> String { [.inserted: "eingefügt", .clipboard:
        "in der Zwischenablage", .notInserted: "nicht eingefügt", .failed: "nicht erkannt"][o] ?? "" }
    /// App names from the journal; a bundle identifier is shown by its name, a bare "pid-…" is no name.
    nonisolated static func appName(_ app: String?) -> String? {
        guard let app, !app.isEmpty, !app.hasPrefix("pid-") else { return nil }
        let url = app.contains(".") ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) : nil
        return url.map { FileManager.default.displayName(atPath: $0.path).replacing(".app", with: "") } ?? app
    }
    /// The rows an action works on: the selection when the row is part of it, else the row alone.
    func targets(_ id: String) -> [HistoryItem] {
        let ids = selection.contains(id) ? selection : [id]
        return items.filter { ids.contains($0.id) }
    }
    func click(_ id: String, extend: Bool) {
        if extend { selection.formSymmetricDifference([id]) } else { selection = selection == [id] ? [] : [id] }
    }
    func copy(_ list: [HistoryItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.joined(list), forType: .string)
        note = list.count == 1 ? "Kopiert." : "\(list.count) Diktate kopiert."
    }
    nonisolated static func joined(_ list: [HistoryItem]) -> String {
        list.sorted { $0.date < $1.date }.map(\.text).joined(separator: "\n\n")
    }
    /// Into the app that was in front before FlowIQ: the window steps back, then the text is inserted.
    func insertAgain(_ item: HistoryItem, hide: @escaping () -> Void) {
        hide()
        Task { if await inserter?.insert(item.text) != .landed { copy([item]) } }
    }
    func play(_ item: HistoryItem) async {
        player?.stop()
        guard let url = await journal?.audio(of: item), let sound = NSSound(contentsOf: url, byReference: true) else {
            note = "Kein Audio gespeichert."
            return
        }
        (player, note) = (sound, "")
        sound.play()
    }
    /// Recognizes the saved audio again, locally; the result stands below the row, the journal stays as it was.
    func recognizeAgain(_ item: HistoryItem) async {
        guard let url = await journal?.audio(of: item) else { return note = "Kein Audio gespeichert." }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        do {
            let r = try await FileTranscriber.recognize(url, locale: Locale(identifier: "de-DE"),
                                                        limit: .seconds(max(60, (item.seconds ?? 0) * 4)),
                                                        log: log)
            again[item.id] = r.text
        } catch { note = "Erneut erkennen ging nicht." }
    }
    /// What a re-recognition over ElevenLabs asks first: more than 10 at once or more than 30 minutes of audio.
    nonisolated static func renewQuestion(count: Int, seconds: Double, recording: Bool = false)
        -> (title: String, text: String)? {
        guard count > 10 || seconds > 1800 else { return nil }
        return (recording ? "Aufnahme mit ElevenLabs neu erkennen?" : "\(count) Diktate mit ElevenLabs neu erkennen?",
                "\(Int((seconds / 60).rounded())) Min. Audio gehen an ElevenLabs.")
    }
    /// "Mit ElevenLabs neu erkennen": the kept audio of each dictation (at most 50, one after the other) goes
    /// through the after-run; the new text replaces the shown one (a "renewed" line in the journal, nothing is
    /// lost: the raw version stays), nothing is inserted anywhere. The busy mark leaves each row when it is done.
    func renew(_ list: [HistoryItem], confirmed: Bool = false) async {
        let batch = Array(list.prefix(50)), seconds = batch.reduce(0) { $0 + ($1.seconds ?? 0) }
        if !confirmed, let ask = Self.renewQuestion(count: batch.count, seconds: seconds) {
            return renewing = (batch, ask)
        }
        renewing = nil
        guard let redo, let journal else { return }
        busy.formUnion(batch.map(\.id))
        var done = 0, stop: String?
        for item in batch where stop == nil {
            do {
                guard let url = await journal.audio(of: item) else { throw CocoaError(.fileNoSuchFile) }
                let text = try await redo(DictationJob(id: item.id, audio: url, language: "de",
                                                       insertedText: item.text, seconds: item.seconds ?? 0))
                try await journal.append(JournalEntry("renewed", id: item.id, ["final_text": .string(text)]))
                done += 1
                items = await journal.history(limit: max(FlowIQTheme.Main.page, items.count), matching: query)
            } catch let failure as PostFailure where [.notAllowed, .keyMissing, .quotaExhausted].contains(failure) {
                stop = failure == .notAllowed ? "Monatsgrenze erreicht." : failure == .keyMissing
                    ? "ElevenLabs-Schlüssel fehlt oder abgelehnt." : "ElevenLabs-Kontingent leer."
            } catch { log?.record(.failure("history_renew_failed", error)) }
            busy.remove(item.id)
        }
        busy.subtract(batch.map(\.id))
        note = stop ?? (done < batch.count ? "\(done) von \(batch.count) neu erkannt."
            : done == 1 ? "Neu erkannt." : "\(done) Diktate neu erkannt.")
    }
    /// A word of the dictation becomes a confirmed name (N.3: one click per name).
    func remember(_ word: String) async {
        do {
            _ = try await lexicon?.apply(.confirmEntry(canonical: word))
            note = "„\(word)“ steht jetzt als Name in Wörter."
        } catch { note = "Name nicht gespeichert." }
    }
    /// Words that can become a name: capitalized or with a digit, without punctuation, each once.
    nonisolated static func nameCandidates(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { w in
            w.count > 1 && (w.first?.isUppercase == true || w.contains { $0.isNumber }) && seen.insert(w).inserted
        }
    }
    /// After the question: text and audio go (the journal month files are rewritten without them).
    func delete(_ ids: Set<String>) async {
        asking = nil
        do { try await journal?.forget(ids) } catch { note = "Löschen ging nicht." }
        selection.subtract(ids)
        await load()
    }
}
