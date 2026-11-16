// The final review, Muss 3: the correction never takes back typed text. The field is edited only where it is
// read and unchanged; Cmd-Z only when no key came since the insertion, the same app is in front and the focus is
// still a text field. Every other case puts the corrected text on the clipboard (the window says so, Cmd-V).
import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQInsert

final class Target: PasteboardPort, KeyPosting, FocusProbing, FrontAppProbing, Sendable {
    struct State { var clip = "alt", count = 1, promise: (@Sendable () -> Void)?, undos = 0
        var front = "test.app", focus = FocusState.unreadable }
    let state = Mutex(State())
    var changeCount: Int { state.withLock { $0.count } }
    func snapshot() throws -> PasteboardSnapshot {
        PasteboardSnapshot(items: [["public.utf8-plain-text": Data(state.withLock { $0.clip }.utf8)]])
    }
    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int {
        state.withLock { s in (s.count, s.clip, s.promise) = (s.count + 1, text, onFetch); return s.count }
    }
    func writePlain(_ text: String) throws -> Int { state.withLock { s in (s.count, s.clip) = (s.count + 1, text)
        return s.count } }
    func restore(_ snapshot: PasteboardSnapshot) throws { state.withLock { $0.count += 1 } }
    func paste() throws { state.withLock { $0.promise }?() }
    func undo() throws { state.withLock { $0.undos += 1 } }
    func probe() async -> FocusState { state.withLock { $0.focus } }
    func frontmost() -> String? { state.withLock { $0.front } }
    var secureInputActive: Bool { false }
}

struct SafeCorrectionTests {
    /// Inserts "heute kommt Sorbal", then changes the world and corrects word 3.
    func correct(keySinceInsert: Bool, _ change: @Sendable (inout Target.State) -> Void = { _ in })
        async -> (ReplaceResult, Int, String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-safe-\(UUID().uuidString)")
        defer { remove(root) }
        let target = Target()
        let inserter = Inserter(focus: target, pasteboard: target, keys: target, front: target,
                                clock: ContinuousClock(), log: EventLog(directory: root, fs: SafeFS(confinedTo: root)))
        #expect(await inserter.insert("heute kommt Zorbal") == .landed)
        await inserter.settled()
        target.state.withLock { change(&$0) }
        let result = await inserter.replaceInLastInsertion(range: 12..<18, with: "Sorbal",
                                                           keySinceInsert: keySinceInsert)
        return (result, target.state.withLock { $0.undos }, target.state.withLock { $0.clip })
    }

    @Test func aKeyTypedAfterTheInsertionNeverUndoes() async {
        let (result, undos, clip) = await correct(keySinceInsert: true)
        #expect(result == .clipboardHint && undos == 0 && clip == "heute kommt Sorbal")
    }

    @Test func anotherAppInFrontNeverUndoes() async {
        let (result, undos, _) = await correct(keySinceInsert: false) { $0.front = "other.app" }
        #expect(result == .clipboardHint && undos == 0)
    }

    @Test func aFocusThatLeftTheTextFieldNeverUndoes() async {
        let (result, undos, _) = await correct(keySinceInsert: false) { $0.focus = .notTextField }
        #expect(result == .clipboardHint && undos == 0)
    }

    @Test func anUnreadableFieldUndoesOnlyWithCertaintyNoKeyCame() async {
        let (result, undos, _) = await correct(keySinceInsert: false)
        #expect(result == .undoReinserted && undos == 1, "K-35 way 2, only when the key watch says nothing came")
    }
}
