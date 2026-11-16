// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 2a, failures while recording (Leitsatz 5 "nie still", A.4, A.5, R-039, R-042, review M4): the microphone says
// no, the device vanishes in the middle, the desktop stream ends, the disk fills up, the live recognizer throws at
// the start or in the middle. Every case ends the same way: the audio that exists is kept and playable, the failure
// is in the log with its kind, the state the pill and menu read is set, and the next try works.
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQRecording
@testable import FlowIQSpeech

@Suite(.timeLimit(.minutes(3)))
struct FehlerAufnahmeTests {
    enum Mode: Sendable { case dictation, call, room }

    private func trackSeconds(_ report: SessionReport, _ name: TrackName) -> Double {
        report.tracks.first { $0.name == name }?.seconds ?? -1
    }

    // MARK: Mikrofon verweigert

    /// The microphone refuses to start (permission withdrawn, device busy): dictation, call and room each end
    /// visibly and leave nothing behind (no file, no folder, no busy mark); the next try works.
    @Test(arguments: [Mode.dictation, .call, .room])
    func aRefusedMicrophoneLeavesNothingBehindAndTheNextTryWorks(_ mode: Mode) async throws {
        var plan = SourceBox.Plan()
        plan.mic.refuseStart = true
        let rig = try Rig(plan: plan)
        defer { rig.remove() }
        let kind: SessionKind = mode == .room ? .room : .call

        switch mode {
        case .dictation:
            rig.press()
            #expect(await eventually { rig.pill.last == .failed })  // a mark at the pill, not just gone
            #expect(await rig.settle())
            rig.key(.trigger, down: false)
            #expect(await rig.scratch.errors("dictation_mic_failed").count == 1)
            let id = try #require(rig.scratch.dictationIDs().first)
            #expect(rig.scratch.journal(of: id).first { $0.event == "begin" }?.string("mic") == "refused")
            #expect(rig.target.field.isEmpty && rig.pasteboard.writes == 0)
            #expect(rig.scratch.audioFiles().isEmpty)
        case .call, .room:
            await #expect(throws: AudioError.self) { _ = try await rig.startSession(kind) }
            #expect(await rig.scratch.errors("session_start_failed").count == 1)
            #expect(names(in: rig.scratch.laufend).isEmpty, "a refused start left a session folder")
        }
        #expect(await rig.busy.reasons.isEmpty)

        rig.sources.set { $0.mic.refuseStart = false }
        switch mode {
        case .dictation:
            rig.recognizer.script(["geht wieder"])
            #expect(await rig.dictate(seconds: 0.5, keepPlaying: false))
            #expect(rig.target.field == "geht wieder")
        case .call, .room:
            let session = try await rig.startSession(kind)
            await rig.play(1.0)
            let report = await session.stop(reason: .normal)
            #expect(abs(trackSeconds(report, .microphone) - rig.micFed) <= 0.15)
        }
    }

    // MARK: Gerät verschwindet mitten in der Aufnahme

    /// B.5 row 4 (AirPods gone): fallback to the built-in microphone in 1 s or less, the gap filled and marked,
    /// the event for pill and menu, the log line; call and room alike, and both tracks stay the same length.
    @Test(arguments: [SessionKind.call, .room])
    func aVanishingDeviceFallsBackWithinOneSecondAndFillsTheGap(_ kind: SessionKind) async throws {
        let rig = try Rig(standard: Dev.airpods, fallback: Dev.builtIn, lidOpen: false)  // lid closed: the room takes the AirPods too
        defer { rig.remove() }
        let tap = EventTap(rig.conductor.events)
        defer { tap.stop() }
        let session = try await rig.startSession(kind)
        let first = try #require(rig.sources.currentMic)
        #expect(first.kind == .microphone(Dev.airpods))
        await rig.play(2.0)

        first.fail("AirPods disconnected")
        #expect(await eventually(timeout: .seconds(1)) { rig.sources.allMics.count == 2 })
        #expect(rig.sources.currentMic?.kind == .microphone(Dev.builtIn))
        await rig.clock.run(for: .milliseconds(500))  // the new device delivers half a second later
        await rig.play(2.0)

        let report = await session.stop(reason: .normal)
        for name in kind == .call ? [TrackName.microphone, .desktop] : [.microphone] {
            #expect(abs(trackSeconds(report, name) - (rig.micFed + 0.5)) <= 0.2, "\(name) track: the hole is part of the timeline")
        }
        let filled = await rig.scratch.events("gap_filled").filter { $0.fields["track"] == "microphone" }
        #expect(abs(filled.reduce(0) { $0 + ($1.double("ms") ?? 0) } - 500) <= 100, "the hole is marked in the log")
        let switches = await rig.scratch.events("device_switch")
        #expect(switches.count == 1 && switches.first?.fields["reason"] == "lost")
        #expect(await rig.scratch.errors("capture_failed").count == 1)
        let events = await tap.events
        #expect(events.contains(.deviceSwitched(Dev.builtIn, lost: true)))
        #expect(!events.contains(.sourceDown(.microphone)), "with a replacement device nothing is down")
    }

    @Test func aDeviceThatVanishesInTheMiddleOfADictationCostsNoText() async throws {
        let rig = try Rig(standard: Dev.airpods, fallback: Dev.builtIn, lidOpen: false)
        defer { rig.remove() }
        rig.recognizer.script(["trotzdem da"])
        rig.press()
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) })
        await rig.play(0.5)
        try #require(rig.sources.currentMic).fail("AirPods disconnected")
        #expect(await eventually(timeout: .seconds(1)) { rig.sources.allMics.count == 2 })
        await rig.play(0.5)
        await rig.release()
        await rig.play(0.11, step: 0.01)
        #expect(await rig.settle())

        #expect(rig.target.field == "trotzdem da")
        #expect(rig.pill.last == .hidden)
        #expect(await rig.scratch.errors("audio_lost").isEmpty)
        #expect(seconds(of: try #require(rig.recognizer.runs.first)) >= 1.0)
    }

    /// No replacement device: the track is filled with silence until the device returns, `sourceDown` shows it,
    /// `sourceRestored` takes it away, the recording itself never stops.
    @Test func withoutAReplacementDeviceTheTrackIsFilledAndTheReturnIsShown() async throws {
        let rig = try Rig(standard: Dev.airpods, fallback: nil, lidOpen: false)
        defer { rig.remove() }
        let tap = EventTap(rig.conductor.events)
        defer { tap.stop() }
        let session = try await rig.startSession(.room)
        await rig.play(1.0)
        try #require(rig.sources.currentMic).fail("AirPods disconnected")

        #expect(await eventually { await rig.conductor.isDown(.microphone) })
        #expect(await eventually { await session.status(of: .microphone) == .gapFilling })  // visible, never "running" on a dead source
        #expect(await tap.events.contains(.sourceDown(.microphone)))
        await rig.conductor.updateDevices(DeviceSetup(standard: Dev.builtIn, fallback: Dev.builtIn, lidOpen: true))
        #expect(await eventually { rig.sources.allMics.count == 2 })
        #expect(await eventually { await !rig.conductor.isDown(.microphone) })
        await rig.play(1.0)

        #expect(await tap.events.contains(.sourceRestored(.microphone)))
        let report = await session.stop(reason: .normal)
        let track = try #require(report.tracks.first)
        #expect(track.seconds >= rig.micFed && track.verdict != .lost)
        #expect(!(await rig.scratch.events("gap_filled")).isEmpty)
    }

    // MARK: Desktop-Strom endet

    /// A.4: the desktop stream ends (lock screen, permission withdrawn): the track is filled and the stream is
    /// opened again; the microphone track never notices.
    @Test func whenTheDesktopStreamEndsTheCallRunsOnAndTheStreamComesBack() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let tap = EventTap(rig.conductor.events)
        defer { tap.stop() }
        let session = try await rig.startSession(.call)
        await rig.play(1.0)
        try #require(rig.sources.currentDesktop).fail("stream stopped")

        #expect(await eventually { await rig.conductor.isDown(.desktop) })
        #expect(await eventually { await session.status(of: .desktop) == .gapFilling })
        await rig.play(1.0)
        #expect(await eventually(timeout: .seconds(4)) { rig.sources.allDesktops.count == 2 })  // first attempt after 1 s
        #expect(await eventually { await !rig.conductor.isDown(.desktop) })
        await rig.play(1.0)

        #expect(await tap.events.contains(.sourceRestored(.desktop)))
        let report = await session.stop(reason: .normal)
        #expect(abs(trackSeconds(report, .microphone) - rig.micFed) <= 0.15)
        let desktop = try #require(report.tracks.first { $0.name == .desktop })
        #expect(desktop.seconds >= 2.0 && desktop.verdict != .lost)
        #expect(await rig.scratch.errors("source_down").count == 1)  // reported once, not once per tick
    }

    /// The desktop does not come back: after the first failed attempt the pill and the menu say so
    /// (`sourceDown(.desktop)`), the call goes on, the restart attempts end with the call.
    @Test func ifTheDesktopDoesNotComeBackTheFirstFailedAttemptIsShown() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let tap = EventTap(rig.conductor.events)
        defer { tap.stop() }
        let session = try await rig.startSession(.call)
        await rig.play(1.0)
        rig.sources.set { $0.desktop.refuseStart = true }  // permission withdrawn: every restart is refused
        try #require(rig.sources.currentDesktop).fail("stream stopped")

        #expect(await eventually(timeout: .seconds(4)) { await tap.events.contains(.sourceDown(.desktop)) })
        #expect(await rig.scratch.errors("desktop_restart").count >= 1)
        await rig.play(1.0)
        let report = await session.stop(reason: .normal)
        #expect(abs(trackSeconds(report, .microphone) - rig.micFed) <= 0.15)
        #expect(report.tracks.contains { $0.name == .desktop && $0.verdict != .lost }, "what the desktop delivered is kept")
    }

    // MARK: Platte voll

    /// A.5: an unreadable answer is an error, never "enough"; the recording goes on.
    @Test func anUnreadableFreeSpaceAnswerIsLoggedOnceAndTheRecordingGoesOn() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await rig.startSession(.room, freeSpace: FreeSpace(nil).answer)
        await rig.play(1.0)
        #expect(await rig.scratch.errors("disk_check_failed").count == 1)
        #expect(await session.status(of: .microphone) == .running)
        let report = await session.stop(reason: .normal)
        #expect(abs(trackSeconds(report, .microphone) - rig.micFed) <= 0.15)
    }

    /// A.5: below 1 GB a warning (once), the recording goes on; below 200 MB a clean end with the audio kept.
    @Test func lessThanOneGigabyteWarnsAndTheRecordingGoesOn() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await rig.startSession(.call, freeSpace: FreeSpace(800_000_000).answer)
        await rig.play(1.0)
        #expect(await rig.scratch.errors("disk_low").count == 1)
        #expect(await session.status(of: .microphone) == .running)
        _ = await session.stop(reason: .normal)
    }

    @Test(.tags(.slow)) func lessThanTwoHundredMegabytesEndsTheRecordingCleanlyWithTheAudioKept() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let free = FreeSpace(5_000_000_000)
        let session = try await rig.startSession(.call, freeSpace: free.answer)
        await rig.play(2.0)
        free.set(150_000_000)
        try await Task.sleep(for: .seconds(10.2))  // the check runs every 10 s of wall clock, on a chunk
        await rig.play(0.5)

        #expect(await eventually { await session.status(of: .microphone) == .ended("diskFull") })
        let report = await session.stop(reason: .normal)
        #expect(await rig.scratch.errors("disk_full").count == 1)
        #expect(rig.sources.currentMic?.counts.stopsBegun == 1)
        for name in [TrackName.microphone, .desktop] {
            let track = try #require(report.tracks.first { $0.name == name })
            let file = try #require(track.m4aURL ?? track.aacURL, "no playable file for \(name)")
            #expect(abs(try audioDuration(file) - track.seconds) <= 0.3)
            #expect(track.seconds >= 2.0 && track.verdict != .lost)
        }
    }

    /// Dictation with no room for its audio file: the text still comes (the stream goes to the recognizer
    /// whatever the disk says), the missing file is an error line, nothing half is left.
    @Test func aDictationThatCannotStoreItsAudioStillInsertsTheText() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let year = Calendar(identifier: .gregorian).component(.year, from: .now)
        try Data().write(to: rig.scratch.paths.diktate.appending(path: String(format: "%04d", year)))  // a file where the year folder must be
        rig.recognizer.script(["ohne ablage"])
        #expect(await rig.dictate(seconds: 0.5, keepPlaying: false))

        #expect(rig.target.field == "ohne ablage")
        #expect(await rig.scratch.errors("dictation_audio_failed").count == 1)
        #expect(rig.scratch.audioFiles().isEmpty)
        #expect(rig.pill.last == .hidden)
    }

    // MARK: Live-Erkenner wirft

    enum Moment: Sendable { case atStart, inTheMiddle }

    private final class Sink: RouterSink {  // same shape as in LiveTroubleTests
        private let list = Mutex<[LiveTrouble]>([]), spoken = Mutex<[String]>([])
        func accepted(_ segment: LiveSegment, from engine: LiveEngine) async { spoken.withLock { $0 += segment.words.map(\.text) } }
        func shadowed(_ segment: LiveSegment, from engine: LiveEngine) async {}
        func switched(at seconds: Double, to engine: LiveEngine, reason: SwitchReason) async {}
        func failed(at seconds: Double, _ trouble: LiveTrouble) async { list.withLock { $0.append(trouble) } }
        var troubles: [LiveTrouble] { list.withLock { $0 } }
        var words: [String] { spoken.withLock { $0 } }
    }

    private final class Recognizer: LiveRecognizer {
        let engine = LiveEngine.appleLocal, events: AsyncStream<LiveEvent>, starts: Bool
        let out: AsyncStream<LiveEvent>.Continuation
        init(starts: Bool) {
            self.starts = starts
            (events, out) = AsyncStream.makeStream()
        }
        func start(_ setup: LiveSetup) async throws { if !starts { throw CocoaError(.featureUnsupported) } }
        func feed(_ chunk: AudioChunk) {}
        func finish() async { out.finish() }
    }

    /// Review M4, audio first: a live recognizer that throws at the start or in the middle never touches the
    /// recording: the track is complete, the failure is reported once, the file run is asked for.
    @Test(arguments: [Moment.atStart, .inTheMiddle], [SessionKind.call, .room])
    func aFailingLiveRecognizerNeverStopsTheRecording(_ moment: Moment, _ kind: SessionKind) async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await rig.startSession(kind)
        let lease = try await rig.conductor.acquireMic(for: kind == .call ? .call : .room)  // the recorder's own lease for live
        let apple = Recognizer(starts: moment == .inTheMiddle), sink = Sink()
        let live = LiveSession(apple: apple, makeCloud: { Recognizer(starts: true) }, sink: sink,
                               clock: ContinuousClock(), usage: nil, room: kind == .room)
        let meter = TrackMeter(.microphone)
        let feed = CallLiveFeed(track: .microphone, chunks: lease.chunks, live: [SessionFeed(session: live, meter: meter)])
        try await live.start(LiveSetup(language: .de, terms: [], track: .microphone, anchor: 0, previousText: nil, backlog: []),
                             engine: .appleLocal)
        feed.start()
        await rig.play(1.0)
        if moment == .inTheMiddle {
            apple.out.yield(.committed(LiveSegment(words: [TimedWord(text: "eins", start: 0, end: 0.3, confidence: nil)], speaker: nil)))
            apple.out.yield(.failure(.transcriberError))
            apple.out.yield(.failure(.transcriberError))  // a second one is not a second report
        }
        #expect(await eventually { await live.trouble != nil })
        await rig.play(1.0)

        #expect(sink.troubles == [.recognizerFailed], "one visible failure")
        #expect(moment == .atStart || sink.words == ["eins"], "what was said before the failure is kept")
        #expect(await live.needsFileRun)
        let report = await session.stop(reason: .normal)
        await lease.release()
        await live.finish()
        #expect(abs(trackSeconds(report, .microphone) - rig.micFed) <= 0.15)
        #expect(await session.status(of: .microphone) == .ended("normal"))
    }
}
