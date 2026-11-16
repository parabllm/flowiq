// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 6: "Rohfassung einfügen" (A.8, R-034): replaces the last insertion by the recognizer text, unchanged by any
// stage, only if the target app is still in front and no key was typed since the insertion; it counts as a
// rejection of all interventions of that dictation in the journal. No system sound, no window to the front.
import Foundation
import Testing
@testable import FlowIQCore
@testable import FlowIQInput
@testable import FlowIQInsert

@Suite(.timeLimit(.minutes(2)))
struct RawVersionTests {
    private let spoken = "das ist flowiq und napiq ein probesatz"
    private let stage = "das ist FlowIQ und NapIQ ein probesatz"

    @Test func replacesTheLastInsertionWithTheUnchangedRecognizerText() async throws {
        let rig = try DictationRig(clipboard: richClipboard())
        defer { rig.remove() }
        let clipboard = rig.pasteboard.items
        rig.recognizer.script([spoken])
        await rig.dictate()
        #expect(rig.target.field == stage)
        #expect(rig.target.posted == ["paste"])

        let coordinator = rig.coordinator
        let result = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: FlowCoordinator.insertRawVersion() async -> RawResult
        #expect(result == .inserted)  // ASSUMPTION: RawResult.inserted
        #expect(rig.target.posted == ["paste", "undo", "paste"])  // Cmd-V, then Cmd-Z, then Cmd-V with the raw text
        #expect(rig.target.field == spoken, "raw text must be exactly what the recognizer heard")
        #expect(rig.pasteboard.items == clipboard)  // the user's clipboard is back after the raw insertion too
        #expect(rig.target.undoCount == 1)
    }

    @Test func countsAsRejectionOfAllInterventionsInTheJournal() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        rig.recognizer.script([spoken])
        await rig.dictate()
        let id = try #require(rig.scratch.journal().ids().first)
        let coordinator = rig.coordinator
        _ = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()

        let lines = rig.scratch.journal().lines(of: id)
        let rejects = lines.filter { $0.event == JE.reject }
        #expect(rejects.count == 1)
        #expect(rejects.first?.number(JK.rejected) == 2)  // R1 for flowiq and R1 for napiq
        let recognized = try #require(lines.first { $0.event == JE.recognized })
        #expect(recognized.string(JK.recognizerText) == spoken)  // the raw text came from here, not from the stage
        #expect(recognized.string(JK.finalText) == stage)  // what was first inserted stays on record
        #expect(lines.map(\.event) == [JE.begin, JE.audio, JE.recognized, JE.inserted, JE.reject])  // appended, nothing rewritten
    }

    @Test func refusedWhenAKeyWasTypedSinceTheInsertion() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        rig.recognizer.script([spoken])
        await rig.dictate()
        rig.key(.other, down: true)  // the user types on
        rig.key(.other, down: false)
        let coordinator = rig.coordinator
        let result = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()
        #expect(result == .refused(.keyTyped))  // ASSUMPTION: RawResult.refused(RawRefusal) with RawRefusal.keyTyped
        #expect(rig.target.undoCount == 0, "Cmd-Z posted although the user had typed")
        #expect(rig.target.field == stage)
        #expect(!rig.scratch.journal().contains { $0.event == JE.reject })
    }

    @Test func refusedWhenAnotherAppIsInFront() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        rig.recognizer.script([spoken])
        await rig.dictate()
        rig.target.configure { $0.frontApp = "app.other" }
        let coordinator = rig.coordinator
        let result = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()
        #expect(result == .refused(.appChanged))  // ASSUMPTION: RawRefusal.appChanged
        #expect(rig.target.undoCount == 0)
        #expect(rig.target.pasteCount == 1)
        #expect(!rig.scratch.journal().contains { $0.event == JE.reject })
    }

    @Test func refusedWithoutAnyInsertionToReplace() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        let coordinator = rig.coordinator
        let fresh = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()
        #expect(fresh == .refused(.nothingToReplace))  // ASSUMPTION: RawRefusal.nothingToReplace

        // A dictation that was not inserted (no text field) has nothing to undo either.
        rig.target.configure { $0.kind = .nonText }
        await rig.dictate()
        let notInserted = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()
        #expect(notInserted == .refused(.nothingToReplace))  // ASSUMPTION: RawRefusal.nothingToReplace
        #expect(rig.target.undoCount == 0)
        #expect(rig.target.pasteCount == 0)
    }

    @Test func worksOnlyOncePerInsertion() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        rig.recognizer.script([spoken])
        await rig.dictate()
        let coordinator = rig.coordinator
        let first = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()
        #expect(first == .inserted)  // ASSUMPTION: RawResult.inserted
        let second = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()
        #expect(second == .refused(.nothingToReplace))  // ASSUMPTION: RawRefusal.nothingToReplace
        #expect(rig.target.undoCount == 1)
        #expect(rig.target.field == spoken)
        #expect(rig.scratch.journal().filter { $0.event == JE.reject }.count == 1)
    }

    @Test func noSoundAndNoWindowToTheFront() async throws {
        // R-018 at the seam: the only things posted are Cmd-V and Cmd-Z, the front app is asked, never changed.
        let rig = try DictationRig()
        defer { rig.remove() }
        rig.recognizer.script([spoken])
        await rig.dictate()
        let coordinator = rig.coordinator
        _ = await rig.drive { await coordinator.insertRawVersion() }  // ASSUMPTION: insertRawVersion()
        #expect(Set(rig.target.posted).isSubset(of: ["paste", "undo"]))
        #expect(rig.target.frontmost() == "app.target")  // ASSUMPTION: FrontAppProbing.frontmost()
    }
}
