// Crash of 16.11. (stack overflow on the tap thread after 2 h 20 min, 12 369 frames, about 6 175 thunk pairs):
// the handler in a bare `Mutex<closure?>` got two reabstraction thunks more at every `withLock`, so every key ran
// one level deeper. The handler must sit at the same stack depth for the first key and for every later one, and
// the input hands its source a handler only once however often the app asks it to start.
import CoreGraphics
import FlowIQCore
import FlowIQLog
import Foundation
import Synchronization
import Testing
@testable import FlowIQInput

/// The stack address of a local one call below the caller: the same for every call at the same depth.
@inline(never) func stackMark() -> UInt {
    var mark = 0
    return withUnsafeMutablePointer(to: &mark) { UInt(bitPattern: $0) }
}

private struct Boxed: Sendable { let call: @Sendable () -> Void }

private final class CountingSource: KeyEventSource, Sendable {
    let starts = Mutex(0)
    func start(_ handler: @escaping @Sendable (KeyEvent) -> Void) throws { starts.withLock { $0 += 1 } }
    func stop() {}
}

private struct Quiet: PillSink { func set(_ state: PillState) {} }

struct TapHandlerChainTests {
    /// The mechanism: a bare closure in a `Mutex` sinks deeper with every read, the same closure in a struct does
    /// not. Should Swift ever stop wrapping, the first expectation fails and the check.sh pattern may go.
    @Test func aBareClosureInAMutexSinksWithEveryReadOneInAStructDoesNot() {
        let seen = Mutex<[UInt]>([])
        let probe: @Sendable () -> Void = { let mark = stackMark(); seen.withLock { $0.append(mark) } }
        let bare = Mutex<(@Sendable () -> Void)?>(probe), boxed = Mutex<Boxed?>(Boxed(call: probe))
        for _ in 0..<200 { bare.withLock { $0 }?() }
        let sinking = seen.withLock { list in defer { list = [] }; return list }
        for _ in 0..<200 { boxed.withLock { $0 }?.call() }
        #expect(Set(sinking).count == 200, "every read of the bare closure one level deeper")
        #expect(Set(seen.withLock { $0 }).count == 1)
    }

    @Test func theTapRunsTheHandlerAtTheSameStackDepthForEveryKey() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-tap-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
            }
        }
        let context = TapContext(profile: .development, log: EventLog(directory: root, fs: SafeFS(confinedTo: root)))
        let seen = Mutex<[UInt]>([])
        context.handler.withLock { $0 = Handler { _ in let mark = stackMark(); seen.withLock { $0.append(mark) } } }
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        for _ in 0..<1000 { context.receive(.keyDown, key) }
        let marks = seen.withLock { $0 }
        #expect(marks.count == 1000)
        #expect(Set(marks).count == 1, "grew by \(Int(marks.first ?? 0) - Int(marks.last ?? 0)) bytes in 1000 keys")
    }

    @Test func startingTheInputAgainNeverHandsTheSourceASecondHandler() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-start-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
            }
        }
        let source = CountingSource()
        let input = InputService(source: source, profile: .development, clock: ContinuousClock(), pill: Quiet(),
                                 log: EventLog(directory: root, fs: SafeFS(confinedTo: root)))
        for _ in 0..<1000 { try input.start() }
        #expect(source.starts.withLock { $0 } == 1)
        input.stop()
        try input.start()
        #expect(source.starts.withLock { $0 } == 2)
    }
}
