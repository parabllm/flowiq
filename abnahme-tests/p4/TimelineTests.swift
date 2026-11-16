// Group 2: timeline of the Fn path (Anhang C, Zeitbudget Fn, R-015, Panotti finding: starting the microphone on
// the main thread delayed the pill by up to 130 ms).
// Order is proven on the trace (every seam writes to it), budgets on the virtual clock, and the "pill does not
// wait for the microphone" claim ALSO in real time with a microphone whose start blocks its thread for 130 ms.
// Serialized: the real-time thresholds must not compete with other tests for the CPU.
import Foundation
import Testing
@testable import FlowIQCore
@testable import FlowIQInput
@testable import FlowIQLog

@Suite(.serialized, .timeLimit(.minutes(2)))
struct TimelineTests {
    @Test func pillEventComesBeforeAnyMicrophoneWork() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        let outcome = await rig.dictate()
        #expect(outcome.opened && outcome.finished)

        let pill = try #require(rig.trace.first("pill.dictating"))
        let micWork = rig.trace.all("mic.")
        #expect(!micWork.isEmpty)
        for entry in micWork { #expect(pill.seq < entry.seq, "\(entry.name) ran before the pill was switched") }
        // Nothing else heavy before the pill either: recognizer, text stage and pasteboard come later.
        for name in ["recognizer.", "text.", "pasteboard.", "focus.", "keys."] {
            if let later = rig.trace.first(name) { #expect(pill.seq < later.seq, "\(name) before the pill") }
        }
    }

    @Test func fnTimelineMarksAreOrderedAndPillPrecedesMicStart() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        await rig.dictate()
        let events = await rig.scratch.events("fn.timeline")
        #expect(events.count == 1)  // exactly one closed timeline per dictation
        let e = try #require(events.first)
        // `<tN>_ms` relative to t0 in real time (FnTimeline); marks are fixed by Anhang C.
        let present = ["t0", "t1", "t2", "t3", "t4", "t7", "t8", "t9", "t10", "t11", "t12", "t13"]
        var values: [String: Double] = [:]
        for name in present {
            let value = e.double("\(name)_ms")
            #expect(value != nil, "mark \(name) missing in fn.timeline")
            values[name] = value
        }
        #expect(values["t0"] == 0)
        let chain = ["t0", "t1", "t2", "t3", "t4"]
        for (a, b) in zip(chain, chain.dropFirst()) {
            #expect((values[a] ?? .nan) <= (values[b] ?? .nan), "\(a) after \(b)")
        }
        let tail = ["t7", "t8", "t9", "t10", "t11", "t12", "t13"]
        for (a, b) in zip(tail, tail.dropFirst()) {
            #expect((values[a] ?? .nan) <= (values[b] ?? .nan), "\(a) after \(b)")
        }
        #expect((values["t2"] ?? .nan) <= (values["t3"] ?? .nan))  // pill shown no later than the microphone start
    }

    @Test func noMicrophoneRecognizerOrInsertWorkOnTheMainThread() async throws {
        let rig = try DictationRig(clipboard: richClipboard())
        defer { rig.remove() }
        await rig.dictate()
        #expect(rig.trace.entries.count > 10)
        for needed in ["mic.factory", "mic.start.begin", "mic.stop", "recognizer.dictate", "pasteboard.snapshot",
                       "pasteboard.write", "keys.paste", "pasteboard.restore", "focus.probe"] {
            #expect(rig.trace.first(needed) != nil, "\(needed) never happened")
        }
        #expect(rig.trace.onMainThread.isEmpty, "on the main thread: \(rig.trace.onMainThread)")
    }

    @Test func slowMicrophoneStartDoesNotDelayThePill() async throws {
        // Panotti's bug in real time: the start call blocks its thread for 130 ms.
        var blocking = P4Mic.Options()
        blocking.blockStartReal = .milliseconds(130)
        let rig = try DictationRig(mic: blocking)
        defer { rig.remove() }

        let sent = ContinuousClock.now
        let sources = rig.mics.all.count
        let callback = rig.press()
        #expect(callback <= .milliseconds(50), "the tap callback waited \(callback.ms) ms")
        #expect(await eventually { rig.pill.changes.contains { $0.state == .dictating } })  // ASSUMPTION: PillState.dictating
        let change = try #require(rig.pill.changes.first { $0.state == .dictating })  // ASSUMPTION: PillState.dictating
        #expect(change.real - sent <= .milliseconds(50), "pill after \((change.real - sent).ms) ms")
        #expect(await rig.awaitMicOpen(after: sources))
        await rig.release(waitForTail: false)
        await rig.settle()
    }

    @Test func tapToPillBudgetOverManyDictations() async throws {
        // R-015: p95 <= 50 ms, max <= 150 ms (real), t1 to t2 <= 5 ms (virtual), mic start 0 to 300 ms virtual.
        var lcg = Lcg(seed: 15)
        let rig = try DictationRig()
        defer { rig.remove() }
        var real: [Double] = []
        var virtual: [Double] = []
        for _ in 0..<30 {
            var options = P4Mic.Options()
            options.startDelay = .milliseconds(lcg.next(0...300))
            rig.mics.set(options)
            let before = rig.trace.all("pill.dictating").count
            let virtualKey = rig.clock.now.offset
            let sent = ContinuousClock.now
            let sources = rig.mics.all.count
            rig.press()
            #expect(await eventually { rig.trace.all("pill.dictating").count > before })
            let change = try #require(rig.pill.changes.last { $0.state == .dictating })  // ASSUMPTION: PillState.dictating
            real.append((change.real - sent).ms)
            let entry = try #require(rig.trace.all("pill.dictating").last)
            virtual.append((entry.virtual - virtualKey).ms)
            #expect(await rig.awaitMicOpen(after: sources))
            await rig.speak(0.4)
            await rig.release()
            await rig.settle()
        }
        #expect(percentile(real, 0.95) <= 50, "p95 \(percentile(real, 0.95)) ms")
        #expect((real.max() ?? .infinity) <= 150, "max \(real.max() ?? 0) ms")
        #expect((virtual.max() ?? .infinity) <= 5, "virtual t1 to t2 \(virtual.max() ?? 0) ms")  // pill is switched before the clock moves: no wait on the mic
    }

    @Test func noQueuedKeyEventsWhileTheMicrophoneStarts() async throws {
        // R-015: 0 queued key presses (callback later than 500 ms after the event), even with a blocked start.
        var blocking = P4Mic.Options()
        blocking.blockStartReal = .milliseconds(400)
        let rig = try DictationRig(mic: blocking)
        defer { rig.remove() }
        var durations = [rig.press()]
        durations.append(rig.key(.space, down: true))  // lock gesture during the blocked start
        durations.append(rig.key(.space, down: false))
        durations.append(rig.key(.escape, down: true))  // and a cancel
        for d in durations { #expect(d <= .milliseconds(500), "callback took \(d.ms) ms") }
        #expect(durations.map(\.ms).max() ?? 0 <= 50)
        _ = await rig.settle()
    }

    @Test func tapCallbackNeverWaitsForRecognizerOrDisk() async throws {
        var options = StubRecognizer.Options()
        options.prepareDelay = .seconds(1)
        options.finalizeDelay = .seconds(1)
        let rig = try DictationRig(recognizer: options)
        defer { rig.remove() }
        for _ in 0..<3 {
            let sources = rig.mics.all.count
            let d = rig.press()
            #expect(d <= .milliseconds(50))
            #expect(await rig.awaitMicOpen(after: sources))
            await rig.speak(0.4)
            await rig.release()
            await rig.settle()
        }
    }
}
