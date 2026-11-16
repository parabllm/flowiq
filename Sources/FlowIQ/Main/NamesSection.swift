import SwiftUI

/// Confirmed names and their hearing variants (16.11.): rename, still a variant, retire a name; one click each.
@MainActor @Observable
final class NamesModel {
    @ObservationIgnored var lexicon: LexiconStore?
    var names: [CanonEntry] = []
    var note = ""
    func load() async {
        guard let lexicon else { return }
        names = await lexicon.entries().filter { $0.status == .confirmed }
            .sorted { $0.canonical.localizedStandardCompare($1.canonical) == .orderedAscending }
    }
    func run(_ request: LexiconChangeRequest, _ done: String) async {
        do { _ = try await lexicon?.apply(request); note = done } catch { note = "Ging nicht." }
        await load()
    }
    /// A suspended variant counts no more; a click takes it back.
    func toggle(_ e: CanonEntry, _ v: HearingVariant) async {
        let off = v.status != .suspended
        await run(.setVariant(entry: e.id, variant: v.id, status: off ? .suspended : .active, reason: "klick"),
                  off ? "„\(v.heard.joined(separator: " "))“ stillgelegt." : "Wieder aktiv.")
    }
}

/// Wörter in the main window: the proposals and the confirmed names (the pill has no signs to explain, 16.11.).
struct WordsSection: View {
    let words: WordsModel?, panotti: Bool
    @Bindable var names: NamesModel
    let review: ReviewExchange
    var body: some View {
        let t = FlowIQTheme.self
        ScrollView {
            VStack(alignment: .leading, spacing: t.Spacing.s10) {
                if let words { WordsPane(model: words, panotti: panotti) }
                ReviewBlock(model: review)
                Block(title: "Bestätigte Namen", trailing: { Text(names.note).textStyle(t.Font.micro,
                                                                                        t.Color.textMuted) }) {
                    if names.names.isEmpty {
                        Text("Noch keine. Ein Klick in den Vorschlägen bestätigt einen Namen.")
                            .textStyle(t.Font.caption, t.Color.textMuted).frame(minHeight: t.Size.row)
                    }
                    ForEach(Array(names.names.enumerated()), id: \.element.id) { n, e in
                        NameRow(entry: e, names: names, last: n == names.names.count - 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, t.Main.inset)
            .padding(.bottom, t.Main.inset)
        }
        .task { await names.load() }
    }
}

struct NameRow: View {
    let entry: CanonEntry
    @Bindable var names: NamesModel
    let last: Bool
    @State private var spelling = ""
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: t.Spacing.s4) {
            HStack(spacing: t.Spacing.s8) {
                TextField("Schreibweise", text: $spelling).textFieldStyle(.plain).font(t.Font.custom(t.Font.caption))
                    .onSubmit { Task { await names.run(.rename(entry: entry.id, canonical: spelling), "Geändert.") } }
                Menu {
                    Button("Name stilllegen") {
                        Task { await names.run(.retireEntry(entry: entry.id, reason: "klick"), "Stillgelegt.") }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Weitere Aktionen: Name stilllegen").accessibilityLabel("Weitere Aktionen")
            }
            if !entry.hearingVariants.isEmpty {
                HStack(spacing: t.Spacing.s4) {
                    Text("gehört als").textStyle(t.Font.micro, t.Color.textMuted)
                    ForEach(entry.hearingVariants, id: \.id) { v in
                        let off = v.status == .suspended || v.status == .retired
                        Button { Task { await names.toggle(entry, v) } } label: {
                            Label(v.heard.joined(separator: " "), systemImage: off ? "arrow.uturn.backward" : "xmark")
                                .labelStyle(.titleAndIcon)
                                .textStyle(t.Font.micro, off ? t.Color.textMuted : t.Color.text)
                                .strikethrough(off).padding(.horizontal, t.Spacing.s6)
                                .background(t.Color.surfaceQuiet, in: Capsule())
                        }
                        .buttonStyle(.plain).help(off ? "Wieder aktiv" : "Stilllegen")
                    }
                }
            }
        }
        .padding(.vertical, t.Spacing.s4).overlay(alignment: .bottom) { Hairline(hidden: last) }
        .onAppear { spelling = entry.canonical }
    }
}
