/// One running call or room as menu and pill see it (A.12, M.6).
nonisolated struct Running: Equatable, Sendable {
    let kind: SessionKind, language: RecordingLanguage, started: Date
    var engine = LiveEngine.appleLocal, sending = false, fallback: SwitchReason?, silent = false, offersSwitch = false
    var desktopSilent = false  // `silent` is the microphone only; the desktop has its own (16.11.)
    var device: String?, cloudSeconds = 0.0, levels: [Float] = []
}

/// A state the user should see with its next step (review M5), one line at the top of the menu.
nonisolated enum AppAlert: Equatable, Sendable {
    case micSilent, permission(String), networkDown, limitReached(Int), keyRejected, postWaiting(Int)
    case notInserted, folderMissing, problem(String), noDesktop, tapStopped, trouble(LiveTrouble), panottiKeys
    /// What the pill said before it lost its text (16.11.): a failed dictation (audio kept or not), a headset
    /// lost mid-recording, a device import that failed (file, count, reason), a recording the Mac slept through.
    case dictationFailed(audio: Bool), micLost(String), importFailed(String?, Int, ImportProblem)
    case paused(SessionKind, String)
    /// A recorder is plugged in while the switch is off, or a volume only may be one (16.11.).
    case recorderOff(String), recorderUnknown(String)
    var text: String {
        switch self {
        case .micSilent: "Mikrofon liefert keinen Ton"
        case .permission(let name): "\(name) fehlt"
        case .networkDown: "Netz weg, Apple schreibt weiter"
        case .limitReached(let m): "Monatsgrenze \(Duration.seconds(m * 60).hoursAndMinutes) erreicht, lokal weiter"
        case .keyRejected: "ElevenLabs-Schlüssel fehlt oder abgelehnt"
        case .postWaiting(let n): "Genauere Fassung wartet (\(n))"
        case .notInserted: "Kein Textfeld, Diktat liegt bereit"
        case .folderMissing: "Ablageordner fehlt, Aufnahme liegt sicher in FlowIQ"
        case .problem(let text): text
        case .noDesktop: "Nur dein Mikrofon wird aufgenommen\nDer Ton der anderen im Call fehlt."  // 16.11.
        case .tapStopped: "Fn und Kurzbefehle reagieren nicht"
        case .trouble(let t): t.text
        case .panottiKeys: "Panotti hält dieselben Tasten"
        case .dictationFailed(true): "Diktat nicht erkannt, der Ton ist gesichert"
        case .dictationFailed: "Diktat nicht aufgenommen, das Mikrofon war nicht erreichbar"
        case .micLost(let name): "\(name) getrennt, das Mac-Mikrofon nimmt weiter auf"
        case .importFailed(let file, let n, let why):
            "Geräte-Import: " + (file.map { "„\($0)“ nicht übernommen" } ?? (n > 0 ? "\(n) Dateien nicht übernommen"
                                                                                 : "gescheitert")) + "\n"
                + ([.journalUnreadable: "Import-Liste nicht lesbar", .unreadable: "Datei nicht lesbar",
                    .copy: "Kopieren brach ab", .transcribe: "Verschriften ging nicht"][why] ?? "Ablegen ging nicht")
                + ", auf dem Gerät wurde nichts gelöscht."
        case .recorderOff(let name): "Rekorder „\(name)“ erkannt, der Geräte-Import ist aus"
        case .recorderUnknown(let name): "„\(name)“ eingesteckt, als Rekorder nicht sicher erkannt"
        case .paused(let kind, let span): "\(kind.rawValue) war von \(span) pausiert, läuft weiter"
        }
    }
    var choosesMic: Bool {
        switch self {
        case .micSilent, .micLost, .dictationFailed(false): true
        default: false
        }
    }
    /// Urgent first (16.11.): a recording loses sound, a permission or the keys are missing, something
    /// failed, something waits.
    var rank: Int {
        switch self {
        case .problem, .micSilent, .noDesktop, .micLost: 0
        case .permission, .tapStopped, .panottiKeys: 1
        case .postWaiting, .notInserted, .paused: 3
        default: 2
        }
    }
    var step: (title: String, action: MenuAction?) {
        switch self {
        case .micSilent, .micLost, .dictationFailed(false): ("Wählen …", nil)  // the row's submenu: the microphones
        case .dictationFailed: ("Erneut erkennen", .recognizeAgain)
        case .importFailed: ("Erneut versuchen", .retryImport)
        case .recorderOff: ("Import einschalten", .enableImport)  // switches on and imports at once
        case .recorderUnknown: ("Zuordnen …", .devices)
        case .paused(let kind, _): ("Ausblenden", .dismissPause(kind))  // no step is due: a click takes it away
        case .permission("Bildschirmaufnahme"): ("Bildschirmaufnahme erlauben …", .allowScreen)
        case .permission, .tapStopped: ("Einrichten …", .setup)
        case .noDesktop: ("Bildschirmaufnahme erlauben …", .setup)
        case .networkDown: ("Erneut verbinden", .reconnect)
        case .limitReached: ("Grenze ändern …", .settings)
        case .keyRejected: ("Schlüssel eintragen …", .keyField)
        case .postWaiting: ("Jetzt versuchen", .retryPost)
        case .notInserted: ("Einfügen ⌃⌘V", .insertLast)
        case .folderMissing: ("Ordner wählen …", .chooseFolder)
        case .problem: ("Einrichten …", .setup)  // a failed start or save: permissions and folders come first
        case .trouble(.modelMissing(let l)): ("Sprachmodell laden", .installModel(l))  // only on this click (M4)
        case .trouble: ("", nil)
        case .panottiKeys: ("Ersatztasten …", .settings)  // FlowIQ rests until Panotti ends or other keys are set
        }
    }
}

nonisolated enum MenuAction: Equatable, Sendable {
    case start(SessionKind, RecordingLanguage), stop(SessionKind), toggleLive(SessionKind), showLive(SessionKind)
    case insertLast, correctLast, open(URL), openAll, words, settings, setup, quit, selfTest, openWindow
    case liveDefault(RecordingMode), post(RecordingMode), keyField, mic(String?), retryPost, chooseFolder, reconnect
    case installModel(RecordingLanguage), allowScreen  // the system question, then the setting (16.11.)
    case recognizeAgain, retryImport, dismissPause(SessionKind), enableImport, devices
}

nonisolated struct RecentTranscript: Equatable, Sendable { let url: URL, kind: SessionKind, date: Date }

/// Everything the menu is built from; the app fills it, tests build it by hand.
nonisolated struct MenuState: Equatable, Sendable {
    var profile: Profile, settings: FlowIQCore.Settings, now = Date()
    var hasKey = false, running: [Running] = [], alerts: [AppAlert] = [], recent: [RecentTranscript] = []
    var newNames = 0, cloudSeconds = 0.0, limitMinutes: Int?, mics: [String: String] = [:], mic: String?
    var openRouterKey = false, openRouterUSD = 0.0  // second after-run service (16.11.)
    var activity: [String] = []  // what else runs, as plain lines: a start, a save, the import, a locked dictation
}

nonisolated struct MenuEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case item, header, separator, alert, info }
    var kind = Kind.item, id = "", title = "", detail: String?, symbol: String?, key: String?
    var keyLabel: String?  // two letters at once (⌥⌘E U) as text on the right: no native key equivalent can
    var checked = false, enabled = true, badge: Int?, action: MenuAction?, submenu: [MenuEntry]?
}

/// The menu as a table (V-e, A.12, review M8): natively drawn, idle 14 commands plus two section heads.
nonisolated enum StatusMenuModel {
    /// The modifiers of a menu key as the native item shows them; development adds Control (and Option for ⌃⌘V).
    static func modifiers(_ key: String, alternate: Bool) -> NSEvent.ModifierFlags {
        let app: NSEvent.ModifierFlags = key == "," || key == "q" ? [.command] : key == "v" ? [.control, .command]
            : alternate ? [.control, .command, .option] : [.command, .option]
        return app.union(alternate && key == "v" ? .option : [])
    }
    /// The same as text in the system order ⌃⌥⌘, for drawings of the menu and the English rows.
    static func keyText(_ key: String, alternate: Bool) -> String {
        let m = modifiers(key, alternate: alternate)
        return [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.command, "⌘")]
            .filter { m.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }
    static var standardItemIDs: [String] {
        entries(MenuState(profile: .production, settings: .defaults(for: .production))).filter { $0.kind == .item }
            .map(\.id)
    }
    static func entries(_ s: MenuState) -> [MenuEntry] {
        var out = s.alerts.enumerated().map { n, a in
            MenuEntry(kind: .alert, id: "alert\(n)", title: a.text, detail: a.step.title,
                symbol: "exclamationmark.triangle",
                      action: a.step.action, submenu: a.choosesMic ? mics(s) : nil)
        }
        if !out.isEmpty { out.append(MenuEntry(kind: .separator)) }
        out += s.activity.enumerated().map { MenuEntry(kind: .info, id: "activity\($0)", title: $1) }
        if !s.activity.isEmpty { out.append(MenuEntry(kind: .separator)) }
        for r in s.running {
            let (name, id) = (r.kind.rawValue, r.kind == .call ? "call" : "room")  // ids English like the start rows
            let cloud = r.fallback != nil ? "Rückfall lokal" : r.sending ? "Cloud sendet" : nil
            let source = r.engine == .appleLocal ? "Live lokal" : "Live ElevenLabs"
            let shared = r.kind == .room && s.running.contains { $0.kind == .call } ? "Mikrofon mit Call geteilt" : nil
            let facts = [r.device.flatMap { s.mics[$0] }, shared, source, cloud,
                r.cloudSeconds > 0 ? Duration.seconds(r.cloudSeconds).hoursAndMinutes : nil]
            out += [MenuEntry(kind: .info, id: "\(id)Running", title: "\(name) läuft · \(r.language.word)",
                              detail: Duration.seconds(s.now.timeIntervalSince(r.started)).clock,
                              symbol: "record.circle"),
                    // no level here: its block glyphs were missing in the menu font (16.11.: boxes)
                    MenuEntry(kind: .info, id: "\(id)Facts", title: facts.compactMap { $0 }.joined(separator: " · ")),
                    MenuEntry(id: "\(id)Live", title: "Live über ElevenLabs",
                        checked: r.engine != .appleLocal, action: s.hasKey ? .toggleLive(r.kind) : .keyField),
                    MenuEntry(id: "\(id)Show", title: "Live-Transkript zeigen", action: .showLive(r.kind)),
                    MenuEntry(id: "\(id)Stop", title: "\(name) beenden", key: r.kind == .call ? "u" : "r",
                              action: .stop(r.kind)), MenuEntry(kind: .separator)]
        }
        out.append(MenuEntry(kind: .header, title: "Aufnehmen"))
        for (kind, id, key, symbol) in [(SessionKind.call, "call", "u", "phone"), (.room, "room", "r", "person.2")]
        where !s.running.contains(where: { $0.kind == kind }) {
            for language in RecordingLanguage.allCases {
                let english = language == .en, e = keyText("e", alternate: s.settings.alternateKeys)
                out.append(MenuEntry(id: id + (english ? "English" : "German"),
                                     title: "\(kind.rawValue) \(language.word)", symbol: symbol,
                                     key: english ? nil : key, keyLabel: english ? "\(e) \(key.uppercased())" : nil,
                                     action: .start(kind, language)))
            }
        }
        out += [MenuEntry(id: "microphone", title: "Mikrofon", detail: s.mic.flatMap { s.mics[$0] } ?? "Automatisch",
                          symbol: "mic", submenu: mics(s)), MenuEntry(id: "liveAndPost",
                          title: "Live und genauere Fassung",
                          detail: Duration.seconds(s.cloudSeconds).hoursAndMinutes, symbol: "cloud", submenu: cloud(s)),
                MenuEntry(kind: .separator),
                MenuEntry(id: "insertLast", title: "Letztes Diktat einfügen", symbol: "doc.on.clipboard", key: "v",
                          action: .insertLast),
                MenuEntry(id: "correctLastDictation", title: "Letztes Diktat korrigieren", symbol: "pencil", key: "k",
                          action: .correctLast), MenuEntry(kind: .header, title: "Zuletzt")]
        out += s.recent.prefix(2).enumerated().map { n, r in
            MenuEntry(id: "recent\(n)", title: "\(r.kind.rawValue)  \(day(r.date, now: s.now))",
                      symbol: r.kind == .call ? "phone" : "person.2",
                      action: .open(r.url))
        }
        out += [MenuEntry(id: "allTranscripts", title: "Alle Transkripte", symbol: "folder", action: .openAll),
                MenuEntry(kind: .separator), MenuEntry(id: "suggestions", title: "Neue Namen", symbol: "textformat",
                          badge: s.newNames > 0 ? s.newNames : nil, action: .words),
                MenuEntry(id: "settings", title: "FlowIQ öffnen …", symbol: "macwindow", key: ",", action: .openWindow)]
        if s.profile == .development {
            out.append(MenuEntry(id: "selfTest", title: "Selbsttest", symbol: "checklist", action: .selfTest))
        }
        out.append(MenuEntry(id: "quit", title: "\(s.profile.displayName) beenden …", key: "q", action: .quit))
        return out
    }
    /// Live and after-run per mode as check marks (review M8): without a key every row leads to the key field.
    static func cloud(_ s: MenuState) -> [MenuEntry] {
        let name: [RecordingMode: String] = [.dictation: "Diktat", .call: "Call", .room: "Raum", .device: "Geräte"]
        var out = [MenuEntry(kind: .header, title: "Live über ElevenLabs")]
        out += [RecordingMode.call, .room].map { m in
            MenuEntry(id: "live-\(m.rawValue)", title: name[m] ?? "", checked: s.settings.effective(m, hasKey: s.hasKey)
                .live == .elevenLabsRealtime, action: s.hasKey ? .liveDefault(m) : .keyField)
        }
        out.append(MenuEntry(kind: .header, title: "Genauere Fassung in der Cloud"))
        let anyKey = s.hasKey || s.openRouterKey
        out += RecordingMode.allCases.map { m in
            MenuEntry(id: "post-\(m.rawValue)", title: name[m] ?? "", checked: s.settings.effective(
                m, hasKey: s.hasKey, openRouterKey: s.openRouterKey).post == .elevenLabs,
                action: anyKey ? .post(m) : .keyField)
        }
        let month = s.now.formatted(.dateTime.month(.wide).locale(Locale(identifier: "de_DE")))
        let used = Duration.seconds(s.cloudSeconds).hoursAndMinutes
        return out + [MenuEntry(kind: .separator),
                      MenuEntry(kind: .info, title: "\(month): \(used)" + (s.limitMinutes.map {
                          " von \(Duration.seconds($0 * 60).hoursAndMinutes)" } ?? ""))]
            + (s.openRouterUSD > 0 ? [MenuEntry(kind: .info, title: "OpenRouter: " + s.openRouterUSD.formatted(
                .number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE"))) + " $")] : [])
            + [MenuEntry(id: "key", title: "Schlüssel und Dienst …", action: .keyField)]
    }
    static func mics(_ s: MenuState) -> [MenuEntry] {
        [MenuEntry(id: "mic-auto", title: "Automatisch", checked: s.mic == nil, action: .mic(nil))]
            + s.mics.sorted { $0.value < $1.value }.map { uid, name in
                MenuEntry(id: "mic-\(uid)", title: name, checked: s.mic == uid, action: .mic(uid))
            }
    }
    static func day(_ date: Date, now: Date) -> String {
        let cal = Calendar.current, time = date.formatted(.dateTime.hour().minute())
        if cal.isDate(date, inSameDayAs: now) { return "heute \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date,
            inSameDayAs: y) { return "gestern \(time)" }
        return date.formatted(.dateTime.day().month(.twoDigits)) + " \(time)"
    }
}

nonisolated extension RecordingLanguage { var word: String { self == .de ? "Deutsch" : "Englisch" } }

nonisolated extension Duration {
    /// "12:41" or "1:02:03".
    var clock: String {
        let s = Int(components.seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
    /// "3 h 12 min", "6 min", "10 h".
    var hoursAndMinutes: String {
        let m = Int((Double(components.seconds) / 60).rounded()), h = m / 60
        return h == 0 ? "\(m) min" : m % 60 == 0 ? "\(h) h" : "\(h) h \(m % 60) min"
    }
}

/// Menu bar item (A.12): AppKit only, never text in the bar (R-051); the symbol carries recording, cloud and warning.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength), profile: Profile
    var state: () -> MenuState
    var perform: (MenuAction) -> Void = { _ in }
    var onOpen: () -> Void = {}
    init(profile: Profile, state: @escaping () -> MenuState) {
        (self.profile, self.state) = (profile, state)
        super.init()
        let menu = NSMenu()
        (menu.autoenablesItems, menu.delegate) = (false, self)
        item.menu = menu
        item.button?.toolTip = profile.displayName
        showSymbol(recording: false, cloud: false, warning: false)
    }
    /// Template images from Resources/MenuBar (Logo B "Stimme"); the warning wins over the cloud.
    func showSymbol(recording: Bool, cloud: Bool, warning: Bool, elapsed: Int? = nil) {
        let name = "menueleiste-b" + (recording ? "-aufnahme" : "") + (warning ? "-warnung" : cloud ? "-cloud" : "")
        let image = Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: FlowIQTheme.Size.menuBarIcon, height: FlowIQTheme.Size.menuBarIcon)
        image?.accessibilityDescription = profile.displayName + (recording ? ", Aufnahme läuft" : "")
            + (warning ? ", Warnung" : "") + (cloud ? ", Cloud sendet" : "")
        item.button?.image = image
        // a red dot and the running time while anything records (review 2: where Mac users look first)
        let title = NSMutableAttributedString(string: elapsed == nil ? "" : " ●", attributes: [
            .foregroundColor: NSColor(FlowIQTheme.Color.recording)])
        if let elapsed {
            let digits = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
            title.append(NSAttributedString(string: " " + PillScene.clock(elapsed), attributes: [.font: digits]))
        }
        item.button?.attributedTitle = title
        item.button?.imagePosition = .imageLeft
    }
    /// The same menu at the pill, for a menu bar icon macOS hid behind the notch (16.11.).
    func popUp(in view: NSView) {
        item.menu?.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }
    var iconVisible: Bool {
        item.button?.window.map { Self.onScreen($0.frame, NSScreen.screens.map(\.frame)) } ?? false
    }
    nonisolated static func onScreen(_ frame: CGRect, _ screens: [CGRect]) -> Bool {
        screens.contains { $0.intersects(frame) && frame.minX >= $0.minX }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        alternate = state().settings.alternateKeys
        fill(menu, StatusMenuModel.entries(state()))
    }
    private var alternate = false  // the key hints follow the key scheme, not the profile (16.11.)
    func menuWillOpen(_ menu: NSMenu) { onOpen() }  // run time and levels are read at every opening (R-051)
    private func fill(_ menu: NSMenu, _ entries: [MenuEntry]) {
        menu.removeAllItems()
        for e in entries { menu.addItem(make(e)) }
    }
    private func make(_ e: MenuEntry) -> NSMenuItem {
        switch e.kind {
        case .separator: return .separator()
        case .header: return .sectionHeader(title: e.title)
        default: break
        }
        let item = NSMenuItem(title: e.title, action: e.action == nil ? nil : #selector(run(_:)),
            keyEquivalent: e.key ?? "")
        item.identifier = NSUserInterfaceItemIdentifier(e.id)
        (item.target, item.state, item.attributedTitle) = (self, e.checked ? .on : .off, Self.title(e))
        item.isEnabled = e.kind != .info && (e.action != nil || e.submenu != nil)
        item.representedObject = e.action.map(ActionBox.init)
        if let key = e.key {
            item.keyEquivalentModifierMask = StatusMenuModel.modifiers(key, alternate: alternate)
        }
        if let symbol = e.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let n = e.badge { item.badge = NSMenuItemBadge(count: n) }
        if let sub = e.submenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            fill(menu, sub)
            item.submenu = menu
        }
        item.setAccessibilityLabel([e.title, e.detail].compactMap { $0 }.joined(separator: ", "))
        return item
    }
    /// DM Sans 12 (design), the detail right-aligned on a tab stop; a warning puts its next step on a second line,
    /// so a long warning never pushes the menu wide or the step off its column.
    private static func title(_ e: MenuEntry) -> NSAttributedString {
        let t = FlowIQTheme.self, style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: t.Size.settings.width / 2 + t.Spacing.s24 * 3)]
        let color = NSColor(e.kind == .alert ? t.Color.warningText : t.Color.text)
        let text = NSMutableAttributedString(string: e.title, attributes: [.font: t.Font.ns(t.Font.caption),
            .foregroundColor: color, .paragraphStyle: style])
        if let detail = e.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: (e.kind == .alert ? "\n" : "\t") + detail, attributes: [
                .font: t.Font.ns(t.Font.caption), .paragraphStyle: style,
                .foregroundColor: NSColor(t.Color.textMuted)]))
        }
        if let label = e.keyLabel {
            text.append(NSAttributedString(string: "\t" + label, attributes: [.font: t.Font.ns(t.Font.caption),
                .paragraphStyle: style, .foregroundColor: NSColor(t.Color.textMuted)]))
        }
        return text
    }
    @objc private func run(_ sender: NSMenuItem) {
        if let box = sender.representedObject as? ActionBox { perform(box.action) }
    }
}

private final class ActionBox: NSObject {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}
