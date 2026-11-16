import Foundation
import Testing
@testable import FlowIQCore

/// Paket V helpers: `Latch`, `within`, `Clock.pause`.
struct WaitingTests {
    struct Boom: Error {}

    @Test func aLatchFiresOnceForWaitersBeforeAndAfter() async {
        let latch = Latch<Int>()
        async let early = latch.wait()
        _ = await ContinuousClock().pause(.milliseconds(20))
        #expect(latch.fire(1))
        #expect(!latch.fire(2), "the first value stays")
        #expect(await early == 1)
        #expect(await latch.wait() == 1 && latch.value == 1)
    }

    @Test func aCancelledWaiterGetsNilAndTheLatchStaysOpenForOthers() async {
        let latch = Latch<Int>()
        let waiter = Task { await latch.wait() }
        _ = await ContinuousClock().pause(.milliseconds(20))
        waiter.cancel()
        #expect(await waiter.value == nil)
        latch.fire(3)
        #expect(await latch.wait() == 3)
    }

    @Test func withinReturnsTheWorkOrNilAtTheLimit() async throws {
        #expect(await within(.seconds(5)) { 7 } == 7)
        let hanging = Latch<Int>()
        #expect(await within(.milliseconds(30)) { await hanging.wait() } == nil)
        await #expect(throws: Boom.self) { try await within(.seconds(5)) { () throws(Boom) -> Int in throw Boom() } }
        let started = ContinuousClock.now
        _ = await within(.milliseconds(30)) {  // ignores cancellation, ends after 1 s
            await withCheckedContinuation { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { done.resume() }
            }
        }
        #expect(ContinuousClock.now - started < .milliseconds(500), "work ignoring cancellation never holds the caller")
    }

    @Test func pauseIsFalseWhenCancelled() async {
        #expect(await ContinuousClock().pause(.milliseconds(1)))
        let sleeper = Task { await ContinuousClock().pause(.seconds(30)) }
        sleeper.cancel()
        #expect(await sleeper.value == false)
    }
}

/// First real run 16.11.: the live link of a profile is an allowed file on its own, its fresh sibling is not listed.
struct LiveLinkAloneTests {
    @Test func aLinkThatLivesAloneMovesAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
        let link = root.appending(path: "live.md"), fs = SafeFS(files: [link])
        for name in ["a.md", "b.md"] {
            try fs.link(link, to: root.appending(path: name))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path).hasSuffix(name))
        }
        #expect(throws: SafeFS.Denied.self) { try fs.link(root.appending(path: "other.md"), to: link) }
    }
}
