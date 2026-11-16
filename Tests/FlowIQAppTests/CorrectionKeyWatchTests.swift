// The final review, Muss 3: the window asks the key watch of the Fn tap whether a key came since the insertion;
// while the tap is not running nobody watches, and that counts as typed (no Cmd-Z, the clipboard way instead).
import FlowIQCore
import FlowIQInput
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQ

private final class Tap: KeyEventSource, Sendable {
    let handler = Mutex<(@Sendable (KeyEvent) -> Void)?>(nil)
    func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws { self.handler.withLock { $0 = handler } }
    func stop() {}
    func key() { handler.withLock { $0 }?(KeyEvent(.other, down: true, at: MachTime.nanos(ticks: MachTime.now()))) }
}

private struct Quiet: PillSink { func set(_ state: PillState) {} }

struct CorrectionKeyWatchTests {
    @Test func theSessionFollowsTheKeyWatchAndAnExplicitAnswerWins() {
        let typed: @Sendable () -> Bool = { true }, quiet: @Sendable () -> Bool = { false }
        let results = [CorrectionSession.typed(nil, typed), CorrectionSession.typed(nil, quiet),
                       CorrectionSession.typed(false, typed), CorrectionSession.typed(true, quiet)]
        #expect(results == [true, false, false, true])
    }

    @Test func aKeyAfterTheInsertionAndANotRunningTapBothCountAsTyped() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-keys-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
            }
        }
        let log = EventLog(directory: root, fs: SafeFS(confinedTo: root)), tap = Tap()
        let input = InputService(source: tap, profile: .development, clock: ContinuousClock(), pill: Quiet(), log: log)
        #expect(input.keySinceInsert, "no tap running: nobody watches")
        try input.start()
        input.noteInsert()
        #expect(!input.keySinceInsert)
        tap.key()
        #expect(input.keySinceInsert, "typed after the insertion")
        input.noteInsert()
        input.stop()
        #expect(input.keySinceInsert, "stopped tap: typed")
    }
}
