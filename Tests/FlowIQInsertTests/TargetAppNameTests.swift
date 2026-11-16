// 16.11.: the history names the app a dictation went to. The inserter hands on the frontmost app's name at
// the moment of the paste, next to the process identity it compares; a probe without names gives none.
import FlowIQCore
import FlowIQLog
import Foundation
import Testing
@testable import FlowIQInsert

struct TargetAppNameTests {
    struct Named: FrontAppProbing {
        let name: String?
        func frontmost() -> String? { "pid-7" }
        func frontmostName() -> String? { name }
        var secureInputActive: Bool { false }
    }

    func insert(front: any FrontAppProbing, focus: FocusState = .textField(preceding: nil)) async -> InsertOutcome {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-target-\(UUID().uuidString)")
        defer { remove(root) }
        let board = Board()
        board.state.withLock { $0.focus = focus }
        let inserter = Inserter(focus: board, pasteboard: board, keys: board, front: front, clock: ContinuousClock(),
                                log: EventLog(directory: root, fs: SafeFS(confinedTo: root)))
        let outcome = await inserter.insertTimed("Diktat")
        await inserter.settled()
        return outcome
    }

    @Test func landedInsertionCarriesTheAppNameAndKeepsTheIdentity() async {
        let outcome = await insert(front: Named(name: "Notizen"))
        #expect(outcome.result == .landed && outcome.appName == "Notizen" && outcome.frontApp == "pid-7")
    }

    @Test func noTextFieldStillNamesTheAppInFront() async {
        let outcome = await insert(front: Named(name: "Finder"), focus: .notTextField)
        #expect(outcome.result == .noTextFocus && outcome.appName == "Finder")
    }

    @Test func probeWithoutNamesGivesNoName() async {
        let outcome = await insert(front: Board())
        #expect(outcome.result == .landed && outcome.appName == nil && outcome.frontApp == "test.app")
    }
}
