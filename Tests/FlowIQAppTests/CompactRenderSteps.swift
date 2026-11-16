// The pages of the main window as the real window draws them, title bar included (16.11.: "viel zu viel
// freier Platz", then large again with dense rows). Runs only with FLOWIQ_RENDER=1 and FLOWIQ_KOMPAKT=<prefix>;
// writes local/design/gebaut/<FLOWIQ_KOMPAKT_DIR or kompakt>/<prefix>-<page>-<look>.png (gitignored, the app is
// never started). The settings come once per tab, the rights with one missing.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FlowIQ

extension GalleryTests {
    @Test func compactPages() throws {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["FLOWIQ_KOMPAKT"] else { return }
        let out = PreviewRenderTests.out.appending(path: env["FLOWIQ_KOMPAKT_DIR"] ?? "kompakt",
                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pages = ["v-gefuellt": "verlauf", "a-aufnahmen": "aufnahmen", "w-woerter": "woerter"]
        var views: [(String, () -> AnyView)] = mainSteps.compactMap { step in
            guard let page = pages[step.id], let side = step.side else { return nil }
            return (page, side)
        }
        for (tab, name) in [(AppModel.Tab.recording, "aufnahme"), (.devices, "geraete"),
                            (.permissions, "berechtigungen")] {
            views.append(("einstellungen-\(name)", {
                let m = self.app { ($0.ui.section, $0.ui.tab) = (.settings, tab) }
                (m.parts.words, m.parts.devices) = (self.words(filled: false), self.devices())
                m.setup.state = PermissionState(granted: [.microphone, .accessibility, .inputMonitoring])
                return AnyView(MainView(model: m, history: HistoryModel(journal: nil) { _ in },
                                        recordings: RecordingsModel())
                    .frame(width: FlowIQTheme.Main.window.width, height: FlowIQTheme.Main.window.height))
            }))
        }
        for (page, side) in views {
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: side().environment(\.colorScheme, dark ? .dark : .light))
                let size = FlowIQTheme.Main.window
                let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                                      backing: .buffered, defer: false)
                (window.title, window.titlebarAppearsTransparent, window.appearance) = ("FlowIQ", true, appearance)
                window.backgroundColor = FlowIQTheme.Color.windowBackground
                window.contentView = host
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                let frame = window.contentView?.superview ?? host  // the theme frame: title and window buttons too
                frame.layoutSubtreeIfNeeded()
                frame.displayIfNeeded()
                guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                let bar = window.frame.height - window.contentLayoutRect.height
                print("kompakt \(prefix) \(page): Fenster \(Int(size.width)) × \(Int(size.height)), Titelleiste \(bar)")
                try rep.representation(using: .png, properties: [:])?
                    .write(to: out.appending(path: "\(prefix)-\(page)-\(dark ? "dunkel" : "hell").png"))
            }
        }
    }
}
