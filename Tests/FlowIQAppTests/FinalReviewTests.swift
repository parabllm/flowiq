// The final review before the first start, one model test per point.
import AppKit
import FlowIQCore
import FlowIQDevices
import FlowIQRecording
import Foundation
import Testing
@testable import FlowIQ

@Suite struct FinalReviewTests {
    private func shown(_ edit: (inout AppModel.Shown) -> Void) -> AppModel.Shown {
        var ui = AppModel.Shown()
        edit(&ui)
        return ui
    }

    @Test func secondInstanceIsRecognizedByItsProcess() {  // (1)
        #expect(!AppDelegate.isSecond(42, own: 42))
        #expect(AppDelegate.isSecond(41, own: 42))
    }

    @Test func grantedButStoppedTapIsAWarningNotAHook() {  // (2)
        #expect(AppModel.alerts(shown { $0.tapRunning = false }, silent: false, limit: 0) == [.tapStopped])
        #expect(AppModel.alerts(shown { $0.tapRunning = true }, silent: false, limit: 0).isEmpty)
        let missing = AppModel.alerts(shown { $0.missing = [.inputMonitoring] }, silent: false, limit: 0)
        #expect(missing == [.permission("Eingabeüberwachung")])
        #expect(AppAlert.tapStopped.step.action == .setup)
    }

    @Test func deadEndsAreConnected() {  // (3)
        // TEST-FIX 16.11.2026 (Nutzerwunsch: ⌘⌥E schaltet nicht mehr die Live-Quelle, E heißt Englisch)
        #expect(AppModel.taken([.call, .english]) == "Kurzbefehl belegt: Call, Englisch (E)")
        // TEST-FIX 16.11.2026 (Pille nach pille-neu.html): der Kreis füllt sich bis höchstens 95 %, voll am Ende
        let cap = FlowIQTheme.Pill.ringCap
        #expect(PillScene.ring(.copying(0.3), now: nil) == 0.3 * cap && PillScene.ring(.transcribing, now: 0.5) == 0.5)
        #expect(PillScene.ring(.hidden, now: nil) == nil && PillScene.ring(.failed(.copy), now: 0.5) == nil)
        #expect(PillScene.ring(.hidden, now: 0.9) == 1 && PillScene.ring(.copying(1), now: nil) == cap)
        let room = shown { ($0.tapRunning, $0.down) = (true, [.microphone]) }
        #expect(AppModel.alerts(room, silent: true, limit: 0) == [.micSilent])
    }

    @Test func warningsAreComputedOffTheMainThread() async {  // (4)
        let ui = shown { ($0.tapRunning, $0.post) = (true, .waiting(count: 2)) }
        let list = await Task.detached { AppModel.alerts(ui, silent: false, limit: 0) }.value
        #expect(list == [.postWaiting(2)])
    }

    @Test func callWithoutScreenRecordingSaysTheOtherSideIsMissing() {  // (5)
        let call = shown { s in
            (s.tapRunning, s.screenGranted) = (true, false)
            s.running = [Running(kind: .call, language: .de, started: .now)]
        }
        // without the permission the desktop never restarts: the cause, not a standing restart warning (16.11.)
        #expect(AppModel.alerts(call, silent: false, limit: 0) == [.permission("Bildschirmaufnahme")])
        #expect(AppAlert.permission("Bildschirmaufnahme").text == "Bildschirmaufnahme fehlt")
        let down = shown { s in
            (s.tapRunning, s.down) = (true, [.desktop])
            s.running = [Running(kind: .call, language: .de, started: .now)]
        }
        #expect(AppModel.alerts(down, silent: false, limit: 0) == [.noDesktop])
        // TEST-FIX (Wortlaut laut Nutzerwunsch 16.11.2026)
        #expect(AppAlert.noDesktop.text == "Nur dein Mikrofon wird aufgenommen\nDer Ton der anderen im Call fehlt.")
        let room = shown { s in
            (s.tapRunning, s.screenGranted) = (true, false)
            s.running = [Running(kind: .room, language: .de, started: .now)]
        }
        #expect(AppModel.alerts(room, silent: false, limit: 0).isEmpty)
    }

    @Test func audioArchiveFollowsAndLiveLinkIsPerProfile() {  // (6)
        var s = FlowIQCore.Settings.defaults(for: .production)
        let paths = Paths(profile: .production)
        #expect(s.locations(paths).liveLink.path == "/tmp/flowiq-live.md")
        #expect(s.locations(paths).archiveAudio == s.folder(.production).appending(path: "audio",
            directoryHint: .isDirectory))
        (s.transcriptFolder, s.audioFolder, s.panottiLink) = ("/tmp/a", "/tmp/b", true)
        #expect(s.locations(paths).archiveAudio.path == "/tmp/b" && s.locations(paths).transcripts.path == "/tmp/a")
        #expect(s.locations(paths).liveLink.path == "/tmp/panotti-live.md")
        #expect(FlowIQCore.Settings.defaults(for: .development).locations(Paths(profile: .development)).liveLink.path
                == "/tmp/flowiq-dev-live.md")
    }

    @Test func afterRunStaysOnButOnlyWorksWithAKey() {  // (7)
        let s = FlowIQCore.Settings.defaults(for: .production)
        for m in RecordingMode.allCases {
            #expect(s[m].post == .elevenLabs)
            #expect(s.effective(m, hasKey: true).post == .elevenLabs)
            #expect(s.effective(m, hasKey: false).post == .off)
            #expect(!CloudPolicy(settings: s, hasKey: false).allows(.post, for: m))
        }
    }
}

// TEST-FIX 16.11.2026 (Pille nach local/design/pille-neu.html): marks, cards and hover are removed, so
// their four tests are replaced by tests that nothing of them is left and that every reason stands in the menu.
@MainActor @Suite struct MinimalPillTests {
    private func running(_ kind: SessionKind, _ edit: (inout Running) -> Void = { _ in }) -> Running {
        var r = Running(kind: kind, language: .en, started: .now.addingTimeInterval(-7300))
        (r.sending, r.device) = (true, "airpods")
        edit(&r)
        return r
    }
    private func scene(_ ui: AppModel.Shown) -> PillScene {
        var s = PillScene()
        AppModel.show(ui, in: &s)
        return s
    }

    @Test func aBusyDayStillDrawsOnlyThreePills() {
        var ui = AppModel.Shown()
        (ui.keysShared, ui.notInserted, ui.missing, ui.mics) = (true, true, [.inputMonitoring], ["airpods": "AirPods"])
        ui.running = [running(.call), running(.room)]
        var s = scene(ui)
        s.dictation = .notInserted
        #expect(s.elements.map(\.id) == ["dictation", "call", "room"])  // cloud, shared microphone, keys: no mark
        #expect(s.elements.map(\.look) == [.outline, .fill(.call), .fill(.room)])
    }

    @Test func everyOrangePillHasItsReasonInTheMenu() {
        let cases: [(String, (inout AppModel.Shown) -> Void, AppAlert)] = [
            ("silent", { $0.running[0].silent = true }, .micSilent),
            ("microphone down", { $0.down = [.microphone] }, .micSilent),
            ("desktop down", { $0.down = [.desktop] }, .noDesktop),
            ("desktop silent", { $0.running[0].desktopSilent = true }, .noDesktop),
            ("screen", { $0.screenGranted = false }, .permission("Bildschirmaufnahme")),
            ("network", { $0.running[0].fallback = .networkError }, .networkDown),
            ("limit", { $0.running[0].fallback = .limit }, .limitReached(0)),
            ("live text", { $0.troubles = [.call: .modelMissing(.en)] }, .trouble(.modelMissing(.en))),
        ]
        for (name, edit, alert) in cases {
            var ui = AppModel.Shown()
            (ui.tapRunning, ui.running) = (true, [running(.call)])
            #expect(scene(ui).call?.problem == false && AppModel.alerts(ui, silent: false, limit: 0).isEmpty)
            edit(&ui)
            #expect(scene(ui).call?.problem == true, "\(name)")
            #expect(AppModel.alerts(ui, silent: AppModel.silent(ui), limit: 0) == [alert], "\(name)")
        }
    }

    @Test func aRoomDoesNotTurnOrangeForTheCallsOtherSide() {
        var ui = AppModel.Shown()
        (ui.running, ui.screenGranted, ui.down) = ([running(.room)], false, [.desktop])
        #expect(scene(ui).room?.problem == false)
        ui.running[0].fallback = .manual  // switched by hand: no problem
        #expect(scene(ui).room?.problem == false)
    }

    @Test func theColorsAreTheTemplatesAndTheSameInBothModes() {
        let hex = { (f: PillScene.Element.Fill, dark: Bool) -> String in
            var out = ""
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                let c = (PillView.color(f).converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                                                     options: nil)?.components ?? []).map { Int(($0 * 255).rounded()) }
                out = c.prefix(3).map { String(format: "%02X", $0) }.joined() + "/\(c.last ?? 0)"
            }
            return out
        }
        for dark in [false, true] {
            #expect(hex(.dictation, dark) == "E0556B/255" && hex(.call, dark) == "6648CB/255")
            #expect(hex(.room, dark) == "9DA1FF/255" && hex(.warning, dark) == "CF7C53/255")
        }
        #expect(hex(.neutral, false) == "1A1726/166" && hex(.neutral, true) == "FFFFFF/191")  // 65 %, 75 %
    }
}
