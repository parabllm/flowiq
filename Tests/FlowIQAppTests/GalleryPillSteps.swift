// Gallery flows A to D: the pill (owned by the pill agent; the frame is GalleryTests.swift).
// TEST-FIX 16.11.2026 (Pille nach local/design/pille-neu.html): no tiles, cards, hover or notices any more;
// the steps show the three narrow pills, "EN", orange for a problem and the ring after the stop.
import AppKit
import FlowIQCore
@testable import FlowIQDevices
import FlowIQRecording
import FlowIQStore
import Foundation
import SwiftUI
@testable import FlowIQ

extension GalleryTests {
    /// Flows A to D: the pill (owned by the pill agent).
    var pillFlows: [(String, [Step])] {
        let rest = PillScene(), active = PillScene(dictation: .dictating)
        let grow = [(rest, rest, 1.0), (active, rest, 0.1), (active, rest, 0.2), (active, rest, 0.3),
                    (active, rest, 0.6)]
        let release = [(active, active, 1.0), (rest, active, 0.1), (rest, active, 0.2), (rest, active, 0.3),
                       (rest, active, 0.6)]
        return [
            ("A Diktat", [
                step("a1-ruhe", "Ruhe: nur die dünne Diktat-Pille am Rand") { _ in },
                Step(id: "a2-fn-gedrueckt", caption: "Fn gedrückt: rot, wächst einmal auf 44 pt, 0, 100, 200, 300, "
                     + "600 ms", frames: grow),
                Step(id: "a3-gesperrt", caption: "Fn Fn: gesperrt, weißer Punkt in der Mitte",
                     pill: PillScene(dictation: .dictating, locked: true)),
                Step(id: "a4-losgelassen", caption: "Fn losgelassen: zurück auf 22 pt Umriss", frames: release),
                step("a5-kein-textfeld", "Kein Textfeld: an der Pille nichts, die Zeile steht im Menü") {
                    $0.ui.notInserted = true
                },
            ]),
            ("B Call", [
                step("b1-start", "Call startet auf Deutsch: Call-Pille oben") { $0.ui.running = [self.call()] },
                step("b2-englisch", "Call auf Englisch: \"EN\" für 5 s", pill: { $0.english = ["call"] }) {
                    $0.ui.running = [self.call(.en)]
                },
                step("b3-gegenseite-fehlt", "Ton der anderen fehlt: Call-Pille orange, Grund im Menü") { m in
                    m.ui.running = [self.call { $0.desktopSilent = true }]
                },
                step("b4-bildschirm-fehlt", "Bildschirmaufnahme fehlt: orange, Grund im Menü") { m in
                    m.ui.running = [self.call()]
                    m.ui.screenGranted = false
                },
                Step(id: "b5-stopp", caption: "Gestoppt: Kreis am Platz der Pille füllt sich bis gespeichert",
                     pill: PillScene(saving: ["call": 0.6])),
            ]),
            ("C Raum", [
                step("c1-start", "Raum: Raum-Pille unten") { $0.ui.running = [self.room()] },
                step("c2-kein-ton", "Kein Ton: Raum-Pille orange, \"Mikrofon wählen\" im Menü") {
                    $0.ui.running = [self.room { $0.silent = true }]
                },
                Step(id: "c3-stopp", caption: "Gestoppt: Kreis füllt sich", pill: PillScene(saving: ["room": 0.4])),
            ]),
            ("D Gleichzeitig", [
                step("d1-call-diktat", "Call plus Diktat: die Diktat-Pille bleibt in der Mitte",
                     pill: { $0.dictation = .dictating }) { $0.ui.running = [self.call()] },
                step("d2-raum-call", "Raum plus Call: beide an ihrem festen Platz") {
                    $0.ui.running = [self.call(), self.room()]
                },
                step("d3-alle-drei", "Call, Raum und Diktat zugleich", pill: { $0.dictation = .dictating }) {
                    $0.ui.running = [self.call(), self.room()]
                },
            ]),
        ]
    }
}
