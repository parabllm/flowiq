// Group 1: late buffers after stop (A.5 points 1, 3, 4; G.2 "Recording"; Panotti S1: 72 empty audios).
// The writer creates the file once, never reopens it, closes only after the source is gone, and
// anything arriving after `closing` is discarded and counted as `late_buffers`.
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQRecording

struct LateBuffersTests {
    @Test(arguments: allEndReasons)
    func lateBuffersNeverEmptyOrReopenTheFile(reason: EndReason) async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, url) = try await openWriter(s)
        await append(writer, seconds: 3)

        _ = await writer.close(reason: reason, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:) returns a CloseReport; nil elapsed means derive from written frames
        let sizeAtClose = fileSize(url)
        let fileNumber = inode(url)
        #expect(sizeAtClose >= 12_000)  // 3 s at the 4,000 B/s floor

        // The late callback of Panotti's bug: the source still delivers after close.
        await append(writer, from: 3, seconds: 2)
        try await Task.sleep(for: .milliseconds(200))

        #expect(fileSize(url) == sizeAtClose)
        #expect(inode(url) == fileNumber)  // same file, never recreated
        #expect(await writer.lateBuffers == 20)  // ASSUMPTION: lateBuffers is an async actor property
        #expect(await writer.state == .closed)  // ASSUMPTION: state enum open, closing, closed (A.5)
        #expect(!(await s.events("late_buffers")).isEmpty)
        #expect(listing(s.laufend) == ["diktat.aac"])  // no second writer, no stray file
    }

    @Test func closeIsIdempotentAndStaysClosed() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, url) = try await openWriter(s)
        await append(writer, seconds: 2)
        let first = await writer.close(reason: .normal, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:)
        let size = fileSize(url)
        let second = await writer.close(reason: .escape, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:)
        #expect(fileSize(url) == size)
        #expect(second.bytes == first.bytes)  // ASSUMPTION: CloseReport.bytes
        let closedEvents = await s.events("track_closed")  // ASSUMPTION: event kind track_closed, one per writer
        #expect(closedEvents.count == 1)
    }

    @Test func secondWriterOnTheSamePathIsRefusedAndFileIsUntouched() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, url) = try await openWriter(s)
        await append(writer, seconds: 2)
        _ = await writer.close(reason: .normal, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:)
        let before = fileSize(url)
        let fileNumber = inode(url)

        await #expect(throws: (any Error).self) {
            _ = try await openWriter(s)  // claimNew: an existing path is an error, never an overwrite
        }
        #expect(fileSize(url) == before)
        #expect(inode(url) == fileNumber)
    }

    @Test func fileNeverShrinksWhileCloseRacesWithBuffers() async throws {
        let s = try Scratch()
        defer { s.remove() }
        let (writer, url) = try await openWriter(s)
        await append(writer, seconds: 1)

        let sampler = Task { () -> [Int] in
            var sizes: [Int] = []
            while !Task.isCancelled {
                sizes.append(fileSize(url))
                do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
            }
            return sizes
        }
        let producer = Task { await append(writer, from: 1, seconds: 4) }
        try await Task.sleep(for: .milliseconds(20))
        _ = await writer.close(reason: .deadline, elapsed: nil)  // ASSUMPTION: close(reason:elapsed:)
        _ = await producer.value  // COMPILE-FIX (P3 build): unused Double is an error with warnings as errors
        sampler.cancel()
        let sizes = await sampler.value

        let firstFilled = sizes.firstIndex { $0 > 0 } ?? sizes.count
        let afterFirst = Array(sizes[firstFilled...])
        #expect(zip(afterFirst, afterFirst.dropFirst()).allSatisfy { $0 <= $1 })  // monotonic: never emptied, never shrunk
        #expect(afterFirst.allSatisfy { $0 > 0 })
        #expect(fileSize(url) == sizes.last)
    }

    /// Order of the end: source off first, queue drained, then close. A slow `stop()` keeps delivering;
    /// closing before the source is gone (Panotti's order) would turn those buffers into late ones.
    @Test func sourceIsStoppedBeforeTheFileIsClosed() async throws {
        let rig = try Rig(micStopDelay: .milliseconds(400))
        defer { rig.remove() }
        let session = try await startSession(.room, rig: rig)
        let source = try #require(rig.mics.current)
        let resume = feed(source, from: 0, seconds: 3)

        let emitter = Task { () -> Double in
            var position = resume
            while source.phase != .stopped {
                position = feed(source, from: position, seconds: 0.1)
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
            return position
        }
        let report = await session.stop(reason: .normal)  // ASSUMPTION: stop(reason:) -> SessionReport with tracks
        _ = await emitter.value
        let track = try #require(report.tracks.first { $0.name == .microphone })  // ASSUMPTION: SessionReport.tracks[].name

        #expect(source.phase == .stopped)
        #expect(track.lateBuffers == 0)  // ASSUMPTION: TrackReport.lateBuffers
        #expect(abs(track.seconds - source.deliveredSeconds) <= 0.15)  // everything the source delivered while stopping is in the file
        #expect(track.verdict == .ok)  // ASSUMPTION: TrackReport.verdict
    }

    @Test func rogueBufferAfterStopDoesNotReopenOrChangeAnything() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let session = try await startSession(.room, rig: rig)
        let source = try #require(rig.mics.current)
        feed(source, from: 0, seconds: 3)
        let report = await session.stop(reason: .escape)  // ASSUMPTION: stop(reason:)
        let track = try #require(report.tracks.first { $0.name == .microphone })  // ASSUMPTION: SessionReport.tracks[].name
        let finalFile = try #require(track.m4aURL ?? track.aacURL)  // ASSUMPTION: TrackReport.m4aURL (after remux) and aacURL
        let folder = finalFile.deletingLastPathComponent()
        let before = listing(folder)
        let size = fileSize(finalFile)

        for i in 0..<20 { source.emitRogue(chunk(Signal.sine(count: 4_800), at: 3 + Double(i) * 0.1)) }
        try await Task.sleep(for: .milliseconds(300))

        #expect(listing(folder) == before)
        #expect(fileSize(finalFile) == size)
        #expect(size >= 3 * 4_000)
    }

    @Test func writerDroppedWithoutExplicitCloseKeepsItsDataAndClosesOnce() async throws {
        let s = try Scratch()
        defer { s.remove() }
        var url: URL?
        do {
            let (writer, fileURL) = try await openWriter(s)
            url = fileURL
            await append(writer, seconds: 2)
            // writer goes out of scope without close: the deinit path of A.5 point 4
        }
        let file = try #require(url)
        #expect(await eventually { (await s.events("track_closed")).count == 1 })  // ASSUMPTION: deinit logs track_closed
        #expect(fileSize(file) >= 2 * 4_000)
    }
}
