import AppKit
import SwiftUI

/// "Mit Claude prüfen" (16.11., format in docs/PRUEFLISTE.md): the open questions leave as a file in the app's
/// data folder, decisions come back as a file and show as a dry run before they apply. FlowIQ itself sends nothing.
@MainActor @Observable
final class ReviewExchange {
    nonisolated struct Item: Codable, Equatable, Sendable {
        let id: String, art: String, gehoert: String, vorschlag: String, beispiele: [String]
    }
    nonisolated struct Decision: Codable, Equatable, Sendable {
        let id: String, aktion: String, schreibweise: String?
    }
    @ObservationIgnored var lexicon: LexiconStore?
    @ObservationIgnored var journal: DictationJournal?
    @ObservationIgnored var folder: URL?
    var path = ""
    var summary = ""
    var pending: [Decision] = []
    /// Proposed names and the list "Zum Prüfen", each with up to three short places from the journal.
    func export() async {
        guard let lexicon, let folder else { return }
        let entries = await lexicon.entries(), review = await lexicon.reviewList()
        var items: [Item] = []
        for e in entries where e.status == .proposed {
            let heard = e.hearingVariants.first?.heard.joined(separator: " ") ?? e.canonical
            items.append(Item(id: e.id, art: "name", gehoert: heard, vorschlag: e.canonical,
                              beispiele: await examples(heard)))
        }
        for (n, r) in review.enumerated() where r.settled == nil {
            let name = entries.first { $0.id == r.entryID }?.canonical ?? r.entryID
            items.append(Item(id: "pruefen-\(n)", art: "pruefen", gehoert: r.variantID ?? "", vorschlag: name,
                              beispiele: await examples(name)))
        }
        do {
            let coder = JSONEncoder()
            coder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let fs = SafeFS(confinedTo: folder)
            try fs.replace(folder.appending(path: "pruefliste.json"), with: coder.encode(items))
            try fs.replace(folder.appending(path: "pruefliste.md"), with: Data(Self.markdown(items).utf8))
            path = folder.appending(path: "pruefliste.md").path
            summary = "\(items.count) Einträge zum Prüfen."
        } catch { summary = "Liste nicht geschrieben." }
    }
    private func examples(_ word: String) async -> [String] {
        await (journal?.history(limit: 3, matching: word) ?? []).map { Self.snippet($0.text, around: word) }
    }
    /// About 80 characters around the word, never a whole dictation.
    nonisolated static func snippet(_ text: String, around word: String) -> String {
        guard let r = text.range(of: word, options: .caseInsensitive) else { return String(text.prefix(80)) }
        let from = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let to = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        return (from > text.startIndex ? "…" : "") + text[from..<to] + (to < text.endIndex ? "…" : "")
    }
    nonisolated static func markdown(_ items: [Item]) -> String {
        "# FlowIQ: Wörter zum Prüfen\n\nAntwort als entscheidungen.json: [{\"id\", \"aktion\": "
            + "bestaetigen | "  // ascii-ok: the key in the file
            + "ablehnen | richtiges-wort | stilllegen, \"schreibweise\"}]\n\n" + items.map { i in
                "## \(i.id) (\(i.art))\n\nGehört: \(i.gehoert) · Vorschlag: \(i.vorschlag)\n\n"
                    + i.beispiele.map { "- \($0)\n" }.joined()
            }.joined(separator: "\n")
    }
    /// The dry run: what would change, nothing changes yet.
    func read(_ url: URL) {
        do {
            pending = try JSONDecoder().decode([Decision].self, from: Data(contentsOf: url))
            let n = Dictionary(grouping: pending, by: \.aktion).mapValues(\.count)
            summary = n.sorted { $0.key < $1.key }.map { "\($0.value) \(Self.words[$0.key] ?? $0.key)" }
                .joined(separator: ", ") + ". Übernehmen?"
        } catch { (pending, summary) = ([], "Datei nicht lesbar, nichts übernommen.") }
    }
    /// The actions as the summary says them; the keys in the file stay ASCII (docs/PRUEFLISTE.md).
    nonisolated static let words = ["bestaetigen": "bestätigen", "richtiges-wort": "richtiges Wort"]  // ascii-ok
    func apply() async {
        guard let lexicon else { return }
        var done = 0
        for d in pending {
            let index = d.id.hasPrefix("pruefen-") ? Int(d.id.dropFirst(8)) : nil
            let request: LexiconChangeRequest? = switch d.aktion {
            case "bestaetigen": .confirmEntry(canonical: d.schreibweise ?? d.id)
            case "ablehnen", "stilllegen": index == nil ? .retireEntry(entry: d.id, reason: "claude") : nil
            case "richtiges-wort": .protect(form: d.schreibweise ?? d.id)
            default: nil
            }
            do {
                if let index { _ = try await lexicon.decide(index, d.aktion == "bestaetigen" ? .reactivate : .retire) }
                else if let request { _ = try await lexicon.apply(request) } else { continue }
                done += 1
            } catch { continue }
        }
        (pending, summary) = ([], "\(done) Entscheidungen übernommen.")
    }
}

/// The block in Wörter: export, path to copy, read the answers, dry run, apply.
struct ReviewBlock: View {
    @Bindable var model: ReviewExchange
    var body: some View {
        let t = FlowIQTheme.self
        Block("Mit Claude prüfen") {
            SettingRow(title: "Liste exportieren", sub: "offene Namen und Zum Prüfen, mit kurzen Beispielen") {
                Button("Exportieren") { Task { await model.export() } }.buttonStyle(FlowButton()).fixedSize()
                if !model.path.isEmpty {
                    Button("Pfad kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.path, forType: .string)
                    }
                    .buttonStyle(.plain).textStyle(t.Font.micro, t.Color.accent)
                }
            }
            SettingRow(title: "Entscheidungen einlesen", sub: "entscheidungen.json, erst eine Vorschau", last: true) {
                Button("Datei wählen …") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url { model.read(url) }
                }
                .buttonStyle(FlowButton()).fixedSize()
                if !model.pending.isEmpty {
                    Button("Übernehmen") { Task { await model.apply() } }.buttonStyle(FlowButton(primary: true))
                        .fixedSize()
                }
            }
            if !model.summary.isEmpty {
                Text(model.summary).textStyle(t.Font.micro, t.Color.textMuted).padding(.vertical, t.Spacing.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
