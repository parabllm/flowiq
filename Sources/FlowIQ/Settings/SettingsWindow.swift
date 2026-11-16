import SwiftUI
/// A themed window, created once, shown and hidden without animation (Panotti B82).
final class SmallWindow: NSObject, NSWindowDelegate {
    private let make: () -> NSWindow
    private lazy var window = make()
    var onClose: () -> Void = {}, onKey: () -> Void = {}
    init(_ title: String, _ root: some View, plain: Bool = false) {
        make = {
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            (w.title, w.animationBehavior, w.isReleasedWhenClosed) = (title, .none, false)
            w.styleMask = plain ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable]
            (w.titleVisibility, w.titlebarAppearsTransparent) = (plain ? .hidden : .visible, plain)
            (w.isMovableByWindowBackground, w.backgroundColor) = (true, FlowIQTheme.Color.windowBackground)
            w.center()
            return w
        }
    }
    func show() {
        window.delegate = self
        Front.show(window)
    }
    func hide() { Front.close(window) }
    func windowDidBecomeKey(_ notification: Notification) { onKey() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        hide()
        return false
    }
}

/// Einstellungen 440 × 520 (A.12, R-077 to R-079): three areas, at most 12 controls each, explanations collapsed.
struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        let t = FlowIQTheme.self
        let tabs = [(AppModel.Tab.recording, "Aufnahme"), (.devices, "Geräte"), (.permissions, "Berechtigungen")]
        return VStack(alignment: .leading, spacing: t.Spacing.s8) {  // Wörter has its own place
            Segments(options: tabs, selection: Binding(get: { model.ui.tab == .words ? .recording : model.ui.tab },
                                                       set: { model.ui.tab = $0 }))
            switch model.ui.tab {
            case .recording, .words: RecordingPane(model: model)
            case .devices: DevicesPane(model: model.parts.devices ?? DevicesModel(nil), panotti: model.panotti != nil)
            case .permissions: PermissionsPane(model: model.setup, tapRunning: model.ui.tapRunning) {
                await model.refresh()
            }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, t.Main.inset).padding(.bottom, t.Main.inset)
        .frame(minWidth: t.Main.form, maxWidth: .infinity).background(t.Color.background)  // fills like Verlauf
    }
}

/// A section: label (with an optional right side) over a card of rows.
struct Block<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: t.Spacing.s4) {
            HStack { Text(title).textStyle(t.Font.label, t.Color.textMuted); Spacer(); trailing }
                .padding(.horizontal, t.Spacing.s4)
            VStack(spacing: 0) { content }.padding(.horizontal, t.Spacing.s12).card()
        }
    }
}

extension Block where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        (self.title, trailing, self.content) = (title, EmptyView(), content())
    }
}

/// One row of a card with its name and a hairline below (none under the last).
struct Row<Content: View>: View {
    let title: String
    var last = false, compact = false
    @ViewBuilder var content: Content
    var body: some View {
        let t = FlowIQTheme.self
        HStack(spacing: t.Spacing.s8) {
            Text(title).textStyle(t.Font.caption).frame(width: compact ? t.Spacing.s24 * 2 : t.Spacing.s24 * 3,
                alignment: .leading)
            content
        }
        .frame(minHeight: compact ? t.Size.control : t.Size.row).overlay(alignment: .bottom) { Hairline(hidden: last) }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct Hairline: View {
    var hidden = false
    var body: some View {
        Rectangle().fill(hidden ? .clear : FlowIQTheme.Color.hairline).frame(height: FlowIQTheme.Size.hairline)
    }
}

/// Wörter (A.12, N.3, N.5, review M10): new names and pairs, each with one main click and "…"; "Zum Prüfen" with "…".
@MainActor @Observable
final class WordsModel {
    /// One proposal: a name with an editable spelling, or a pair from the ledger.
    typealias Work = @Sendable () async throws -> Void
    struct Item: Identifiable {
        let id: String, heard: String, spelling: String?, main: String
        let run: @Sendable (String) async throws -> Void, more: [(String, Work)]
    }
    let lexicon: LexiconStore, ledger: CorrectionLedger
    var items: [Item] = []
    var review: [(index: Int, title: String, detail: String)] = []
    var spelling: [String: String] = [:]
    var head = ""
    var importable = false
    var start: (URL, StartSummary)?
    @ObservationIgnored var adopted: () -> Void = {}
    init(lexicon: LexiconStore, ledger: CorrectionLedger) { (self.lexicon, self.ledger) = (lexicon, ledger) }
    func count() async -> Int {
        await lexicon.entries().filter { $0.status == .proposed }.count + (await ledger.suggestions()).count
    }
    /// "Panotti-Daten übernehmen": a folder with the finished start lexicon, a dry run, then one click.
    func chooseStart() {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles) = (true, false)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { start = (url, try CorrectionLedger.preview(url)) } catch { NSSound.beep() }
    }
    func decide(_ work: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await work() } catch { NSSound.beep() }
            let (lexicon, ledger) = (lexicon, ledger)
            let entries = await lexicon.entries(), stage = await lexicon.stage(), list = await lexicon.reviewList()
            let byID = Dictionary(entries.map { ($0.id, $0) }) { a, _ in a }
            items = entries.filter { $0.status == .proposed }.map { e in
                let near = stage.soundNeighbors(of: e.canonical, limit: 1).first.flatMap { n in
                    entries.first { $0.canonical == n && $0.status == .confirmed } }
                return Item(id: e.id, heard: e.hearingVariants.map { $0.heard.joined(separator: " ") }
                    .joined(separator: ", "), spelling: e.canonical, main: "So schreiben", run: { s in
                        if s != e.canonical { _ = try await lexicon.apply(.rename(entry: e.id, canonical: s)) }
                        _ = try await lexicon.apply(.confirmEntry(canonical: s))
                    }, more: (near.map { n in [("Gehört zu \(n.canonical)", { try await lexicon.belongs(e.id,
                        to: n.id) } as Work)] }
                        ?? []) + [("Normales Wort", {
                            _ = try await lexicon.apply(.protect(form: e.canonical))
                            _ = try await lexicon.apply(.retireEntry(entry: e.id, reason: "wort")) } as Work),
                        ("Nicht mehr fragen", { _ = try await lexicon.apply(.retireEntry(entry: e.id,
                            reason: "abgelehnt")) } as Work)])
            } + (await ledger.suggestions()).map { s in
                Item(id: s.id, heard: "\(s.heard) → \(s.target) · \(s.label)", spelling: nil, main: "Übernehmen",
                     run: { _ in try await ledger.accept(s, context: []) },
                     more: (s.context.first.map { n in [("Nur neben \(n)",
                         { try await ledger.accept(s) } as Work)] } ?? [])
                        + [("Normales Wort", { try await ledger.protect(s) } as Work), ("Ablehnen",
                            { try await ledger.reject(s) } as Work)])
            }
            review = list.enumerated().filter { $0.element.settled == nil }.map { n, r in
                let e = byID[r.entryID], v = e?.hearingVariants.first { $0.id == r.variantID }
                return (n, (v.map { $0.heard.joined(separator: " ") + " → " } ?? "") + (e?.canonical ?? ""),
                        "\(r.reason). \(v?.counters.benefit ?? 0) Treffer, "
                            + "\(v?.counters.harm ?? e?.counters.harm ?? 0) Schäden.")
            }
            let variants = entries.flatMap(\.hearingVariants)
            let n = { (s: VariantStatus) in variants.filter { $0.status == s }.count }
            let last = await lexicon.lastProbation().map { $0.formatted(date: .numeric, time: .shortened) } ?? "nie"
            head = "\(entries.filter { $0.status == .confirmed }.count) Einträge · \(n(.active)) aktiv · "
                + "\(n(.suspended)) ausgesetzt · \(list.filter { $0.reason == "ruhend" && $0.settled == nil }.count) "
                + "ruhend · Bewährung \(last)"
            importable = await lexicon.importable()
        }
    }
    /// One line of text for "Ziel ändern …" (N.5).
    static func prompt(_ title: String) -> String? {
        let alert = NSAlert(), field = NSTextField(frame: NSRect(x: 0, y: 0, width: FlowIQTheme.Size.field,
                                                                 height: FlowIQTheme.Size.control))
        (alert.messageText, alert.accessoryView) = (title, field)
        alert.addButton(withTitle: "Übernehmen")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty ? field.stringValue : nil
    }
}

struct WordsPane: View {
    @Bindable var model: WordsModel
    let panotti: Bool
    var body: some View {
        let t = FlowIQTheme.self, shown = Array(model.items.prefix(3)), lexicon = model.lexicon
        VStack(alignment: .leading, spacing: t.Spacing.s8) {
            VStack(alignment: .leading, spacing: t.Spacing.s2) {
                Text(model.items.isEmpty ? "Keine neuen Namen" : model.items.count == 1 ? "1 neuer Name"
                     : "\(model.items.count) neue Namen").textStyle(t.Font.badge)
                Text(model.items.isEmpty ? "Neue Namen erscheinen hier, sobald ein Wort an zwei Tagen anders kommt."
                     : "Ein Klick bestätigt die Schreibweise.").textStyle(t.Font.micro, t.Color.textMuted)
            }
            if !shown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { n, item in
                        let spelling = model.spelling[item.id] ?? item.spelling ?? ""
                        VStack(alignment: .leading, spacing: t.Spacing.s4) {
                            HStack(spacing: t.Spacing.s8) {
                                if item.spelling != nil {
                                    TextField("Schreibweise", text: Binding(get: { spelling },
                                        set: { model.spelling[item.id] = $0 }))
                                        .textFieldStyle(.roundedBorder).font(t.Font.custom(t.Font.caption))
                                } else { Spacer() }
                                Button(item.main) { model.decide { try await item.run(spelling) } }
                                    .buttonStyle(FlowButton(primary: n == 0))
                                more(item.more.map { title, work in (title, { model.decide(work) }) })
                            }
                            Text("Gehört: " + item.heard).textStyle(t.Font.micro, t.Color.textMuted)
                        }
                        .padding(.vertical, t.Spacing.s6)
                        .overlay(alignment: .bottom) { Hairline(hidden: n == shown.count - 1) }
                    }
                }
                .padding(.horizontal, t.Spacing.s12).card()
            }
            Block(title: "Zum Prüfen", trailing: { Text(model.head).textStyle(t.Font.micro,
                t.Color.textMuted).lineLimit(1) }) {
                if model.review.isEmpty {
                    Text("Nichts zu prüfen.").textStyle(t.Font.caption, t.Color.textMuted)
                        .frame(maxWidth: .infinity, minHeight: t.Size.row, alignment: .leading)
                }
                ForEach(model.review.prefix(2), id: \.index) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: t.Spacing.s2) {
                            Text(r.title).textStyle(t.Font.caption)
                            Text(r.detail).textStyle(t.Font.micro, t.Color.textMuted)
                        }
                        Spacer()
                        Button("Ziel ändern …") {
                            if let to = WordsModel.prompt("Neues Ziel für \(r.title)") {
                                model.decide { _ = try await lexicon.decide(r.index, .retarget(to)) }
                            }
                        }
                        .buttonStyle(.plain).textStyle(t.Font.micro, t.Color.accent)
                        Button("Endgültig aus") { model.decide { _ = try await lexicon.decide(r.index, .retire) } }
                            .buttonStyle(FlowButton()).fixedSize()
                        Button("Wieder aktiv") { model.decide { _ = try await lexicon.decide(r.index, .reactivate) } }
                            .buttonStyle(FlowButton(primary: true)).fixedSize()
                    }
                    .frame(minHeight: t.Main.row)
                }
            }
            if let (url, s) = model.start {
                Button("\(s.entries) Einträge und \(s.proposals) Vorschläge übernehmen") {
                    model.decide { [ledger = model.ledger] in _ = try await ledger.importStart(from: url) }
                    (model.start, ()) = (nil, model.adopted())
                }.buttonStyle(FlowButton(primary: true))
            } else if panotti && model.importable {
                Button("Panotti-Daten übernehmen …") { model.chooseStart() }.buttonStyle(FlowButton())
            }
            Explain(title: "Woher kommen die Vorschläge?", text: "Aus Wörtern, die der Erkenner an mindestens zwei "
                    + "Tagen anders schreibt. Die Schreibweise kommt aus deinen Diktaten, nie aus ElevenLabs. "
                    + "Bestätigte "
                    + "Namen gelten ab dem nächsten Diktat. Nichts wird gelöscht.")
        }
        .onAppear { model.decide {} }
    }
    private func more(_ actions: [(String, () -> Void)]) -> some View {
        Menu("…") { ForEach(actions, id: \.0) { title, run in Button(title, action: run) } }
            .menuStyle(.button).buttonStyle(FlowButton()).fixedSize().accessibilityLabel("Weitere Wege")
            .help("Weitere Wege: " + actions.map(\.0).joined(separator: ", "))
    }
}
