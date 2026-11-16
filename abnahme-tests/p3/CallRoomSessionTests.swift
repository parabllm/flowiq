// Session-level checks of two ABNAHME rows that sit next to the groups above:
// R-037 (call: two tracks, one folder, equal lengths), R-038 (room file unprocessed),
// R-046 (no growing file below the vault).
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQRecording

struct CallRoomSessionTests {
    @Test func callWritesTwoSoundingTracksOfEqualLengthIntoOneFolder() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.call, rig: rig, stamp: "2026-01-01 10-00-00")
        let mic = try #require(rig.mics.current)
        let desktop = try #require(rig.desktops.current)
        var t = 0.0
        for _ in 0..<60 {
            feed(desktop, from: t, seconds: 1, hz: 880)
            t = feed(mic, from: t, seconds: 1)
            #expect(await eventually { await writtenSeconds(session, .desktop) >= t - 1 })
        }
        let report = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:)

        #expect(report.folder.lastPathComponent == "2026-01-01 10-00-00 Call")  // ASSUMPTION: SessionReport.folder; name pattern YYYY-MM-DD HH-mm-ss Call
        #expect(listing(report.folder) == ["desktop.m4a", "mikrofon.m4a"])  // both tracks, nothing else left behind
        let lengths = try ["mikrofon.m4a", "desktop.m4a"].map { try audioDuration(report.folder.appending(path: $0)) }
        #expect(abs(lengths[0] - lengths[1]) <= 0.5)
        #expect(abs(lengths[0] - 60) <= 1)
        for name in ["mikrofon.m4a", "desktop.m4a"] {
            let decoded = try decode(report.folder.appending(path: name))
            #expect(Signal.rmsDB(decoded) > -40)  // neither track is silent
        }
    }

    @Test func roomFileKeepsTheSignalWithinOneDecibelPerBand() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.room, rig: rig)
        let mic = try #require(rig.mics.current)
        let bands = [250.0, 1_000.0, 4_000.0]  // three octave-spaced tones of equal level
        for second in 0..<10 {
            for tenth in 0..<10 {
                let first = (second * 10 + tenth) * 4_800
                var mix = [Float](repeating: 0, count: 4_800)
                for hz in bands {
                    for (i, v) in Signal.sine(hz: hz, amp: 0.1, count: 4_800, startSample: first).enumerated() { mix[i] += v }
                }
                mic.emit(chunk(mix, at: Double(second * 10 + tenth) / 10))
            }
            #expect(await eventually { await writtenSeconds(session, .microphone) >= Double(second) })
        }
        let report = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:)
        let track = try #require(report.tracks.first { $0.name == .microphone })  // ASSUMPTION: SessionReport.tracks[].name
        let decoded = try decode(try #require(track.m4aURL))  // ASSUMPTION: TrackReport.m4aURL
        let middle = Array(decoded[48_000..<(48_000 * 9)])  // skip encoder start and end
        let source = (0..<(48_000 * 8)).map { i -> Float in bands.reduce(0) { $0 + 0.1 * Float(sin(2 * Double.pi * $1 * Double(i + 48_000) / Signal.rate)) } }
        for hz in bands {
            #expect(abs(toneDB(middle, hz: hz) - toneDB(source, hz: hz)) <= 1)  // R-038: at most 1 dB per band
        }
    }

    @Test func noGrowingFileEverAppearsBelowTheVault() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.call, rig: rig)
        let mic = try #require(rig.mics.current)
        var t = 0.0
        for _ in 0..<12 {
            t = feed(mic, from: t, seconds: 1)
            #expect(listing(rig.scratch.vault).isEmpty)  // sampled while the recording is live
        }
        let report = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:)
        #expect(listing(rig.scratch.vault).isEmpty)
        #expect(report.folder.path.hasPrefix(rig.scratch.paths.support.path))  // ASSUMPTION: SessionReport.folder; the only place a recording is written is the profile's own folder
    }
}
