// Group 2: size against duration after close (A.5 point 5). Thresholds from the architecture:
// below 4,000 B/s (dictation) or 6,000 B/s (call, room) the audio is not "gesichert"; header only
// or far below the floor is `audio_lost`. Boundaries at exactly 10 % of nominal are not tested
// (the nominal value is not given as a number in the architecture).
import Foundation
import Testing
@testable import FlowIQRecording

struct SizeVsDurationTests {
    struct Case: Sendable {
        let purpose: TrackPurpose
        let bytesPerSecond: Int
        let expected: SizeVerdict
    }

    static let cases: [Case] = [
        Case(purpose: .dictation, bytesPerSecond: 8_000, expected: .ok),  // 64 kbit/s nominal
        Case(purpose: .dictation, bytesPerSecond: 4_000, expected: .ok),  // exactly the floor
        Case(purpose: .dictation, bytesPerSecond: 3_999, expected: .suspicious),
        Case(purpose: .dictation, bytesPerSecond: 2_000, expected: .suspicious),
        Case(purpose: .dictation, bytesPerSecond: 100, expected: .lost),
        Case(purpose: .call, bytesPerSecond: 12_000, expected: .ok),  // 96 kbit/s nominal
        Case(purpose: .call, bytesPerSecond: 6_000, expected: .ok),
        Case(purpose: .call, bytesPerSecond: 5_999, expected: .suspicious),
        Case(purpose: .call, bytesPerSecond: 100, expected: .lost),
        Case(purpose: .room, bytesPerSecond: 6_000, expected: .ok),
        Case(purpose: .room, bytesPerSecond: 5_999, expected: .suspicious),
        Case(purpose: .room, bytesPerSecond: 100, expected: .lost),
    ]

    @Test(arguments: cases)
    func verdictFollowsTheByteFloor(_ c: Case) {
        #expect(verdict(bytes: c.bytesPerSecond * 60, seconds: 60, purpose: c.purpose) == c.expected)
    }

    @Test(arguments: [TrackPurpose.dictation, .call, .room])
    func emptyOrHeaderOnlyFileIsLostNeverOk(purpose: TrackPurpose) {
        // Panotti's case: a recording of a minute whose file holds nothing.
        #expect(verdict(bytes: 0, seconds: 60, purpose: purpose) == .lost)
        #expect(verdict(bytes: 7, seconds: 60, purpose: purpose) == .lost)  // one ADTS header, no frame
    }

    @Test func realWriterOutputMeetsTheFloor() async throws {
        let s = try Scratch()
        defer { s.remove() }
        for (purpose, floor) in [(TrackPurpose.dictation, 4_000), (.call, 6_000), (.room, 6_000)] {
            let (writer, url) = try await openWriter(s, name: "\(purpose).aac", purpose: purpose)
            await append(writer, seconds: 10)
            let report = await writer.close(reason: .normal, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:)
            #expect(report.verdict == .ok)  // ASSUMPTION: CloseReport.verdict
            #expect(fileSize(url) >= floor * 10)
        }
    }

    /// The elapsed time says 60 s, but the file holds 3 s: the audio went missing, and the track says so.
    @Test func shortFileAgainstElapsedTimeIsReportedAndLogged() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, _) = try await openWriter(s)
        await append(writer, seconds: 3)
        let report = await writer.close(reason: .normal, elapsed: .seconds(60))  // ASSUMPTION: close(reason:elapsed:) takes the wall-clock duration
        #expect(report.verdict == .lost)
        let lost = await s.events("audio_lost")
        #expect(lost.count == 1)
        #expect(lost.first?.level == "error")
        #expect(await s.events("track_saved").isEmpty)  // ASSUMPTION: success is logged as track_saved, never together with audio_lost
    }

    @Test func belowTheFloorIsSuspiciousAndNeverSaved() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, _) = try await openWriter(s)
        await append(writer, seconds: 3)  // about 24,000 bytes
        let report = await writer.close(reason: .normal, elapsed: .seconds(10))  // 2,400 B/s: below 4,000, above lost
        #expect(report.verdict == .suspicious)
        #expect(!(await s.events("audio_verdaechtig")).isEmpty)
        #expect(await s.events("track_saved").isEmpty)  // ASSUMPTION: success is logged as track_saved
    }

    @Test func existingTruncatedFileIsCaughtByFileCheck() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, url) = try await openWriter(s)
        await append(writer, seconds: 10)
        _ = await writer.close(reason: .normal, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:)
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 40)  // artificially shortened
        try handle.close()
        #expect(SizeCheck.verdict(url: url, seconds: 10, purpose: .dictation) == .lost)  // ASSUMPTION: SizeCheck.verdict(url:seconds:purpose:) reads the size from disk
    }
}
