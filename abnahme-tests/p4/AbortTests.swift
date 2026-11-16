// Group 8: abort and failure (R-019, R-022, Leitsatz 5 "nie still", Panotti finding: audio was lost). Escape, a
// chord abort in the development profile, a failing recognizer, a refusing microphone and a failing insertion all
// end the same way: no text is inserted unasked, the clipboard is untouched, the audio file and the journal stay,
// the pill shows a mark or goes out, the next dictation works.
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQInput
@testable import FlowIQInsert
@testable import FlowIQRecording

@Suite(.timeLimit(.minutes(3)))
struct AbortTests {
    @Test func escapeInsertsNothingAndKeepsAudioAndJournal() async throws {
        let rig = try DictationRig(clipboard: richClipboard())
        defer { rig.remove() }
        let clipboard = rig.pasteboard.items
        let count = rig.pasteboard.changeCount
        let sources = rig.mics.all.count
        rig.press()
        #expect(await rig.awaitMicOpen(after: sources))
        let spoken = await rig.speak(0.8)
        let source = try #require(rig.mics.current)
        rig.key(.escape, down: true)
        #expect(await rig.settle())
        rig.key(.trigger, down: false)  // the release after the cancel is silent
        #expect(await rig.settle())

        #expect(rig.target.field.isEmpty)
        #expect(rig.target.pasteCount == 0)
        #expect(rig.pasteboard.writes == 0)
        #expect(rig.pasteboard.changeCount == count)
        #expect(rig.pasteboard.items == clipboard)
        #expect(source.counts.stopsBegun == 1)  // the microphone is released
        #expect(await rig.busy.reasons.isEmpty)
        #expect(rig.pill.last == .hidden)  // ASSUMPTION: PillState.hidden

        let journal = rig.scratch.journal()
        let id = try #require(journal.ids().first)
        let lines = journal.lines(of: id)
        #expect(lines.first?.event == JE.begin)
        let audio = try #require(lines.first { $0.event == JE.audio })
        #expect(audio.string(JK.endReason) == EndReason.escape.rawValue)
        #expect((audio.number(JK.bytes) ?? 0) >= 4_000 * 0.8)
        #expect(!lines.contains { $0.event == JE.inserted })
        let file = try #require(rig.scratch.audioFile(for: id))
        #expect(abs(try audioDuration(file) - seconds(of: spoken)) <= 0.1)  // everything up to the Escape is kept

        // The next dictation works at once.
        let next = await rig.dictate()
        #expect(next.finished)
        #expect(rig.target.pasteCount == 1)
    }

    @Test func recognizerFailureInsertsNothingButKeepsTheAudio() async throws {
        var options = StubRecognizer.Options()
        options.fail = true
        let rig = try DictationRig(recognizer: options, clipboard: richClipboard())
        defer { rig.remove() }
        let clipboard = rig.pasteboard.items
        let outcome = await rig.dictate(seconds: 1.0)
        #expect(outcome.finished)

        #expect(rig.target.field.isEmpty)
        #expect(rig.pasteboard.writes == 0 && rig.pasteboard.items == clipboard)
        #expect(await rig.scratch.errorEvents() > 0)  // never silent: an error line in fehler.ndjson
        #expect(rig.pill.last == .failed || rig.pill.last == .notInserted)  // ASSUMPTION: PillState.failed, .notInserted: a mark, not just gone
        let id = try #require(rig.scratch.journal().ids().first)
        let lines = rig.scratch.journal().lines(of: id)
        let audio = try #require(lines.first { $0.event == JE.audio })
        #expect((audio.number(JK.bytes) ?? 0) >= 4_000 * 1.0)
        #expect(audio.string(JK.verdict) == SizeVerdict.ok.rawValue)
        #expect(!lines.contains { $0.event == JE.inserted })
        #expect(rig.scratch.audioFile(for: id) != nil)
        #expect(await rig.busy.reasons.isEmpty)

        rig.recognizer.set(StubRecognizer.Options())  // the next dictation is fine again
        let next = await rig.dictate()
        #expect(next.finished)
        #expect(rig.target.pasteCount == 1)
    }

    @Test func microphoneThatRefusesToStartEndsCleanly() async throws {
        var refusing = P4Mic.Options()
        refusing.refuseStart = true
        let rig = try DictationRig(mic: refusing)
        defer { rig.remove() }
        let sources = rig.mics.all.count
        rig.press()
        #expect(await rig.awaitMicOpen(after: sources))
        #expect(await rig.settle())
        rig.key(.trigger, down: false)
        #expect(await rig.settle())

        #expect(rig.target.pasteCount == 0)
        #expect(await rig.scratch.errorEvents() > 0)
        #expect(rig.pill.last == .failed || rig.pill.last == .notInserted)  // ASSUMPTION: PillState.failed, .notInserted
        #expect(!(rig.pill.changes.last.map { $0.state == .dictating } ?? false))  // ASSUMPTION: PillState.dictating; never stuck red
        #expect(await rig.busy.reasons.isEmpty)
        #expect(rig.scratch.journal().contains { $0.event == JE.begin })  // the attempt is on record

        rig.mics.set(P4Mic.Options())
        let next = await rig.dictate()
        #expect(next.finished)
        #expect(rig.target.pasteCount == 1)
        #expect(rig.pill.last == .hidden)  // ASSUMPTION: PillState.hidden
    }

    @Test func chordAbortInTheDevelopmentProfileKeepsAudioAndCountsSeparately() async throws {
        let rig = try DictationRig(profile: .development, clipboard: richClipboard())
        defer { rig.remove() }
        let clipboard = rig.pasteboard.items
        let sources = rig.mics.all.count
        rig.press()
        #expect(await rig.awaitMicOpen(after: sources))
        let spoken = await rig.speak(0.6)
        rig.key(.other, down: true)  // a second key while the trigger is held
        rig.key(.other, down: false)
        #expect(await rig.settle())
        rig.key(.trigger, down: false)
        #expect(await rig.settle())

        #expect(rig.target.field.isEmpty)
        #expect(rig.pasteboard.writes == 0 && rig.pasteboard.items == clipboard)
        #expect(await rig.scratch.events("chord_abort").count == 1)  // counted on its own, excluded from the numbers (R-015)
        let id = try #require(rig.scratch.journal().ids().first)
        let lines = rig.scratch.journal().lines(of: id)
        #expect(!lines.contains { $0.event == JE.inserted })
        let file = try #require(rig.scratch.audioFile(for: id))
        #expect(abs(try audioDuration(file) - seconds(of: spoken)) <= 0.1)
        #expect(rig.pill.last == .hidden)  // ASSUMPTION: PillState.hidden
        #expect(await rig.busy.reasons.isEmpty)

        let next = await rig.dictate()
        #expect(next.finished)
        #expect(await rig.scratch.events("chord_abort").count == 1)  // a normal dictation adds none
    }

    @Test func noTextFieldMarksThePillAndTheTextCanBeFetchedWithTheShortcut() async throws {
        // R-019: without a text field no "inserted"; the text is retrievable with Ctrl-Cmd-V, a mark sits on the pill.
        let rig = try DictationRig(clipboard: richClipboard())
        defer { rig.remove() }
        let clipboard = rig.pasteboard.items
        rig.target.configure { $0.kind = .nonText }
        rig.recognizer.script(["das ist flowiq probesatz eins"])
        let outcome = await rig.dictate()
        #expect(outcome.finished)
        #expect(rig.target.field.isEmpty && rig.target.pasteCount == 0)
        #expect(rig.pill.last == .notInserted)  // ASSUMPTION: PillState.notInserted
        #expect(rig.pasteboard.items == clipboard && rig.pasteboard.writes == 0)
        let id = try #require(rig.scratch.journal().ids().first)
        let first = try #require(rig.scratch.journal().lines(of: id).last { $0.event == JE.inserted })
        #expect(first.string(JK.result) == "noTextFocus")  // ASSUMPTION: the `inserted` line carries the result even when nothing was inserted

        rig.target.configure { $0.kind = .text }
        rig.key(.v, down: true, modifiers: [.control, .option, .command])  // development profile: the shortcut has the option key too
        rig.key(.v, down: false, modifiers: [.control, .option, .command])
        #expect(await rig.run(until: { rig.target.pasteCount == 1 }))
        await rig.clock.run(for: .seconds(1))
        #expect(rig.target.field == "das ist FlowIQ probesatz eins")  // the final text of that dictation
        #expect(rig.pasteboard.items == clipboard)
        #expect(rig.pill.last == .hidden)  // ASSUMPTION: PillState.hidden; the mark is cleared once inserted
        let results = rig.scratch.journal().lines(of: id).filter { $0.event == JE.inserted }.map { $0.string(JK.result) }
        #expect(results == ["noTextFocus", "landed"])  // ASSUMPTION: every attempt appends its own `inserted` line
    }

    @Test func failedInsertionReturnsTheClipboardAndKeepsTheTextRetrievable() async throws {
        let rig = try DictationRig(clipboard: richClipboard())
        defer { rig.remove() }
        let clipboard = rig.pasteboard.items
        rig.target.configure { $0.failPaste = true }
        rig.recognizer.script(["das ist flowiq probesatz zwei"])
        let outcome = await rig.dictate()
        #expect(outcome.finished)
        #expect(rig.target.field.isEmpty)
        #expect(rig.pasteboard.items == clipboard)  // returned although the paste failed
        #expect(!rig.pasteboard.hasPromise)
        #expect(rig.pill.last == .notInserted)  // ASSUMPTION: PillState.notInserted

        rig.target.configure { $0.failPaste = false }
        let coordinator = rig.coordinator
        let again = await rig.drive { await coordinator.reinsertLast() }  // ASSUMPTION: FlowCoordinator.reinsertLast() async -> InsertResult
        #expect(again == .landed)  // ASSUMPTION: InsertResult.landed
        #expect(rig.target.field == "das ist FlowIQ probesatz zwei")
        #expect(rig.pasteboard.items == clipboard)
    }
}
