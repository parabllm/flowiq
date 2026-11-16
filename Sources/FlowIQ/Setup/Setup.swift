import SwiftUI
/// The four rights of the setup list (A.12, R-082), each with one purpose, its symbol and its privacy pane.
nonisolated enum Permission: String, CaseIterable, Hashable, Sendable {
    case microphone = "Privacy_Microphone", accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent", screenRecording = "Privacy_ScreenCapture"
    var row: (title: String, purpose: String, symbol: String) {
        switch self {
        case .microphone: ("Mikrofon", "Diktat, Call und Raum hören", "mic")
        case .accessibility: ("Bedienungshilfen", "Text ins aktive Feld einfügen", "accessibility")
        case .inputMonitoring: ("Eingabeüberwachung", "Fn und Kurzbefehle erkennen", "keyboard")
        case .screenRecording: ("Bildschirmaufnahme", "nur für Calls, später möglich", "display")
        }
    }
    var title: String { row.title }
    var settingsURL: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") }
}

/// Status read with APIs that never show a prompt.
nonisolated struct PermissionState: Equatable, Sendable {
    var granted: Set<Permission> = [], microphoneUndetermined = false
    @concurrent
    static func read() async -> PermissionState {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let checks: [(Permission, Bool)] = [(.microphone, mic == .authorized), (.accessibility, AXIsProcessTrusted()),
                                            (.inputMonitoring, CGPreflightListenEventAccess()),
                                            (.screenRecording, CGPreflightScreenCaptureAccess())]
        return PermissionState(granted: Set(checks.filter(\.1).map(\.0)), microphoneUndetermined: mic == .notDetermined)
    }
    /// Shows the system prompt; only ever called from a click on the row's button.
    @concurrent
    static func ask(_ permission: Permission) async {
        switch permission {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        }
    }
}

/// Nothing is asked at launch; a click asks once, a second click (or a decided microphone) opens the privacy pane.
@Observable
final class PermissionModel {
    var state = PermissionState()  // settable for the gallery; the app only reads it via refresh
    private(set) var asked: Set<Permission> = []
    @ObservationIgnored var read: @Sendable () async -> PermissionState = { await PermissionState.read() }
    func refresh() async {
        let next = await read()
        if next != state { state = next }
    }
    func request(_ permission: Permission) async {
        let promptPossible = permission == .microphone ? state.microphoneUndetermined : !asked.contains(permission)
        asked.insert(permission)
        if promptPossible { await PermissionState.ask(permission) } else if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        }
        await refresh()
    }
    func needsRestart(_ p: Permission) -> Bool {
        [.inputMonitoring, .screenRecording].contains(p) && asked.contains(p) && !state.granted.contains(p)
    }
    static func restart() { AppDelegate.quit(restart: true) }  // asks first, then the new instance, then the end
}

/// The FlowIQ mark, Logo B "Stimme": five bars like a level meter, the middle one runs on as the stem.
struct BrandMark: View {
    var body: some View {
        let b = FlowIQTheme.Brand.self, c = FlowIQTheme.Color.self
        Canvas { context, size in
            let unit = size.height / b.grid, half = b.stroke / 2
            for (n, bar) in b.bars.enumerated() {
                let rect = CGRect(x: (bar.x - half - b.inset) * unit, y: (bar.top - half) * unit,
                    width: b.stroke * unit, height: (bar.bottom - bar.top + b.stroke) * unit)
                let color = [c.brandOuter, c.brandMid, c.brandCenter][min(n, b.bars.count - 1 - n)]
                context.fill(Path(roundedRect: rect, cornerRadius: half * unit), with: .color(color))
            }
        }
        .aspectRatio(b.aspect, contentMode: .fit).accessibilityHidden(true)
    }
}

/// Einrichten (R-082): four rights and the start at login; only the next open right in ink, "Fertig" always.
struct SetupView: View {
    let model: PermissionModel
    @Bindable var app: AppModel
    var body: some View {
        let t = FlowIQTheme.self, next = Permission.allCases.first { !model.state.granted.contains($0)
            || $0 == .inputMonitoring && !app.ui.tapRunning }
        VStack(alignment: .leading, spacing: t.Spacing.s12) {
            HStack(spacing: t.Spacing.s12) {
                BrandMark().frame(height: t.Size.appMark)
                VStack(alignment: .leading, spacing: t.Spacing.s2) {
                    Text("Vier Rechte, dann läuft \(app.profile.displayName).").textStyle(t.Font.smallMedium)
                    Text("Jedes Recht hat genau einen Zweck.").textStyle(t.Font.caption, t.Color.textMuted)
                }
            }
            .padding(.top, t.Spacing.s20)
            VStack(spacing: 0) {
                ForEach(Permission.allCases, id: \.self) { p in
                    row(p, primary: p == next)
                    Rectangle().fill(t.Color.hairline).frame(height: t.Size.hairline)
                }
                if app.profile == .production {
                    Toggle(isOn: Binding(get: { app.settings.launchAtLogin }, set: { on in
                        app.change { $0.launchAtLogin = on } })) {
                        Text("Bei Anmeldung starten").textStyle(t.Font.small)
                    }
                    .toggleStyle(FlowSwitch()).frame(minHeight: t.Size.rowTall)
                }
            }
            .padding(.horizontal, t.Spacing.s12).card()
            HStack {
                Explain(title: "Was \(app.profile.displayName) damit nicht tut", text: "Kein Bild vom Bildschirm, nur "
                        + "Ton. Keine Tastatureingaben speichern, nur Fn und deine Kurzbefehle erkennen. Diktat-Ton "
                        + "verlässt den Mac nur mit eingeschalteter genauerer Fassung und Schlüssel.")
                Spacer()
                Button("Fertig") { app.setupWindow.hide() }.buttonStyle(FlowButton()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, t.Spacing.s16).padding(.bottom, t.Spacing.s16)
        .frame(width: t.Size.setupWidth).background(t.Color.background)
        .task { await model.refresh() }
    }
    private func row(_ p: Permission, primary: Bool) -> some View {
        PermissionRow(model: model, permission: p, tapRunning: app.ui.tapRunning, primary: primary)
    }
}

/// One right with its state; Einrichten shows a symbol tile, the settings tab (`words`) the state as a word.
struct PermissionRow: View {
    let model: PermissionModel, permission: Permission, tapRunning: Bool
    var primary = false, words = false
    var body: some View {
        let t = FlowIQTheme.self, p = permission, restart = model.needsRestart(p)
        let granted = model.state.granted.contains(p) && (p != .inputMonitoring || tapRunning)  // Review M2
        HStack(spacing: t.Spacing.s12) {
            if !words {
                Image(systemName: p.row.symbol).font(t.Font.symbol(t.Size.symbolLarge)).foregroundStyle(t.Color.accent)
                    .frame(width: t.Size.iconTile, height: t.Size.iconTile).background(t.Color.accentTint,
                        in: RoundedRectangle(cornerRadius: t.Spacing.s8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(p.title).textStyle(t.Font.small)
                Text(restart && !words ? "Neustart nötig" : p.row.purpose).textStyle(t.Font.micro, t.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)  // the purpose keeps its line, the button keeps its size
            Spacer(minLength: t.Spacing.s8)
            if granted && words {
                HStack(spacing: t.Spacing.s4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(t.Color.success)
                    Text("erteilt").textStyle(t.Font.caption, t.Color.successText)
                }
            } else if granted {
                Image(systemName: "checkmark.circle.fill").font(t.Font.symbol(t.Size.symbolLarge + t.Spacing.s4))
                    .foregroundStyle(t.Color.success).accessibilityLabel("erteilt")
            } else {
                if words {
                    Text(restart ? "Neustart nötig" : "fehlt").textStyle(t.Font.caption, t.Color.warningText)
                }
                if restart {
                    Button("Neu starten") { PermissionModel.restart() }.buttonStyle(FlowButton(primary: primary))
                } else {
                    Button("Öffnen …") { Task { await model.request(p) } }.buttonStyle(FlowButton(primary: primary))
                }
            }
        }
        .padding(.vertical, t.Spacing.s6)  // wrapped text breathes
        .frame(minHeight: words ? t.Size.rowTall : t.Size.rowTall + t.Spacing.s8)
        .accessibilityElement(children: .combine)
    }
}

/// Einstellungen, Reiter "Berechtigungen": the four rights of Einrichten, read again when the tab appears and
/// whenever a window comes to the front; `after` lets the app follow (key tap, menu), as Einrichten does.
struct PermissionsPane: View {
    let model: PermissionModel, tapRunning: Bool
    var after: () async -> Void = {}
    /// Back from the system settings: the app is active again or one of its windows is the key window.
    static let front = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Permission.allCases, id: \.self) { p in
                PermissionRow(model: model, permission: p, tapRunning: tapRunning, words: true)
                    .overlay(alignment: .bottom) { Hairline(hidden: p == Permission.allCases.last) }
            }
        }
        .padding(.horizontal, FlowIQTheme.Spacing.s12).card()
        .task { await read() }
        .onReceive(Self.front) { _ in Task { await read() } }
    }
    private func read() async {
        await model.refresh()
        await after()
    }
}
