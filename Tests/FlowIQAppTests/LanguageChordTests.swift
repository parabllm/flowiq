// Call and room keys after the decision of 16.11.: ⌘⌥U and ⌘⌥R alone German, E held as well English (either
// order), the same key stops, ⌘⌥E alone does nothing, no Shift any more. Pure model plus the Carbon-free driver.
import Carbon.HIToolbox
import FlowIQCore
@testable import FlowIQInput
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQ

private let ms: UInt64 = 1_000_000

@Suite struct LanguageChordTests {
    @Test func eFirstThenUIsEnglishAtOnce() {
        var c = LanguageChord()
        #expect(c.handle(.english, down: true, at: 0, running: false).isEmpty)
        #expect(c.handle(.call, down: true, at: 40 * ms, running: false) == [.callEnglish])
        #expect(c.deadline == nil, "nothing waits")
        #expect(c.handle(.call, down: false, at: 90 * ms, running: false).isEmpty)
        #expect(c.handle(.english, down: false, at: 95 * ms, running: false).isEmpty)
        #expect(c.tick(now: 1_000 * ms).isEmpty)
    }

    @Test func uFirstThenEInsideTheWindowIsEnglish() {
        var c = LanguageChord()
        #expect(c.handle(.call, down: true, at: 0, running: false).isEmpty, "U waits for a possible E")
        #expect(c.deadline == LanguageChord.window)
        #expect(c.handle(.english, down: true, at: 60 * ms, running: false) == [.callEnglish])
        #expect(c.deadline == nil)
        #expect(c.tick(now: 1_000 * ms).isEmpty, "decided once, never twice")
        var r = LanguageChord()
        #expect(r.handle(.room, down: true, at: 0, running: false).isEmpty)
        #expect(r.handle(.english, down: true, at: LanguageChord.window - 1, running: false) == [.roomEnglish])
    }

    @Test func uAloneIsGermanAfterTheWait() {
        var c = LanguageChord()
        #expect(c.handle(.call, down: true, at: 1_000 * ms, running: false).isEmpty)
        #expect(c.handle(.call, down: false, at: 1_060 * ms, running: false).isEmpty, "the release decides nothing")
        #expect(c.tick(now: 1_000 * ms + LanguageChord.window - 1).isEmpty)
        #expect(c.tick(now: 1_000 * ms + LanguageChord.window) == [.callGerman])
        #expect(c.deadline == nil && c.tick(now: 2_000 * ms).isEmpty)
        // an E after the wait is too late: German stands, the E alone does nothing
        #expect(c.handle(.english, down: true, at: 2_100 * ms, running: false).isEmpty)
        var r = LanguageChord()
        #expect(r.handle(.room, down: true, at: 0, running: false).isEmpty)
        #expect(r.handle(.english, down: true, at: LanguageChord.window, running: false) == [.roomGerman],
                "the overdue German comes first, the late E adds nothing")
    }

    @Test func theWaitIsShortAndNamed() {
        #expect(LanguageChord.window >= 120 * ms && LanguageChord.window <= 180 * ms)
    }

    @Test func eAloneDoesNothing() {
        var c = LanguageChord()
        #expect(c.handle(.english, down: true, at: 0, running: false).isEmpty)
        #expect(c.deadline == nil)
        #expect(c.handle(.english, down: false, at: 200 * ms, running: false).isEmpty)
        #expect(c.tick(now: 10_000 * ms).isEmpty)
        // after the release a lone U is German again, not English
        #expect(c.handle(.call, down: true, at: 300 * ms, running: false).isEmpty)
        #expect(c.tick(now: 300 * ms + LanguageChord.window) == [.callGerman])
    }

    @Test func aLostEReleaseDoesNotMakeEverythingEnglish() {
        var c = LanguageChord()
        _ = c.handle(.english, down: true, at: 0, running: false)  // its release never arrives
        c.releaseE()  // the driver saw the real key up
        #expect(c.handle(.call, down: true, at: 400 * ms, running: false).isEmpty)
        #expect(c.tick(now: 400 * ms + LanguageChord.window) == [.callGerman])
    }

    @Test func anEHeldForLongStillMeansEnglish() {
        var c = LanguageChord()
        _ = c.handle(.english, down: true, at: 0, running: false)
        #expect(c.handle(.room, down: true, at: 20_000 * ms, running: false) == [.roomEnglish])
        // and both letters one after the other under the same held E
        #expect(c.handle(.call, down: true, at: 21_000 * ms, running: false) == [.callEnglish])
    }

    @Test func theSameLetterAgainInsideTheWaitStartsOnce() {
        var c = LanguageChord()
        _ = c.handle(.call, down: true, at: 0, running: false)
        #expect(c.handle(.call, down: true, at: 60 * ms, running: false) == [.callGerman])
        #expect(c.deadline == nil && c.tick(now: 1_000 * ms).isEmpty, "no second start, no stop of the first")
    }

    @Test func aRunningRecordingStopsAtOnceWithOrWithoutE() {
        var c = LanguageChord()
        #expect(c.handle(.call, down: true, at: 0, running: true) == [.callGerman])
        #expect(c.deadline == nil, "a stop never waits")
        _ = c.handle(.english, down: true, at: 500 * ms, running: false)
        #expect(c.handle(.room, down: true, at: 520 * ms, running: true) == [.roomEnglish])
        #expect(c.deadline == nil)
        // U first and E right after it while the call runs: the stop went out with U, the E adds nothing
        var u = LanguageChord()
        #expect(u.handle(.call, down: true, at: 0, running: true) == [.callGerman])
        #expect(u.handle(.english, down: true, at: 30 * ms, running: true).isEmpty)
        // both reach AppModel as a stop of the running kind
        #expect(AppModel.decide(running: true, startedAt: nil, now: .now) == .stop)
    }

    @Test func aSecondLetterWhileWaitingSettlesTheFirstAsGerman() {
        var c = LanguageChord()
        _ = c.handle(.call, down: true, at: 0, running: false)
        #expect(c.handle(.room, down: true, at: 50 * ms, running: false) == [.callGerman])
        #expect(c.deadline == 50 * ms + LanguageChord.window)
        #expect(c.tick(now: 50 * ms + LanguageChord.window) == [.roomGerman])
    }

    @Test func correctionStaysDirect() {
        var c = LanguageChord()
        #expect(c.handle(.correct, down: true, at: 0, running: false) == [.correctLast])
        #expect(c.handle(.correct, down: false, at: 10 * ms, running: false).isEmpty)
    }

    @Test func commandOptionEAloneTriggersNothingAnyMore() {
        #expect(!Shortcut.allCases.map(\.rawValue).contains("liveSource"))
        var c = LanguageChord()
        for n in UInt64(0)..<20 {  // E pressed and released ten times, nothing else
            #expect(c.handle(.english, down: n % 2 == 0, at: n * 100 * ms, running: true).isEmpty)
        }
        #expect(c.tick(now: 5_000 * ms).isEmpty)
        var s = MenuState(profile: .production, settings: .defaults(for: .production), hasKey: true)
        s.running = [Running(kind: .call, language: .de, started: .now)]
        let live = StatusMenuModel.entries(s).first { $0.id == "callLive" }
        #expect(live?.key == nil && live?.keyLabel == nil && live?.action == .toggleLive(.call))
    }

    @Test func keysHaveNoShiftAndAlternateAddsControlOnly() {
        for key in HotKey.allCases {
            let (prod, dev) = (key.combination(for: .production), key.combination(for: .development))
            #expect(prod.keyCode == dev.keyCode)
            #expect(prod.modifiers == UInt32(cmdKey | optionKey), "\(key)")
            #expect(dev.modifiers == UInt32(cmdKey | optionKey | controlKey), "\(key)")
        }
        #expect(HotKey.english.combination(for: .production).keyCode == UInt32(kVK_ANSI_E))
        #expect(HotKey.call.combination(for: .production).keyCode == UInt32(kVK_ANSI_U))
        #expect(HotKey.room.combination(for: .production).keyCode == UInt32(kVK_ANSI_R))
        var alternate = FlowIQCore.Settings.defaults(for: .production)
        alternate.alternateKeys = true
        #expect(alternate.keyScheme == .development, "the alternate scheme registers the same keys with ⌃")
    }

    @Test func menuShowsTheTwoLetterKeysAsText() {
        let rows = StatusMenuModel.entries(MenuState(profile: .production, settings: .defaults(for: .production)))
        let row = { (id: String) in rows.first { $0.id == id } }
        #expect(row("callGerman")?.key == "u" && row("callGerman")?.keyLabel == nil)
        #expect(row("callEnglish")?.key == nil && row("callEnglish")?.keyLabel == "⌥⌘E U")
        #expect(row("roomEnglish")?.key == nil && row("roomEnglish")?.keyLabel == "⌥⌘E R")
        var settings = FlowIQCore.Settings.defaults(for: .production)
        settings.alternateKeys = true
        let alt = StatusMenuModel.entries(MenuState(profile: .production, settings: settings))
        #expect(alt.first { $0.id == "callEnglish" }?.keyLabel == "⌃⌥⌘E U")
        #expect(StatusMenuModel.keyText("u", alternate: false) == "⌥⌘U")
    }
}

/// The driver without Carbon: `receive` gets the edges as the Carbon callback would hand them over.
@MainActor @Suite struct HotKeysDriverTests {
    private func rig(running: Bool = false, eDown: Bool = true) -> (HotKeys, () -> [Shortcut], URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-chord-\(UUID().uuidString)")
        let log = EventLog(directory: root, fs: SafeFS(confinedTo: root))
        final class Box { var seen: [Shortcut] = [] }
        let box = Box()
        let keys = HotKeys(profile: .production, log: log, running: { _ in running },
                           deliver: { box.seen.append($0) }, eDown: { eDown })
        return (keys, { box.seen }, root)
    }
    private func cleanup(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
    }

    @Test func loneUBecomesGermanOnItsOwnAfterTheWait() async throws {
        let (keys, seen, root) = rig()
        defer { cleanup(root) }
        keys.receive(.call, down: true)
        #expect(seen().isEmpty, "not at once: an E may follow")
        for _ in 0..<300 where seen().isEmpty { try await Task.sleep(for: .milliseconds(100)) }  // busy test runs
        #expect(seen() == [.callGerman])
    }

    @Test func eHeldMakesUEnglishWithoutWaiting() {
        let (keys, seen, root) = rig()
        defer { cleanup(root) }
        keys.receive(.english, down: true)
        keys.receive(.call, down: true)
        #expect(seen() == [.callEnglish])
    }

    @Test func anEWhoseReleaseWasLostDoesNotMakeUEnglish() {
        let (keys, seen, root) = rig(eDown: false)  // Carbon said E down, the keyboard says it is up
        defer { cleanup(root) }
        keys.receive(.english, down: true)
        keys.receive(.call, down: true)
        #expect(seen().isEmpty, "waits like a lone U instead of starting English")
    }

    @Test func uFirstThenEIsEnglishAndNothingFollows() async throws {
        let (keys, seen, root) = rig()
        defer { cleanup(root) }
        keys.receive(.room, down: true)
        keys.receive(.english, down: true)
        #expect(seen() == [.roomEnglish])
        try await Task.sleep(nanoseconds: LanguageChord.window * 3)
        #expect(seen() == [.roomEnglish], "the cancelled wait delivers no German afterwards")
    }

    @Test func eAloneDeliversNothing() async throws {
        let (keys, seen, root) = rig()
        defer { cleanup(root) }
        keys.receive(.english, down: true)
        keys.receive(.english, down: false)
        try await Task.sleep(nanoseconds: LanguageChord.window * 2)
        #expect(seen().isEmpty)
    }

    @Test func runningStopsWithEHeldToo() {
        let (keys, seen, root) = rig(running: true)
        defer { cleanup(root) }
        keys.receive(.english, down: true)
        keys.receive(.call, down: true)
        #expect(seen() == [.callEnglish], "at once; AppModel stops the running call whatever the language")
    }

    @Test func runningStopsWithoutWaiting() {
        let (keys, seen, root) = rig(running: true)
        defer { cleanup(root) }
        keys.receive(.room, down: true)
        #expect(seen() == [.roomGerman])
    }
}
