// Paket G (16.11.): the history row with "Mit ElevenLabs neu erkennen", the settings row with the hint for a
// pasted key id, and the question before a large batch. The steps are part of the gallery; `renewPictures` also
// writes them alone, light and dark, into local/design/gebaut/neu-erkennen/ (gitignored, the app is never started).
import AppKit
import FlowIQCloud
import FlowIQStore
import Foundation
import SwiftUI
import Testing
@testable import FlowIQ

extension GalleryTests {
    var renewSteps: [Step] {
        let now = Date.now
        func item(_ id: String, _ ago: Double, _ text: String, renewed: Bool = false) -> HistoryItem {
            HistoryItem(id: id, date: now.addingTimeInterval(-ago), text: text, rawText: text.lowercased(),
                        changed: [], app: "Mail", result: "landed", seconds: 4, msToText: 180, renewed: renewed)
        }
        let items = [item("1", 300, "Schick mir bis Freitag die Zahlen für das Kalmora Angebot."),
                     item("2", 3_600, "Kurze Notiz an mich: Rückruf bei Wiebke wegen der Lieferung.", renewed: true),
                     item("3", 7_200, "Termin am Donnerstag passt.")]
        func history(_ id: String, _ caption: String, key: Bool, _ edit: @escaping (HistoryModel) -> Void) -> Step {
            Step(id: id, caption: caption) {
                let m = self.app { ($0.ui.section, $0.ui.hasKey) = (.history, key) }
                let h = HistoryModel(journal: nil) { _ in }
                (h.items, h.stats) = (items, HistoryStats(dictations: 3))
                edit(h)
                let size = FlowIQTheme.Main.window
                return AnyView(MainView(model: m, history: h, recordings: RecordingsModel())
                    .frame(width: size.width, height: size.height))
            }
        }
        func window(_ id: String, _ caption: String, _ edit: @escaping (AppModel) -> Void) -> Step {
            Step(id: id, caption: caption) {  // the settings as the window at its opening size shows them
                let m = self.app { $0.ui.section = .settings; edit($0) }
                (m.parts.words, m.parts.devices) = (self.words(filled: false), self.devices())
                let size = FlowIQTheme.Main.window
                return AnyView(MainView(model: m, history: HistoryModel(journal: nil) { _ in },
                                        recordings: RecordingsModel()).frame(width: size.width, height: size.height))
            }
        }
        return [
            history("n-verlauf-neu-erkennen", "Zeile gewählt: Aktion Mit ElevenLabs neu erkennen in der Leiste, eine "
                    + "Zeile schon neu erkannt, eine läuft", key: true) { ($0.selection, $0.busy) = (["1"], ["3"]) },
            history("n-verlauf-ohne-schluessel", "Ohne Schlüssel: die Aktion ist ausgegraut", key: false) {
                $0.selection = ["1"]
            },
            window("n-schluessel-id", "Schlüssel-ID eingefügt: nicht gespeichert, Hinweis neben dem Feld") {
                ($0.ui.hasKey, $0.ui.keyWrong) = (false, [.elevenLabs])
            },
            window("n-schluessel-openrouter", "Falscher Text im OpenRouter-Feld: Hinweis neben dem Feld") {
                ($0.ui.openRouterKey, $0.ui.keyWrong) = (false, [.openRouter])
            },
            Step(id: "n-rueckfrage", caption: "Mehr als 10 Diktate oder 30 Minuten: Rückfrage mit Anzahl und Minuten") {
                AnyView(DeleteConfirm(count: 14, onDelete: {}, onCancel: {},
                                      renew: HistoryModel.renewQuestion(count: 14, seconds: 2_340)))
            },
        ]
    }

    @Test func renewPictures() throws {
        let out = PreviewRenderTests.out.appending(path: "neu-erkennen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for step in renewSteps {
            for dark in [false, true] {
                guard let side = step.side else { continue }
                let host = NSHostingView(rootView: side().environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                      backing: .buffered, defer: false)
                (window.appearance, window.contentView) = (host.appearance, host)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: out.appending(path: "\(step.id)-\(dark ? "dunkel" : "hell").png"))
            }
        }
    }
}
