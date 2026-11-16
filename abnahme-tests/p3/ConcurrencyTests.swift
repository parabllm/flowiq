// Group 7: simultaneity (B.5, E6) and device change in the middle of a recording (A.4, R-042).
// One microphone serves dictation, room and call; a change applies to all of them without a hole
// bigger than the timeline guard's 200 ms and is logged as `device_switch`.
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQRecording

struct ConcurrencyTests {
    @Test func dictationDuringCallSharesTheRunningMicrophone() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.call, rig: rig)
        let mic = try #require(rig.mics.current)

        let dictation = try await rig.conductor.acquireMic(for: .dictation)
        #expect(rig.mics.all.count == 1)  // no second opening of the device
        #expect(uid(of: dictation) == micUID(mic))  // same device as the call, no switch
        let heard = collect(dictation.chunks)

        feed(mic, from: 0, seconds: 3)
        #expect(await eventually { await writtenSeconds(session, .microphone) >= 2.8 })
        await dictation.release(hold: .zero)
        let dictated = await heard.finish()

        #expect(abs(dictated.reduce(0) { $0 + $1.length } - 3.0) <= 0.001)  // the dictation got the whole 3 s
        #expect(mic.phase == .running)  // releasing the dictation does not stop the call's microphone
        #expect(mic.counts.stopsBegun == 0)

        feed(mic, from: 3, seconds: 2)
        #expect(await eventually { await writtenSeconds(session, .microphone) >= 4.8 })
        _ = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:)
        #expect(mic.counts.stopsBegun == 1)  // the last lease gone stops the source, once
        #expect(rig.mics.all.count == 1)
    }

    @Test func roomAndCallGetIdenticalSamplesFromOneMicrophone() async throws {
        let rig = try Rig(standard: Devices.airpods, fallback: Devices.builtIn)
        defer { rig.remove() }
        let room = try await rig.conductor.acquireMic(for: .room)
        let call = try await rig.conductor.acquireMic(for: .call)
        #expect(rig.mics.all.count == 1)  // one microphone for both (E6)
        #expect(uid(of: room) == uid(of: call))
        let roomHeard = collect(room.chunks)
        let callHeard = collect(call.chunks)

        let mic = try #require(rig.mics.current)
        feed(mic, from: 0, seconds: 10)
        await room.release(hold: .zero)
        await call.release(hold: .zero)
        let a = await roomHeard.finish()
        let b = await callHeard.finish()

        #expect(a.count == 100)
        #expect(a.map(\.samples) == b.map(\.samples))  // the very same samples
        #expect(a.map(\.hostTime) == b.map(\.hostTime))
        #expect(a.map(\.samples) == expectedSine(from: 0, seconds: 10).map(\.samples))  // and unchanged against the source
    }

    @Test func roomPlusCallSessionsRecordSameLengthFromOneDevice() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let room = try await startSession(.room, rig: rig, stamp: "2026-01-01 10-00-00")
        let call = try await startSession(.call, rig: rig, stamp: "2026-01-01 10-00-05")
        #expect(rig.mics.all.count == 1)
        let mic = try #require(rig.mics.current)
        let desktop = try #require(rig.desktops.current)

        var t = 0.0
        for _ in 0..<20 {
            t = feed(mic, from: t, seconds: 1)
            feed(desktop, from: t - 1, seconds: 1, hz: 880)
            #expect(await eventually { await writtenSeconds(room, .microphone) >= t - 0.5 })
        }
        let roomReport = await room.stop(reason: .normal)  // ASSUMPTION: stop(reason:)
        #expect(mic.phase == .running)  // the call still holds the microphone
        let callReport = await call.stop(reason: .normal)  // ASSUMPTION: stop(reason:)

        let roomTrack = try #require(roomReport.tracks.first { $0.name == .microphone })  // ASSUMPTION: SessionReport.tracks[].name
        let callTrack = try #require(callReport.tracks.first { $0.name == .microphone })  // ASSUMPTION: SessionReport.tracks[].name
        #expect(abs(roomTrack.seconds - callTrack.seconds) <= 0.5)  // ASSUMPTION: TrackReport.seconds
        #expect(abs(roomTrack.seconds - 20) <= 0.5)
        #expect(roomTrack.verdict == .ok && callTrack.verdict == .ok)  // ASSUMPTION: TrackReport.verdict
        #expect(mic.counts.stopsBegun == 1)
    }

    @Test func deviceChangeInTheMiddleLosesNoBufferAndLeavesNoOpenGap() async throws {
        let rig = try Rig(standard: Devices.airpods, fallback: Devices.builtIn)
        defer { rig.remove() }
        let room = try await rig.conductor.acquireMic(for: .room)
        let call = try await rig.conductor.acquireMic(for: .call)
        let roomHeard = collect(room.chunks)
        let callHeard = collect(call.chunks)
        let first = try #require(rig.mics.current)

        feed(first, from: 0, seconds: 2, hz: 440)
        await rig.conductor.switchMic(to: Devices.usb)  // ASSUMPTION: switchMic(to:) is the menu action and applies to every running lease
        #expect(rig.mics.all.count == 2)
        let second = try #require(rig.mics.current)
        #expect(micUID(second) == Devices.usb.uid)  // ASSUMPTION: InputDevice.uid
        feed(second, from: 2.5, seconds: 2, hz: 880)  // the new device delivers 0.5 s later: a hole on the timeline

        #expect(await eventually { await roomHeard.snapshot().last.map { $0.end >= 4.49 } ?? false })
        await room.release(hold: .zero)
        await call.release(hold: .zero)
        let a = await roomHeard.finish()
        let b = await callHeard.finish()

        for received in [a, b] {  // the change applies to both leases
            let real = received.filter { !isSilent($0) }
            #expect(real.count == 40)  // 0 buffers lost
            #expect(real.map(\.samples) == (expectedSine(from: 0, seconds: 2, hz: 440) + expectedSine(from: 2.5, seconds: 2, hz: 880)).map(\.samples))
            #expect(largestGap(received) <= 0.2 + 1e-6)  // nothing larger than the guard's threshold is left open
            let span = (received.last?.end ?? 0) - (received.first?.start ?? 0)
            #expect(abs(span - 4.5) <= 0.01)  // duration equals the timeline, hole included
            #expect(received.contains(where: isSilent))  // the hole is filled with silence
        }
        let switches = await rig.scratch.events("device_switch")
        #expect(switches.count == 1)  // logged once, not once per lease
        let filled = await rig.scratch.events("gap_filled")
        #expect(!filled.isEmpty)
        #expect(abs((filled.map { $0.double("ms") ?? 0 }.reduce(0, +)) - 500) <= 100)  // ASSUMPTION: gap_filled carries the filled length in ms (field ms)
    }

    @Test func lostDeviceFallsBackToTheBuiltInMicrophoneWithinOneSecond() async throws {
        let rig = try Rig(standard: Devices.airpods, fallback: Devices.builtIn)
        defer { rig.remove() }
        let room = try await rig.conductor.acquireMic(for: .room)
        let heard = collect(room.chunks)
        let first = try #require(rig.mics.current)
        feed(first, from: 0, seconds: 2)

        first.fail("device removed")  // ASSUMPTION: a failing source reports its end through onEnd and the conductor reacts

        #expect(await eventually(timeout: .seconds(1)) { rig.mics.all.count == 2 })  // fallback opened in 1 s or less
        let second = try #require(rig.mics.current)
        #expect(micUID(second) == Devices.builtIn.uid)  // ASSUMPTION: InputDevice.uid
        feed(second, from: 2.6, seconds: 2)
        #expect(await eventually { await heard.snapshot().last.map { $0.end >= 4.59 } ?? false })
        await room.release(hold: .zero)
        let received = await heard.finish()

        #expect(largestGap(received) <= 0.2 + 1e-6)
        let lost = await rig.scratch.events("device_switch")
        #expect(lost.count == 1)
        #expect(lost.first?.fields["reason"] == "lost")  // ASSUMPTION: device_switch carries reason lost or menu
    }

    @Test func boundedRecordingStreamCountsEveryDroppedBuffer() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let lease = try await rig.conductor.acquireMic(for: .room)  // recording streams hold at most 30 s of audio
        let mic = try #require(rig.mics.current)
        feed(mic, from: 0, seconds: 45)  // nobody reads for 45 s of audio: 450 chunks of 100 ms
        #expect(await eventually { !(await rig.scratch.events("overflow")).isEmpty })

        await lease.release(hold: .zero)
        let kept = await collect(lease.chunks).finish()
        let dropped = (await rig.scratch.events("overflow")).reduce(0) { $0 + ($1.int("count") ?? 0) }  // ASSUMPTION: overflow carries the number of dropped buffers in field count
        #expect(dropped > 0)
        #expect(kept.count + dropped == 450)  // nothing disappears without being counted
        #expect(kept.reduce(0) { $0 + $1.length } <= 30.0 + 0.1)
    }
}
