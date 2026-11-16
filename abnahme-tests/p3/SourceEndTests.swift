// Group 5: end of stream equals end of writer (Leitsatz 5 "Nie still", A.4 desktop restart, A.5 point 4).
// When a source ends, the track ends visibly with a status or keeps going visibly marked; it never
// just stops growing without a trace.
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQRecording

struct SourceEndTests {
    @Test func finishedStreamClosesTheWriterAndChecksTheSize() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, url) = try await openWriter(s)
        let (stream, input) = AsyncStream<AudioChunk>.makeStream()
        let consumer = Task { await writer.consume(stream) }  // ASSUMPTION: TrackWriter.consume(_:) drains a lease stream, closes at its end (reason sourceEnded) and returns the CloseReport

        for c in expectedSine(from: 0, seconds: 3) { input.yield(c) }
        input.finish()
        let report = await consumer.value

        #expect(await writer.state == .closed)  // ASSUMPTION: state enum open, closing, closed
        #expect(report.verdict == .ok)  // ASSUMPTION: CloseReport.verdict
        #expect(fileSize(url) >= 3 * 4_000)
        let closed = await s.events("track_closed")  // ASSUMPTION: event kind track_closed with field reason
        #expect(closed.count == 1)
        #expect(closed.first?.fields["reason"] == "sourceEnded")  // ASSUMPTION: reason value for a stream end

        await append(writer, from: 3, seconds: 1)  // anything arriving afterwards is late and counted
        #expect(await writer.lateBuffers == 10)  // ASSUMPTION: lateBuffers async property
    }

    @Test func micFailureWithoutReplacementDeviceIsVisibleAndKeepsTheFile() async throws {
        let rig = try Rig(fallback: nil)
        defer { rig.remove() }
        let session = try await startSession(.room, rig: rig)
        let source = try #require(rig.mics.current)
        feed(source, from: 0, seconds: 2)
        #expect(await eventually { await writtenSeconds(session, .microphone) >= 1.8 })

        source.fail("device removed")

        #expect(await eventually { await status(session, .microphone) != .running })  // visible state, never "running" on a dead source
        let errors = await rig.scratch.events().filter { $0.level == "error" }
        #expect(!errors.isEmpty)  // reported in the log, not swallowed
        let report = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:) -> SessionReport
        let track = try #require(report.tracks.first { $0.name == .microphone })  // ASSUMPTION: SessionReport.tracks[].name
        #expect(track.bytes >= 2 * 4_000)  // ASSUMPTION: TrackReport.bytes; what was recorded before the failure is kept
        #expect(track.verdict != .lost)  // ASSUMPTION: TrackReport.verdict
    }

    @Test func desktopStreamEndKeepsTheTrackAliveFillsAndRestarts() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.call, rig: rig)
        let desktop = try #require(rig.desktops.current)
        let mic = try #require(rig.mics.current)
        feed(mic, from: 0, seconds: 2)
        feed(desktop, from: 0, seconds: 2, hz: 880)
        #expect(await eventually { await writtenSeconds(session, .desktop) >= 1.8 })
        rig.desktops.refuseFromNowOn()  // every restart attempt fails: the worst case

        desktop.fail("stream stopped by system")

        // A.4: restart attempts after 1, 5, 15 s; the first one must show up within about a second.
        #expect(await eventually(timeout: .seconds(3)) { !(await rig.scratch.events("desktop_restart")).isEmpty })
        let first = try #require(await rig.scratch.events("desktop_restart").first)
        #expect(first.int("attempt") == 1)  // ASSUMPTION: field attempt on desktop_restart
        #expect(await status(session, .desktop) == .gapFilling)  // alive and marked, not ended, not "running"
        #expect(await status(session, .microphone) == .running)  // the other track is untouched

        let before = await writtenSeconds(session, .desktop)
        try await Task.sleep(for: .seconds(2))
        #expect(await writtenSeconds(session, .desktop) > before)  // silence is written while the stream is down
        #expect(!(await rig.scratch.events("gap_filled")).isEmpty)
    }

    @Test func silentTrackWarningReachesTheLogWithinFifteenSeconds() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.room, rig: rig)
        let source = try #require(rig.mics.current)
        var t = 0.0
        for _ in 0..<15 {  // 15 s of digital silence, one second at a time
            for _ in 0..<10 {
                source.emit(chunk([Float](repeating: 0, count: 4_800), at: t))
                t += 0.1
            }
        }
        #expect(await eventually { !(await rig.scratch.events("track_warning")).isEmpty })  // ASSUMPTION: event kind track_warning with field stage
        let warning = try #require(await rig.scratch.events("track_warning").first)
        #expect(warning.int("stage") == 1)  // ASSUMPTION: field stage
        let report = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:)
        #expect(report.tracks.count == 1)
    }
}
