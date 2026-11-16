import SwiftUI

/// One row of every settings card (16.11.: "immer gescheit formatiert"): name with a grey line what it is in
/// one column, the value or control from the same left edge, the same height everywhere.
struct SettingRow<Content: View>: View {
    let title: String
    var sub: String? = nil, last = false
    @ViewBuilder var content: Content
    var body: some View {
        let t = FlowIQTheme.self
        HStack(alignment: .center, spacing: t.Spacing.s12) {
            VStack(alignment: .leading, spacing: t.Spacing.s2) {
                Text(title).textStyle(t.Font.caption)
                if let sub { Text(sub).textStyle(t.Font.micro, t.Color.textMuted).fixedSize(horizontal: false,
                                                                                             vertical: true) }
            }
            .frame(width: t.Main.label, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .padding(.vertical, t.Spacing.s4).frame(minHeight: t.Main.row)
        .overlay(alignment: .bottom) { Hairline(hidden: last) }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Aufnahme: what writes along and what comes after, the cloud services, storage, shortcuts (M.1, R-077 to R-079).
struct RecordingPane: View {
    @Bindable var model: AppModel
    @SwiftUI.FocusState private var keyFocused: Bool
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: t.Spacing.s10) {
            Block("Transkript") {
                HStack(spacing: t.Spacing.s12) {  // the column heads stand exactly over their controls
                    Spacer().frame(width: t.Main.label, height: t.Size.hairline)
                    Text("Live-Mitschrift").frame(width: t.Main.live, alignment: .leading)
                    Text("Genauere Fassung danach").fixedSize()  // one line, it stands over the switches
                }
                .frame(maxWidth: .infinity, alignment: .leading)  // no spacer: its gap made this card wider
                .textStyle(t.Font.micro, t.Color.textMuted).padding(.top, t.Spacing.s4)
                SettingRow(title: "Diktat", sub: "was du mit Fn sprichst") {
                    fixed("immer auf dem Mac"); post(.dictation) }
                SettingRow(title: "Call", sub: "du und die anderen im Gespräch") { live(.call); post(.call) }
                SettingRow(title: "Raum", sub: "nur das Mikrofon, z.B. Vorlesung") { live(.room); post(.room) }
                SettingRow(title: "Geräte", sub: "Dateien vom Diktiergerät", last: blocked == nil) {
                    fixed("auf dem Mac nach dem Einstecken"); post(.device) }
                if let blocked { reason(blocked) }
            }
            cloud
            Block("Allgemein") {
                SettingRow(title: "Ablage", sub: "Transkripte und Audio") {
                    Text(Self.shortPath(model.folder)).textStyle(t.Font.caption, t.Color.textMuted).lineLimit(1)
                        .truncationMode(.head).help(model.folder.path)
                    Spacer()
                    Menu("Wählen …") {
                        Button("Ordner für Transkripte …") { model.chooseFolder() }
                        Button("Ordner für Audio …") { model.chooseFolder(audio: true) }
                    }
                    .menuStyle(.button).buttonStyle(FlowButton()).fixedSize()
                }
                SettingRow(title: "Zwischenablage", sub: "letztes Diktat bleibt, ⌘V fügt es noch einmal ein") {
                    toggle(model.settings.keepDictationInClipboard) { on in
                        model.change { $0.keepDictationInClipboard = on } }
                }
                SettingRow(title: "Verlauf behalten", sub: "bleibt auf diesem Mac", last: true) {
                    Segments(options: [(0, "immer"), (90, "90 Tage"), (30, "30 Tage")], selection: Binding(
                        get: { model.settings.historyDays ?? 0 },
                        set: { d in model.change { $0.historyDays = d == 0 ? nil : d } }))
                }
            }
            if model.ui.iconHint {  // once, when the full menu bar hid the icon (16.11.)
                Text("Das Symbol in der Menüleiste ist verdeckt. Klick auf die Pille links am Rand öffnet das Menü.")
                    .textStyle(t.Font.caption, t.Color.warningText).padding(t.Spacing.s12)
                    .background(t.Color.warningTint, in: RoundedRectangle(cornerRadius: t.Radius.sm))
            }
            Block("Kurzbefehle") { shortcuts }
        }
        .onChange(of: model.ui.keyFocus, initial: true) { _, on in
            if on { (keyFocused, model.ui.keyFocus) = (true, false) }
        }
    }
    /// Why a cloud choice is off right now, with the one step that changes it; nil when everything can be chosen.
    var blocked: (text: String, step: String, run: () -> Void)? {
        if !model.cloudAllowed {
            return ("Die Testversion sendet nichts ins Netz.", "Senden erlauben",
                    { model.change { $0.devCloudAllowed = true } })
        }
        if !model.ui.hasKey && !model.ui.openRouterKey {
            return ("ElevenLabs und genauere Fassung brauchen einen Schlüssel.", "Schlüssel eintragen",
                    { keyFocused = true })
        }
        return nil
    }
    private var cloud: some View {
        let t = FlowIQTheme.self, (k, o) = (model.ui.hasKey, model.ui.openRouterKey)
        return Block("Cloud") {
            if model.profile == .development {
                SettingRow(title: "Testversion", sub: "ohne diesen Schalter verlässt nichts den Mac") {
                    toggle(model.settings.devCloudAllowed) { on in model.change { $0.devCloudAllowed = on } }
                    Text("an ElevenLabs und OpenRouter senden").textStyle(t.Font.caption, t.Color.textMuted)
                }
            }
            SettingRow(title: "ElevenLabs", sub: "Live-Mitschrift und genauere Fassung") {
                keyField("ElevenLabs", has: k, text: $model.ui.keyDraft, openRouter: false).focused($keyFocused)
                state(k)
            }
            SettingRow(title: "OpenRouter", sub: "nur genauere Fassung, viele Modelle") {
                VStack(alignment: .leading, spacing: t.Spacing.s6) {
                    HStack(spacing: t.Spacing.s12) {
                        keyField("OpenRouter", has: o, text: $model.ui.orDraft, openRouter: true)
                        state(o)
                    }
                    modelPicker
                }
            }
            SettingRow(title: "Fassung über", sub: "Automatisch: ElevenLabs, bei leerem Kontingent OpenRouter") {
                Segments(options: [(PostService.elevenLabs, "ElevenLabs"), (.openRouter, "OpenRouter"),
                                   (.auto, "Automatisch")],
                         selection: Binding(get: { model.settings.postService },
                                            set: { s in model.change { $0.postService = s } }),
                         enabled: { s in s == .openRouter ? o : s == .elevenLabs ? k : k || o })
            }
            SettingRow(title: "Monatsgrenze", sub: "danach nur noch auf dem Mac", last: true) {
                Picker("Monatsgrenze", selection: Binding(get: { model.settings.cloudLimitMinutes ?? 0 },
                                                          set: { model.setLimit($0 == 0 ? nil : $0) })) {
                    ForEach([0, 60, 300, 600, 1200, 3000], id: \.self) { m in
                        Text(m == 0 ? "keine" : Duration.seconds(m * 60).hoursAndMinutes).tag(m)
                    }
                }
                .labelsHidden().fixedSize()
                Text("bisher \(Duration.seconds(model.ui.cloudSeconds).hoursAndMinutes)" + (model.ui.openRouterUSD > 0
                    ? " · OpenRouter \(model.ui.openRouterUSD.formatted(.number.precision(.fractionLength(2)))) $"
                    : ""))
                    .textStyle(t.Font.caption, t.Color.textMuted)
            }
        }
    }
    private func reason(_ b: (text: String, step: String, run: () -> Void)) -> some View {
        let t = FlowIQTheme.self
        return HStack(spacing: t.Spacing.s8) {
            Image(systemName: "info.circle").foregroundStyle(t.Color.warningText)
            Text(b.text).textStyle(t.Font.micro, t.Color.warningText)
            Button(b.step, action: b.run).buttonStyle(.plain).textStyle(t.Font.micro, t.Color.accent)
            Spacer()
        }
        .padding(.vertical, t.Spacing.s4)
    }
    private func fixed(_ text: String) -> some View {
        Text(text).textStyle(FlowIQTheme.Font.caption, FlowIQTheme.Color.textMuted)
            .frame(width: FlowIQTheme.Main.live, alignment: .leading)
    }
    private func state(_ has: Bool) -> some View {
        let t = FlowIQTheme.self
        return Text(has ? "gespeichert" : "fehlt")
            .textStyle(t.Font.micro, has ? t.Color.successText : t.Color.textMuted)
    }
    private func toggle(_ on: Bool, _ set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) { EmptyView() }.toggleStyle(FlowSwitch()).fixedSize()
    }
    /// Lokal or ElevenLabs; ElevenLabs is greyed out without a key or in the test build, the reason stands below.
    private func live(_ m: RecordingMode) -> some View {
        let binding = Binding(get: { model.settings.effective(m, hasKey: model.ui.hasKey).live },
                              set: { e in model.change { try $0.set(m, live: e, hasKey: model.ui.hasKey) } })
        return Segments(options: [(LiveEngine.appleLocal, "auf dem Mac"), (.elevenLabsRealtime, "ElevenLabs")],
                        selection: binding, enabled: { $0 == .appleLocal || model.ui.hasKey })
            .accessibilityLabel("Live-Mitschrift \(m == .call ? "Call" : "Raum")")
            .frame(width: FlowIQTheme.Main.live, alignment: .leading)
    }
    private func post(_ m: RecordingMode) -> some View {
        let (k, o) = (model.ui.hasKey, model.ui.openRouterKey)
        return toggle(model.settings.effective(m, hasKey: k, openRouterKey: o).post == .elevenLabs) { on in
            model.change { try $0.set(m, post: on ? .elevenLabs : .off, hasKey: k, openRouterKey: o) }
        }
        .disabled(!k && !o).accessibilityLabel("Genauere Fassung danach")
    }
    /// A key straight into the keychain (M.7); the field in the theme's own frame, no system focus ring.
    private func keyField(_ name: String, has: Bool, text: Binding<String>, openRouter: Bool) -> some View {
        let t = FlowIQTheme.self
        return HStack(spacing: t.Spacing.s8) {
            SecureField(has ? "neuer Schlüssel ersetzt den alten" : "Schlüssel einfügen", text: text)
                .textFieldStyle(.plain).focusEffectDisabled().font(t.Font.custom(t.Font.caption))
                .padding(.horizontal, t.Spacing.s8).frame(width: t.Main.keyField, height: t.Size.control)
                .background(RoundedRectangle(cornerRadius: t.Spacing.s6).strokeBorder(t.Color.rim)
                    .background(t.Color.surface, in: RoundedRectangle(cornerRadius: t.Spacing.s6)))
                .onSubmit { model.storeKey(openRouter: openRouter) }
                .accessibilityLabel("\(name)-Schlüssel" + (has ? ", im Schlüsselbund" : ""))
            if !text.wrappedValue.isEmpty {  // a pasted key is saved by a click too, not only by Return (16.11.)
                Button("Speichern") { model.storeKey(openRouter: openRouter) }
                    .buttonStyle(FlowButton(primary: true)).fixedSize()
            }
        }
    }
    /// The model menu: name, price per hour, abilities.
    nonisolated static func modelTitle(_ m: OpenRouterModel) -> String {
        let price = m.usdPerHour.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
        return m.name + " · " + price + " $/h" + (m.speakers ? " · Sprecher" : "") + (m.words ? " · Wortzeiten" : "")
    }
    private var modelPicker: some View {
        let id = model.settings.openRouterModel, list = model.parts.models
        return Menu("Modell: " + (list.first { $0.id == id }.map(\.name) ?? id)) {
            ForEach(list, id: \.id) { m in Button(Self.modelTitle(m)) { model.change { $0.openRouterModel = m.id } } }
            Divider()
            Button("Eigene Modell-ID …") {
                if let own = WordsModel.prompt("OpenRouter-Modell-ID") { model.change { $0.openRouterModel = own } }
            }
        }
        .menuStyle(.button).buttonStyle(FlowButton()).fixedSize()
    }
    /// "~/Documents/FlowIQ" instead of the whole path; the help shows the whole one.
    nonisolated static func shortPath(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
    /// The predecessor app Panotti is named only where its data folder exists (optional, most users have none).
    nonisolated static func alternateHint(panotti: Bool) -> String {
        "wenn ⌘⌥ schon belegt ist\(panotti ? " (z.B. von Panotti)" : ""); ab Neustart"
    }
    /// Action left, key right, as the menu shows them (one table, 16.11.).
    private var shortcuts: some View {
        let t = FlowIQTheme.self, alt = model.settings.alternateKeys, c = alt ? "⌃⌥⌘" : "⌘⌥"
        let rows = [("Call starten", c + "U"), ("Raum starten", c + "R"), ("Call auf Englisch", c + "E U"),
                    ("Raum auf Englisch", c + "E R"), ("Diktat halten", alt ? "⌥ rechts" : "Fn"),
                    ("Diktat sperren", alt ? "2× ⌥ rechts" : "Fn Fn"), ("Abbrechen", "Esc"),
                    ("Erneut einfügen", alt ? "⌃⌥⌘V" : "⌃⌘V"), ("Korrigieren", c + "K")]
        return Group {
            ForEach(rows, id: \.0) { what, key in
                HStack {
                    Text(what).textStyle(t.Font.caption)
                    Spacer()
                    Text(key).textStyle(t.Font.badge, t.Color.textSecondary)
                }
                .frame(minHeight: t.Size.control).overlay(alignment: .bottom) { Hairline() }
            }
            SettingRow(title: "Ersatztasten", sub: Self.alternateHint(panotti: model.panotti != nil), last: true) {
                toggle(alt) { on in model.change { $0.alternateKeys = on } }
            }
        }
    }
}
