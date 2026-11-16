// R-117: with keepText the dictation's final text stays on the clipboard after every insertion (landed or not),
// so Cmd-V inserts it again; without it the old clipboard comes back in full (A.8, R-019).
import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQInsert

final class Board: PasteboardPort, KeyPosting, FocusProbing, FrontAppProbing, Sendable {
    struct State { var items: [[String: Data]] = [["public.utf8-plain-text": Data("alt".utf8)]]; var count = 1
        var promise: (@Sendable () -> Void)?; var fetches = true
        var focus = FocusState.textField(preceding: nil), secure = false, snapshotFails = false, pasteFails = false }
    let state = Mutex(State())
    var changeCount: Int { state.withLock { $0.count } }
    var text: String? {
        state.withLock { $0.items.first?["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } }
    }
    func snapshot() throws -> PasteboardSnapshot {
        if state.withLock({ $0.snapshotFails }) { throw InsertError.unsupported }
        return PasteboardSnapshot(items: state.withLock { $0.items })
    }
    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int {
        state.withLock { s in s.count += 1; s.items = [["public.utf8-plain-text": Data(text.utf8)]]; s.promise = onFetch
            return s.count }
    }
    func writePlain(_ text: String) throws -> Int {
        state.withLock { s in s.count += 1; s.items = [["public.utf8-plain-text": Data(text.utf8)]]; return s.count }
    }
    func restore(_ snapshot: PasteboardSnapshot) throws { state.withLock { $0.count += 1; $0.items = snapshot.items } }
    func paste() throws {
        if state.withLock({ $0.pasteFails }) { throw InsertError.unsupported }
        if let fire = state.withLock({ $0.fetches ? $0.promise : nil }) { fire() } }
    func undo() throws {}
    func probe() async -> FocusState { state.withLock { $0.focus } }
    func frontmost() -> String? { "test.app" }
    var secureInputActive: Bool { state.withLock { $0.secure } }
}

func remove(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try FileManager.default.removeItem(at: url) } catch { Issue.record("cleanup: \(error)") }
}

struct KeepInClipboardTests {
    func run(keep: Bool, fetches: Bool, _ setup: @Sendable (inout Board.State) -> Void = { _ in }) async throws
        -> (InsertResult, String?) {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-keep-\(UUID().uuidString)")
        defer { remove(root) }
        let board = Board()
        board.state.withLock {
            $0.fetches = fetches
            setup(&$0)
        }
        let fs = SafeFS(confinedTo: root)
        let inserter = Inserter(focus: board, pasteboard: board, keys: board, front: board, clock: ContinuousClock(),
                                log: EventLog(directory: root, fs: fs), keepText: keep)
        let result = await inserter.insert("Diktat")
        await inserter.settled()
        return (result, board.text)
    }

    @Test func onTheTextStaysAfterALandedInsertion() async throws {
        #expect(try await run(keep: true, fetches: true) == (.landed, "Diktat"))
    }

    @Test func onTheTextStaysWhenNothingWasFetched() async throws {
        #expect(try await run(keep: true, fetches: false) == (.notFetched, "Diktat"))
    }

    @Test func offTheOldClipboardComesBack() async throws {
        #expect(try await run(keep: false, fetches: true) == (.landed, "alt"))
        #expect(try await run(keep: false, fetches: false) == (.notFetched, "alt"))
    }

    /// Review 15.11. (d): no text field, secure input, unreadable clipboard, failing Cmd-V, in both settings.
    @Test func onTheTextStaysAlsoWhenNothingWasPasted() async throws {
        #expect(try await run(keep: true, fetches: true) { $0.focus = .notTextField } == (.noTextFocus, "Diktat"))
        #expect(try await run(keep: true, fetches: true) { $0.secure = true } == (.secureInput, "Diktat"))
        #expect(try await run(keep: true, fetches: true) { $0.snapshotFails = true } == (.failed, "Diktat"))
        #expect(try await run(keep: true, fetches: true) { $0.pasteFails = true } == (.failed, "Diktat"))
    }

    @Test func offTheOldClipboardStaysWhenNothingWasPasted() async throws {
        #expect(try await run(keep: false, fetches: true) { $0.focus = .notTextField } == (.noTextFocus, "alt"))
        #expect(try await run(keep: false, fetches: true) { $0.secure = true } == (.secureInput, "alt"))
        #expect(try await run(keep: false, fetches: true) { $0.snapshotFails = true } == (.failed, "alt"))
        #expect(try await run(keep: false, fetches: true) { $0.pasteFails = true } == (.failed, "alt"))
    }
}
