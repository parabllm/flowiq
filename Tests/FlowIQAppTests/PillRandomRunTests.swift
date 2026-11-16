// The pill's state machine under a fixed random run (review 16.11.: 40,000 steps found failures that every
// hand-picked case missed). Real types: AppModel.settle and AppModel.show feed a real PillView.
// TEST-FIX 16.11.2026 (Pille nach local/design/pille-neu.html): the invariants are those of the approved
// template now (always a dictation pill, fixed places and sizes, orange only with a reason in the menu, "EN" only
// for an English recording, rings only rise); the question at the pill and the headset card are gone with their
// tests, the stop without a question has one instead.
import AppKit
import Foundation
import Testing
@testable import FlowIQ

@MainActor @Suite struct PillRandomRunTests {
    /// A small fixed generator, so a failure always comes back with the same steps.
    struct Seeded { var state: UInt64; mutating func next(_ n: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(n))
    } }
    /// The invariants after every step; returns what broke.
    private func broken(_ ui: AppModel.Shown, _ s: PillScene, dictating: Bool) -> [String] {
        var out: [String] = []
        let p = FlowIQTheme.Pill.self, drawn = s.elements, area = CGRect(origin: .zero, size: p.canvas)
        let find = { (id: String) in drawn.first { $0.id == id } }
        let pills = Set(drawn.filter { $0.id == "call" || $0.id == "room" }.map(\.id))
        if pills != Set(ui.running.map(\.kind.pillID)) { out.append("a: Pille ohne Aufnahme oder umgekehrt") }
        let middle = CGRect(x: p.edgeInset, y: PillScene.middle - (dictating ? p.active : p.idle) / 2, width: p.width,
                            height: dictating ? p.active : p.idle)
        if drawn.filter({ $0.id == "dictation" }).map(\.frame) != [middle] { out.append("b: Diktat-Pille falsch") }
        if find("dictation")?.look != (dictating ? .fill(.dictation) : .outline) { out.append("b: Diktat-Farbe") }
        for id in pills where find(id)?.frame != PillScene.slot(id) { out.append("c: \(id) nicht an seinem Platz") }
        if !drawn.allSatisfy({ area.contains($0.frame) }) { out.append("d: außerhalb") }
        if ui.running.isEmpty && !ui.down.isEmpty { out.append("e: Warnung bleibt") }
        let alerts = AppModel.alerts(ui, silent: AppModel.silent(ui), limit: 0)
        let reasons = alerts.filter { $0 != .tapStopped && $0 != .panottiKeys }
        let orange = drawn.contains { $0.look == .fill(.warning) }
        if orange && reasons.isEmpty { out.append("f: Orange ohne Grund") }
        for r in ui.running {
            let id = r.kind.pillID
            if find(id + "-en") != nil && r.language != .en { out.append("g: EN ohne Englisch") }
            if find(id + "-ring") != nil { out.append("h: Kreis über laufender Aufnahme") }
        }
        if drawn.contains(where: { $0.id.hasSuffix("-en") && !pills.contains(String($0.id.dropLast(3))) }) {
            out.append("g: EN ohne Pille")
        }
        return out
    }

    @Test func fortyThousandStepsKeepEveryInvariant() {
        var rng = Seeded(state: 20_261_116), ui = AppModel.Shown(), dictating = false
        (ui.tapRunning, ui.mics) = (true, ["builtin": "MacBook-Mikrofon", "airpods": "AirPods"])
        let view = PillView(show: false), start = Date(timeIntervalSinceReferenceDate: 0)
        var failures: [String] = [], rings: [String: Double] = [:], open: Set<String> = []  // stops not yet saved
        for step in 0..<40_000 {
            let kind: SessionKind = rng.next(2) == 0 ? .call : .room
            let index = ui.running.firstIndex { $0.kind == kind }
            switch rng.next(13) {
            case 0, 1:
                if index == nil {
                    var r = Running(kind: kind, language: rng.next(2) == 0 ? .de : .en, started: .now)
                    r.device = rng.next(2) == 0 ? "builtin" : "airpods"
                    ui.running.append(r)
                }
            case 2:
                if let index {
                    ui.running.remove(at: index)
                    if open.insert(kind.pillID).inserted { rings[kind.pillID] = nil }  // a new ring starts empty
                    view.saving(kind, recorded: Double(rng.next(3600)), now: start.addingTimeInterval(Double(step)))
                }
            case 3: ui.down.insert(.microphone)
            case 4: ui.down.remove(.microphone)
            case 5: ui.down.insert(.desktop)
            case 6: if let index { ui.running[index].silent.toggle() }
            case 7: ui.keysShared.toggle()
            case 8: ui.tapRunning.toggle()
            case 9: dictating.toggle()
            case 10:
                view.saved(kind)
                open.remove(kind.pillID)
            case 11: if let index { ui.running[index].fallback = rng.next(2) == 0 ? .networkError : .limit }
            default: view.fire(rng.next(2) == 0 ? "en-call" : "en-room")  // the 5 s are over
            }
            AppModel.settle(&ui)
            let shown = ui
            view.update(animated: false) { s in
                AppModel.show(shown, in: &s)
                s.dictation = dictating ? .dictating : .hidden
            }
            view.tick(start.addingTimeInterval(Double(step) + 0.5))
            var problems = broken(ui, view.scene, dictating: dictating)
            for (tag, share) in view.scene.saving {
                if share < rings[tag] ?? 0 { problems.append("i: Kreis läuft zurück") }
                if open.contains(tag) && share > FlowIQTheme.Pill.ringCap { problems.append("i: voll vor dem Ende") }
            }
            rings = view.scene.saving
            if !problems.isEmpty { failures.append("Schritt \(step): \(problems)") }
            if failures.count > 3 { break }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    /// V1: a microphone that failed in one room must not warn in the next.
    @Test func aFailureEndsWithItsSession() {
        var ui = AppModel.Shown()
        ui.running = [Running(kind: .room, language: .de, started: .now)]
        ui.down = [.microphone]
        AppModel.settle(&ui)
        var s = PillScene()
        AppModel.show(ui, in: &s)
        #expect(s.room?.problem == true)
        ui.running = []
        AppModel.settle(&ui)
        ui.running = [Running(kind: .room, language: .de, started: .now)]
        AppModel.show(ui, in: &s)
        #expect(s.room?.problem == false && ui.down.isEmpty)
    }

    /// The stop needs no question any more: the ring takes the pill's place at once and goes when it is saved.
    @Test func aStopPutsTheRingInThePillsPlaceWithoutAQuestion() async {
        let view = PillView(show: false)
        let m = AppModel(profile: .production, settings: .defaults(for: .production), pill: view)
        m.ui.running = [Running(kind: .room, language: .en, started: .now.addingTimeInterval(-90))]
        view.update(animated: false) { AppModel.show(m.ui, in: &$0) }
        #expect(view.scene.elements.map(\.id) == ["dictation", "room", "room-en"])
        await m.stop(.room)
        #expect(m.ui.running.isEmpty && m.parts.stopping.isEmpty && view.scene.room == nil)
        // saved: the ring is full for 0.4 s, then gone (the look at the system in `refresh` may take longer)
        let ids = view.scene.elements.map(\.id)
        #expect(ids == ["dictation", "room-ring"] && view.scene.saving == ["room": 1] || ids == ["dictation"])
        view.fire("ring-room")
        #expect(view.scene.elements.map(\.id) == ["dictation"])
    }

    /// A look at the recorder while the stop still runs must not bring the pill (or "EN") back.
    @Test func aRecordingBeingStoppedStaysARing() {
        let view = PillView(show: false)
        var ui = AppModel.Shown()
        ui.running = [Running(kind: .call, language: .en, started: .now)]
        view.update(animated: false) { AppModel.show(ui, in: &$0) }
        view.fire("en-call")
        view.update(animated: false) { $0.call = nil }
        view.saving(.call, recorded: 60)
        view.update(animated: false) { AppModel.show(ui, in: &$0, except: [.call]) }  // the recorder still lists it
        #expect(view.scene.elements.map(\.id) == ["dictation", "call-ring"])
    }
}
