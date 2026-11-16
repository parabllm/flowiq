// Group 4: from release to insertion (R-017, Anhang C, B.1 step 6 to 8, Leitsatz 2, Panotti finding: audio was lost
// when buffers still arrived after the stop).
//  - the tail is fixed at 110 ms: chunks that arrive in it are recognized and written, then the lease is freed;
//  - after the lease is freed no chunk reaches recognizer or file; a late callback is counted, never fatal;
//  - release (t7) to the target app fetching the text (t13): median <= 350 ms, p95 <= 800 ms up to 30 s of
//    speech, <= 2 s up to 5 minutes;
//  - the text is in the journal before it is inserted;
//  - dictations in quick succession all arrive, in order.
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQInput
@testable import FlowIQRecording

@Suite(.timeLimit(.minutes(5)))
struct ReleaseToInsertTests {
    @Test func tailIsExactly110Milliseconds() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        let sources = rig.mics.all.count
        rig.press()
        #expect(await rig.awaitMicOpen(after: sources))
        let heldChunks = await rig.speak(0.5, step: 0.05)
        let source = try #require(rig.mics.current)
        let keyUp = rig.clock.now.offset
        await rig.release()  // returns once the coordinator waits on the virtual clock

        // 110 ms of tail, audio keeps coming every 10 ms (the last chunk starts at +100 ms and ends at +110 ms).
        var tail: [AudioChunk] = []
        for _ in 0..<11 {
            let c = toneChunk(at: rig.clock.nowNanos, seconds: 0.01, hz: 500)
            if source.emit(c) { tail.append(c) }
            if tail.count < 11 { await rig.clock.run(for: .milliseconds(10)) }
        }
        #expect(tail.count == 11)
        await rig.clock.run(for: .milliseconds(9))  // now at keyUp + 109 ms
        #expect(source.counts.stopsBegun == 0, "lease freed before the 110 ms tail were over")
        await rig.clock.run(for: .milliseconds(2))  // keyUp + 111 ms
        #expect(await eventually { source.counts.stopsBegun == 1 }, "lease not freed after the tail")
        #expect(await rig.settle())

        let stop = try #require(rig.trace.first("mic.stop"))
        let afterKeyUp = (stop.virtual - keyUp).ms
        #expect(afterKeyUp >= 110 && afterKeyUp <= 125, "microphone stopped \(afterKeyUp) ms after the key up")

        // Everything up to +110 ms reached the recognizer, nothing later, and not a chunk is missing.
        let got = try #require(rig.recognizer.runs.first)
        let expected = heldChunks + tail
        #expect(Array(got.prefix(expected.count)) == expected)
        // Anything after the tail may only be the silence the recognizer stage appends (A.6: 160 ms), never audio.
        let extra = got.dropFirst(expected.count)
        #expect(extra.allSatisfy { $0.samples.allSatisfy { $0 == 0 } })
        #expect(seconds(of: Array(extra)) <= 0.2)
        let end = Double(expected.last?.endTime ?? 0) / 1e9
        let up = Double(keyUp.nanos) / 1e9
        #expect(end - up >= 0.110 - 0.0001 && end - up <= 0.130, "recognized audio ends \(end - up) s after the key up")
    }

    @Test func tailAudioIsInTheFileToo() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        let sources = rig.mics.all.count
        rig.press()
        #expect(await rig.awaitMicOpen(after: sources))
        let held = await rig.speak(1.0, step: 0.05)
        let source = try #require(rig.mics.current)
        await rig.release()
        var tail = 0.0
        for _ in 0..<11 {
            if source.emit(toneChunk(at: rig.clock.nowNanos, seconds: 0.01, hz: 450)) { tail += 0.01 }
            await rig.clock.run(for: .milliseconds(10))
        }
        #expect(await rig.settle())
        let id = try #require(rig.scratch.journal().ids().first)
        let file = try #require(rig.scratch.audioFile(for: id))
        let expected = seconds(of: held) + tail
        #expect(abs(try audioDuration(file) - expected) <= 0.1)
    }

    enum Ending: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case normal, escape, recognizerFailed
        var testDescription: String { rawValue }
    }

    @Test(arguments: Ending.allCases)
    func buffersAfterTheStopNeverEmptyOrReopenTheFile(_ ending: Ending) async throws {
        var options = StubRecognizer.Options()
        options.fail = ending == .recognizerFailed
        let rig = try DictationRig(recognizer: options)
        defer { rig.remove() }
        let sources = rig.mics.all.count
        rig.press()
        #expect(await rig.awaitMicOpen(after: sources))
        let spoken = await rig.speak(1.0, step: 0.05)
        let source = try #require(rig.mics.current)
        if ending == .escape {
            rig.key(.escape, down: true)
        } else {
            await rig.release()
        }
        #expect(await eventually(timeout: .seconds(5)) {
            await rig.clock.run(for: .milliseconds(20))
            return source.counts.stopsBegun == 1
        })
        // The late callback of Panotti's bug: the source still delivers after stop() returned.
        let rogue = (0..<5).map { toneChunk(at: rig.clock.nowNanos + UInt64($0) * 10_000_000, seconds: 0.01, hz: 900) }
        for c in rogue { source.emitRogue(c) }
        #expect(await rig.settle())

        let id = try #require(rig.scratch.journal().ids().first)
        let file = try #require(rig.scratch.audioFile(for: id))
        let size = fileSize(file)
        #expect(size >= Int(4_000 * seconds(of: spoken)), "audio file is \(size) bytes")
        let duration = try audioDuration(file)
        #expect(duration >= seconds(of: spoken) - 0.1)
        for i in 0..<5 { source.emitRogue(toneChunk(at: rig.clock.nowNanos + UInt64(i) * 10_000_000, seconds: 0.01)) }
        await rig.clock.run(for: .milliseconds(300))
        #expect(fileSize(file) == size, "the closed file changed after late buffers")
        #expect(rig.scratch.audioFiles().count == 1)  // never a second file, never reopened
        #expect(!(await rig.scratch.events("late_buffers")).isEmpty)  // counted, visible
        if let run = rig.recognizer.runs.first {
            #expect(!run.contains { rogue.contains($0) }, "a buffer that arrived after the stop reached the recognizer")
        }
        let audio = try #require(rig.scratch.journal().lines(of: id).first { $0.event == JE.audio })
        #expect((audio.number(JK.bytes) ?? 0) > 0)
    }

    @Test func releaseToFetchBudgetUpTo30Seconds() async throws {
        // R-017: median <= 350 ms, p95 <= 800 ms for dictations up to 30 s; Fremdwert for finalizing 49 ms.
        var options = StubRecognizer.Options()
        options.finalizeDelay = .milliseconds(49)
        let rig = try DictationRig(recognizer: options)
        defer { rig.remove() }
        var lcg = Lcg(seed: 17)
        var spans: [Double] = []
        for _ in 0..<20 {
            let outcome = await rig.dictate(seconds: Double(lcg.next(1...4)), step: 0.25)
            #expect(outcome.finished)
            let fetched = try #require(rig.pasteboard.fetchedAt)
            spans.append((fetched - outcome.releasedAt).ms)
        }
        #expect(percentile(spans, 0.5) <= 350, "median \(percentile(spans, 0.5)) ms")
        #expect(percentile(spans, 0.95) <= 800, "p95 \(percentile(spans, 0.95)) ms")
        #expect((spans.min() ?? 0) >= 110, "faster than the fixed tail: \(spans.min() ?? 0) ms")
    }

    @Test(.tags(.slow)) func releaseToFetchBudgetFiveMinutes() async throws {
        var options = StubRecognizer.Options()
        options.finalizeDelay = .milliseconds(300)  // generous for a long recording
        let rig = try DictationRig(recognizer: options)
        defer { rig.remove() }
        let outcome = await rig.dictate(seconds: 300, step: 1.0)
        #expect(outcome.finished)
        let fetched = try #require(rig.pasteboard.fetchedAt)
        #expect((fetched - outcome.releasedAt).ms <= 2_000, "\((fetched - outcome.releasedAt).ms) ms")
        let id = try #require(rig.scratch.journal().ids().first)
        let file = try #require(rig.scratch.audioFile(for: id))
        #expect(abs(try audioDuration(file) - 300) <= 0.5)
    }

    @Test func textIsInTheJournalBeforeItIsInserted() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        let seen = Mutex<[JournalLine]>([])
        let audioThere = Mutex(false)
        let scratch = rig.scratch
        rig.target.onPaste {
            seen.withLock { $0 = scratch.journal() }
            audioThere.withLock { $0 = !scratch.audioFiles().isEmpty }
        }
        await rig.dictate()
        let atPaste = seen.withLock { $0 }
        let recognized = try #require(atPaste.first { $0.event == JE.recognized }, "no `recognized` line yet when Cmd-V was posted")
        #expect(recognized.string(JK.finalText) == rig.target.field)
        #expect(atPaste.contains { $0.event == JE.audio })  // audio checked and noted before the text
        #expect(!atPaste.contains { $0.event == JE.inserted })  // the result of the insertion comes after
        #expect(audioThere.withLock { $0 })
    }

    @Test func dictationsInQuickSuccessionAllArriveInOrder() async throws {
        // R-020 area: 10 dictations 150 ms apart while the previous one is still being finished.
        var options = StubRecognizer.Options()
        options.finalizeDelay = .milliseconds(300)
        let rig = try DictationRig(recognizer: options)
        defer { rig.remove() }
        for _ in 0..<10 {
            let sources = rig.mics.all.count
            rig.press()
            #expect(await rig.awaitMicOpen(after: sources))
            await rig.speak(0.4, step: 0.05)
            await rig.release()
            await rig.clock.run(for: .milliseconds(150))
        }
        #expect(await rig.settle(limit: .seconds(60)))
        let expected = (1...10).map { "das ist FlowIQ probesatz nummer \($0)" }.joined(separator: " ")
        #expect(rig.target.field == expected)  // no text lost, none doubled, one space between, in order
        #expect(rig.scratch.audioFiles().count == 10)
        let ids = rig.scratch.journal().ids()
        #expect(ids.count == 10)
        for id in ids {
            let events = rig.scratch.journal().lines(of: id).map(\.event)
            #expect(events == [JE.begin, JE.audio, JE.recognized, JE.inserted], "journal of \(id): \(events)")
        }
    }
}
