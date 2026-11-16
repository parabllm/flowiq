// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 1, simultaneity (B.5, E6, R-043): dictation during a call or room, room plus call on one microphone, a
// second start of a running recording, a start while another one is still opening, three starts inside 50 ms, a
// locked dictation while a call stops, import while a dictation and a recording run. Every case ends with the same
// questions: one device opened, no sample lost on any track, no second stop of a shared source, nothing left busy.
import Foundation
import Testing
@testable import FlowIQ  // ASSUMPTION: FlowCoordinator.observe needs the app module in this file too
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQDevices
@testable import FlowIQInput
@testable import FlowIQRecording

@Suite(.timeLimit(.minutes(3)))
struct GleichzeitigkeitTests {
    /// Every track of a stopped session holds what the microphone delivered, untouched.
    private func expectComplete(_ report: SessionReport, fed: Double, tracks: [TrackName]) {
        for name in tracks {
            guard let track = report.tracks.first(where: { $0.name == name }) else {
                Issue.record("no \(name) track in the report")
                continue
            }
            #expect(abs(track.seconds - fed) <= 0.15, "\(name) track \(track.seconds) s, fed \(fed) s")
            #expect(track.verdict != .lost)  // `ok` or `suspicious` depends on wall clock against synthetic time; P3 holds the rate
            #expect(track.lateBuffers == 0)
        }
    }

    // MARK: Diktat x Call, Diktat x Raum

    /// B.5 row 1: the dictation lease hangs on the running device, no second opening, no switch; the recording
    /// loses no sample; the dictation is inserted once and the call or room is told about its window.
    @Test(arguments: [SessionKind.call, .room])
    func dictationDuringARecordingSharesTheRunningDevice(_ kind: SessionKind) async throws {
        let rig = try Rig(standard: Dev.airpods, fallback: Dev.builtIn)
        defer { rig.remove() }
        let watcher = WindowRecorder()
        await rig.coordinator.observe(watcher)  // ASSUMPTION: FlowCoordinator.observe(_:) is reachable via @testable import
        rig.recognizer.script(["hallo welt"])
        try await rig.busy.begin(.recording)  // what the recorder does after a start
        let session = try await rig.startSession(kind)
        let mic = try #require(rig.sources.currentMic)
        // Bluetooth standard, lid open: a call takes the standard input, a room takes the built-in microphone (A.4).
        #expect(mic.kind == .microphone(kind == .call ? Dev.airpods : Dev.builtIn))

        await rig.play(2.0)
        #expect(await rig.dictate(seconds: 1.0))
        await rig.play(2.0)

        #expect(rig.sources.allMics.count == 1, "the dictation opened a second microphone source")
        #expect(mic.counts.starts == 1 && mic.counts.stopsBegun == 0, "the dictation stopped the microphone of the recording")
        #expect(await rig.scratch.events("device_switch").isEmpty)
        #expect(rig.target.field == "hallo welt" && rig.target.pasteCount == 1)
        let heard = seconds(of: try #require(rig.recognizer.runs.first))
        #expect(heard >= 1.0 && heard <= 1.4, "the dictation heard \(heard) s")
        #expect(watcher.windows.map(\.started) == [true, false])  // the recording keeps dictation audio out of its live stream (R-102)
        #expect(watcher.insertedJobs.map(\.insertedText) == ["hallo welt"])
        let id = try #require(rig.scratch.dictationIDs().first)
        #expect(rig.scratch.journal(of: id).first { $0.event == "begin" }?.string("situation") == "with_recording")
        #expect(rig.pill.states.first == .dictating && rig.pill.last == .hidden)
        #expect(await !rig.busy.reasons.contains(.dictation))

        let report = await session.stop(reason: .normal)
        expectComplete(report, fed: rig.micFed, tracks: kind == .call ? [.microphone, .desktop] : [.microphone])
        #expect(mic.counts.stopsBegun == 1)  // the last lease gone stops the source, once
        #expect(await rig.scratch.events("gap_filled").isEmpty)
        #expect(await rig.scratch.events("overflow").isEmpty)
    }

    // MARK: Raum + Call

    /// E6: one microphone for both, the device of the one that started first; a menu change applies to both.
    @Test(arguments: [SessionKind.room, .call])
    func roomPlusCallShareOneMicrophoneAndBothTracksAreComplete(first: SessionKind) async throws {
        let rig = try Rig(standard: Dev.airpods, fallback: Dev.builtIn)
        defer { rig.remove() }
        let second: SessionKind = first == .room ? .call : .room
        let a = try await rig.startSession(first, stamp: "2026-01-01 10-00-00")
        let b = try await rig.startSession(second, stamp: "2026-01-01 10-00-05")
        #expect(rig.sources.allMics.count == 1)
        #expect(rig.sources.allDesktops.count == 1)  // only the call has a desktop track
        let mic = try #require(rig.sources.currentMic)
        #expect(mic.kind == .microphone(first == .room ? Dev.builtIn : Dev.airpods))  // the first one decides, the second follows

        await rig.play(10)
        let reportA = await a.stop(reason: .normal)
        #expect(mic.phase == .running && mic.counts.stopsBegun == 0, "the other recording still holds the microphone")
        let reportB = await b.stop(reason: .normal)
        #expect(mic.counts.stopsBegun == 1)

        expectComplete(reportA, fed: rig.micFed, tracks: [.microphone])
        expectComplete(reportB, fed: rig.micFed, tracks: [.microphone])
        let call = first == .call ? reportA : reportB
        expectComplete(call, fed: rig.micFed, tracks: [.desktop])
    }

    @Test func aMicrophoneChangeInTheMenuAppliesToRoomAndCallWithoutAHole() async throws {
        let rig = try Rig(standard: Dev.airpods, fallback: Dev.builtIn)
        defer { rig.remove() }
        let room = try await rig.startSession(.room, stamp: "2026-01-01 10-00-00")
        let call = try await rig.startSession(.call, stamp: "2026-01-01 10-00-05")
        await rig.play(2.0)
        await rig.conductor.switchMic(to: Dev.usb)
        #expect(rig.sources.allMics.count == 2)
        #expect(rig.sources.currentMic?.kind == .microphone(Dev.usb))
        await rig.play(2.0)

        let reports = [await room.stop(reason: .normal), await call.stop(reason: .normal)]
        for report in reports { expectComplete(report, fed: rig.micFed, tracks: [.microphone]) }
        let switches = await rig.scratch.events("device_switch")
        #expect(switches.count == 1 && switches.first?.fields["reason"] == "menu")  // once, not once per recording
        #expect(await rig.scratch.events("gap_filled").isEmpty)
    }

    // MARK: Call starten während Call läuft

    /// A second start of the same recording in the same second is refused as a whole: the first one runs on
    /// untouched, nothing new is opened, the refusal is in the log (the app turns it into the message).
    @Test func startingACallWhileTheSameCallRunsOpensNothingNew() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let stamp = "2026-01-01 10-00-00"
        let first = try await rig.startSession(.call, stamp: stamp)
        await rig.play(1.0)
        await #expect(throws: CocoaError.self) { _ = try await rig.startSession(.call, stamp: stamp) }
        await rig.play(1.0)

        #expect(rig.sources.allMics.count == 1 && rig.sources.allDesktops.count == 1)
        #expect(rig.sources.currentMic?.counts.stopsBegun == 0 && rig.sources.currentDesktop?.counts.stopsBegun == 0)
        #expect(names(in: rig.scratch.laufend) == ["\(stamp) Call"])  // one folder, nothing half made
        #expect(await rig.scratch.errors("session_start_failed").count == 1)
        let report = await first.stop(reason: .normal)
        expectComplete(report, fed: rig.micFed, tracks: [.microphone, .desktop])
    }

    // MARK: Fn während Start einer Aufnahme

    /// Fn pressed while the capture session of a call or room is still starting: the dictation joins that start,
    /// there is no second source, and both consumers get the very first buffer.
    @Test(arguments: [SessionKind.call, .room])
    func fnDuringTheStartOfARecordingJoinsTheOpeningMicrophone(_ kind: SessionKind) async throws {
        var plan = SourceBox.Plan()
        plan.mic.startDelay = .milliseconds(500)
        let rig = try Rig(plan: plan)
        defer { rig.remove() }
        rig.recognizer.script(["hallo"])
        let starting = Task { try await rig.startSession(kind) }
        #expect(await rig.awaitMicOpen())
        let source = try #require(rig.sources.currentMic)
        rig.press()  // while `start` is still blocked on the virtual 500 ms
        await rig.clock.run(for: .milliseconds(500))
        let session = try await starting.value
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) })
        await rig.play(1.0)
        await rig.release()
        await rig.play(0.11, step: 0.01)
        #expect(await rig.settle(keepPlaying: true))

        #expect(rig.sources.allMics.count == 1 && source.counts.starts == 1)
        #expect(rig.target.field == "hallo" && rig.target.pasteCount == 1)
        #expect(seconds(of: try #require(rig.recognizer.runs.first)) >= 1.0)
        let report = await session.stop(reason: .normal)
        expectComplete(report, fed: rig.micFed, tracks: [.microphone])
    }

    // MARK: Drei Kurzbefehle innerhalb von 50 ms

    enum Press: Sendable { case call, room, fn }

    /// Three functions inside 50 ms in every order: one microphone for all three, the device of the first, every
    /// consumer gets every buffer, the dictation is inserted once.
    @Test(arguments: [[Press.call, .room, .fn], [.room, .call, .fn], [.fn, .call, .room]])
    func threeStartsInsideFiftyMillisecondsShareOneDeviceAndLoseNothing(_ order: [Press]) async throws {
        var plan = SourceBox.Plan()
        plan.mic.startDelay = .milliseconds(200)  // the first start is still opening while the others arrive
        let rig = try Rig(standard: Dev.airpods, fallback: Dev.builtIn, plan: plan)
        defer { rig.remove() }
        rig.recognizer.script(["eins zwei"])
        var sessions: [(SessionKind, Task<RecordingSession, any Error>)] = []
        for (index, press) in order.enumerated() {
            switch press {
            case .call: sessions.append((.call, Task { try await rig.startSession(.call, stamp: "2026-01-01 10-00-01") }))
            case .room: sessions.append((.room, Task { try await rig.startSession(.room, stamp: "2026-01-01 10-00-00") }))
            case .fn: rig.press()
            }
            if index == 0 { #expect(await rig.awaitMicOpen()) }  // the first one has chosen its device
            await rig.clock.run(for: .milliseconds(15))  // 3 x 15 ms: all three inside 50 ms
        }
        await rig.clock.run(for: .milliseconds(300))
        var started: [(SessionKind, RecordingSession)] = []
        for (kind, task) in sessions { started.append((kind, try await task.value)) }
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) || order.contains(.fn) == false })

        // Rule: a running or starting device wins (E6); dictation and room prefer the built-in one with Bluetooth
        // as standard and the lid open, a call takes the standard.
        let expected: InputDevice = order.first == .call ? Dev.airpods : Dev.builtIn
        #expect(rig.sources.allMics.count == 1 && rig.sources.currentMic?.kind == .microphone(expected))
        #expect(rig.sources.allDesktops.count == (order.contains(.call) ? 1 : 0))

        await rig.play(1.0)
        if order.contains(.fn) {
            await rig.release()
            await rig.play(0.11, step: 0.01)
            #expect(await rig.settle(keepPlaying: true))
            #expect(rig.target.field == "eins zwei" && rig.target.pasteCount == 1)
        }
        for (kind, session) in started {
            let report = await session.stop(reason: .normal)
            expectComplete(report, fed: rig.micFed, tracks: kind == .call ? [.microphone, .desktop] : [.microphone])
        }
        #expect(rig.sources.currentMic?.counts.stopsBegun == 1)
    }

    // MARK: Diktat gesperrt + Call-Stopp

    enum Stops: Sendable { case callFirst, dictationFirst }

    /// Hands-free dictation (Fn Fn) while a call runs: stopping the call never stops the microphone under the
    /// dictation, and stopping the dictation never stops the microphone under the call.
    @Test(arguments: [Stops.callFirst, .dictationFirst])
    func aLockedDictationAndTheStopOfACallNeverStopTheSharedMicrophone(_ order: Stops) async throws {
        let rig = try Rig(standard: Dev.airpods, fallback: Dev.builtIn)
        defer { rig.remove() }
        rig.recognizer.script(["freie hand"])
        try await rig.busy.begin(.recording)
        let session = try await rig.startSession(.call)
        let mic = try #require(rig.sources.currentMic)
        await rig.play(1.0)
        await rig.lockDictation()
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) })
        await rig.play(1.0)

        func stopDictation() async {
            let before = rig.clock.sleeperCount
            rig.key(.trigger, down: true)  // the third edge of the lock gesture
            _ = await rig.clock.waitForSleepers(atLeast: before + 1)
            await rig.play(0.11, step: 0.01)
            rig.key(.trigger, down: false)
            #expect(await rig.settle(keepPlaying: order == .dictationFirst))
        }

        let report: SessionReport
        switch order {
        case .callFirst:
            report = await session.stop(reason: .normal)
            #expect(mic.phase == .running && mic.counts.stopsBegun == 0, "the dictation lost its microphone")
            await rig.play(1.0)  // the dictation still hears audio after the call is gone
            await stopDictation()
            #expect(mic.counts.stopsBegun == 1)  // now the last lease is gone
            #expect(seconds(of: try #require(rig.recognizer.runs.first)) >= 1.9)
        case .dictationFirst:
            await stopDictation()
            #expect(mic.phase == .running && mic.counts.stopsBegun == 0, "the call lost its microphone")
            await rig.play(1.0)
            report = await session.stop(reason: .normal)
            #expect(mic.counts.stopsBegun == 1)
        }
        #expect(rig.target.field == "freie hand" && rig.target.pasteCount == 1)
        // TEST-FIX (geprüft): TimelineGuard füllt die 230 ms des Gerüsts nach A.4
        expectComplete(report, fed: (order == .callFirst ? 2.0 : rig.micFed) + 0.23, tracks: [.microphone])
        #expect(await !rig.busy.reasons.contains(.dictation))
    }

    // MARK: Import läuft während Diktat und Aufnahme

    /// B.5 row 3: during a dictation the copy waits between blocks, during a recording it only yields; no file
    /// is lost, the recording and the dictation lose nothing.
    @Test func importRunsThrottledWhileADictationAndACallRunAndLosesNothing() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let devices = try DeviceRig(scratch: rig.scratch)
        for n in 1...3 { try devices.put("probe-\(n).wav", DeviceRig.wav(seconds: 2, seed: UInt8(n))) }
        rig.recognizer.script(["mitten im import"])
        try await rig.busy.begin(.recording)
        let session = try await rig.startSession(.call)
        await rig.play(1.0)
        rig.press()
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) })

        let importer = try await devices.importer(gate: ThrottleGate(rig.busy, pause: .milliseconds(5)), busy: rig.busy)
        let scan = Task { await importer.scan() }
        await rig.play(1.0)
        #expect(await eventually { await rig.busy.reasons.contains(.import) })
        #expect(await devices.transcriber.state.calls.isEmpty, "the import transcribed while a dictation ran")
        #expect(devices.archived().isEmpty, "the import copied while a dictation ran")

        await rig.release()
        await rig.play(0.11, step: 0.01)
        #expect(await rig.settle(keepPlaying: true))
        let report = await scan.value
        #expect(report.imported == 3 && report.failed == 0)
        #expect(devices.archived().count == 3)
        #expect(await devices.filing.state.filed.count == 3)
        #expect(await !rig.busy.reasons.contains(.import))

        await rig.play(1.0)
        expectComplete(await session.stop(reason: .normal), fed: rig.micFed, tracks: [.microphone, .desktop])
        #expect(rig.target.field == "mitten im import" && rig.target.pasteCount == 1)
        #expect(await rig.scratch.events("gap_filled").isEmpty)
    }
}
