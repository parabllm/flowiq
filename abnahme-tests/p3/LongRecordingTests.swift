// Group 9: a 3-hour recording in accelerated simulation (R-039, R-047, A.4 bounded streams).
// The timeline is virtual: 108,000 chunks of 100 ms go through the conductor, the lease and the
// writer as fast as the writer takes them. The producer waits for the writer (no overflow, nothing
// dropped); the point is that memory stays flat and the file is complete.
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQRecording

struct LongRecordingTests {
    @Test(.tags(.slow), .timeLimit(.minutes(15)))
    func threeHourRoomRecordingKeepsMemoryFlatAndTheFileComplete() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.room, rig: rig)
        let mic = try #require(rig.mics.current)
        let cycle = Signal.sine(hz: 480, count: 4_800)  // 480 Hz repeats every 100 samples: one array serves every chunk
        let totalSeconds = 3 * 3_600

        var footprintAtQuarterHour: UInt64 = 0
        var peak: UInt64 = 0
        for second in 0..<totalSeconds {
            for tenth in 0..<10 { mic.emit(chunk(cycle, at: Double(second) + Double(tenth) / 10)) }
            while Double(second + 1) - (await writtenSeconds(session, .microphone)) > 10 {  // backpressure, not a sleep per chunk
                try await Task.sleep(for: .milliseconds(1))
            }
            if second % 60 == 0 {
                let now = footprintBytes()
                peak = max(peak, now)
                if second == 15 * 60 { footprintAtQuarterHour = now }
            }
        }
        let report = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:)
        let track = try #require(report.tracks.first { $0.name == .microphone })  // ASSUMPTION: SessionReport.tracks[].name

        #expect(footprintAtQuarterHour > 0)
        #expect(peak <= footprintAtQuarterHour + 64 * 1_048_576)  // no growth beyond 64 MB after the first quarter hour (3 h of Float samples would be 2 GB)
        #expect(await rig.scratch.events("overflow").isEmpty)
        #expect(await rig.scratch.events("late_buffers").isEmpty)
        #expect(await rig.scratch.events("gap_filled").isEmpty)  // a gapless timeline needs no filling

        #expect(abs(track.seconds - Double(totalSeconds)) <= 1)  // ASSUMPTION: TrackReport.seconds
        #expect(track.verdict == .ok)  // ASSUMPTION: TrackReport.verdict
        let m4a = try #require(track.m4aURL)  // ASSUMPTION: TrackReport.m4aURL
        #expect(abs(try audioDuration(m4a) - Double(totalSeconds)) <= 1)
        #expect(fileSize(m4a) <= 3 * 45_000_000)  // R-047: at most 45 MB per hour and track
        #expect(fileSize(m4a) >= 3 * 3_600 * 6_000)  // and not hollow: above the 6,000 B/s floor
    }
}
