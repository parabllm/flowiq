// OpenRouter as second after-run service and the live trouble of review M4 (16.11.), as models.
import FlowIQCloud
import FlowIQCore
import FlowIQRecording
import FlowIQSpeech
import Foundation
import Testing
@testable import FlowIQ

@Suite struct CloudServiceTests {
    @Test func anOpenRouterKeyAloneOffersTheAfterRun() {
        var s = MenuState(profile: .production, settings: .defaults(for: .production))
        s.openRouterKey = true
        let rows = StatusMenuModel.cloud(s)
        #expect(rows.first { $0.id == "post-call" }?.checked == true)
        #expect(rows.first { $0.id == "post-call" }?.action == .post(.call))
        #expect(rows.first { $0.id == "live-call" }?.action == .keyField)  // live stays ElevenLabs or local
        s.openRouterUSD = 1.234
        #expect(StatusMenuModel.cloud(s).contains { $0.title == "OpenRouter: 1,23 $" })
    }

    @Test func serviceAndModelLiveInTheSettings() throws {
        var s = FlowIQCore.Settings.defaults(for: .production)
        #expect(s.postService == .auto && s.openRouterModel == "elevenlabs/scribe-v2")
        (s.postService, s.openRouterModel) = (.openRouter, "own/model")
        let back = try JSONDecoder().decode(FlowIQCore.Settings.self, from: JSONEncoder().encode(s))
        #expect(back.postService == .openRouter && back.openRouterModel == "own/model")
        #expect(CloudPolicy(settings: back, hasKey: false, openRouterKey: true).service == .openRouter)
        #expect(CloudPolicy(settings: back, hasKey: false, openRouterKey: false).service == nil)
        #expect(!OpenRouterModels.load(nil).isEmpty)
    }

    @Test func liveTroubleIsAWarningWithItsNextStep() {
        let missing = AppAlert.trouble(.modelMissing(.en))
        #expect(missing.text == LiveTrouble.modelMissing(.en).text)
        #expect(missing.step.title == "Sprachmodell laden" && missing.step.action == .installModel(.en))
        #expect(AppAlert.trouble(.recognizerFailed).step.action == nil)
        var ui = AppModel.Shown()
        (ui.tapRunning, ui.troubles) = (true, [.call: .modelMissing(.en)])
        #expect(AppModel.alerts(ui, silent: false, limit: 0) == [.trouble(.modelMissing(.en))])
    }

    @Test func troubleStaysAtThePillWhenTheInformationFades() {
        // TEST-FIX 16.11.2026 (Pille nach pille-neu.html): die Pille wird orange statt einer Marke, kein "EN"
        var ui = AppModel.Shown(), scene = PillScene()
        ui.running = [Running(kind: .call, language: .en, started: .now)]
        ui.troubles = [.call: .recognizerFailed]
        AppModel.show(ui, in: &scene)
        #expect(scene.elements.map(\.look) == [.outline, .fill(.warning)])
    }
}
