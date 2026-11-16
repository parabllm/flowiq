import SwiftUI

/// Verlauf: search and stats on top, then the days; a row shows its actions on hover or when selected.
struct HistoryPane: View {
    @Bindable var model: HistoryModel
    let keep: Bool, stepBack: () -> Void
    var body: some View {
        let t = FlowIQTheme.self
        HStack(alignment: .top, spacing: t.Spacing.s12) {
            VStack(alignment: .leading, spacing: t.Spacing.s8) {
                header
                if model.items.isEmpty { empty } else { list }
            }
            if model.stats.dictations > 0 { StatsCard(stats: model.stats).frame(width: t.Main.stats) }
        }
        .padding(.horizontal, t.Main.inset)
        .task { await model.load() }
        .onChange(of: model.query) { Task { await model.load() } }
        .sheet(isPresented: Binding(get: { model.asking != nil }, set: { if !$0 { model.asking = nil } })) {
            DeleteConfirm(count: model.asking?.count ?? 0, onDelete: {
                Task { await model.delete(model.asking ?? []) } }, onCancel: { model.asking = nil })
        }
    }
    private var header: some View {
        let t = FlowIQTheme.self
        return VStack(alignment: .leading, spacing: t.Spacing.s8) {
            HStack(spacing: t.Spacing.s8) {
                Image(systemName: "magnifyingglass").foregroundStyle(t.Color.textMuted)
                TextField("Verlauf durchsuchen", text: $model.query).textFieldStyle(.plain)
                    .font(t.Font.custom(t.Font.caption))
            }
            .padding(.horizontal, t.Spacing.s10).frame(height: t.Size.control + t.Spacing.s2).card()
            if model.selection.count > 1 || !model.note.isEmpty { HStack(spacing: t.Spacing.s8) {
                if model.selection.count > 1 {
                    Text("\(model.selection.count) ausgewählt").textStyle(t.Font.caption)
                    Button("Kopieren") { model.copy(model.targets(model.selection.first ?? "")) }
                        .buttonStyle(FlowButton())
                    Button("Löschen …") { model.asking = model.selection }.buttonStyle(FlowButton()).fixedSize()
                }
                Text(model.note).textStyle(t.Font.micro, t.Color.textMuted)
            } }
        }
    }
    private var empty: some View {
        let t = FlowIQTheme.self
        let none = model.query.isEmpty
        return VStack(alignment: .leading, spacing: t.Spacing.s4) {
            Text(none ? "Noch keine Diktate." : "Nichts gefunden für „\(model.query)“.").textStyle(t.Font.smallMedium)
            Text(none ? "Fn halten und sprechen, das Diktat steht danach hier." : "Die Suche sieht den eingefügten "
                 + "Text, nicht die Rohfassung.").textStyle(t.Font.caption, t.Color.textMuted)
        }
        .padding(.top, t.Spacing.s4)
    }
    private var list: some View {
        let t = FlowIQTheme.self
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: t.Spacing.s4) {
                ForEach(model.days, id: \.title) { day in
                    Text(day.title).textStyle(t.Font.label, t.Color.textMuted).padding(.top, t.Spacing.s6)
                    VStack(spacing: 0) {
                        ForEach(Array(day.items.enumerated()), id: \.element.id) { n, item in
                            HistoryRow(model: model, item: item, keep: keep, last: n == day.items.count - 1,
                                       stepBack: stepBack)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: t.Radius.md, style: .continuous)).card()
                }
                if model.hasMore {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        .task { await model.load(more: true) }
                }
            }
            .padding(.bottom, t.Main.inset)
        }
        .onCopyCommand { model.selection.isEmpty ? [] : [NSItemProvider(object: HistoryModel.joined(
            model.targets(model.selection.first ?? "")) as NSString)] }
        .onDeleteCommand { if !model.selection.isEmpty { model.asking = model.selection } }
    }
}

/// One dictation: time, text with the words FlowIQ changed dotted, app and outcome; actions on hover.
struct HistoryRow: View {
    @Bindable var model: HistoryModel
    let item: HistoryItem, keep: Bool, last: Bool, stepBack: () -> Void
    @State private var hover = false
    var body: some View {
        let t = FlowIQTheme.self, picked = model.selection.contains(item.id)
        let outcome = HistoryModel.outcome(item, keep: keep)
        HStack(alignment: .firstTextBaseline, spacing: t.Spacing.s8) {
            Text(item.date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE"))))
                .textStyle(t.Font.micro, t.Color.textMuted).frame(width: t.Main.time, alignment: .leading)
            VStack(alignment: .leading, spacing: t.Spacing.s2) {
                let long = item.text.count > t.Main.long, open = model.open.contains(item.id)
                Self.marked(item).textStyle(t.Font.caption).lineLimit(long && !open ? t.Main.folded : nil)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if long {
                    Button(open ? "Weniger" : "Ganzen Text zeigen") { model.open.formSymmetricDifference([item.id]) }
                        .buttonStyle(.plain).textStyle(t.Font.micro, t.Color.accent)
                }
                if outcome == .failed { Button("Erneut erkennen") { Task { await model.recognizeAgain(item) } }
                    .buttonStyle(FlowButton()).fixedSize() }
                if model.raw.contains(item.id) { aside("Rohfassung", item.rawText) }
                if let again = model.again[item.id] { aside("Neu erkannt", again) }
                HStack(spacing: t.Spacing.s6) {
                    Text([HistoryModel.appName(item.app), HistoryModel.outcomeText(outcome),
                          item.changed.isEmpty ? nil : "von FlowIQ geändert"].compactMap { $0 }
                        .joined(separator: " · "))
                        .textStyle(t.Font.micro, outcome == .inserted ? t.Color.textMuted : t.Color.warningText)
                    if model.busy.contains(item.id) { ProgressView().controlSize(.mini) }
                }
            }
            Spacer(minLength: 0)
            actions.opacity(hover || picked ? 1 : 0).allowsHitTesting(hover || picked)  // always laid out: no reflow
        }
        .padding(.horizontal, t.Spacing.s10).padding(.vertical, t.Spacing.s6)
        .background(picked ? t.Color.accentTint : hover ? t.Color.surfaceQuiet : .clear)
        .overlay(alignment: .bottom) { Hairline(hidden: last) }
        .contentShape(Rectangle()).onHover { hover = $0 }
        .onTapGesture { model.click(item.id, extend: NSEvent.modifierFlags.contains(.command)) }
        .accessibilityElement(children: .contain)
    }
    private func aside(_ title: String, _ text: String) -> some View {
        let t = FlowIQTheme.self
        return VStack(alignment: .leading, spacing: t.Spacing.s2) {
            Text(title).textStyle(t.Font.micro, t.Color.textMuted)
            Text(text).textStyle(t.Font.caption, t.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(t.Spacing.s8).frame(maxWidth: .infinity, alignment: .leading)
        .background(t.Color.surfaceQuiet, in: RoundedRectangle(cornerRadius: t.Spacing.s8, style: .continuous))
    }
    private var actions: some View {  // icon buttons with tooltips, the rest behind "…": the row stays calm
        let t = FlowIQTheme.self, list = model.targets(item.id)
        return HStack(spacing: t.Spacing.s2) {
            icon("doc.on.doc", "Kopieren") { model.copy(list) }
            icon("arrow.uturn.forward", "Erneut einfügen") { model.insertAgain(item, hide: stepBack) }
            icon("pencil", "Korrigieren") { model.correct(item.id) }
            Menu {
                Button(model.raw.contains(item.id) ? "Rohfassung ausblenden" : "Rohfassung zeigen") {
                    model.raw.formSymmetricDifference([item.id])
                }
                Button("Audio abspielen") { Task { await model.play(item) } }
                Button("Erneut erkennen") { Task { await model.recognizeAgain(item) } }
                Menu("Als Name merken") {
                    ForEach(HistoryModel.nameCandidates(item.text), id: \.self) { w in
                        Button(w) { Task { await model.remember(w) } }
                    }
                }
                Divider()
                Button("Löschen …", role: .destructive) { model.asking = Set(list.map(\.id)) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .frame(width: t.Size.control, height: t.Size.control).accessibilityLabel("Weitere Aktionen")
                .help("Weitere Aktionen: Rohfassung, abspielen, erneut erkennen, als Name merken, löschen")
        }
        .foregroundStyle(t.Color.textMuted)
    }
    private func icon(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        let t = FlowIQTheme.self
        return Button(action: run) { Image(systemName: symbol).frame(width: t.Size.control, height: t.Size.control) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    /// The final text, words FlowIQ put in dotted in the accent (N.2).
    static func marked(_ item: HistoryItem) -> Text {
        let changed = Set(item.changed.flatMap { $0.split(separator: " ").map(String.init) })
        var out = AttributedString()
        for (n, word) in item.text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((n == 0 ? "" : " ") + word)
            if changed.contains(word.trimmingCharacters(in: .punctuationCharacters)) {
                piece.underlineStyle = Text.LineStyle(pattern: .dot, color: FlowIQTheme.Color.accent)
            }
            out += piece
        }
        return Text(out)
    }
}

struct StatsCard: View {  // counted from the journal only
    let stats: HistoryStats
    var body: some View {
        let t = FlowIQTheme.self
        let rows: [(String, String)] = [
            (stats.words.formatted(.number.locale(Locale(identifier: "de_DE"))), "Wörter gesamt"),
            (stats.wordsToday.formatted(), "Wörter heute"), (stats.dictations.formatted(), "Diktate"),
            (stats.msToText > 0 ? "\(Int(stats.msToText.rounded())) ms" : "–", "bis der Text da ist"),
            (stats.corrections.formatted(), "Korrekturen gelernt")]
        VStack(alignment: .leading, spacing: t.Spacing.s6) {
            ForEach(rows, id: \.1) { value, label in
                HStack(alignment: .firstTextBaseline, spacing: t.Spacing.s4) {
                    Text(value).textStyle(t.Font.badge)
                    Text(label).textStyle(t.Font.micro, t.Color.textMuted)
                }
            }
        }
        .padding(t.Spacing.s10).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

/// The question before deleting, in the window's own build so it shows in the gallery too; Escape cancels.
struct DeleteConfirm: View {
    let count: Int, onDelete: () -> Void, onCancel: () -> Void
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: t.Spacing.s8) {
            Text(count == 1 ? "Dieses Diktat löschen?" : "\(count) Diktate löschen?").textStyle(t.Font.smallMedium)
            Text("Text und Audio gehen von diesem Mac. Das lässt sich nicht zurückholen.")
                .textStyle(t.Font.caption, t.Color.textMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: t.Spacing.s8) {
                Spacer(minLength: 0)
                Button("Abbrechen", action: onCancel).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button("Löschen", role: .destructive, action: onDelete).buttonStyle(.borderedProminent)
                    .tint(t.Color.warning)
            }
            .controlSize(.large).padding(.top, t.Spacing.s8).environment(\.controlActiveState, .key)
        }
        .padding(t.Spacing.s20).frame(width: t.Main.dialog, alignment: .leading).background(t.Color.surface)
    }
}
