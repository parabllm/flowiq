// The menu with the hints of Paket D (16.11.), drawn from the app's own model, light and dark, into
// local/design/gebaut/menue-final/ (gitignored). Runs only with FLOWIQ_RENDER=1.
import AppKit
import FlowIQCore
import FlowIQDevices
import FlowIQRecording
import SwiftUI
import Testing
@testable import FlowIQ

@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["FLOWIQ_RENDER"] == "1"))
struct MenuHintRenderSteps {
    static let out = PreviewRenderTests.out.appending(path: "menue-final", directoryHint: .isDirectory)
    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for name in ["DMSans-Regular", "DMSans-Medium", "DMSans-SemiBold"] {
            let url = PreviewRenderTests.root.appending(path: "Resources/Fonts/\(name).ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
    }
    private func save(_ name: String, _ m: AppModel) throws {
        m.ui.alerts = AppModel.alerts(m.ui, silent: AppModel.silent(m.ui), limit: 0)
        for dark in [false, true] {
            let view = MenuSheet(entries: StatusMenuModel.entries(m.menuState))
            let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            (window.appearance, window.contentView) = (host.appearance, host)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: Self.out.appending(path: name + (dark ? "-dunkel" : "-hell") + ".png"))
        }
    }
    private func model(_ edit: (AppModel) -> Void) -> AppModel {
        let m = AppModel(profile: .production, settings: .defaults(for: .production), pill: PillView(show: false))
        (m.ui.tapRunning, m.ui.hasKey) = (true, true)
        m.ui.mics = ["airpods": "AirPods Pro", "builtin": "MacBook-Mikrofon"]
        edit(m)
        return m
    }
    private func running(_ kind: SessionKind, _ device: String = "builtin", ago: Double = 761) -> Running {
        Running(kind: kind, language: .de, started: .now.addingTimeInterval(-ago), device: device)
    }
    @Test func hints() throws {
        try save("1-diktat-nicht-erkannt", model { $0.ui.dictationFailed = true })
        try save("1b-diktat-ohne-ton", model { $0.ui.dictationFailed = false })
        try save("2-kopfhoerer-getrennt", model {
            $0.ui.running = [self.running(.call, "airpods")]
            $0.ui.micLost = "AirPods Pro"
        })
        try save("3-import-gescheitert", model {
            ($0.ui.importing, $0.ui.importFailed) = (.failed(.copy), ["2026_11_09_19_02_40.WAV"])
        })
        try save("4-schlaf-pause", model {
            $0.ui.running = [self.running(.room, ago: 3 * 3600 + 62)]
            $0.ui.pauses = [.room: "14:02 bis 15:10"]
        })
        try save("5-was-laeuft", model {
            $0.ui.running = [self.running(.call), self.running(.room, ago: 1830)]
            ($0.parts.afterRun, $0.ui.importing) = ([.call], .copying(0.4))
            $0.parts.stopping = [.call]
            $0.pill.update { ($0.dictation, $0.locked) = (.dictating, true) }
        })
        try save("6-start-und-verschriften", model {
            $0.parts.starting[.call] = .now
            $0.ui.importing = .transcribing
        })
        try save("7-alle-hinweise-zugleich", model {
            $0.ui.running = [self.running(.call, "airpods"), self.running(.room, "airpods")]
            $0.ui.running[0].silent = true
            ($0.ui.missing, $0.ui.micLost, $0.ui.dictationFailed) = ([.accessibility], "AirPods Pro", true)
            ($0.ui.importing, $0.ui.importFailed) = (.failed(.transcribe), ["a.WAV", "b.WAV", "c.WAV"])
            ($0.ui.post, $0.ui.notInserted, $0.ui.pauses) = (.waiting(count: 2), true, [.room: "14:02 bis 15:10"])
        })
    }
}
