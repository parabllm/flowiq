// Preview images of the views without starting the app (P7 visual check): offscreen windows that are never shown,
// layers rendered into bitmaps. Runs only with FLOWIQ_RENDER=1; writes to local/design/gebaut/ (gitignored).
import AppKit
import CoreText
import FlowIQCore
@testable import FlowIQDevices
import FlowIQRecording
import FlowIQStore
import Foundation
import SwiftUI
import Testing
@testable import FlowIQ

@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["FLOWIQ_RENDER"] == "1"))
struct PreviewRenderTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let out = root.appending(path: "local/design/gebaut", directoryHint: .isDirectory)

    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for name in ["DMSans-Regular", "DMSans-Medium", "DMSans-SemiBold"] {
            let url = Self.root.appending(path: "Resources/Fonts/\(name).ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
    }

    private func save(_ name: String, dark: Bool, size: CGSize? = nil, _ view: some View) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? host.fittingSize),
            styleMask: .borderless,
                              backing: .buffered, defer: false)
        (window.appearance, window.contentView) = (host.appearance, host)
        host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: Self.out.appending(path: name + (dark ? "-dunkel" : "") + ".png"))
    }

    private func model() -> AppModel {
        let m = AppModel(profile: .production, settings: .defaults(for: .production), pill: PillView(show: false))
        (m.ui.hasKey, m.ui.cloudSeconds, m.settings.cloudLimitMinutes) = (true, 192 * 60, 600)
        m.parts.models = OpenRouterModels.load(Self.root.appending(path: "Resources/Cloud/openrouter-modelle.json"))
        m.change { try $0.set(.call, live: .elevenLabsRealtime, hasKey: true) }
        return m
    }

    @Test func settingsSetupCorrection() throws {
        for dark in [false, true] {
            let m = model()
            m.ui.tab = .recording
            let dev = AppModel(profile: .development, settings: .defaults(for: .development),
                               pill: PillView(show: false))
            dev.parts.models = m.parts.models
            try save("einstellungen-testversion", dark: dark, size: FlowIQTheme.Size.settings, SettingsView(model: dev))
            try save("einstellungen", dark: dark, size: FlowIQTheme.Size.settings, SettingsView(model: m))
            let dir = FileManager.default.temporaryDirectory.appending(path: "flowiq-render-words")
            let fs = SafeFS(confinedTo: dir), log = EventLog(directory: dir.appending(path: "log"), fs: fs)
            let lexicon = LexiconStore(folder: dir, fs: fs, log: log)
            m.parts.words = WordsModel(lexicon: lexicon, ledger: CorrectionLedger(lexicon: lexicon, fs: fs, log: log))
            m.ui.tab = .words
            try save("einstellungen-woerter", dark: dark, size: FlowIQTheme.Size.settings, SettingsView(model: m))
            m.ui.tab = .devices
            let devices = DevicesModel(nil)
            devices.enabled = true
            devices.files = [.init(name: "REC_0042.WAV", state: "abgelegt", retry: false),
                             .init(name: "REC_0043.WAV", state: "fehlgeschlagen", retry: true)]
            m.parts.devices = devices
            try save("einstellungen-geraete", dark: dark, size: FlowIQTheme.Size.settings, SettingsView(model: m))
            m.ui.tab = .recording
            let setup = PermissionModel()
            try save("einrichten", dark: dark, SetupView(model: setup, app: m))
            let c = CorrectionModel()
            c.words = ("Schick mir bis Freitag die Zahlen für das Calmora Angebot, dann gehen wir es am Montag "
                       + "mit Brightloop durch.")
                .split(separator: " ").map(String.init)
            (c.changed, c.selection, c.recent, c.current) = ([17..<18], 8..<9, [("a", "vor 1 min"), ("b", "Bitte")],
                "a")
            c.options = CorrectionOptions(recognizerAlternatives: ["Kal Mora"], lexiconNeighbors: ["Kalmora"],
                                          rawForm: "Calmora", offersWasRight: false)
            try save("korrektur", dark: dark, CorrectionPanel(model: c))
            c.asking = true
            c.question = (2, "Angebot", true)
            try save("korrektur-frage", dark: dark, CorrectionPanel(model: c))
            // TEST-FIX 16.11.2026: die Nachfrage an der Pille ist entfernt, ihre Bilder mit ihr
        }
    }

    @Test func menuAsDrawnFromTheModel() throws {
        var s = MenuState(profile: .production, settings: .defaults(for: .production), hasKey: true)
        s.recent = [RecentTranscript(url: URL(filePath: "/tmp/a.md"), kind: .call,
            date: .now.addingTimeInterval(-3600)),
                    RecentTranscript(url: URL(filePath: "/tmp/b.md"), kind: .room,
                        date: .now.addingTimeInterval(-90_000))]
        (s.newNames, s.cloudSeconds, s.limitMinutes) = (3, 192 * 60, 600)
        var running = s
        running.alerts = [.micSilent, .permission("Eingabeüberwachung"), .trouble(.modelMissing(.en))]
        running.running = [Running(kind: .call, language: .de, started: .now.addingTimeInterval(-761), sending: true,
                                   device: "airpods", cloudSeconds: 360, levels: [0.6, 0.4])]
        running.mics = ["airpods": "AirPods Pro"]
        for dark in [false, true] {
            try save("menue", dark: dark, MenuSheet(entries: StatusMenuModel.entries(s)))
            try save("menue-fehler", dark: dark, MenuSheet(entries: StatusMenuModel.entries(running)))
            try save("menue-live-nachlauf", dark: dark, MenuSheet(entries: StatusMenuModel.cloud(s)))
        }
    }

    /// Backdrops: light, dark and a photo (a macOS desktop picture, read only).
    static let photoImage: NSImage? = ["/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic",
        "/System/Library/Desktop Pictures/Sonoma.heic"].lazy.compactMap { NSImage(contentsOfFile: $0) }.first
    static func backdrop(_ kind: String, _ ctx: CGContext, _ cell: CGRect, _ n: Int) {
        switch kind {
        case "dunkel": ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(cell)
        case "foto":
            guard let image = photoImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let w = CGFloat(image.width), h = CGFloat(image.height), scale = max(cell.width * 3 / w, cell.height / h)
            ctx.saveGState()
            ctx.clip(to: cell)
            ctx.draw(image, in: CGRect(x: cell.minX - CGFloat(n % 3) * cell.width, y: cell.minY, width: w * scale,
                                       height: h * scale))
            ctx.restoreGState()
        default: ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(cell)
        }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))  // the screen edge
        ctx.fill(CGRect(x: cell.minX, y: cell.minY, width: 1, height: cell.height))
    }
    /// A sheet of cells, each the pill canvas cut to `crop`, `columns` wide.
    private func sheet(_ name: String, _ crop: CGRect, columns: Int, _ cells: [(PillView) -> Void]) throws {
        let rows = (cells.count + columns - 1) / columns
        for kind in ["hell", "dunkel", "foto"] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(crop.width) * 2 * columns,
                pixelsHigh: Int(crop.height) * 2 * rows, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            ctx.scaleBy(x: 2, y: 2)
            for (n, draw) in cells.enumerated() {
                let view = PillView(show: false)
                let look = NSAppearance(named: kind == "dunkel" ? .darkAqua : .aqua)
                view.panel.appearance = look
                view.panel.contentView?.appearance = look
                draw(view)
                let cell = CGRect(x: CGFloat(n % columns) * crop.width,
                                  y: CGFloat(rows - 1 - n / columns) * crop.height, width: crop.width,
                                  height: crop.height)
                Self.backdrop(kind, ctx, cell, n)
                ctx.saveGState()
                ctx.clip(to: cell)
                ctx.translateBy(x: cell.minX - crop.minX, y: cell.minY - crop.minY)
                view.panel.contentView?.layer?.render(in: ctx)
                ctx.restoreGState()
            }
            try rep.representation(using: .png, properties: [:])?
                .write(to: Self.out.appending(path: "pille-neu-\(name)-\(kind).png"))
        }
    }

    @Test func pillStates() throws {
        // TEST-FIX 16.11.2026: the states of local/design/pille-neu.html (all of them in PillSheetTests)
        let scenes = PillSheetTests.states
        try sheet("zustaende", CGRect(origin: .zero, size: FlowIQTheme.Pill.canvas), columns: 6,
                  scenes.map { _, scene in { view in view.show(scene) } })
        try String(scenes.map(\.0).joined(separator: ", ")).write(to: Self.out.appending(path: "pille-neu.txt"),
                                                                   atomically: true, encoding: .utf8)
        let rest = PillScene(), active = PillScene(dictation: .dictating)
        let frames: [(PillScene, PillScene, Double)] = [(rest, rest, 1), (active, rest, 0.1), (active, rest, 0.2),
            (active, rest, 0.3), (active, rest, 0.6), (active, active, 1), (rest, active, 0.2), (rest, active, 0.6)]
        try sheet("wachsen", CGRect(x: 0, y: 20, width: 40, height: 80), columns: frames.count, frames.map { f in
            { view in view.still(f.0, from: f.1, at: f.2) }
        })
    }
}

/// A stand-in drawing of the native menu from the same entries (the real NSMenu only shows in the test window).
struct MenuSheet: View {
    let entries: [MenuEntry]
    var body: some View {
        let t = FlowIQTheme.self
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                switch e.kind {
                case .separator: Rectangle().fill(t.Color.hairline).frame(height: 1).padding(.vertical, 4)
                case .header: Text(e.title).textStyle(t.Font.label, t.Color.textMuted).padding(.top,
                    6).padding(.bottom, 2)
                case .alert:  // two lines like the native item: the warning, then its next step
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: e.symbol ?? "").frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).textStyle(t.Font.caption, t.Color.warningText)
                            Text(e.detail ?? "").textStyle(t.Font.caption, t.Color.textMuted)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4).background(t.Color.warningTint)
                default:
                    HStack(spacing: 8) {
                        Image(systemName: e.checked ? "checkmark" : e.symbol ?? "").frame(width: 14)
                        Text(e.title).textStyle(t.Font.caption, e.kind == .alert ? t.Color.warningText : t.Color.text)
                        Spacer()
                        if let n = e.badge { Text("\(n)").textStyle(t.Font.badge, t.Color.accent) }
                        Text(e.detail ?? "").textStyle(t.Font.caption,
                            e.kind == .alert ? t.Color.warningText : t.Color.textMuted)
                        if e.submenu != nil { Image(systemName: "chevron.right") }
                        // COMPILE-FIX 16.11.2026: no Shift any more, English shows its two letters as text
                        if let k = e.keyLabel ?? e.key.map({ StatusMenuModel.keyText($0, alternate: false) }) { Text(k)
                            .textStyle(t.Font.caption, t.Color.textMuted) }
                    }
                    .frame(height: 22).opacity(e.kind == .info ? 0.8 : 1)
                    .background(e.kind == .alert ? t.Color.warningTint : .clear)
                }
            }
        }
        .padding(10).frame(width: 360).background(t.Color.surface)
    }
}

// TEST-FIX 16.11.2026 (Pille nach pille-neu.html): the frozen moment covers every element, not only the capsule.
extension PillView {
    /// A scene exactly as given, "EN" included (no timers).
    func show(_ s: PillScene) {
        update(animated: false) { $0 = s }
        update(animated: false) { $0.english = s.english }
    }
    /// For the previews: `seconds` into the change from `start` to `target`, frozen as the real animation runs it:
    /// sizes on the spring around their center, colors over 0.3 s, what comes or goes scaling from half size at its
    /// place with its opacity over 0.2 s.
    func still(_ target: PillScene, from start: PillScene, at seconds: Double) {
        let m = FlowIQTheme.PillMotion.self, spring = CGFloat(m.progress(seconds))
        let fade = Float(min(1, seconds / m.fade)), tint = CGFloat(min(1, seconds / m.color))
        let before = PillView(show: false)
        before.panel.appearance = panel.appearance
        before.panel.contentView?.appearance = panel.appearance
        before.show(start)
        show(target)
        let old = Dictionary(uniqueKeysWithValues: start.elements.map { ($0.id, $0) })
        let new = Set(target.elements.map(\.id))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let parts = { (c: CGColor?) in c?.converted(to: space, intent: .defaultIntent, options: nil)?.components
            ?? [0, 0, 0, 0] }
        let mix = { (x: CGColor?, y: CGColor?) in
            CGColor(colorSpace: space, components: zip(parts(x), parts(y)).map { $0 + ($1 - $0) * tint })
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for e in target.elements {
            guard let layer = layer(e.id) else { continue }
            guard let o = old[e.id], let was = before.layer(e.id) else {
                (layer.opacity, layer.transform) = (fade, CATransform3DMakeScale(m.start + (1 - m.start) * spring,
                                                                                m.start + (1 - m.start) * spring, 1))
                continue
            }
            let w = o.frame.width + (e.frame.width - o.frame.width) * spring
            let h = o.frame.height + (e.frame.height - o.frame.height) * spring, r = min(w, h) / 2
            (layer.bounds, layer.cornerRadius) = (CGRect(x: -w / 2, y: -h / 2, width: w, height: h), r)
            layer.backgroundColor = mix(was.backgroundColor, layer.backgroundColor)
            layer.borderColor = mix(was.borderColor, layer.borderColor)
            guard let rim = layer.sublayers?.first, let rimWas = was.sublayers?.first else { continue }
            (rim.bounds, rim.cornerRadius) = (layer.bounds.insetBy(dx: -1, dy: -1), r + 1)
            rim.borderColor = mix(rimWas.borderColor, rim.borderColor)
        }
        for e in start.elements where !new.contains(e.id) {
            guard let was = before.layer(e.id) else { continue }
            was.removeFromSuperlayer()
            panel.contentView?.layer?.addSublayer(was)
            let s = 1 - (1 - m.start) * spring
            (was.opacity, was.transform) = (1 - fade, CATransform3DMakeScale(s, s, 1))
        }
        CATransaction.commit()
    }
}
