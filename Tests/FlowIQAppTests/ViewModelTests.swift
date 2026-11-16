// P7: the state logic of the views as plain models (menu entries, pill states, alert texts, settings bindings).
// Nothing here starts the app, opens a window or asks for a permission.
import AppKit
import FlowIQCloud
import FlowIQCore
import FlowIQDevices
import FlowIQRecording
import Foundation
import Testing
@testable import FlowIQ

private func state(_ profile: Profile = .production, key: Bool = false) -> MenuState {
    MenuState(profile: profile, settings: .defaults(for: profile), hasKey: key)
}

private func items(_ s: MenuState) -> [MenuEntry] { StatusMenuModel.entries(s).filter { $0.kind == .item } }

@Suite struct MenuModelTests {
    @Test func idleHasFifteenCommandsAndTwoHeads() {
        let all = StatusMenuModel.entries(MenuState(profile: .production, settings: .defaults(for: .production),
            recent: [RecentTranscript(url: URL(filePath: "/tmp/a.md"), kind: .call, date: .now),
                     RecentTranscript(url: URL(filePath: "/tmp/b.md"), kind: .room, date: .now)]))
        #expect(all.filter { $0.kind == .item }.count == 14)
        #expect(all.filter { $0.kind == .header }.map(\.title) == ["Aufnehmen", "Zuletzt"])
        #expect(all.last?.action == .quit)
    }

    @Test func standardIdsKeepCorrectionAndHaveNoRawVersion() {
        let ids = StatusMenuModel.standardItemIDs
        for id in ["callGerman", "callEnglish", "roomGerman", "roomEnglish", "insertLast", "correctLastDictation",
                   "microphone", "liveAndPost", "allTranscripts", "suggestions", "settings", "quit"] {
            #expect(ids.contains(id), "\(id)")
        }
        #expect(!ids.contains("insertRawVersion"))
    }

    @Test func runningCallShowsHeadAndStopAndHidesItsStarts() {
        var s = state(key: true)
        s.running = [Running(kind: .call, language: .de, started: s.now.addingTimeInterval(-61))]
        let ids = items(s).map(\.id)
        #expect(!ids.contains("callGerman") && !ids.contains("callEnglish"))
        #expect(ids.contains("roomGerman") && ids.contains("callStop") && ids.contains("callShow"))
        let head = StatusMenuModel.entries(s).first { $0.id == "callRunning" }
        #expect(head?.title == "Call läuft · Deutsch" && head?.detail == "01:01")
        #expect(items(s).first { $0.id == "callStop" }?.action == .stop(.call))
    }

    @Test func liveSwitchWithoutKeyLeadsToTheKeyField() {
        var s = state()
        s.running = [Running(kind: .room, language: .en, started: .now)]
        #expect(items(s).first { $0.id == "roomLive" }?.action == .keyField)
    }

    @Test func withoutKeyNoCloudRowIsChecked() {
        let rows = StatusMenuModel.cloud(state())  // production defaults want the after-run, the key is missing
        #expect(rows.filter(\.checked).isEmpty)
        #expect(rows.filter { $0.kind == .item }.allSatisfy { $0.action == .keyField })
        let keyed = StatusMenuModel.cloud(state(key: true))
        #expect(keyed.first { $0.id == "post-dictation" }?.checked == true)
        #expect(keyed.first { $0.id == "post-call" }?.action == .post(.call))
    }

    @Test func alertsComeFirstWithTheirNextStep() {
        var s = state()
        s.alerts = [.permission("Eingabeüberwachung"), .micSilent]
        let all = StatusMenuModel.entries(s)
        #expect(all[0].kind == .alert && all[0].title == "Eingabeüberwachung fehlt" && all[0].action == .setup)
        #expect(all[1].submenu?.first?.title == "Automatisch")
        #expect(all[2].kind == .separator)
    }

    @Test func developmentAddsTheSelfTest() {
        #expect(items(state(.development)).contains { $0.action == .selfTest })
        #expect(!items(state()).contains { $0.action == .selfTest })
        #expect(items(state(.development)).last?.title == "FlowIQ Dev beenden …")
    }

    @Test func monthLineAndMeter() {
        var s = state(key: true)
        (s.cloudSeconds, s.limitMinutes) = (192 * 60, 600)
        #expect(StatusMenuModel.cloud(s).contains { $0.title.hasSuffix(": 3 h 12 min von 10 h") })
        // TEST-FIX 16.11.2026: Pegel aus der Menüzeile genommen, seine Zeichen fehlten in der Menüschrift (Kästchen)
        s.running = [Running(kind: .call, language: .de, started: .now, levels: [0.4, 0.2])]
        #expect(StatusMenuModel.entries(s).first { $0.id == "callFacts" }.map { $0.detail == nil } == true)
        #expect(Duration.seconds(3723).clock == "1:02:03" && Duration.seconds(360).hoursAndMinutes == "6 min")
    }
}

@Suite struct AlertTests {
    @Test func everyStateHasTextAndStep() {
        let cases: [(AppAlert, String, MenuAction?)] = [
            (.micSilent, "Mikrofon liefert keinen Ton", nil), (.permission("Mikrofon"), "Mikrofon fehlt", .setup),
            (.networkDown, "Netz weg, Apple schreibt weiter", .reconnect),
            (.limitReached(600), "Monatsgrenze 10 h erreicht, lokal weiter", .settings),
            (.keyRejected, "ElevenLabs-Schlüssel fehlt oder abgelehnt", .keyField),
            (.postWaiting(2), "Genauere Fassung wartet (2)", .retryPost),
            (.notInserted, "Kein Textfeld, Diktat liegt bereit", .insertLast),
            (.folderMissing, "Ablageordner fehlt, Aufnahme liegt sicher in FlowIQ", .chooseFolder),
        ]
        for (alert, text, action) in cases {
            #expect(alert.text == text)
            #expect(alert.step.action == action)
            #expect(!alert.step.title.isEmpty)
        }
    }
}

// TEST-FIX 16.11.2026 (Pille nach local/design/pille-neu.html): the tests of tiles, signs, cards and the
// question at the pill are replaced by the tests of the approved template; the key decision test stays as it was.
@MainActor @Suite struct PillSceneTests {
    typealias P = FlowIQTheme.Pill
    static let states = PillSheetTests.states.map(\.1)
    private func frame(_ s: PillScene, _ id: String) -> CGRect? { s.elements.first { $0.id == id }?.frame }

    @Test func theDictationPillIsThereInEveryState() {
        for s in Self.states { #expect(s.elements.filter { $0.id == "dictation" }.count == 1) }
        for state in [PillState.hidden, .dictating, .notInserted, .failed] {  // no mark for a failure, it stays a pill
            #expect(PillScene(dictation: state).elements.map(\.id) == ["dictation"])
        }
    }

    @Test func everyPillIsSixWideAndTheDictationPillOnly22Or44High() {
        for s in Self.states {
            for e in s.elements where ["dictation", "call", "room"].contains(e.id) {
                #expect(e.frame.width == 6 && e.frame.minX == 10)
            }
            let d = frame(s, "dictation")
            #expect(d?.height == (s.dictation == .dictating ? 44 : 22) && d?.midY == PillScene.middle)
            #expect(frame(s, "call")?.height ?? 18 == 18 && frame(s, "room")?.height ?? 18 == 18)
        }
        #expect(PillScene().elements.first?.look == .outline)
        #expect(PillScene(dictation: .dictating).elements.first?.look == .fill(.dictation))
    }

    @Test func callAndRoomKeepTheirPlacesInEveryState() {  // AppKit counts upwards: the call is the upper one
        let call = PillScene.slot("call"), room = PillScene.slot("room"), middle = PillScene.middle
        #expect(call.minY == middle + 22 + 3 && room.maxY == middle - 22 - 3)
        for s in Self.states {
            #expect(frame(s, "call") ?? call == call && frame(s, "room") ?? room == room)
            for (ring, slot) in [("call-ring", call), ("room-ring", room)] {
                guard let f = frame(s, ring) else { continue }
                #expect(f.size == CGSize(width: 12, height: 12) && f.midX == slot.midX && f.midY == slot.midY)
            }
        }
    }

    @Test func nothingButPillsDotEnglishAndRings() {
        let allowed: Set = ["dictation", "lock", "call", "room", "call-en", "room-en", "call-ring", "room-ring", "pen"]
        let area = CGRect(origin: .zero, size: P.canvas)
        for s in Self.states {
            #expect(Set(s.elements.map(\.id)).isSubset(of: allowed))
            #expect(s.elements.allSatisfy { area.contains($0.frame.insetBy(dx: -P.rim, dy: -P.rim)) })
            let beside = { (id: String) in id.hasSuffix("-en") || id == "pen" }
            #expect(s.elements.allSatisfy { PillScene.reach.contains($0.frame) || beside($0.id) })
        }
        let lock = frame(PillScene(dictation: .dictating, locked: true), "lock")
        #expect(lock?.size == CGSize(width: 4, height: 4) && lock?.midX == 13 && lock?.midY == PillScene.middle)
        #expect(frame(PillScene(locked: true), "lock") == nil)  // only on the red pill
        let pen = frame(PillScene(importing: 0.5), "pen")
        #expect(pen?.midX == 10 + 6 + 11 && pen?.midY == PillScene.middle && pen?.width == 12)
        let tag = frame(PillScene(call: .init(english: true), english: ["call"]), "call-en")
        #expect(tag?.minX == 10 + 6 + 5 && tag?.height == 16 && tag?.midY == PillScene.slot("call").midY)
    }

    @Test func englishShowsOnlyAfterAnEnglishStartAndIsGoneAfterFiveSeconds() {
        let view = PillView(show: false), shown = { view.scene.elements.contains { $0.id.hasSuffix("-en") } }
        view.update(animated: false) { ($0.call, $0.dictation) = (.init(), .dictating) }
        #expect(!shown())  // German: no text at the pill at all
        view.update(animated: false) { $0.room = .init(english: true) }
        #expect(view.scene.elements.filter { $0.id.hasSuffix("-en") }.map(\.id) == ["room-en"] && P.englishHold == 5)
        view.update(animated: false) { $0.room = .init(english: true, problem: true) }  // later looks never restart it
        view.fire("en-room")  // what the timer does after `englishHold`
        #expect(!shown())
        view.update(animated: false) { $0.room = .init(english: true) }
        #expect(!shown())
        view.update(animated: false) { $0.call = nil }
        view.update(animated: false) { $0.call = .init(english: true) }
        #expect(shown())
        view.update(animated: false) { $0.call = nil }  // the stop takes it along
        #expect(!shown() && view.scene.english.isEmpty)
    }

    @Test func aProblemTurnsOnlyItsOwnPillOrange() {
        var ui = AppModel.Shown()
        ui.running = [Running(kind: .call, language: .de, started: .now), Running(kind: .room, language: .de,
                                                                                 started: .now)]
        let looks = { (ui: AppModel.Shown) -> [String: PillScene.Element.Look] in
            var s = PillScene(dictation: .dictating)
            AppModel.show(ui, in: &s)
            return Dictionary(uniqueKeysWithValues: s.elements.map { ($0.id, $0.look) })
        }
        #expect(looks(ui) == ["dictation": .fill(.dictation), "call": .fill(.call), "room": .fill(.room)])
        ui.down = [.desktop]  // the other side of the call is missing
        #expect(looks(ui) == ["dictation": .fill(.dictation), "call": .fill(.warning), "room": .fill(.room)])
        #expect(AppModel.alerts(ui, silent: false, limit: 0).contains(.noDesktop))  // the reason is in the menu
        (ui.down, ui.running[1].silent) = ([], true)
        #expect(looks(ui) == ["dictation": .fill(.dictation), "call": .fill(.call), "room": .fill(.warning)])
        (ui.running[1].silent, ui.troubles) = (false, [.call: .modelMissing(.en)])
        #expect(looks(ui)["call"] == .fill(.warning) && looks(ui)["room"] == .fill(.room))
        var s = PillScene()
        AppModel.show(ui, in: &s, except: [.call])  // a call being stopped does not come back
        #expect(s.call == nil && s.room != nil)
    }

    @Test func theRingAfterAStopOnlyRisesAndIsFullOnlyWhenSaved() {
        var last = 0.0
        for t in stride(from: 0.0, through: 7200, by: 0.5) {
            let now = PillScene.estimate(after: t, recorded: 3600)
            #expect(now >= last && now <= P.ringCap && now < 1)
            last = now
        }
        let view = PillView(show: false), start = Date(timeIntervalSinceReferenceDate: 0)
        view.update(animated: false) { $0.call = .init() }
        view.update(animated: false) { $0.call = nil }
        view.saving(.call, recorded: 600, now: start)
        var shares: [Double] = []
        for t in [1.0, 5, 30, 120, 3600] {
            if t == 30 { view.saving(.call, recorded: 5, now: start.addingTimeInterval(t)) }  // a second stop
            view.tick(start.addingTimeInterval(t))
            shares.append(view.scene.saving["call"] ?? -1)
        }
        #expect(shares == shares.sorted() && shares[0] > 0 && shares.allSatisfy { $0 < 1 })
        #expect(view.scene.elements.map(\.id) == ["dictation", "call-ring"])
        view.saved(.call)
        #expect(view.scene.saving["call"] == 1)
        view.fire("ring-call")  // full for a moment, then gone
        #expect(view.scene.saving.isEmpty && view.scene.elements.map(\.id) == ["dictation"])
    }

    @Test func thePenRingShowsTheRealShareAndIsFullOnlyAtTheEnd() {
        let view = PillView(show: false)
        var shares: [Double] = []
        for p in [ImportProgress.copying(0), .copying(0.4), .copying(0.2), .copying(1), .transcribing] {
            view.importing(p)
            shares.append(view.scene.importing ?? -1)
        }
        #expect(shares == shares.sorted() && shares[1] == 0.4 * P.ringCap && shares.allSatisfy { $0 >= 0 && $0 < 1 })
        view.importing(.hidden)
        #expect(view.scene.importing == 1)
        view.importing(.copying(0.1))  // the next import starts from the beginning
        #expect(view.scene.importing == 0.1 * P.ringCap)
        view.importing(.failed(.copy))  // the reason is in the devices list
        #expect(view.scene.importing == nil)
        view.importing(.hidden)
        #expect(view.scene.importing == nil)
    }

    @Test func aBounceIsNoSecondPress() {  // review V5, V6
        #expect(PillScene(pending: ["call"]).elements.map(\.id) == ["dictation", "call"])  // the pill shows at once
        let t = Date()
        #expect(AppModel.decide(running: false, startedAt: nil, now: t) == .start)
        #expect(AppModel.decide(running: true, startedAt: nil, now: t) == .stop)
        #expect(AppModel.decide(running: false, startedAt: t, now: t.addingTimeInterval(0.05)) == .ignored)
        #expect(AppModel.decide(running: false, startedAt: t, now: t.addingTimeInterval(0.4)) == .stop)
    }

    @Test func theSpringOvershootsALittleAndSettlesInAboutSixTenths() {
        let m = FlowIQTheme.PillMotion.self, zeta = m.damping / (2 * m.stiffness.squareRoot())
        #expect(abs(zeta - 0.62) < 0.01 && m.color == 0.3 && m.fade == 0.2 && m.start == 0.5)
        let peak = stride(from: 0.0, through: 1, by: 0.005).map(m.progress).max() ?? 0
        #expect(m.progress(0) == 0 && peak > 1.03 && peak < 1.12)
        #expect(stride(from: 0.6, through: 1.5, by: 0.01).allSatisfy { abs(m.progress($0) - 1) < 0.01 })
    }
}

@MainActor @Suite struct SettingsBindingTests {
    @Test func neutralStartPlaceAndFieldsInTheSettingsFile() throws {
        var s = FlowIQCore.Settings.defaults(for: .production)
        #expect(s.folder(.production) == URL.documentsDirectory.appending(path: "FlowIQ", directoryHint: .isDirectory))
        #expect(s.cloudLimitMinutes == nil && s.keepDictationInClipboard)
        #expect(s.folder(.development).path.hasPrefix(Paths(profile: .development).support.path))
        (s.transcriptFolder, s.cloudLimitMinutes) = ("/tmp/flowiq-ablage", 600)
        let back = try JSONDecoder().decode(FlowIQCore.Settings.self, from: JSONEncoder().encode(s))
        #expect(back.folder(.production).path == "/tmp/flowiq-ablage" && back.cloudLimitMinutes == 600)
        #expect(back.locations(Paths(profile: .production)).archiveAudio.lastPathComponent == "audio")
    }

    @Test func withoutKeyEveryCloudSwitchIsOffAndCannotBeTurnedOn() throws {
        var s = FlowIQCore.Settings.defaults(for: .production)
        for m in RecordingMode.allCases {
            #expect(s.effective(m, hasKey: false).post == .off && s.effective(m, hasKey: false).live == .appleLocal)
        }
        #expect(throws: ModeChoiceError.keyMissing) { try s.set(.call, live: .elevenLabsRealtime, hasKey: false) }
        try s.set(.call, live: .elevenLabsRealtime, hasKey: true)
        #expect(s.effective(.call, hasKey: true).live == .elevenLabsRealtime)
        #expect(throws: ModeChoiceError.notOffered) { try s.set(.dictation, live: .elevenLabsRealtime, hasKey: true) }
    }

    @Test func recentTranscriptsFromFileNames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "flowiq-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record(error) } }
        for n in ["2026-11-14-1605-raum.md", "2026-11-15-1130-call.md", "notiz.md", "2026-11-15-1200-call.txt"] {
            FileManager.default.createFile(atPath: dir.appending(path: n).path, contents: Data())
        }
        let recent = AppModel.recent(in: dir)
        #expect(recent.map(\.kind) == [.call, .room])
        #expect(Calendar.current.component(.hour, from: recent[0].date) == 11)
    }
}

/// 16.11.: "die Pillen fliegen einfach links aus dem Bildschirm raus". For every transition between the
/// template's states the real view is driven with animation: no frame leaves the window, nothing is animated in its
/// position, every layer that stays keeps its center, sizes change on the spring, colors over 0.3 s.
// TEST-FIX 16.11.2026 (Pille nach pille-neu.html): walks the new states; no element may move at all any more.
@MainActor @Suite struct PillMotionTests {
    private func check(_ a: PillScene, _ b: PillScene) -> [String] {
        var problems: [String] = []
        let view = PillView(show: false)
        view.show(a)
        let before = Dictionary(uniqueKeysWithValues: a.elements.compactMap { e in
            view.layer(e.id).map { (e.id, $0) }
        })
        let centers = before.mapValues(\.position)
        view.update(animated: true) { $0 = b }
        view.update(animated: true) { $0.english = b.english }
        let window = CGRect(origin: .zero, size: FlowIQTheme.Pill.canvas)
        for layer in view.panel.contentView?.layer?.sublayers ?? [] {
            if !window.contains(layer.frame) { problems.append("Rahmen außerhalb") }
            let keys = (layer.animationKeys() ?? []).compactMap { (layer.animation(forKey: $0) as? CAPropertyAnimation)?
                .keyPath }
            if keys.contains(where: { $0.hasPrefix("position") || $0.hasPrefix("frame") }) { problems.append("fliegt") }
        }
        for e in b.elements {
            guard let layer = view.layer(e.id) else { problems.append("\(e.id) fehlt"); continue }
            if let old = before[e.id], old !== layer { problems.append("\(e.id): zweite Form") }
            if let c = centers[e.id], c != layer.position { problems.append("\(e.id) rückt") }
            if e.id == "dictation", a.dictation != b.dictation, a.dictation == .dictating || b.dictation == .dictating {
                let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let spring = layer.animation(forKey: "bounds") is CASpringAnimation
                if !reduced && !spring { problems.append("keine Feder") }
                if (layer.animation(forKey: "backgroundColor") as? CABasicAnimation)?.duration != 0.3 {
                    problems.append("Farbe nicht 0,3 s")
                }
            }
        }
        return problems
    }
    @Test func everyTransitionStaysInPlace() {
        let all = PillSheetTests.states.map(\.1), rest = PillScene()
        var failed: [String] = []
        for (n, s) in all.enumerated() {
            for (a, b) in [(rest, s), (s, rest), (s, all[(n + 1) % all.count])] {
                let problems = check(a, b)
                if !problems.isEmpty { failed.append("\(n): \(Set(problems).sorted())") }
            }
        }
        #expect(failed.isEmpty, "\(failed.prefix(5))")
    }

    /// 16.11.: the growth is one layer changing size and color, never a second shape over the first.
    @Test func theDictationPillIsOneLayerThroughTheGrowth() {
        let view = PillView(show: false), rest = view.layer("dictation")
        #expect(rest?.frame == CGRect(x: 10, y: PillScene.middle - 11, width: 6, height: 22))
        view.update(animated: false) { $0.dictation = .dictating }
        #expect(rest != nil && view.layer("dictation") === rest)
        #expect(rest?.frame == CGRect(x: 10, y: PillScene.middle - 22, width: 6, height: 44) && rest?.cornerRadius == 3)
        let rim = rest?.sublayers?.first  // the fine rim lies 1 pt outside the fill, 30 % ink or 28 % white
        #expect(rim?.frame == CGRect(x: -4, y: -23, width: 8, height: 46) && rim?.borderWidth == 1)
        #expect(rim?.cornerRadius == 4 && [0.3, 0.28].contains { abs($0 - (rim?.borderColor?.alpha ?? 0)) < 0.01 })
        view.update(animated: false) { $0.dictation = .hidden }
        #expect(view.layer("dictation") === rest && rest?.frame.height == 22)
        #expect(rim?.borderColor?.alpha == 0 && rest?.borderWidth == 1 && rest?.backgroundColor?.alpha == 0)  // outline
        view.update(animated: false) { $0.call = .init(english: true) }
        let texts = (view.layer("call-en")?.sublayers ?? []).compactMap { ($0 as? CATextLayer)?.string as? String }
        #expect(texts == ["EN"] && view.layer("call")?.sublayers?.contains { $0 is CATextLayer } == false)
        #expect(view.panel.contentView?.layer?.sublayers?.count == 3)  // dictation, call, "EN": nothing else
    }

    @Test func aClickOnTheColumnOpensTheMenuAndTheCanvasStaysSmall() {
        let reach = PillScene.reach, p = FlowIQTheme.Pill.self
        #expect(reach.contains(PillScene.slot("call")) && reach.contains(PillScene.slot("room")) && reach.minX == 0)
        #expect(reach.contains(CGPoint(x: PillScene.column, y: PillScene.middle)))
        #expect(!reach.contains(CGPoint(x: p.edgeInset + p.width + p.tagGap + 4, y: PillScene.slot("call").midY)))
        #expect(PillView(show: false).panel.frame.size == p.canvas && p.canvas.width <= 60)
    }
}

/// The log said `permission` and the menu stayed silent while idle (16.11.): screen recording is a missing
/// permission like the others, said once, also during a call.
@Suite struct ScreenPermissionTests {
    @Test func missingScreenRecordingIsAWarningAlsoWhileIdleAndOnlyOnce() {
        #expect(PermissionState(granted: [.microphone, .accessibility, .inputMonitoring]).missing == [.screenRecording])
        var ui = AppModel.Shown()
        (ui.tapRunning, ui.missing, ui.screenGranted) = (true, [.screenRecording], false)
        #expect(AppModel.alerts(ui, silent: false, limit: 0) == [.permission("Bildschirmaufnahme")])
        ui.running = [Running(kind: .call, language: .de, started: .now)]
        #expect(AppModel.alerts(ui, silent: false, limit: 0) == [.permission("Bildschirmaufnahme")])
    }
}
