// The state gallery (16.11.: "was alles passieren kann, wenn man die Knöpfe drückt"): every flow step drawn
// from the real models and views, pill layers plus menu or window, light and dark, the pill also over a photo.
// Runs only with FLOWIQ_RENDER=1; writes local/design/gebaut/galerie/ and galerie.html (gitignored, never started).
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
struct GalleryTests {
    static let out = PreviewRenderTests.out.appending(path: "galerie", directoryHint: .isDirectory)
    static let looks = ["hell", "dunkel"]
    static let crop = CGRect(origin: .zero, size: FlowIQTheme.Pill.canvas)  // the whole pill canvas

    /// One step of a flow: what the user did or what happened, and what is on screen then.
    struct Step {
        let id: String, caption: String
        var pill: PillScene?
        var frames: [(PillScene, PillScene, Double)] = []  // an animation strip instead of one pill
        var side: (() -> AnyView)?
    }

    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for name in ["DMSans-Regular", "DMSans-Medium", "DMSans-SemiBold"] {
            CTFontManagerRegisterFontsForURL(PreviewRenderTests.root.appending(path: "Resources/Fonts/\(name).ttf")
                as CFURL, .process, nil)
        }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
    }

    // MARK: state from the real models

    /// The app model in a given situation; alerts and the pill come from the app's own functions.
    func app(_ edit: (AppModel) -> Void = { _ in }) -> AppModel {
        let m = AppModel(profile: .production, settings: .defaults(for: .production), pill: PillView(show: false))
        (m.ui.tapRunning, m.ui.hasKey, m.ui.cloudSeconds, m.settings.cloudLimitMinutes) = (true, true, 192 * 60, 600)
        m.ui.mics = ["airpods": "AirPods Pro", "builtin": "MacBook-Mikrofon"]
        m.parts.models = OpenRouterModels.load(PreviewRenderTests.root.appending(
            path: "Resources/Cloud/openrouter-modelle.json"))
        edit(m)
        m.ui.alerts = AppModel.alerts(m.ui, silent: AppModel.silent(m.ui), limit: m.settings.cloudLimitMinutes ?? 0)
        return m
    }
    func scene(_ m: AppModel, _ edit: (inout PillScene) -> Void = { _ in }) -> PillScene {
        var s = PillScene()
        AppModel.show(m.ui, in: &s)
        edit(&s)
        return s
    }
    func menu(_ m: AppModel) -> () -> AnyView {
        let entries = StatusMenuModel.entries(m.menuState)
        return { AnyView(MenuSheet(entries: entries)) }
    }
    func call(_ language: RecordingLanguage = .de, _ edit: (inout Running) -> Void = { _ in }) -> Running {
        var r = Running(kind: .call, language: language, started: .now.addingTimeInterval(-761))
        r.device = "builtin"
        edit(&r)
        return r
    }
    func room(_ edit: (inout Running) -> Void = { _ in }) -> Running {
        var r = Running(kind: .room, language: .de, started: .now.addingTimeInterval(-1830))
        r.device = "builtin"
        edit(&r)
        return r
    }
    /// One step from an app situation: its pill and its menu.
    func step(_ id: String, _ caption: String, pill edit: (inout PillScene) -> Void = { _ in },
              _ situation: (AppModel) -> Void) -> Step {
        let m = app(situation)
        return Step(id: id, caption: caption, pill: scene(m, edit), side: menu(m))
    }

    // MARK: flows

    // MARK: flows (A to D in GalleryPillSteps.swift, E to G in GalleryWindowSteps.swift)

    // MARK: drawing

    private static let photo = PreviewRenderTests.photoImage
    private func pillImage(_ scene: PillScene?, frames: [(PillScene, PillScene, Double)], look: String) -> CGImage? {
        let cells: [(PillView) -> Void] = scene.map { s in [{ v in v.show(s) }] }
            ?? frames.map { f in { v in v.still(f.0, from: f.1, at: f.2) } }
        guard !cells.isEmpty else { return nil }
        let crop = frames.isEmpty ? Self.crop : CGRect(x: 0, y: 20, width: 44, height: 80)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(crop.width) * 2 * cells.count,
            pixelsHigh: Int(crop.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.scaleBy(x: 2, y: 2)
        for (n, draw) in cells.enumerated() {
            let view = PillView(show: false), appearance = NSAppearance(named: look == "dunkel" ? .darkAqua : .aqua)
            view.panel.appearance = appearance
            view.panel.contentView?.appearance = appearance
            draw(view)
            let cell = CGRect(x: CGFloat(n) * crop.width, y: 0, width: crop.width, height: crop.height)
            PreviewRenderTests.backdrop(look, ctx, cell, n)
            ctx.saveGState()
            ctx.clip(to: cell)
            ctx.translateBy(x: cell.minX - crop.minX, y: -crop.minY)
            view.panel.contentView?.layer?.render(in: ctx)
            ctx.restoreGState()
        }
        return rep.cgImage
    }
    private func viewImage(_ view: AnyView, dark: Bool) -> CGImage? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        (window.appearance, window.contentView) = (host.appearance, host)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
    /// Pill left, menu or window right, on the look's background; returns the file name.
    private func compose(_ step: Step, look: String) throws -> String? {
        let pill = pillImage(step.pill, frames: step.frames, look: look)
        let side = look == "foto" ? nil : step.side.flatMap { viewImage($0(), dark: look == "dunkel") }
        guard pill != nil || side != nil else { return nil }
        let margin = 32, gap = 32
        let pw = pill?.width ?? 0, ph = pill?.height ?? 0, sw = side?.width ?? 0, sh = side?.height ?? 0
        let width = margin * 2 + pw + sw + (pill != nil && side != nil ? gap : 0)
        let height = margin * 2 + max(ph, sh)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(look == "dunkel" ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.86, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let pill { ctx.draw(pill, in: CGRect(x: margin, y: height - margin - ph, width: pw, height: ph)) }
        if let side {
            ctx.draw(side, in: CGRect(x: width - margin - sw, y: height - margin - sh, width: sw, height: sh))
        }
        let name = "\(step.id)-\(look).png"
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])?
            .write(to: Self.out.appending(path: name))
        return name
    }

    @Test func gallery() throws {
        var html = """
        <!doctype html><html lang="de"><meta charset="utf-8"><title>FlowIQ Zustandsgalerie</title>
        <style>body{font:14px/1.45 -apple-system,sans-serif;margin:24px;background:#f6f5fd;color:#1a1726}
        h2{margin-top:40px}figure{margin:0 0 28px}figcaption{margin:0 0 8px;font-weight:600}
        .row{display:flex;gap:12px;flex-wrap:wrap;align-items:flex-start}img{max-width:100%;border-radius:8px;
        box-shadow:0 1px 4px rgba(0,0,0,.15)}@media(prefers-color-scheme:dark){body{background:#1a1726;
        color:#fbf9fe}}</style>
        <h1>FlowIQ Zustandsgalerie</h1><p>Gerendert aus den echten Modellen und Ansichten im Testlauf, App nicht
        gestartet. Je Schritt hell, dunkel und die Pille über einem Foto.</p>
        """
        for (title, steps) in pillFlows + windowFlows + [("G Fenster", windows)] {
            html += "<h2>\(title)</h2>"
            for step in steps {
                html += "<figure><figcaption>\(step.id): \(step.caption)</figcaption><div class=row>"
                let looks = Self.looks + (step.pill != nil || !step.frames.isEmpty ? ["foto"] : [])
                for look in looks {
                    guard let name = try compose(step, look: look) else { continue }
                    let data = try Data(contentsOf: Self.out.appending(path: name)).base64EncodedString()
                    html += "<img alt=\"\(name)\" src=\"data:image/png;base64,\(data)\">"
                }
                html += "</div></figure>"
            }
        }
        try (html + "</html>").write(to: Self.out.appending(path: "galerie.html"), atomically: true, encoding: .utf8)
    }
}
