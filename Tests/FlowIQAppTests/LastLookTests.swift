// The last look before the first start, W1 to W3 as models.
import FlowIQCloud
import FlowIQCore
@testable import FlowIQDevices
import Foundation
import Testing
@testable import FlowIQ

@Suite struct LastLookTests {
    @Test func restartPassesTheOldProcessToWaitFor() {  // W1
        #expect(AppDelegate.restarted(from: ["FlowIQ", "--nach-neustart", "4711"]) == 4711)
        #expect(AppDelegate.restarted(from: ["FlowIQ"]) == nil)
        #expect(AppDelegate.restarted(from: ["FlowIQ", "--nach-neustart"]) == nil)
        #expect(FlowIQTheme.Motion.restartWait >= 5)
    }

    @Test func developmentSendsOnlyOnItsExplicitSwitch() {  // W3
        var s = FlowIQCore.Settings.defaults(for: .development)
        s[.call].post = .elevenLabs
        #expect(!s.devCloudAllowed)
        #expect(!AppModel.policy(s, .development, key: true, openRouterKey: true).allows(.post, for: .call))
        #expect(AppModel.policy(s, .development, key: true, openRouterKey: true).service == nil)
        s.devCloudAllowed = true
        #expect(AppModel.policy(s, .development, key: true, openRouterKey: false).allows(.post, for: .call))
        #expect(AppModel.policy(s, .development, key: false, openRouterKey: true).service == .openRouter)
        #expect(!AppModel.policy(s, .development, key: false, openRouterKey: false).allows(.post, for: .call))
        var p = FlowIQCore.Settings.defaults(for: .production)
        p.devCloudAllowed = false  // the switch means nothing in production
        #expect(AppModel.policy(p, .production, key: true, openRouterKey: false).allows(.post, for: .call))
    }

    @MainActor @Test func filesShowTheirStateAndRetryWithoutAnImporter() {  // W2
        let m = DevicesModel(nil)
        m.files = [DeviceImporter.FileRow(name: "REC001.WAV", state: "fehlgeschlagen", retry: true)]
        m.retry()  // no importer: nothing happens, nothing crashes
        #expect(m.files.first?.retry == true && m.files.first?.state == "fehlgeschlagen")
    }
}

/// First real start (16.11.): Panotti keys, a hidden menu bar icon, the docked pill.
@Suite struct FirstStartTests {
    @Test func keysAreAsPanottiUnlessAlternate() {
        var s = FlowIQCore.Settings.defaults(for: .development)
        #expect(s.keyScheme == .production && !s.alternateKeys)  // Fn and ⌘⌥ in the test build too
        s.alternateKeys = true
        #expect(s.keyScheme == .development)  // right Option and ⌃⌥⌘ as an option
        // COMPILE-FIX 16.11.2026: Carbon registers HotKey (U, R, E, K), Shortcut is only the resulting action
        #expect(HotKey.call.combination(for: FlowIQCore.Settings.defaults(for: .development).keyScheme)
                == HotKey.call.combination(for: .production))
    }

    @Test func panottiSharingIsAWarningAndFnRests() {
        var ui = AppModel.Shown()
        ui.keysShared = true
        #expect(AppModel.alerts(ui, silent: false, limit: 0) == [.panottiKeys])  // not "Fn reagiert nicht"
        #expect(AppAlert.panottiKeys.text == "Panotti hält dieselben Tasten")
        #expect(AppAlert.panottiKeys.step.action == .settings)
    }

    @Test func iconOffEveryScreenIsRecognized() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(StatusMenu.onScreen(CGRect(x: 1200, y: 950, width: 24, height: 24), [screen]))
        #expect(!StatusMenu.onScreen(CGRect(x: -9251, y: 950, width: 24, height: 24), [screen]))
    }
}
