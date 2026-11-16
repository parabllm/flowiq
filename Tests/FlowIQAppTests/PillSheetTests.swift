// TEST-FIX 16.11.2026 (Pille nach local/design/pille-neu.html): the contact sheets of tiles, cards and marks
// are gone with them. This file now holds the states of the template (table ROWS plus the room's counterparts) and
// draws each of them from the real PillView, light and dark, on the template's backgrounds, four times the real
// size, into local/design/gebaut/pille-final/. The drawing runs only with FLOWIQ_RENDER=1; the states are also what
// the pill's model tests walk through (ViewModelTests, PillRandomRunTests).
import AppKit
import Foundation
import Testing
@testable import FlowIQ

@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["FLOWIQ_RENDER"] == "1"))
struct PillSheetTests {
    static let out = PreviewRenderTests.out.appending(path: "pille-final", directoryHint: .isDirectory)
    /// The template's backgrounds (--hell, --dunkel).
    static let looks: [(name: String, dark: Bool, back: CGColor)] = [
        ("hell", false, CGColor(srgbRed: 0xEC / 255.0, green: 0xEA / 255.0, blue: 0xF2 / 255.0, alpha: 1)),
        ("dunkel", true, CGColor(srgbRed: 0x0C / 255.0, green: 0x0B / 255.0, blue: 0x10 / 255.0, alpha: 1)),
    ]
    static let zoom = 4

    /// Every state of the template in its order, the room's counterparts after their call rows.
    nonisolated static let states: [(String, PillScene)] = [
        ("ruhe", PillScene()),
        ("diktat", PillScene(dictation: .dictating)),
        ("diktat-gesperrt", PillScene(dictation: .dictating, locked: true)),
        ("call-deutsch", PillScene(call: .init())),
        ("call-englisch", PillScene(call: .init(english: true), english: ["call"])),
        ("raum", PillScene(room: .init())),
        ("raum-englisch", PillScene(room: .init(english: true), english: ["room"])),
        ("call-plus-diktat", PillScene(dictation: .dictating, call: .init())),
        ("raum-plus-diktat", PillScene(dictation: .dictating, room: .init())),
        ("raum-plus-call", PillScene(call: .init(), room: .init())),
        ("alle-drei", PillScene(dictation: .dictating, call: .init(), room: .init())),
        ("problem-im-call", PillScene(call: .init(problem: true))),
        ("problem-im-raum", PillScene(call: .init(), room: .init(problem: true))),
        ("call-wird-verarbeitet", PillScene(saving: ["call": 0.65])),
        ("raum-wird-verarbeitet", PillScene(call: .init(), saving: ["room": 0.65])),
        ("stift-import", PillScene(importing: 0.65)),
    ]

    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
    }

    /// Cells of the pill canvas side by side, `columns` wide, on the look's background with the screen edge.
    private func render(_ cells: [(PillView) -> Void], columns: Int, look: (name: String, dark: Bool, back: CGColor),
                        to name: String) throws {
        let size = FlowIQTheme.Pill.canvas, rows = (cells.count + columns - 1) / columns, zoom = CGFloat(Self.zoom)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * zoom) * columns,
            pixelsHigh: Int(size.height * zoom) * rows, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.scaleBy(x: zoom, y: zoom)
        for (n, draw) in cells.enumerated() {
            let view = PillView(show: false), appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
            view.panel.appearance = appearance
            view.panel.contentView?.appearance = appearance
            draw(view)
            let cell = CGRect(x: CGFloat(n % columns) * size.width, y: CGFloat(rows - 1 - n / columns) * size.height,
                              width: size.width, height: size.height)
            ctx.setFillColor(look.back)
            ctx.fill(cell)
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.55, alpha: 0.35))  // the screen edge
            ctx.fill(CGRect(x: cell.minX, y: cell.minY, width: 1, height: cell.height))
            ctx.saveGState()
            ctx.clip(to: cell)
            ctx.translateBy(x: cell.minX, y: cell.minY)
            view.panel.contentView?.layer?.render(in: ctx)
            ctx.restoreGState()
        }
        try rep.representation(using: .png, properties: [:])?.write(to: Self.out.appending(path: name))
    }

    @Test func everyStateLightAndDark() throws {
        let rest = PillScene(), active = PillScene(dictation: .dictating), call = PillScene(call: .init())
        let strips: [(String, PillScene, PillScene)] = [
            ("wachsen", rest, active), ("loslassen", active, rest), ("call-erscheint", rest, call),
            ("call-gestoppt", call, PillScene(saving: ["call": 0])),
        ]
        let times = [0.0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.6]
        for look in Self.looks {
            try render(Self.states.map { _, scene in { $0.show(scene) } }, columns: 8, look: look,
                       to: "zustaende-\(look.name).png")
            for (name, scene) in Self.states {
                try render([{ $0.show(scene) }], columns: 1, look: look, to: "\(name)-\(look.name).png")
            }
            for (name, from, to) in strips {
                try render(times.map { t in { $0.still(to, from: from, at: t) } }, columns: times.count, look: look,
                           to: "bewegung-\(name)-\(look.name).png")
            }
        }
        let list = "Zustände in zustaende-hell.png und zustaende-dunkel.png, zeilenweise von links oben, je Zelle "
            + "60 × 120 pt in vierfacher Größe:\n" + Self.states.map(\.0).joined(separator: ", ")
            + "\n\nbewegung-*.png: 0, 50, 100, 150, 200, 300, 400, 600 ms nach dem Wechsel.\n"
        try list.write(to: Self.out.appending(path: "zustaende.txt"), atomically: true, encoding: .utf8)
    }
}
