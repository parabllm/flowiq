// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 3, display (A.12, R-051, R-072, R-081, M.6, review M5): for every case of the first two groups the state the user
// sees: the warning line of the menu with its next step, the marks at the pill, the rows of the menu while
// recordings run. Everything here is pure (AppModel.alerts, StatusMenuModel, PillScene), no window is opened.
// Where the case has no visible state in the app yet, README.md lists it under "Anzeige fehlt".
import Foundation
import Testing
@testable import FlowIQ  // ASSUMPTION: AppModel, StatusMenuModel, PillScene need the app module in this file too
@testable import FlowIQCore
@testable import FlowIQDevices
@testable import FlowIQInput
@testable import FlowIQRecording
@testable import FlowIQSpeech
@testable import FlowIQStore

@Suite(.timeLimit(.minutes(2)))
struct AnzeigeTests {
    private static let started = Date(timeIntervalSince1970: 1_800_000_000)

    private static func running(_ kind: SessionKind, language: RecordingLanguage = .de,
                                _ edit: (inout Running) -> Void = { _ in }) -> Running {
        var r = Running(kind: kind, language: language, started: started)
        edit(&r)
        return r
    }

    // MARK: Warnzeile mit nächstem Schritt, je Fall

    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let edit: @Sendable (inout AppModel.Shown) -> Void
        let silent: Bool, limit: Int
        let alert: AppAlert
        let text: String
        let step: (title: String, action: MenuAction?)
        var description: String { name }
    }

    /// One row per failure of group 2: what the user reads and what the button does.
    static let cases: [Case] = [
        Case(name: "microphone right missing", edit: { $0.missing = [.microphone] }, silent: false, limit: 0,
             alert: .permission("Mikrofon"), text: "Mikrofon fehlt", step: ("Einrichten …", .setup)),
        Case(name: "desktop of a call not recorded",
             edit: { $0.running = [AnzeigeTests.running(.call)]; $0.down = [.desktop] }, silent: false, limit: 0,
             // TEST-FIX (Wortlaut laut Nutzerwunsch 16.11.2026)
             alert: .noDesktop, text: "Nur dein Mikrofon wird aufgenommen\nDer Ton der anderen im Call fehlt.",
             step: ("Bildschirmaufnahme erlauben …", .setup)),
        Case(name: "microphone down in a room",
             edit: { $0.running = [AnzeigeTests.running(.room)]; $0.down = [.microphone] }, silent: true, limit: 0,
             alert: .micSilent, text: "Mikrofon liefert keinen Ton", step: ("Wählen …", nil)),  // TEST-FIX (Wortlaut laut Nutzerwunsch 16.11.2026)
        Case(name: "network gone while the cloud writes",
             edit: { $0.running = [AnzeigeTests.running(.call) { $0.fallback = .networkError }] }, silent: false, limit: 0,
             alert: .networkDown, text: "Netz weg, Apple schreibt weiter", step: ("Erneut verbinden", .reconnect)),
        Case(name: "monthly limit reached",
             edit: { $0.running = [AnzeigeTests.running(.call) { $0.fallback = .limit }] }, silent: false, limit: 600,
             alert: .limitReached(600), text: "Monatsgrenze 10 h erreicht, lokal weiter", step: ("Grenze ändern …", .settings)),
        Case(name: "after-run waiting", edit: { $0.post = .waiting(count: 2) }, silent: false, limit: 0,
             alert: .postWaiting(2), text: "Genauere Fassung wartet (2)", step: ("Jetzt versuchen", .retryPost)),  // TEST-FIX (Wortlaut laut Nutzerwunsch 16.11.2026)
        Case(name: "after-run paused", edit: { $0.post = .paused(count: 1) }, silent: false, limit: 0,
             alert: .keyRejected, text: "ElevenLabs-Schlüssel fehlt oder abgelehnt", step: ("Schlüssel eintragen …", .keyField)),
        Case(name: "dictation without a text field", edit: { $0.notInserted = true }, silent: false, limit: 0,
             alert: .notInserted, text: "Kein Textfeld, Diktat liegt bereit", step: ("Einfügen ⌃⌘V", .insertLast)),
        Case(name: "archive folder missing", edit: { $0.folderOK = false }, silent: false, limit: 0,
             alert: .folderMissing, text: "Ablageordner fehlt, Aufnahme liegt sicher in FlowIQ", step: ("Ordner wählen …", .chooseFolder)),
        Case(name: "key tap stopped", edit: { $0.tapRunning = false }, silent: false, limit: 0,
             alert: .tapStopped, text: "Fn und Kurzbefehle reagieren nicht", step: ("Einrichten …", .setup)),
    ]

    /// The state computes to exactly this one line, with this text and this next step, and nothing else.
    @Test(arguments: cases)
    func everyCaseShowsItsOneWarningWithItsNextStep(_ c: Case) {
        let ui = Display.shown(c.edit)
        let alerts = Display.alerts(ui, silent: c.silent, limit: c.limit)
        #expect(alerts == [c.alert])
        #expect(c.alert.text == c.text)
        #expect(c.alert.step.title == c.step.title && c.alert.step.action == c.step.action)
    }

    /// In the menu the warning is the first line, with the step as its detail and the action behind it, then a separator.
    @Test(arguments: cases)
    func theMenuShowsTheWarningAtTheTopWithItsStep(_ c: Case) {
        let entries = Display.menu { $0.alerts = [c.alert] }
        let first = entries[0]
        #expect(first.kind == .alert && first.title == c.text)
        #expect(first.detail == c.step.title && first.action == c.step.action)
        #expect((first.submenu != nil) == c.alert.choosesMic, "only the silent microphone carries the microphone list")
        #expect(entries[1].kind == .separator)
    }

    /// The real state computes `silent` in `AppModel.refresh`: a source that is down in any track counts as a silent
    /// microphone. A desktop that is down is not a silent microphone: the call shows `noDesktop` and nothing else.
    /// ASSUMPTION: `Display.silent` copies that formula (refresh, "let silent = ..."); today it yields `micSilent` as
    /// well, so this test is expected red until the app tells the microphone from the desktop.
    @Test func aDesktopThatIsDownIsNotReportedAsASilentMicrophone() {
        let ui = Display.shown {
            $0.running = [Self.running(.call)]
            $0.down = [.desktop]
        }
        #expect(Display.alerts(ui, silent: Display.silent(ui)) == [.noDesktop])
    }

    /// Several at once: always in the same order, the user's own problem text first (review M5, N3).
    @Test func severalWarningsComeInAFixedOrder() {
        let ui = Display.shown {
            $0.problem = "Call nicht gestartet"
            $0.missing = [.microphone]
            $0.running = [Self.running(.call) { $0.fallback = .networkError }]
            $0.down = [.desktop]
            $0.post = .waiting(count: 1)
            $0.notInserted = true
            $0.folderOK = false
        }
        // TEST-FIX 16.11.2026 (Erwartung geändert, Nutzerwunsch: Dringendes zuerst): Ton verloren, dann Rechte, dann
        // Gescheitertes, dann Wartendes; innerhalb einer Stufe die alte Reihenfolge
        #expect(Display.alerts(ui, silent: true) == [.problem("Call nicht gestartet"), .noDesktop, .micSilent,
                                                      .permission("Mikrofon"), .networkDown, .folderMissing,
                                                      .postWaiting(1), .notInserted])
    }

    /// "Fehlertext mit nächstem Schritt" for every warning. ASSUMPTION: a `.problem` line (a start that failed for
    /// a reason the app cannot name, e.g. "Call nicht gestartet") also carries a step; today its step is empty, so
    /// this test is expected to stay red until the app names one (for example "Erneut versuchen").
    @Test func everyWarningNamesItsNextStep() {
        let all: [AppAlert] = [.micSilent, .permission("Mikrofon"), .networkDown, .limitReached(60), .keyRejected,
                               .postWaiting(1), .notInserted, .folderMissing, .noDesktop, .tapStopped,
                               .problem("Call nicht gestartet")]
        for alert in all { #expect(!alert.step.title.isEmpty, "\(alert) names no next step") }
    }

    // MARK: Menü bei laufenden Aufnahmen

    /// Call starten während Call läuft: the menu has no start row for the running kind (the second press is the
    /// stop), shows its rows, and keeps the other kind startable; with both running there is no start row at all.
    @Test func aRunningKindHasNoStartRowOnlyItsStop() {
        func starts(_ entries: [MenuEntry]) -> [SessionKind] {
            entries.compactMap { if case .start(let kind, _) = $0.action { kind } else { nil } }
        }
        let idle = Display.menu()
        #expect(starts(idle) == [.call, .call, .room, .room])

        let call = Display.menu { $0.running = [Self.running(.call)] }
        #expect(!starts(call).contains(.call) && starts(call).contains(.room))
        #expect(call.first { $0.id == "callRunning" }?.title == "Call läuft · Deutsch")
        #expect(call.first { $0.id == "callStop" }?.action == .stop(.call))
        #expect(call.contains { $0.id == "callShow" } && call.contains { $0.id == "callLive" })

        let both = Display.menu { $0.running = [Self.running(.call), Self.running(.room, language: .en)] }
        #expect(starts(both).isEmpty)
        #expect(both.first { $0.id == "roomRunning" }?.title == "Raum läuft · Englisch")
    }

    /// B.5, E6: room plus call on one microphone: both rows name the same device; a lost cloud shows "Rückfall
    /// lokal", a sending one "Cloud sendet".
    @Test func roomPlusCallNameOneDeviceAndTheCloudState() {
        let uid = Dev.airpods.uid
        let entries = Display.menu {
            $0.mics = [uid: "AirPods"]
            $0.running = [Self.running(.call) { $0.device = uid; $0.fallback = .networkError },
                          Self.running(.room) { $0.device = uid; $0.sending = true }]
        }
        let call = entries.first { $0.id == "callFacts" }?.title ?? ""
        let room = entries.first { $0.id == "roomFacts" }?.title ?? ""
        #expect(call.contains("AirPods") && room.contains("AirPods"))
        #expect(call.contains("Rückfall lokal") && !call.contains("Cloud sendet"))
        #expect(room.contains("Cloud sendet"))
    }

    // MARK: Pille

    private func looks(_ scene: PillScene) -> [PillScene.Element.Look] { scene.elements.map(\.look) }

    /// Room plus call: two recording pills (call above, room below) and the shared-microphone mark.
    // TEST-FIX 16.11.2026 (Nutzerwunsch: Pille nach local/design/pille-neu.html, keine Marken, Karten, Zeichen): the six
    // pill tests below keep their cases; what they expect at the pill is the approved template now. Each changed
    // line carries TEST-FIX; where a hint is gone without a line in the menu, the line says "Lücke" (reported).
    @Test func roomPlusCallShowTwoPillsAndTheSharedMicrophoneMark() throws {
        let scene = Display.scene(running: [Self.running(.call), Self.running(.room)])
        let call = try #require(scene.elements.first { $0.id == "call" })
        let room = try #require(scene.elements.first { $0.id == "room" })
        #expect(call.look == .fill(.call) && room.look == .fill(.room))  // TEST-FIX: Look heißt jetzt fill
        #expect(call.frame.minY > room.frame.minY)  // origin bottom left: the call is above
        #expect(scene.elements.map(\.id) == ["dictation", "call", "room"])  // TEST-FIX: no shared-microphone mark any more (Lücke: kein Menü-Hinweis "Mikrofon geteilt"), the dictation pill is always there
        #expect(Display.scene(running: [Self.running(.call)]).elements.map(\.id) == ["dictation", "call"])  // TEST-FIX: wie oben
        #expect(PillScene.reach.contains(call.frame) && PillScene.reach.contains(room.frame))  // TEST-FIX: a click anywhere on the column opens the menu, no pill has its own click
    }

    /// Diktat während Call or Raum: the red dictation pill beside the recording pill; locked adds the dot.
    @Test(arguments: [SessionKind.call, .room])
    func aDictationDuringARecordingShowsBothPills(_ kind: SessionKind) {
        var scene = Display.scene(running: [Self.running(kind)])
        scene.dictation = .dictating
        #expect(scene.elements.map(\.id).contains("dictation") && scene.elements.map(\.id).contains(kind == .call ? "call" : "room"))
        #expect(!scene.elements.map(\.id).contains("lock"))
        scene.locked = true
        #expect(scene.elements.map(\.id).contains("lock"))
    }

    /// A silent track (microphone down, no replacement) is an alarm mark at its pill; the desktop down is not.
    @Test func aSilentMicrophoneIsAnAlarmMarkAtItsPill() {
        let micDown = Display.scene(running: [Self.running(.room)], down: [.microphone])
        #expect(micDown.elements.first { $0.id == "room" }?.look == .fill(.warning))  // TEST-FIX: the room pill turns orange instead of the mark
        let metered = Display.scene(running: [Self.running(.call) { $0.silent = true }])
        #expect(metered.elements.first { $0.id == "call" }?.look == .fill(.warning))  // TEST-FIX: orange instead of the mark
        let desktopDown = Display.scene(running: [Self.running(.call)], down: [.desktop])
        #expect(looks(desktopDown).contains(.fill(.warning)))  // TEST-FIX (Erwartung geändert, Vorlage Zeile "Problem im Call"): the missing other side turns the call pill orange too; which problem it is says only the menu, see the cases above
        #expect(AppModel.alerts(Display.shown { ($0.running, $0.down) = ([Self.running(.call)], [.desktop]) }, silent: false, limit: 0) == [.noDesktop])  // TEST-FIX: the reason in the menu is the desktop, not a silent microphone
    }

    /// The language and the cloud state of a running recording are marks at its pill.
    @Test func englishAndTheLostCloudAreMarksAtThePill() {
        let started = Display.scene(running: [Self.running(.call, language: .en) { $0.fallback = .networkError }])  // TEST-FIX: nur umbenannt
        var scene = started  // TEST-FIX: "EN" is set by the view for 5 s after the start, here by hand
        scene.english = ["call"]  // TEST-FIX
        #expect(scene.call?.english == true && looks(scene).contains(.english(.call)) && looks(scene).contains(.fill(.warning)))  // TEST-FIX: "EN" beside the pill; the lost cloud turns it orange instead of the mark
    }

    /// A dictation that failed (microphone refused, recognizer failed) is an alarm mark; one that found no text
    /// field is the clipboard mark; the red pill is gone in both.
    @Test func aFailedOrNotInsertedDictationLeavesAMarkNotJustNothing() {
        var scene = PillScene()
        scene.dictation = .failed
        #expect(looks(scene) == [.outline])  // TEST-FIX (Erwartung geändert): no mark at the pill any more. Lücke: "Diktat fehlgeschlagen" hat keinen Menü-Hinweis
        scene.dictation = .notInserted
        #expect(looks(scene) == [.outline])  // TEST-FIX (Erwartung geändert): no clipboard mark; the menu says "Kein Textfeld, Diktat liegt bereit" (AppAlert.notInserted, cases above)
        scene.dictation = .hidden
        #expect(looks(scene) == [.outline])  // TEST-FIX: the dictation pill is always there
    }

    /// R-072: while the pen is imported a ring sits at the pill, a share while copying, a pulse while recognizing,
    /// also while a recording runs; it is gone when the import ends.
    @Test func theImportRingShowsAtThePillAlsoDuringARecording() {
        var scene = Display.scene(running: [Self.running(.room)])
        scene.importing = PillScene.ring(.copying(0.4), now: nil)  // TEST-FIX: the ring only rises, so it knows its share so far
        #expect(looks(scene).contains(.ring(.neutral, 0.4 * FlowIQTheme.Pill.ringCap)) && scene.elements.map(\.id).contains("room"))  // TEST-FIX: never full before the end (95 %)
        scene.importing = PillScene.ring(.transcribing, now: scene.importing)  // TEST-FIX
        #expect(looks(scene).contains(.ring(.neutral, 0.4 * FlowIQTheme.Pill.ringCap)))  // TEST-FIX: no pulse, no turning: the ring holds while recognizing
        scene.importing = PillScene.ring(.hidden, now: scene.importing)  // TEST-FIX
        #expect(looks(scene).contains(.ring(.neutral, 1)))  // TEST-FIX: full at the end for a moment, then the view takes it away (PillSceneTests)
        scene.importing = PillScene.ring(.hidden, now: nil)  // TEST-FIX: nothing ran
        #expect(!looks(scene).contains { if case .ring = $0 { true } else { false } })
    }

    // MARK: Datei und Liste

    /// Review M4: when live recognition is out, the live file says so in one visible line with the next step
    /// (the text comes after the stop); the contributions stay.
    @Test(arguments: [LiveTrouble.recognizerFailed, .modelMissing(.en)])
    func aFailedLiveRecognizerIsOneVisibleLineInTheFile(_ trouble: LiveTrouble) async throws {
        let rig = try PostRig.make(postEnabled: false)
        defer { rig.remove() }
        let live = try await rig.store.beginLive(kind: .call, startedAt: rig.clock.now, language: "en")  // ASSUMPTION: beginLive(kind:startedAt:language:)
        await live.note(seconds: 5, trouble.text)  // ASSUMPTION: LiveTranscript.note(seconds:_:) is what the router sink calls on a failure
        try await rig.aftercare.finish(live, durationSeconds: 60, rawAudio: try rig.makeRaw(.call, seconds: 60))
        let doc = try readDoc(live.url)
        #expect(doc.notes.count == 1)
        #expect(doc.notes.first?.contains("Text nach dem Stopp") == true)
        #expect(trouble.text.contains(trouble == .recognizerFailed ? "ausgefallen" : "Englisch"))
    }
}
