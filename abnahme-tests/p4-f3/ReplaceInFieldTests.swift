// Group F3-2: replacing the corrected text in the target field (ARCHITEKTUR N.2 point 3, R-110; Anhang I addition to
// `InsertionTests`). Three ways, strictly in this order:
//   1. field readable and the inserted text still stands there unchanged -> exactly that range is replaced
//      (no keys posted, the user's clipboard untouched);
//   2. otherwise, if no key was typed since the insertion and the target app is in front -> Cmd-Z, then the corrected
//      WHOLE text is inserted again (Cmd-V), clipboard restored as for any insertion;
//   3. otherwise the corrected whole text lands on the clipboard with a hint; nothing is posted.
// Field content is only compared, never stored (R-021, A.8).
import Foundation
import Testing
@testable import FlowIQCore
@testable import FlowIQInsert

@Suite(.timeLimit(.minutes(2)))
struct ReplaceInFieldTests {
    private let original = "wir treffen uns morgen"
    private let corrected = "wir treffen uns übermorgen"

    /// Character range of "morgen" inside the inserted text.
    private let word = 16..<22

    @Test func readableFieldGetsExactlyTheRangeReplaced() async throws {
        let rig = try InsertRig(field: "Hallo ", clipboard: richClipboard())
        defer { rig.remove() }
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        let clipboard = rig.pasteboard.items
        let writesBefore = rig.pasteboard.writes
        let result = await rig.replace(word, with: "übermorgen")  // ASSUMPTION: assumed API, see the Support header
        #expect(result == .fieldReplaced)  // ASSUMPTION: ReplaceResult.fieldReplaced
        #expect(rig.target.field == "Hallo " + corrected)
        #expect(rig.target.replaced == [22..<28])  // "Hallo " is 6 characters: the range moves by the text before the insertion
        #expect(rig.target.posted == ["paste"], "no key for an in-field replacement")
        #expect(rig.pasteboard.items == clipboard)
        #expect(rig.pasteboard.writes == writesBefore, "the clipboard was written although the field was edited directly")
    }

    @Test func rangesCountCharactersNotBytes() async throws {
        let rig = try InsertRig(field: "")
        defer { rig.remove() }
        let text = "Größe 👍 für uns"  // ö, ß, an emoji and ü: several bytes per character
        _ = await rig.insert(text)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        let start = text.distance(from: text.startIndex, to: text.range(of: "für")!.lowerBound)
        let result = await rig.replace(start..<(start + 3), with: "vor")  // ASSUMPTION: assumed API, see the Support header
        #expect(result == .fieldReplaced)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.field == "Größe 👍 vor uns")
    }

    @Test func fieldTextChangedMeanwhileWithoutAKeyTakesTheUndoWay() async throws {
        let rig = try InsertRig(field: "Hallo ")
        defer { rig.remove() }
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        rig.target.mutateSilently(6..<7, with: "W")  // an app-side autocorrect inside the inserted text: no key event
        let result = await rig.replace(word, with: "übermorgen")  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        #expect(result == .undoReinserted)  // ASSUMPTION: ReplaceResult.undoReinserted
        #expect(rig.target.replaced.isEmpty, "the field was edited in place although the inserted text no longer stood there unchanged")
        #expect(rig.target.posted == ["paste", "undo", "paste"])
        #expect(rig.target.field == "Hallo " + corrected, "the corrected WHOLE text is inserted again")
    }

    @Test func unreadableFieldTakesTheUndoWayWhenNoKeyWasTyped() async throws {
        let rig = try InsertRig(field: "", clipboard: richClipboard())
        defer { rig.remove() }
        rig.target.setKind(.unreadable)  // Electron or web field: accessibility gives no value
        let clipboard = rig.pasteboard.items
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        let result = await rig.replace(word, with: "übermorgen", keySinceInsert: false)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        #expect(result == .undoReinserted)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.posted == ["paste", "undo", "paste"])
        #expect(rig.target.field == corrected)
        #expect(rig.pasteboard.items == clipboard, "the user's clipboard must be back after the second insertion too")
    }

    @Test func aFieldEditFailureFallsBackWithoutLosingTheText() async throws {
        let rig = try InsertRig(field: "")
        defer { rig.remove() }
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        rig.target.setFailReplace(true)  // the accessibility write is refused
        let result = await rig.replace(word, with: "übermorgen")  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        #expect(result == .undoReinserted || result == .clipboardHint)  // ASSUMPTION: assumed API, see the Support header
        let landed = rig.target.field == corrected
        let onClipboard = rig.pasteboard.plainText == corrected
        #expect(landed || onClipboard, "the corrected text is neither in the field nor on the clipboard")
    }

    @Test func aKeyTypedSinceTheInsertionLeavesOnlyTheClipboardWay() async throws {
        let rig = try InsertRig(field: "")
        defer { rig.remove() }
        rig.target.setKind(.unreadable)
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        let result = await rig.replace(word, with: "übermorgen", keySinceInsert: true)  // ASSUMPTION: assumed API, see the Support header
        #expect(result == .clipboardHint)  // ASSUMPTION: ReplaceResult.clipboardHint
        #expect(rig.target.posted == ["paste"], "Cmd-Z or Cmd-V posted although the user typed on")
        #expect(rig.pasteboard.plainText == corrected, "the corrected whole text must be on the clipboard")
        #expect(rig.target.field == original, "the field is not touched")
    }

    @Test func anotherAppInFrontLeavesOnlyTheClipboardWay() async throws {
        let rig = try InsertRig(field: "")
        defer { rig.remove() }
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        rig.target.setFront("app.other")
        let result = await rig.replace(word, with: "übermorgen")  // ASSUMPTION: assumed API, see the Support header
        #expect(result == .clipboardHint)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.posted == ["paste"])
        #expect(rig.target.replaced.isEmpty)
        #expect(rig.pasteboard.plainText == corrected)
    }

    @Test func secureInputIsNeverWrittenInto() async throws {
        let rig = try InsertRig(field: "")
        defer { rig.remove() }
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        rig.target.setSecure(true)
        let result = await rig.replace(word, with: "übermorgen")  // ASSUMPTION: assumed API, see the Support header
        #expect(result == .clipboardHint)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.posted == ["paste"])
        #expect(rig.target.replaced.isEmpty)
    }

    @Test func withoutAnInsertionThereIsNothingToReplace() async throws {
        let rig = try InsertRig(field: "fremder Text")
        defer { rig.remove() }
        let result = await rig.replace(0..<3, with: "xyz")  // ASSUMPTION: assumed API, see the Support header
        #expect(result == .nothingToReplace)  // ASSUMPTION: ReplaceResult.nothingToReplace
        #expect(rig.target.field == "fremder Text")
        #expect(rig.target.posted.isEmpty)
        #expect(rig.pasteboard.writes == 0)
    }

    @Test func aReplacementNeverTouchesTextOutsideTheInsertion() async throws {
        let rig = try InsertRig(field: "Vorher steht hier etwas. ")
        defer { rig.remove() }
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        rig.target.mutateSilently(rig.target.field.count..<rig.target.field.count, with: " Danach kommt anderes.")
        let result = await rig.replace(word, with: "übermorgen")  // ASSUMPTION: assumed API, see the Support header
        #expect(result == .fieldReplaced)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.field == "Vorher steht hier etwas. " + corrected + " Danach kommt anderes.")
    }

    @Test func fieldContentIsComparedNeverStored() async throws {
        let secret = "Zugangswort-Kolibri-4711"
        let rig = try InsertRig(field: secret + " ")
        defer { rig.remove() }
        _ = await rig.insert(original)  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        _ = await rig.replace(word, with: "übermorgen")  // ASSUMPTION: assumed API, see the Support header
        await rig.settle()
        let log = await rig.scratch.logText()
        #expect(!log.contains(secret), "field content in the protocol")
        #expect(!rig.scratch.everythingAsText().contains(secret), "field content stored below the data folder")
    }
}
