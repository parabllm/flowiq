// Group 5: insertion (A.8, R-019, R-020, G.1 "Insert", G.2 "Insert", Anhang F G10).
//  - focus probe first (deadline 50 ms): only a readable non-text focus prevents the insertion; an unreadable
//    field (Electron, web) is inserted;
//  - the old clipboard is saved completely, the text is offered as promise data, Cmd-V is posted, the old
//    clipboard comes back 100 ms after the app fetched (or after 2 s without a fetch) and ONLY if the change count
//    is still the one of the own write;
//  - nothing is written when there is nothing to put back, and the user's clipboard is never lost, on any path;
//  - no insertion into a non-text field or a secure input; the field's content is never stored or logged.
import Foundation
import Synchronization
import Testing
@testable import FlowIQCore
@testable import FlowIQInsert
@testable import FlowIQLog

@Suite(.timeLimit(.minutes(2)))
struct InsertionTests {
    private let text = "Das ist ein künstlicher Probesatz."

    @Test func happyPathPutsTheClipboardBackCompletely() async throws {
        let rig = try InsertRig(clipboard: richClipboard())
        defer { rig.remove() }
        let before = rig.pasteboard.items
        let result = await rig.insert(text)
        await rig.runOn()
        #expect(result == .landed)  // ASSUMPTION: InsertResult.landed
        #expect(rig.target.field == text)  // the dictation arrived, not the old clipboard
        #expect(rig.target.posted == ["paste"])
        #expect(rig.pasteboard.items == before)  // every item, every type, every byte
        #expect(rig.pasteboard.restores == 1)
        #expect(!rig.pasteboard.hasPromise)
        #expect(rig.pasteboard.writes == 1)
    }

    @Test func clipboardComesBackOnlyAfterTheAppFetchedPlus100ms() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.fetchDelay = .milliseconds(1_500) }  // an artificially slow target app
        let inserting = Task { await rig.inserter.insert(text) }  // ASSUMPTION: Inserter.insert(_:)
        await rig.clock.run(for: .milliseconds(1_000))
        #expect(rig.pasteboard.restores == 0, "clipboard returned before the app fetched the text")
        #expect(rig.pasteboard.hasPromise)
        #expect(rig.target.field.isEmpty)
        await rig.clock.run(for: .milliseconds(1_000))
        let result = await inserting.value
        await rig.runOn()
        #expect(result == .landed)  // ASSUMPTION: InsertResult.landed
        #expect(rig.target.field == text)
        let fetched = try #require(rig.pasteboard.fetchedAt)
        let restored = try #require(rig.pasteboard.restoredAt)
        let gap = (restored - fetched).ms
        #expect(gap >= 100 && gap <= 400, "clipboard returned \(gap) ms after the fetch")
    }

    @Test func withoutAFetchTheClipboardReturnsAfterTwoSecondsAndTheResultIsNotFetched() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.neverFetch = true }
        let before = rig.pasteboard.items
        let started = rig.clock.now.offset
        let result = await rig.insert(text, limit: .seconds(10))
        await rig.runOn()
        #expect(result == .notFetched)  // ASSUMPTION: InsertResult.notFetched
        #expect(rig.target.field.isEmpty)
        let restored = try #require(rig.pasteboard.restoredAt)
        let waited = (restored - started).ms
        #expect(waited >= 2_000 && waited <= 2_600, "clipboard returned after \(waited) ms")
        #expect(rig.pasteboard.items == before)
    }

    @Test func clipboardIsNotOverwrittenWhenTheUserCopiedMeanwhile() async throws {
        // Return only if the change count is still the one of the own write (G.1, G10).
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.fetchDelay = .milliseconds(20) }
        let inserting = Task { await rig.inserter.insert(text) }  // ASSUMPTION: Inserter.insert(_:)
        await rig.clock.run(for: .milliseconds(60))  // fetched at 20 ms, the return is due at 120 ms
        #expect(rig.target.field == text)
        rig.pasteboard.userCopies("etwas Neues, das der Nutzer gerade kopiert hat")
        let countAfterCopy = rig.pasteboard.changeCount
        _ = await inserting.value
        await rig.runOn()
        #expect(rig.pasteboard.restores == 0, "the user's new clipboard was overwritten by the old one")
        #expect(rig.pasteboard.changeCount == countAfterCopy)
        #expect(rig.pasteboard.items == [[FakePasteboard.plain: Data("etwas Neues, das der Nutzer gerade kopiert hat".utf8)]])
    }

    @Test func failedPasteStillReturnsTheClipboard() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.failPaste = true }
        let before = rig.pasteboard.items
        let result = await rig.insert(text)
        await rig.runOn()
        #expect(result == .failed)  // ASSUMPTION: InsertResult.failed
        #expect(rig.target.field.isEmpty)
        #expect(rig.pasteboard.items == before)
        #expect(!rig.pasteboard.hasPromise)  // no promise left behind that would paste later
    }

    @Test func unreadableOldClipboardMeansNothingIsWritten() async throws {
        // If the old content cannot be saved completely it must not be overwritten.
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.pasteboard.setFailSnapshot(true)
        let before = rig.pasteboard.items
        let count = rig.pasteboard.changeCount
        let result = await rig.insert(text)
        await rig.runOn()
        #expect(result == .failed)  // ASSUMPTION: InsertResult.failed
        #expect(rig.pasteboard.writes == 0)
        #expect(rig.pasteboard.changeCount == count)
        #expect(rig.pasteboard.items == before)
        #expect(rig.target.pasteCount == 0)
    }

    @Test func failedWriteLeavesTheClipboardUntouched() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.pasteboard.setFailWrite(true)
        let before = rig.pasteboard.items
        let result = await rig.insert(text)
        await rig.runOn()
        #expect(result == .failed)  // ASSUMPTION: InsertResult.failed
        #expect(rig.pasteboard.items == before)
        #expect(rig.target.pasteCount == 0)
    }

    @Test func noInsertionIntoANonTextField() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.kind = .nonText }
        let before = rig.pasteboard.items
        let count = rig.pasteboard.changeCount
        let result = await rig.insert(text)
        await rig.runOn()
        #expect(result == .noTextFocus)  // ASSUMPTION: InsertResult.noTextFocus
        #expect(rig.target.pasteCount == 0, "Cmd-V was posted into a non-text field")
        #expect(rig.pasteboard.writes == 0)
        #expect(rig.pasteboard.changeCount == count)  // the clipboard was not even touched
        #expect(rig.pasteboard.items == before)
        #expect(rig.target.field.isEmpty)
    }

    @Test func noInsertionIntoASecureInput() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.secure = true }
        let before = rig.pasteboard.items
        let result = await rig.insert(text)
        await rig.runOn()
        #expect(result == .secureInput)  // ASSUMPTION: InsertResult.secureInput
        #expect(rig.target.pasteCount == 0)
        #expect(rig.pasteboard.writes == 0)
        #expect(rig.pasteboard.items == before)
    }

    @Test func unreadableFieldIsInsertedNormally() async throws {
        // Electron and web fields cannot be read; only a readable NON-text field blocks the insertion.
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.kind = .unreadable }
        let result = await rig.insert(text)
        await rig.runOn()
        #expect(result == .landed)  // ASSUMPTION: InsertResult.landed
        #expect(rig.target.field == text)
    }

    @Test func aHangingFocusProbeIsCutOffAfter50Milliseconds() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        rig.target.configure { $0.probeHangs = true }  // the Bedienungshilfen call never answers
        let started = rig.clock.now.offset
        let result = await rig.insert(text, limit: .seconds(5))
        await rig.runOn()
        #expect(result == .landed)  // ASSUMPTION: InsertResult.landed; unreadable, so inserted
        let posted = try #require(rig.trace.first("keys.paste"))
        let waited = (posted.virtual - started).ms
        #expect(waited >= 50 && waited <= 100, "Cmd-V posted \(waited) ms after the start, deadline is 50 ms")
    }

    @Test func probeComesBeforeAnyClipboardAccess() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        _ = await rig.insert(text)
        await rig.runOn()
        let probe = try #require(rig.trace.first("focus.probe"))
        for name in ["pasteboard.snapshot", "pasteboard.write", "keys.paste"] {
            let later = try #require(rig.trace.first(name))
            #expect(probe.seq < later.seq, "\(name) before the focus probe")
        }
        let order = rig.trace.entries.map(\.name).filter { ["pasteboard.snapshot", "pasteboard.write", "keys.paste", "pasteboard.fetch", "pasteboard.restore"].contains($0) }
        #expect(order == ["pasteboard.snapshot", "pasteboard.write", "keys.paste", "pasteboard.fetch", "pasteboard.restore"])
    }

    @Test func insertionRunsOffTheMainThread() async throws {
        let rig = try InsertRig()
        defer { rig.remove() }
        _ = await rig.insert(text)
        await rig.runOn()
        #expect(rig.trace.entries.count >= 5)
        #expect(rig.trace.onMainThread.isEmpty, "on the main thread: \(rig.trace.onMainThread)")
    }

    @Test func twentyInsertionsInARowKeepExactlyOneSpaceBetweenThem() async throws {
        // R-020: 20 dictations directly one after another: 0 missing, 0 doubled spaces.
        let rig = try InsertRig(clipboard: [])
        defer { rig.remove() }
        let sentences = (1...20).map { "Satz Nummer \($0) ohne Besonderheit." }
        for sentence in sentences {
            let result = await rig.insert(sentence)
            #expect(result == .landed)  // ASSUMPTION: InsertResult.landed
            await rig.runOn(.milliseconds(300))
        }
        #expect(rig.target.field == sentences.joined(separator: " "))
        #expect(!rig.target.field.contains("  "))
    }

    @Test func noExtraSpaceAfterWhitespaceOrAtTheStart() async throws {
        let rig = try InsertRig(clipboard: [])
        defer { rig.remove() }
        rig.target.configure { $0.field = "Zeile eins\n" }
        _ = await rig.insert("zeile zwei")
        await rig.runOn()
        #expect(rig.target.field == "Zeile eins\nzeile zwei")
        rig.target.configure { $0.field = "Wort " }
        _ = await rig.insert("weiter")
        await rig.runOn()
        #expect(rig.target.field == "Wort weiter")
    }

    @Test func fieldContentAndDictationAreNeverLogged() async throws {
        // A.8 and G.2: the content of foreign fields is only compared, never stored or logged; the protocol is text-free.
        let rig = try InsertRig(clipboard: [])
        defer { rig.remove() }
        rig.target.configure { $0.field = "GEHEIMES-FELD-93 " }
        let secret = "Prueflingswort-Quarz"
        let result = await rig.insert("Ein Satz mit \(secret) darin.")
        await rig.runOn()
        #expect(result == .landed)  // ASSUMPTION: InsertResult.landed
        let logged = await rig.scratch.logText()
        #expect(!logged.contains("GEHEIMES-FELD-93"))
        #expect(!logged.contains(secret))
        let events = await rig.scratch.events("insert_result")
        #expect(events.count == 1)  // one result event per insertion (A.2)
        #expect(events.first?.fields["result"] == "landed")  // ASSUMPTION: insert_result carries the InsertResult raw value in `result`
    }

    @Test func everyResultIsLoggedOncePerInsertion() async throws {
        let rig = try InsertRig(clipboard: [])
        defer { rig.remove() }
        rig.target.configure { $0.kind = .nonText }
        _ = await rig.insert("eins")
        rig.target.configure { $0.kind = .text; $0.secure = true }
        _ = await rig.insert("zwei")
        rig.target.configure { $0.secure = false; $0.neverFetch = true }
        _ = await rig.insert("drei", limit: .seconds(10))
        await rig.runOn()
        let results = await rig.scratch.events("insert_result").map { $0.fields["result"] ?? "?" }  // ASSUMPTION: field `result`
        #expect(results == ["noTextFocus", "secureInput", "notFetched"])  // ASSUMPTION: raw values equal the case names
    }
}
