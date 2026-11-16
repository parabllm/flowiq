import SwiftUI
/// "Letztes Diktat korrigieren" (N.2): words as buttons, changes dotted; a click (Shift extends) shows the choices.
@MainActor @Observable
final class CorrectionModel: CorrectionWindowPresenting {
    var session: CorrectionSession?
    var words: [String] = []
    var changed: [Range<Int>] = []
    var selection: Range<Int>?
    var options = CorrectionOptions()
    var typed = ""
    var asking = false
    var note = ""
    var current = ""
    var recent: [(id: String, title: String)] = []
    var question: (earlier: Int, nextTo: String?, always: Bool) = (0, nil, false)
    @ObservationIgnored lazy var window = SmallWindow("Letztes Diktat korrigieren", CorrectionPanel(model: self))
    nonisolated func present(_ view: CorrectionView) async {
        await MainActor.run {
            (words, changed, selection, current) = (view.words, view.interventionSpans, nil, view.dictationID)
            (options, typed, asking, note) = (CorrectionOptions(), "", false, "")
            recent = view.recent.prefix(3).map { ($0.id,
                $0.finalText.split(separator: " ").prefix(3).joined(separator: " ")) }
            window.onClose = { [weak self] in self?.act { await $0.close() } }
            window.show()
        }
    }
    nonisolated func dismiss() async { await MainActor.run { window.hide() } }
    func select(_ index: Int, extend: Bool) {
        let range = extend ? min(selection?.lowerBound ?? index, index)..<max(selection?.upperBound ?? 0, index + 1)
            : index..<index + 1
        selection = range
        Task { options = await session?.options(for: range) ?? CorrectionOptions() }
    }
    func pick(_ id: String) { if let session { Task { _ = await session.open(from: .menu, dictation: id) } } }
    /// After the field edit the window comes back only to ask the scope question or to report a blocked change.
    func choose(_ choice: CorrectionChoice) {
        guard let range = selection, let session else { return }
        Task {
            let outcome = await session.apply(choice, to: range)
            guard outcome.learning == .askScope || outcome.learning == .blocked
                    || outcome.replace == .clipboardHint else { return }
            (question, asking) = (await session.question, outcome.learning == .askScope)
            note = outcome.learning == .blocked
                ? "Nicht gelernt: die Änderung bräche einen Dauerfall. Sie steht unter Wörter."
                : asking ? "" : "Feld nicht erreichbar. Der korrigierte Text liegt in der Zwischenablage, ⌘V."
            await session.keepOpen()
            window.show()
        }
    }
    func act(_ work: @escaping @Sendable (CorrectionSession) async -> Void) {
        (asking, note) = (false, "")
        if let session { Task { await work(session) } }
    }
}

struct CorrectionPanel: View {
    @Bindable var model: CorrectionModel
    var body: some View {
        let t = FlowIQTheme.self, q = model.question
        let picked = model.selection.map { model.words[$0.clamped(to: 0..<model.words.count)] } ?? []
        let heard = picked.isEmpty ? "Das gehörte Wort" : picked.joined(separator: " ")
        VStack(alignment: .leading, spacing: t.Spacing.s12) {
            if model.asking {  // the one question after a real word (N.2 point 4); default "Nur dieses Mal" (review M7)
                Text("„\(heard)“ ist ein normales Wort und stand in \(q.earlier) früheren Diktaten. "
                     + "Wann soll FlowIQ es ersetzen?")
                    .textStyle(t.Font.small).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: t.Spacing.s8) {
                    pill("Nur dieses Mal", primary: true) { await $0.resolve(.once) }
                    if let next = q.nextTo { pill("Nur neben \(next)") { await $0.resolve(.nextTo(next)) } }
                    if q.always { pill("Immer") { await $0.resolve(.always) } }
                }
            } else if !model.note.isEmpty {
                Text(model.note).textStyle(t.Font.small).fixedSize(horizontal: false, vertical: true)
                pill("OK", primary: true) { _ = $0 }
            } else {
                if model.recent.count > 1 {
                    Segments(options: model.recent.map { ($0.id, $0.title) },
                             selection: Binding(get: { model.current }, set: { model.pick($0) }))
                }
                words.padding(t.Spacing.s12).frame(maxWidth: .infinity, alignment: .leading).card()
                if model.selection != nil { choices } else {
                    Text("Ein Wort antippen, um es zu ändern.")
                        .textStyle(t.Font.caption, t.Color.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: t.Spacing.s8) {
                    pill("Rohfassung") { _ = await $0.rawVersion() }
                    Text("Gepunktet: von FlowIQ geändert.").textStyle(t.Font.micro, t.Color.textMuted)
                    Spacer()
                    Button("Fertig") { model.act { await $0.close() } }.buttonStyle(FlowButton(primary: true))
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(t.Spacing.s16).frame(width: t.Size.correctionWidth).background(t.Color.background)
    }
    /// Tab moves only between marked places (review S7): the changed words are focusable, the rest by click.
    private var words: some View {
        let t = FlowIQTheme.self, range = model.selection ?? 0..<0
        return Flow(spacing: t.Spacing.s4) {
            ForEach(Array(model.words.enumerated()), id: \.offset) { n, word in
                let picked = range.contains(n), changed = model.changed.contains { $0.contains(n) }
                Button { model.select(n, extend: NSEvent.modifierFlags.contains(.shift)) } label: {
                    Text(word).textStyle(t.Font.small).underline(changed, pattern: .dot, color: t.Color.accent)
                        .padding(.horizontal, t.Spacing.s2)
                        .background(picked ? t.Color.accentTint : .clear,
                            in: RoundedRectangle(cornerRadius: t.Spacing.s4))
                }
                .buttonStyle(.plain).focusable(changed)
                .accessibilityLabel(changed ? "\(word), von FlowIQ geändert" : word)
            }
        }
    }
    /// Recognizer, known names, raw form, own spelling; "war richtig" only where FlowIQ intervened (N.2).
    private var choices: some View {
        let t = FlowIQTheme.self, o = model.options, range = model.selection ?? 0..<0
        let all = o.recognizerAlternatives.map { ($0, CorrectionChoice.alternative($0), "Erkenner") }
            + o.lexiconNeighbors.map { ($0, CorrectionChoice.lexicon($0), "bekannt") }
            + (o.rawForm.isEmpty ? [] : [(o.rawForm, CorrectionChoice.raw, "Rohform")])
        return VStack(alignment: .leading, spacing: t.Spacing.s4) {
            ForEach(all, id: \.0) { title, choice, source in
                Button { model.choose(choice) } label: {
                    HStack { Text(title).textStyle(t.Font.caption); Spacer(); Text(source).textStyle(t.Font.micro,
                        t.Color.textMuted) }
                        .frame(minHeight: t.Size.control).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: t.Spacing.s8) {
                TextField("Eigene Schreibweise", text: $model.typed).textFieldStyle(.roundedBorder)
                    .font(t.Font.custom(t.Font.caption)).onSubmit { model.choose(.typed(model.typed)) }
                Button("OK") { model.choose(.typed(model.typed)) }.buttonStyle(FlowButton())
                if o.offersWasRight { pill("war richtig") { _ = await $0.markWasRight(range) } }
            }
        }
        .padding(t.Spacing.s12).card()
    }
    /// A button that runs on the session and closes the window afterwards (focus back to the previous app).
    private func pill(_ title: String, primary: Bool = false,
                      _ work: @escaping @Sendable (CorrectionSession) async -> Void) -> some View {
        Button(title) { model.act { await work($0); await $0.close() } }.buttonStyle(FlowButton(primary: primary))
            .keyboardShortcut(primary ? .defaultAction : nil)
    }
}

/// Words in lines like text: each keeps its width, a line breaks where the next word no longer fits.
struct Flow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, at) in zip(subviews, place(bounds.width, subviews).points) {
            view.place(at: CGPoint(x: bounds.minX + at.x, y: bounds.minY + at.y), proposal: .unspecified)
        }
    }
    private func place(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var (x, y, line, widest, points) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), [CGPoint]())
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { (x, y, line) = (0, y + line + spacing, 0) }
            points.append(CGPoint(x: x, y: y))
            (x, line, widest) = (x + size.width + spacing, max(line, size.height), max(widest, x + size.width))
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}
