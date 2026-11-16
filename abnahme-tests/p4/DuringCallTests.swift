// Group 7: dictation during a call (B.5, E6, R-024 P4 share): the dictation lease hangs on the running device, no
// second open, no switch, the call tracks lose no sample, and ending the dictation any way never stops the
// microphone while the call still runs. (The appended "(Diktat)" line in the live file is package P5.)
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQInput
@testable import FlowIQRecording

@Suite(.timeLimit(.minutes(3)))
struct DuringCallTests {
    /// One step of call audio on both sources; returns the microphone chunk that was delivered.
    private func feedBoth(_ rig: DictationRig, seconds: Double, step: Double = 0.05) async -> [AudioChunk] {
        guard let mic = rig.mics.current, let desktop = rig.desktops.current else {
            Issue.record("no call sources")
            return []
        }
        var delivered: [AudioChunk] = []
        for i in 0..<Int((seconds / step).rounded()) {
            let t = rig.clock.nowNanos
            let m = toneChunk(at: t, seconds: step, hz: 300 + Double(i % 8) * 30)
            if mic.emit(m) { delivered.append(m) }
            desktop.emit(toneChunk(at: t, seconds: step, hz: 700 + Double(i % 8) * 30))
            await rig.clock.run(for: .seconds(step))
        }
        return delivered
    }

    private func startCall(_ rig: DictationRig) async throws -> RecordingSession {
        try await RecordingSession.start(kind: .call, conductor: rig.conductor, folder: rig.scratch.laufend,
                                         stamp: "2026-01-01 10-00-00", fs: rig.scratch.fs, log: rig.scratch.log,
                                         lock: rig.lock)
    }

    @Test(arguments: ReleaseToInsertTests.Ending.allCases)
    func callTracksAreUntouchedByADictation(_ ending: ReleaseToInsertTests.Ending) async throws {
        var options = StubRecognizer.Options()
        options.fail = ending == .recognizerFailed
        // Bluetooth is the standard input: alone a dictation would take the built-in microphone, but the running
        // device wins (E6), so the dictation must hang on the AirPods and open nothing.
        let rig = try DictationRig(standard: P4Devices.airpods, fallback: P4Devices.builtIn, recognizer: options)
        defer { rig.remove() }
        let session = try await startCall(rig)
        let source = try #require(rig.mics.current)
        #expect(source.kind == .microphone(P4Devices.airpods))

        var fed = await feedBoth(rig, seconds: 2.0)
        // The dictation starts now.
        let pressedAt = rig.clock.nowNanos
        rig.press()
        #expect(await eventually { rig.trace.first("pill.dictating") != nil })
        #expect(await eventually { await rig.busy.reasons.contains(.dictation) })
        let heard = await feedBoth(rig, seconds: 1.0)
        fed += heard
        if ending == .escape {
            rig.key(.escape, down: true)
        } else {
            await rig.release()
            let tail = await feedBoth(rig, seconds: 0.11, step: 0.01)  // the 110 ms tail
            fed += tail
        }
        // The call goes on while the dictation is finished.
        for _ in 0..<40 {
            if await rig.coordinator.isIdle { break }
            fed += await feedBoth(rig, seconds: 0.05)
        }
        #expect(await rig.settle())

        #expect(rig.mics.all.count == 1, "the dictation opened a second microphone source")
        #expect(source.counts.starts == 1)
        #expect(source.counts.stopsBegun == 0, "the microphone was stopped while the call still runs")
        #expect(rig.mics.all.allSatisfy { $0.kind == .microphone(P4Devices.airpods) })
        #expect(await rig.scratch.events("device_switch").isEmpty)
        #expect(!(await rig.busy.reasons.contains(.dictation)))

        if ending == .normal {
            #expect(rig.target.field == "das ist FlowIQ probesatz nummer 1")
            let got = try #require(rig.recognizer.runs.first)
            #expect((got.first?.hostTime ?? 0) >= pressedAt)  // nothing from before the key press
            #expect(Array(got.prefix(heard.count)) == heard)
        } else {
            #expect(rig.target.field.isEmpty)
        }

        fed += await feedBoth(rig, seconds: 2.0)  // the call after the dictation
        let report = await session.stop(reason: .normal)
        for name in [TrackName.microphone, .desktop] {
            let track = try #require(report.tracks.first { $0.name == name })
            #expect(abs(track.seconds - seconds(of: fed)) <= 0.15, "\(name) track \(track.seconds) s, fed \(seconds(of: fed)) s")
            #expect(track.lateBuffers == 0)
            #expect(track.verdict == .ok)
        }
        #expect(await rig.scratch.events("gap_filled").isEmpty, "the dictation left a hole in a call track")
        #expect(await rig.scratch.events("overflow").isEmpty)
    }

    @Test func dictationAfterTheCallEndedOpensTheMicrophoneItself() async throws {
        let rig = try DictationRig(standard: P4Devices.airpods, fallback: P4Devices.builtIn)
        defer { rig.remove() }
        let session = try await startCall(rig)
        _ = await feedBoth(rig, seconds: 0.5)
        _ = await session.stop(reason: .normal)
        let sources = rig.mics.all.count
        // No call: Bluetooth standard with the lid open means the built-in microphone for a dictation.
        let outcome = await rig.dictate(seconds: 0.5)
        #expect(outcome.finished)
        #expect(rig.mics.all.count == sources + 1)
        #expect(rig.mics.current?.kind == .microphone(P4Devices.builtIn))
    }
}
