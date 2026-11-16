import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQLog
@testable import FlowIQRecording

/// Own tests beyond the P3 acceptance set: write errors, repacking checks, rescue after an abort while
/// repacking, delivery before "rescued", the busy marker contract with bundle.sh, disk space, the encoder.
struct RecordingTests {
    let root: URL
    let paths: Paths
    let fs: SafeFS
    let log: EventLog

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-rec-\(UUID().uuidString)")
        paths = Paths(profile: .development, applicationSupport: root)
        fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        log = EventLog(directory: paths.log, fs: fs)
    }

    private func cleanup() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
    }

    private func chunk(_ index: Int, rate: Double = 48_000) -> AudioChunk {
        let count = Int(rate / 10)
        let samples = (0..<count).map { Float(sin(Double(index * count + $0) * 0.05)) * 0.3 }
        return AudioChunk(hostTime: UInt64(index) * 100_000_000, sampleRate: rate, samples: samples)
    }

    @discardableResult
    private func write(_ url: URL, seconds: Int, purpose: TrackPurpose = .room) async throws -> CloseReport {
        let writer = try await TrackWriter.create(url: url, purpose: purpose, sampleRate: 48_000, fs: fs, log: log)
        for index in 0..<(seconds * 10) { await writer.append(chunk(index)) }
        return await writer.close(reason: .normal, elapsed: nil)
    }

    private func events(_ kind: String) async throws -> [[String: Any]] {
        await log.flush()
        let text = try String(contentsOf: paths.log.appending(path: "ereignisse.ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["kind"] as? String == kind }
    }

    private func visible(_ folder: URL) -> [String] {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return names.filter { !$0.hasPrefix(".") }.sorted()
        } catch {
            return []
        }
    }

    // MARK: Writer

    /// Review A1: the disk goes away after 60 % of the recording; the track must never end as saved.
    @Test func writeErrorLateInTheRecordingIsNeverSaved() async throws {
        defer { cleanup() }
        let writer = try await TrackWriter.create(url: paths.laufend.appending(path: "kaputt.aac"), purpose: .dictation,
                                                  sampleRate: 48_000, fs: fs, log: log)
        for index in 0..<100 {
            if index == 60, let descriptor = await writer.descriptor {  // writes fail from here on (EBADF)
                let readOnly = open("/dev/null", O_RDONLY)
                dup2(readOnly, descriptor)
                close(readOnly)
            }
            await writer.append(chunk(index))
        }
        let report = await writer.close(reason: .normal, elapsed: nil)
        #expect(report.failure == "write")
        #expect(report.verdict == .lost)
        #expect(report.seconds <= 6.01)  // only what reached the disk
        #expect(try await events("track_saved").isEmpty)
        #expect(try await !events("track_write_failed").isEmpty)
        #expect(try await events("audio_lost").first?["failure"] as? String == "write")
    }

    /// Review A6: a chunk at another rate is a visible track error at the first chunk, not a surprise at the end.
    @Test func wrongSampleRateFailsTheTrackAtTheFirstChunk() async throws {
        defer { cleanup() }
        let writer = try await TrackWriter.create(url: paths.laufend.appending(path: "rate.aac"), purpose: .room,
                                                  sampleRate: 48_000, fs: fs, log: log)
        await writer.append(chunk(0, rate: 24_000))
        #expect(await writer.failure == "rate")
        #expect(try await events("track_write_failed").first?["step"] as? String == "rate")
        for index in 1..<20 { await writer.append(chunk(index)) }
        let report = await writer.close(reason: .normal, elapsed: nil)
        #expect(report.verdict == .lost)
        #expect(try await events("track_saved").isEmpty)
    }

    @Test(arguments: [64_000, 96_000])
    func encoderKeepsItsBitRateAndEveryFrameParses(bitRate: Int) throws {
        let encoder = try ADTSEncoder(sampleRate: 48_000, bitRate: bitRate)
        var data = Data()
        for index in 0..<100 { data += encoder.encode(chunk(index).samples) }
        data += encoder.finish()
        #expect(encoder.encodedFrames >= 480_000)
        let perSecond = Double(data.count) / 10
        #expect(perSecond >= Double(bitRate) / 8 && perSecond <= Double(bitRate) / 8 * 1.05)
        let frames = data.withUnsafeBytes { raw -> Int in
            var (offset, count) = (0, 0)
            while let frame = ADTSFrame(raw, at: offset) { (offset, count) = (offset + frame.length, count + 1) }
            return offset == raw.count ? count : -1
        }
        #expect(frames * ADTSEncoder.packetFrames >= 480_000)
    }

    // MARK: Repacking and rescue

    @Test func tornFileIsRepackedAndTheSourceGoesOnlyAfterTheCheck() async throws {
        defer { cleanup() }
        let url = paths.laufend.appending(path: "torn.aac")
        try await write(url, seconds: 5)
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: try handle.seekToEnd() - 300)
        try handle.close()
        let result = try Remux.toM4A(url, fs: fs, log: log)
        #expect(!result.keptSource)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(abs(result.seconds - 5) <= 0.1)
    }

    /// Review A2: a broken frame in the middle; the `.aac` stays, the `.m4a` holds what came before, the log says why.
    @Test(arguments: [true, false])
    func brokenFrameInTheMiddleKeepsTheSource(writerKnown: Bool) async throws {
        defer { cleanup() }
        let url = paths.laufend.appending(path: "mitte.aac")
        let report = try await write(url, seconds: 10)
        var data = try Data(contentsOf: url)
        let middle = data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count / 2, let frame = ADTSFrame(raw, at: offset) { offset += frame.length }
            return offset
        }
        data[middle] = 0  // first byte of the sync word
        try data.write(to: url)
        let result = try Remux.toM4A(url, source: writerKnown ? report : nil, fs: fs, log: log)
        #expect(result.keptSource)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(result.seconds < 6)
        #expect(try await !events("remux_kept_source").isEmpty)
    }

    @Test func repackingNeverOverwritesAnExistingFile() async throws {
        defer { cleanup() }
        let url = paths.laufend.appending(path: "twice.aac")
        try await write(url, seconds: 2)
        let m4a = url.deletingPathExtension().appendingPathExtension("m4a")
        try fs.claimNew(m4a, with: Data([1, 2, 3]))
        #expect(throws: (any Error).self) { _ = try Remux.toM4A(url, fs: fs, log: log) }
        #expect(try Data(contentsOf: m4a) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Review A3: an abort while repacking left a part file, or a finished `.m4a` before the `.aac` was removed.
    /// The next start finishes the job and delivers; nothing stays in `laufend/`.
    @Test(arguments: ["part", "finished"])
    func abortWhileRepackingIsFinishedAtTheNextStart(left: String) async throws {
        defer { cleanup() }
        let name = "2026-01-01 08-00-00 Raum"
        let folder = paths.laufend.appending(path: name)
        try fs.makeFolder(folder)
        let aac = folder.appending(path: "mikrofon.aac")
        try await write(aac, seconds: 5)
        if left == "part" {
            try fs.claimNew(folder.appending(path: "mikrofon.teil.m4a"), with: Data(repeating: 1, count: 500))
        } else {
            let doubt = CloseReport(reason: .normal, bytes: 0, seconds: 5, verdict: .suspicious, lateBuffers: 0,
                                    failure: nil)
            #expect(try Remux.toM4A(aac, source: doubt, fs: fs, log: log).keptSource)  // both files now exist
        }
        let delivered = paths.support.appending(path: "abgeliefert")
        let report = try await Rescue.run(laufend: paths.laufend, deliverTo: delivered, fs: fs, log: log)
        #expect(report.failed.isEmpty)
        #expect(report.rescuedTracks.map(\.url.lastPathComponent) == ["mikrofon.m4a"])
        #expect(visible(paths.laufend).isEmpty)
        #expect(visible(delivered.appending(path: name)) == ["mikrofon.m4a"])
    }

    /// Review A4: a track counts as rescued only once it is delivered; an undeliverable folder leaves `laufend/`.
    @Test func undeliverableFolderIsNotCountedAndLeavesLaufend() async throws {
        defer { cleanup() }
        let name = "2026-01-01 07-00-00 Call"
        try fs.makeFolder(paths.laufend.appending(path: name))
        try await write(paths.laufend.appending(path: "\(name)/mikrofon.aac"), seconds: 3)
        let delivered = paths.support.appending(path: "abgeliefert")
        try fs.makeFolder(delivered.appending(path: name))  // the target is taken
        let report = try await Rescue.run(laufend: paths.laufend, deliverTo: delivered, fs: fs, log: log)
        #expect(report.rescuedTracks.isEmpty)
        #expect(!report.failed.isEmpty)
        #expect(visible(paths.laufend).isEmpty)
        #expect(visible(paths.support.appending(path: "zu-pruefen/\(name)")) == ["mikrofon.m4a"])
    }

    // MARK: Busy marker and disk space

    @Test func busyMarkerCarriesThePidForBundleScriptAndGoesWithTheLastReason() async throws {
        defer { cleanup() }
        let busy = BusyState(paths: paths, fs: fs, pid: 4_242)
        try await busy.begin(.recording)
        try await busy.begin(.recording)
        try await busy.begin(.dictation)
        let text = try String(contentsOf: busy.file, encoding: .utf8)
        #expect(text.contains("\"pid\":4242"))  // the pattern scripts/bundle.sh reads
        try await busy.end(.recording)
        try await busy.end(.dictation)
        #expect(await busy.reasons == [.recording])
        #expect(FileManager.default.fileExists(atPath: busy.file.path))
        try await busy.end(.recording)
        try await busy.end(.recording)  // one end too many changes nothing
        #expect(await busy.reasons.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: busy.file.path))
    }

    private func session(freeSpace: @escaping RecordingSession.FreeSpace) async throws
        -> (RecordingSession, ManualSource) {
        let source = ManualSource()
        let conductor = AudioConductor(microphone: { _ in source }, desktop: { source },
                                       devices: DeviceSetup(standard: InputDevice(uid: "m", isBuiltIn: true),
                                                            fallback: nil), log: log)
        let lock = try RecordingLock.acquire(in: paths.laufend)
        let session = try await RecordingSession.start(kind: .room, conductor: conductor, folder: paths.laufend,
                                                       stamp: "2026-01-01 09-00-00", fs: fs, log: log, lock: lock,
                                                       freeSpace: freeSpace)
        return (session, source)
    }

    @Test func almostFullDiskEndsTheRecordingCleanly() async throws {
        defer { cleanup() }
        let (session, _) = try await session(freeSpace: { _ in 150_000_000 })
        var ended = false
        for _ in 0..<300 where !ended {
            ended = await session.status(of: .microphone) == .ended(EndReason.diskFull.rawValue)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ended)
        #expect(try await events("disk_full").first?["level"] as? String == "error")
    }

    /// Review A5: an unanswered question for free space is an error, never "plenty".
    @Test func unreadableFreeSpaceIsReportedAsAnError() async throws {
        defer { cleanup() }
        let (session, source) = try await session(freeSpace: { _ in nil })
        for index in 0..<30 { source.emit(chunk(index)) }
        #expect(try await events("disk_check_failed").first?["level"] as? String == "error")
        #expect(await session.status(of: .microphone) == .running)  // recording goes on, the warning is visible
        _ = await session.stop(reason: .normal)
    }
}

/// Minimal source for the session tests; the acceptance tests have the full synthetic source.
final class ManualSource: CaptureSource {
    let kind = SourceKind.microphone(InputDevice(uid: "m", isBuiltIn: true))
    private let deliver = Mutex<(@Sendable (AudioChunk) -> Void)?>(nil)

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
               onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        self.deliver.withLock { $0 = deliver }
    }

    func stop() async { deliver.withLock { $0 = nil } }

    func emit(_ chunk: AudioChunk) { deliver.withLock { $0 }?(chunk) }
}
