// The hints the pill carried before it lost its text (16.11., Paket D): each one arises, says what is wrong
// in plain German, names its one step and goes away again. Pure model tests, no window, invented names only.
import AppKit
import FlowIQCore
import FlowIQDevices
import FlowIQInput
import FlowIQRecording
import Foundation
import Testing
@testable import FlowIQ

@MainActor @Suite struct MenuHintTests {
    private func model() -> AppModel {
        let m = AppModel(profile: .production, settings: .defaults(for: .production), pill: PillView(show: false))
        (m.ui.tapRunning, m.ui.mics) = (true, ["airpods": "AirPods Pro", "builtin": "MacBook-Mikrofon"])
        return m
    }
    private func running(_ kind: SessionKind, device: String = "builtin") -> Running {
        Running(kind: kind, language: .de, started: .now.addingTimeInterval(-761), device: device)
    }
    private func alerts(_ ui: AppModel.Shown) -> [AppAlert] {
        AppModel.alerts(ui, silent: AppModel.silent(ui), limit: 0)
    }
    private func entry(_ alert: AppAlert, _ edit: (inout MenuState) -> Void = { _ in }) -> MenuEntry {
        var s = MenuState(profile: .production, settings: .defaults(for: .production))
        s.alerts = [alert]
        edit(&s)
        return StatusMenuModel.entries(s)[0]
    }

    // 1: a failed dictation
    @Test func aFailedDictationOffersToRecognizeItAgain() async {
        let m = model()
        #expect(alerts(m.ui).isEmpty)
        m.ui.dictationFailed = true
        #expect(alerts(m.ui) == [.dictationFailed(audio: true)])
        let row = entry(.dictationFailed(audio: true))
        #expect(row.kind == .alert && row.title == "Diktat nicht erkannt, der Ton ist gesichert")
        #expect(row.detail == "Erneut erkennen" && row.action == .recognizeAgain && row.submenu == nil)
        m.ui.dictationFailed = nil
        #expect(alerts(m.ui).isEmpty)
    }
    @Test func withoutAudioTheFailedDictationLeadsToTheMicrophones() {
        let row = entry(.dictationFailed(audio: false)) { $0.mics = ["builtin": "MacBook-Mikrofon"] }
        #expect(row.title == "Diktat nicht aufgenommen, das Mikrofon war nicht erreichbar")
        #expect(row.detail == "Wählen …" && row.action == nil)
        #expect(row.submenu?.map(\.title) == ["Automatisch", "MacBook-Mikrofon"])
    }
    /// The pill's states drive it: failed sets the line; without a journal that still knows the failure, the next
    /// dictation's end takes it away; "Kein Textfeld" stays its own line.
    @Test func theFailureFollowsTheDictationStates() async {
        let m = model()
        await m.dictation(.failed)
        #expect(m.ui.dictationFailed == false && m.ui.alerts == [.dictationFailed(audio: false)])
        await m.dictation(.dictating)
        #expect(m.ui.dictationFailed == false)  // a new dictation that only began changes nothing
        await m.dictation(.notInserted)
        #expect(m.ui.dictationFailed == nil && m.ui.alerts == [.notInserted])
        await m.dictation(.dictating)
        #expect(m.ui.alerts.isEmpty)
    }

    // 2: the headset lost mid-recording
    @Test func aLostHeadsetIsNamedAndTurnsThePillOrange() {
        let m = model()
        m.micSwitched(lost: true)
        #expect(m.ui.micLost == nil)  // nothing records: no line
        m.ui.running = [running(.call, device: "airpods"), running(.room, device: "airpods")]
        m.micSwitched(lost: true)
        #expect(alerts(m.ui) == [.micLost("AirPods Pro")])
        var scene = PillScene()
        AppModel.show(m.ui, in: &scene)
        #expect(scene.call?.problem == true && scene.room?.problem == true)  // one microphone for both
        let row = entry(.micLost("AirPods Pro")) { $0.mics = m.ui.mics }
        #expect(row.title == "AirPods Pro getrennt, das Mac-Mikrofon nimmt weiter auf")
        #expect(row.detail == "Wählen …" && row.submenu?.contains { $0.action == .mic("builtin") } == true)
        m.micSwitched(lost: false)  // back again, or another one chosen
        AppModel.show(m.ui, in: &scene)
        #expect(alerts(m.ui).isEmpty && scene.call?.problem == false)
    }
    @Test func theLostHeadsetEndsWithTheRecordingAndHasANameWithoutOne() {
        let m = model()
        m.ui.running = [running(.room, device: "unknown")]
        m.micSwitched(lost: true)
        #expect(alerts(m.ui) == [.micLost("Kopfhörer-Mikrofon")])
        m.ui.running = []
        AppModel.settle(&m.ui)
        #expect(m.ui.micLost == nil && alerts(m.ui).isEmpty)
    }

    // 3: the device import failed
    @Test func aFailedImportNamesFileReasonAndRetry() {
        var ui = AppModel.Shown()
        ui.tapRunning = true
        (ui.importing, ui.importFailed) = (.failed(.copy), ["REC_0042.WAV"])
        #expect(alerts(ui) == [.importFailed("REC_0042.WAV", 1, .copy)])
        let one = entry(.importFailed("REC_0042.WAV", 1, .copy))
        #expect(one.title == "Geräte-Import: „REC_0042.WAV“ nicht übernommen\n"
            + "Kopieren brach ab, auf dem Gerät wurde nichts gelöscht.")
        #expect(one.detail == "Erneut versuchen" && one.action == .retryImport)
        ui.importFailed = ["a.WAV", "b.WAV", "c.WAV"]
        #expect(alerts(ui) == [.importFailed(nil, 3, .copy)])
        #expect(AppAlert.importFailed(nil, 3, .transcribe).text == "Geräte-Import: 3 Dateien nicht übernommen\n"
            + "Verschriften ging nicht, auf dem Gerät wurde nichts gelöscht.")
        #expect(AppAlert.importFailed(nil, 0, .journalUnreadable).text == "Geräte-Import: gescheitert\n"
            + "Import-Liste nicht lesbar, auf dem Gerät wurde nichts gelöscht.")
        for why in [ImportProblem.unreadable, .filing] {
            #expect(AppAlert.importFailed(nil, 2, why).text.hasSuffix(", auf dem Gerät wurde nichts gelöscht."))
        }
        ui.importing = .copying(0.1)  // the next import runs: the warning is gone, the line of the import stands
        #expect(alerts(ui).isEmpty)
    }
    @Test func theImportReachesTheModel() async {
        let m = model()
        await m.imported(.failed(.transcribe))
        #expect(m.ui.alerts == [.importFailed(nil, 0, .transcribe)])
        await m.imported(.hidden)
        #expect(m.ui.alerts.isEmpty)
    }

    // 4: the Mac slept
    @Test func aRecordingTheMacSleptThroughSaysFromWhenToWhen() async throws {
        let m = model(), day = Calendar.current.startOfDay(for: .now)
        let from = day.addingTimeInterval(14 * 3600 + 2 * 60), to = day.addingTimeInterval(15 * 3600 + 10 * 60)
        m.slept(true, now: from)
        m.slept(false, now: to)
        #expect(m.ui.pauses.isEmpty)  // nothing recorded: nothing to say
        m.ui.running = [running(.room)]
        m.slept(true, now: from)
        m.slept(false, now: to)
        #expect(alerts(m.ui) == [.paused(.room, "14:02 bis 15:10")])
        let row = entry(.paused(.room, "14:02 bis 15:10"))
        #expect(row.title == "Raum war von 14:02 bis 15:10 pausiert, läuft weiter")
        #expect(row.detail == "Ausblenden" && row.action == .dismissPause(.room))
        var scene = PillScene()
        AppModel.show(m.ui, in: &scene)
        #expect(scene.room?.problem == false)  // it records again: the pill stays in its colour
        m.perform(.dismissPause(.room))  // a click takes it away
        #expect(alerts(m.ui).isEmpty)
        m.slept(true, now: from)
        m.slept(false, now: to)
        m.ui.running = []  // or the end of the recording
        AppModel.settle(&m.ui)
        #expect(m.ui.pauses.isEmpty)
    }

    // 5 to 8: plain lines for what runs, never a warning
    @Test func whatRunsStandsAsPlainLines() {
        let none = AppModel.activity(locked: false, starting: [], stopping: [], afterRun: [], importing: .hidden)
        #expect(none.isEmpty)
        let act = { (i: ImportProgress) in
            AppModel.activity(locked: false, starting: [], stopping: [], afterRun: [], importing: i) }
        #expect(act(.copying(0.4)) == ["Geräte-Import · 40 %"])
        #expect(act(.transcribing) == ["Geräte-Import · wird verschriftet"])
        #expect(act(.failed(.copy)).isEmpty)
        #expect(AppModel.activity(locked: false, starting: [.call], stopping: [], afterRun: [], importing: .hidden)
            == ["Call startet …"])
        #expect(AppModel.activity(locked: false, starting: [], stopping: [.call], afterRun: [.room],
                                  importing: .hidden)
            == ["Call wird gespeichert …", "Raum: genauere Fassung wird erstellt …"])
        #expect(AppModel.activity(locked: true, starting: [], stopping: [], afterRun: [], importing: .hidden)
            == ["Diktat läuft freihändig · Fn beendet"])
    }
    @Test func theLinesStandAboveTheRecordingsAndAreNoWarning() {
        var s = MenuState(profile: .production, settings: .defaults(for: .production))
        let idle = StatusMenuModel.entries(s)
        s.activity = ["Call startet …", "Geräte-Import · 40 %"]
        s.running = [running(.room)]
        let all = StatusMenuModel.entries(s)
        #expect(all.prefix(3).map(\.kind) == [.info, .info, .separator])
        #expect(all.prefix(2).map(\.title) == s.activity && all[0].action == nil && all[0].symbol == nil)
        #expect(all[3].id == "roomRunning" && !all.contains { $0.kind == .alert })
        s.running = []
        #expect(Array(StatusMenuModel.entries(s).dropFirst(3)) == idle)  // nothing else moves
    }
    @Test func theModelFillsTheLinesFromItsState() async {
        let m = model()
        #expect(m.menuState.activity.isEmpty)
        m.parts.starting[.call] = .now
        #expect(m.menuState.activity == ["Call startet …"])
        m.parts.starting = [:]
        m.ui.running = [running(.call), running(.room)]
        m.parts.stopping = [.call]  // while the stop runs the call is no longer "läuft"
        #expect(m.menuState.activity == ["Call wird gespeichert …"])
        #expect(m.menuState.running.map(\.kind) == [.room])
        (m.parts.stopping, m.parts.afterRun) = ([], [.call])
        #expect(m.menuState.activity == ["Call: genauere Fassung wird erstellt …"])
        m.parts.afterRun = []
        m.pill.update { ($0.dictation, $0.locked) = (.dictating, true) }
        #expect(m.menuState.activity == ["Diktat läuft freihändig · Fn beendet"])
        m.pill.update { $0.dictation = .hidden }
        await m.imported(.copying(0.4))
        #expect(m.menuState.activity == ["Geräte-Import · 40 %"] && m.ui.alerts.isEmpty)
    }

    // 9: run time, the shared microphone, no question any more
    @Test func runningRowsCarryTimeSharedMicrophoneAndAPlainStop() {
        var s = MenuState(profile: .production, settings: .defaults(for: .production))
        (s.mics, s.now) = (["builtin": "MacBook-Mikrofon"], .now)
        s.running = [Running(kind: .room, language: .de, started: s.now.addingTimeInterval(-3 * 3600 - 62),
                             device: "builtin")]
        let find = { (id: String) in StatusMenuModel.entries(s).first { $0.id == id } }
        #expect(find("roomRunning")?.title == "Raum läuft · Deutsch" && find("roomRunning")?.detail == "3:01:02")
        #expect(find("roomFacts")?.title == "MacBook-Mikrofon · Live lokal")
        #expect(find("roomStop")?.title == "Raum beenden" && find("roomStop")?.action == .stop(.room))
        s.running.insert(Running(kind: .call, language: .de, started: s.now, device: "builtin"), at: 0)
        #expect(find("roomFacts")?.title == "MacBook-Mikrofon · Mikrofon mit Call geteilt · Live lokal")
        #expect(find("callFacts")?.title == "MacBook-Mikrofon · Live lokal")
        #expect(find("callStop")?.title == "Call beenden")
    }

    /// Urgent first: a recording loses sound, then permissions and keys, then what failed, then what waits.
    @Test func theHintsComeInOrderOfUrgency() {
        var ui = AppModel.Shown()
        (ui.tapRunning, ui.running, ui.missing) = (true, [running(.call), running(.room)], [.accessibility])
        (ui.post, ui.notInserted, ui.dictationFailed, ui.micLost) = (.waiting(count: 2), true, true, "AirPods Pro")
        (ui.importing, ui.importFailed, ui.pauses) = (.failed(.copy), ["a.WAV"], [.room: "14:02 bis 15:10"])
        ui.running[0].silent = true
        let list = alerts(ui)
        #expect(list == [.micSilent, .micLost("AirPods Pro"), .permission("Bedienungshilfen"),
                         .dictationFailed(audio: true), .importFailed("a.WAV", 1, .copy), .postWaiting(2),
                         .notInserted, .paused(.room, "14:02 bis 15:10")])
        #expect(list.map(\.rank) == list.map(\.rank).sorted())
        for a in list { #expect(!a.step.title.isEmpty && !a.text.isEmpty) }
    }
}
