import AppKit
import SwiftUI

/// The FlowIQ window (16.11.): a narrow sidebar, the content right; opens at launch, from the menu and the Dock.
final class MainWindow: NSObject, NSWindowDelegate {
    private let make: () -> NSWindow
    private lazy var window = make()
    init(_ root: some View) {
        make = {
            let t = FlowIQTheme.Main.self, w = NSWindow(contentViewController: NSHostingController(rootView: root))
            (w.title, w.animationBehavior, w.isReleasedWhenClosed) = ("FlowIQ", .none, false)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            (w.titlebarAppearsTransparent, w.backgroundColor, w.contentMinSize) = (true,
                FlowIQTheme.Color.windowBackground, t.minimum)
            w.setContentSize(t.window)
            w.center()
            w.setFrameAutosaveName("FlowIQMain900")  // new name: the saved frame was the small 780 × 540 window
            return w
        }
    }
    var isVisible: Bool { window.isVisible }
    func show() {
        window.delegate = self
        Front.show(window)
    }
    /// Steps back so the app that was in front before gets the focus again (insert again).
    func stepBack() {
        _ = windowShouldClose(window)
        NSApp.hide(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Front.close(window)
        return false
    }
}

/// Windows of an app that stays in the Dock (16.11.): opening comes in front of everything, closing hands the
/// focus to the app behind, so a dictation never lands in a FlowIQ without a window.
enum Front {
    /// In front even when another app holds the focus, the window is minimized or on another Space.
    static func show(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    static func close(_ window: NSWindow) {
        window.orderOut(nil)
        let open = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count
        guard handsOn(active: NSApp.isActive, openWindows: open), let next = behind() else { return }
        NSApp.yieldActivation(to: next)
        next.activate()
    }
    nonisolated static func handsOn(active: Bool, openWindows: Int) -> Bool { active && openWindows == 0 }
    /// The app of the topmost normal window that is not ours (window list order is front to back).
    private static func behind() -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        for entry in (list as? [[CFString: Any]]) ?? [] {
            guard entry[kCGWindowLayer] as? Int == 0, let pid = entry[kCGWindowOwnerPID] as? pid_t, pid != own,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }
}

struct MainView: View {
    enum Section: String, CaseIterable { case history = "Verlauf", recordings = "Aufnahmen", words = "Wörter"
        case settings = "Einstellungen" }
    @Bindable var model: AppModel
    let history: HistoryModel, recordings: RecordingsModel
    var body: some View {
        let t = FlowIQTheme.self
        HStack(spacing: 0) {
            sidebar.frame(width: t.Main.sidebar)
            Rectangle().fill(t.Color.hairline).frame(width: t.Size.hairline)
            VStack(alignment: .leading, spacing: t.Spacing.s8) {  // one head for every view, same height (review 2)
                Text(model.ui.section.rawValue).textStyle(t.Font.smallMedium).padding(.horizontal, t.Main.inset)
                    .frame(minHeight: t.Size.control).padding(.top, t.Main.top).accessibilityAddTraits(.isHeader)
                switch model.ui.section {
                case .history: HistoryPane(model: history, keep: model.settings.keepDictationInClipboard,
                                           stepBack: { model.mainWindow.stepBack() }, key: model.ui.hasKey)
                case .recordings: RecordingsPane(model: recordings, app: model)
                case .words: WordsSection(words: model.parts.words, panotti: model.panotti != nil, names: model.names,
                                          review: model.review)
                case .settings: ScrollView { SettingsView(model: model) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)  // `Main.top` counts from the window's edge, title bar included
        .background(t.Color.background).environment(\.locale, Locale(identifier: "de_DE"))
    }
    private var sidebar: some View {
        let t = FlowIQTheme.self
        let symbols: [Section: String] = [.history: "clock.arrow.circlepath", .recordings: "waveform",
                                          .words: "textformat", .settings: "gearshape"]
        return VStack(alignment: .leading, spacing: t.Spacing.s2) {  // the name stands once, in the title bar
            ForEach(Section.allCases, id: \.self) { s in
                let on = model.ui.section == s
                Button { model.ui.section = s } label: {
                    Label(s.rawValue, systemImage: symbols[s] ?? "circle").labelStyle(.titleAndIcon)
                        .textStyle(on ? t.Font.badge : t.Font.caption, on ? t.Color.text : t.Color.textMuted)
                        .padding(.horizontal, t.Spacing.s8).frame(maxWidth: .infinity, minHeight: t.Size.control,
                                                                  alignment: .leading)
                        .background(on ? t.Color.surfaceStrong : .clear,
                                    in: RoundedRectangle(cornerRadius: t.Spacing.s8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, t.Spacing.s8).padding(.top, t.Main.top).background(t.Color.surfaceQuiet)
    }
}
