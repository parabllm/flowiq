// Plugging in a recorder always says what is going on (16.11.): a warning line with its step while the switch is
// off or the volume only may be a recorder, a plain line for nothing new and for what came. Model tests only.
import FlowIQCore
import FlowIQDevices
import Foundation
import Testing
@testable import FlowIQ

@MainActor @Suite struct RecorderHintTests {
    private func notice(_ what: DeviceNotice.What, _ kind: DeviceKind = .dvt1600, _ name: String = "DVT1600")
        -> DeviceNotice { DeviceNotice(what, kind, name: name, uuid: "u") }
    private func alerts(_ d: DeviceNotice?) -> [AppAlert] {
        var ui = AppModel.Shown()
        (ui.tapRunning, ui.device) = (true, d)
        return AppModel.alerts(ui, silent: false, limit: 0)
    }
    private func lines(_ d: DeviceNotice?, importing: ImportProgress = .hidden) -> [String] {
        AppModel.activity(locked: false, starting: [], stopping: [], afterRun: [], importing: importing, device: d)
    }

    @Test func switchedOffTheRecorderIsNamedWithTheStepThatSwitchesOn() {
        #expect(alerts(notice(.off)) == [.recorderOff("DVT1600")])
        var s = MenuState(profile: .production, settings: .defaults(for: .production))
        s.alerts = [.recorderOff("DVT1600")]
        let e = StatusMenuModel.entries(s)[0]
        #expect(e.kind == .alert && e.title == "Rekorder „DVT1600“ erkannt, der Geräte-Import ist aus")
        #expect(e.detail == "Import einschalten" && e.action == .enableImport)
        #expect(lines(notice(.off)).isEmpty)
    }

    @Test func aVolumeThatOnlyMayBeOneLeadsToTheList() {
        #expect(alerts(notice(.unknown, .zephyr, "STICK")) == [.recorderUnknown("STICK")])
        #expect(AppAlert.recorderUnknown("STICK").text == "„STICK“ eingesteckt, als Rekorder nicht sicher erkannt")
        #expect(AppAlert.recorderUnknown("STICK").step.title == "Zuordnen …")
        #expect(AppAlert.recorderUnknown("STICK").step.action == .devices)
        let m = AppModel(profile: .production, settings: .defaults(for: .production), pill: PillView(show: false))
        m.ui.tab = .recording
        m.perform(.devices)
        #expect(m.ui.tab == .devices)
    }

    @Test func nothingNewAndWhatCameArePlainLinesNeverAWarning() {
        #expect(alerts(notice(.nothingNew)).isEmpty && alerts(notice(.imported(2))).isEmpty && alerts(nil).isEmpty)
        #expect(lines(notice(.nothingNew)) == ["Stift: nichts Neues"])
        #expect(lines(notice(.nothingNew, .zephyr, "NO NAME")) == ["ZEPHYR: nichts Neues"])
        #expect(lines(notice(.imported(1))) == ["Stift: 1 Aufnahme importiert"])
        #expect(lines(notice(.imported(3))) == ["Stift: 3 Aufnahmen importiert"])
        #expect(lines(nil).isEmpty)
        // while an import runs its own line stands alone
        #expect(lines(notice(.nothingNew), importing: .copying(0.5)) == ["Geräte-Import · 50 %"])
        #expect(lines(notice(.imported(1)), importing: .failed(.copy)).isEmpty)
    }

    /// The list follows every step while it is on screen; a block of the same copy is no step.
    @Test func theListOffersOnlyTheKindsOfItsBuildAndTakesTheNoticeAlong() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "flowiq-hint-\(UUID().uuidString)")
        let fs = SafeFS(confinedTo: dir), log = EventLog(directory: dir.appending(path: "log"), fs: fs)
        struct None: DeviceTranscriber, DeviceFiling {
            func transcribe(_ audio: URL, language: RecordingLanguage) async throws -> [LiveSegment] { [] }
            func file(_ r: DeviceRecording) async throws -> URL { r.audio }
        }
        for (profile, kinds) in [(Profile.production, [DeviceKind.dvt1600, .zephyr]), (.development, [.test])] {
            let importer = DeviceImporter(profile: profile, folders: .init(data: dir, archive: dir), fs: fs, log: log,
                                          transcriber: None(), filing: None(), post: { false }, volumes: { [] })
            let d = DevicesModel(importer)
            #expect(d.kinds == kinds)
            d.notice = notice(.nothingNew)
            await d.step(.copying(0.2), was: .copying(0.1))
            #expect(d.notice != nil)  // not asked again for every block
            await d.step(.hidden, was: .transcribing)
            #expect(d.notice == nil)  // the importer's own state
            await d.look()
            #expect(d.notice == nil && !d.enabled)
        }
    }
}
