@_exported import FlowIQAudio
@_exported import FlowIQLog
@_exported import Synchronization

public enum SessionKind: String, Sendable { case call = "Call", room = "Raum" }
public enum TrackStatus: Sendable, Equatable { case running, gapFilling, ended(String) }
public struct SessionReport: Sendable { public let folder: URL, tracks: [TrackReport] }

/// `aacURL` is set while the `.aac` still exists: repacking failed or one of its checks did not pass.
public struct TrackReport: Sendable {
    public let name: TrackName, seconds: Double, bytes: Int, verdict: SizeVerdict, lateBuffers: Int
    public let m4aURL: URL?, aacURL: URL?
}

/// One call or room recording (A.5, B.2, B.3, R-038, R-046), stopped per A.5 point 3, then repacked.
public actor RecordingSession {
    /// Free bytes on the volume of a folder; nil when the system does not answer.
    public typealias FreeSpace = @Sendable (URL) -> Int64?
    static let warnBelow: Int64 = 1_000_000_000, stopBelow: Int64 = 200_000_000, diskEvery = Duration.seconds(10)
    private final class Track {
        let name: TrackName, writer: TrackWriter, release: @Sendable () async -> Void
        var guardian: TrackGuard, pump: Task<Void, Never>? = nil, ended: String? = nil
        init(_ name: TrackName, _ writer: TrackWriter, _ release: @escaping @Sendable () async -> Void) {
            (self.name, self.writer, self.release, guardian) = (name, writer, release, TrackGuard(kind: name))
        }
    }
    public nonisolated let folder: URL
    private nonisolated let queue = DispatchSerialQueue(label: "flowiq.recording.session", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let kind: SessionKind, fs: SafeFS, log: EventLog, freeSpace: FreeSpace
    private let lock: RecordingLock  // held for the whole session
    private let conductor: AudioConductor, started = ContinuousClock.now
    private var tracks: [Track] = [], stopping: Task<SessionReport, Never>?, diskChecked: ContinuousClock.Instant?
    private var diskWarned = false, diskUnknown = false
    private init(kind: SessionKind, folder: URL, conductor: AudioConductor, fs: SafeFS, log: EventLog,
                 lock: RecordingLock, freeSpace: @escaping FreeSpace) {
        (self.kind, self.folder, self.conductor, self.fs, self.log) = (kind, folder, conductor, fs, log)
        (self.lock, self.freeSpace) = (lock, freeSpace)
    }
    /// `folder` is the profile's `laufend/`, which `lock` must hold; the session folder is `<stamp> Call|Raum`.
    public static func start(kind: SessionKind, conductor: AudioConductor, folder: URL, stamp: String, fs: SafeFS,
                             log: EventLog, lock: RecordingLock,
                             freeSpace: @escaping FreeSpace = volumeFree) async throws -> RecordingSession {
        guard lock.folder.standardizedFileURL == folder.standardizedFileURL else { throw RecordingError.notLocked }
        let dir = folder.appending(path: "\(stamp) \(kind.rawValue)", directoryHint: .isDirectory)
        let session = RecordingSession(kind: kind, folder: dir, conductor: conductor, fs: fs, log: log, lock: lock,
                                       freeSpace: freeSpace)
        try await session.begin()
        return session
    }
    public static let volumeFree: FreeSpace = { url in
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        do {  // a fresh URL: resource values are cached per URL object
            return try URL(filePath: url.path).resourceValues(forKeys: [key]).volumeAvailableCapacityForImportantUsage
        } catch {
            return nil
        }
    }
    public func writtenSeconds(of name: TrackName) async -> Double { await track(name)?.writer.writtenSeconds ?? 0 }
    public func status(of name: TrackName) async -> TrackStatus {
        guard let track = track(name) else { return .ended("none") }
        if let ended = track.ended { return .ended(ended) }
        if await track.writer.failure != nil { return .ended("failed") }
        return await conductor.isDown(name) ? .gapFilling : .running
    }
    /// Why the session ended by itself or by a stop; nil while it runs (the app sees a disk-full end, A.5).
    public private(set) var endedBy: EndReason?
    public func stop(reason: EndReason) async -> SessionReport {
        if let stopping { return await stopping.value }
        endedBy = reason
        let task = Task { await self.finish(reason) }
        stopping = task
        return await task.value
    }
    private func track(_ name: TrackName) -> Track? { tracks.first { $0.name == name } }
    private func begin() async throws {
        let purpose: TrackPurpose = kind == .call ? .call : .room
        var leases: [(TrackName, AsyncStream<AudioChunk>, @Sendable () async -> Void)] = []
        do {
            let mic = try await conductor.acquireMic(for: kind == .call ? .call : .room)
            leases.append((.microphone, mic.chunks, { await mic.release(hold: .zero) }))
            if kind == .call {
                let desktop = try await conductor.acquireDesktop()
                leases.append((.desktop, desktop.chunks, { await desktop.release() }))
            }
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists) }
            try fs.makeFolder(folder)
            for (name, chunks, release) in leases {
                let url = folder.appending(path: "\(name.rawValue).aac")
                let writer = try await TrackWriter.create(url: url, purpose: purpose,
                                                          sampleRate: AudioChunk.channelRate, fs: fs, log: log)
                tracks.append(Track(name, writer, release))
                track(name)?.pump = Task { await self.pump(name, chunks) }
            }
        } catch {
            log.record(LogEvent("session_start_failed", level: .error, ["mode": .string(kind.rawValue)]))
            for (name, _, release) in leases where track(name) == nil { await release() }
            if !tracks.isEmpty { _ = await stop(reason: .normal) }
            throw error
        }
        log.record(LogEvent("session_started", ["mode": .string(kind.rawValue), "tracks": .int(Int64(tracks.count))]))
        checkDisk()
    }
    private func pump(_ name: TrackName, _ chunks: AsyncStream<AudioChunk>) async {
        guard let track = track(name) else { return }
        for await chunk in chunks {
            await track.writer.append(chunk)
            watch(track, chunk)
        }
    }
    /// Track guard (R-040) on every chunk, free disk space every 10 s of wall clock, whichever track delivers.
    private func watch(_ track: Track, _ chunk: AudioChunk) {
        let before = track.guardian.level
        let peer = track.name == .desktop ? (self.track(.microphone)?.guardian.hasTone ?? false) : true
        let level = track.guardian.ingest(chunk, peerHasTone: peer)
        if level != before {
            log.record(LogEvent("track_warning", level: level == .none ? .info : .error,
                                ["track": .string(track.name.logName), "stage": .int(Int64(level.rawValue))]))
        }
        if let diskChecked, ContinuousClock.now - diskChecked < Self.diskEvery { return }
        checkDisk()
    }
    /// A.5: warning below 1 GB, clean end below 200 MB; an unreadable answer is an error, never "enough".
    private func checkDisk() {
        diskChecked = .now
        guard let free = freeSpace(folder) else {
            if !diskUnknown { log.record(LogEvent("disk_check_failed", level: .error, [:])) }
            diskUnknown = true
            return
        }
        diskUnknown = false
        if free < Self.stopBelow {
            log.record(LogEvent("disk_full", level: .error, ["mb": .int(free / 1_000_000)]))
            Task { _ = await self.stop(reason: .diskFull) }
        } else if free < Self.warnBelow, !diskWarned {
            diskWarned = true
            log.record(LogEvent("disk_low", level: .error, ["mb": .int(free / 1_000_000)]))
        }
    }
    private func finish(_ reason: EndReason) async -> SessionReport {
        let elapsed = ContinuousClock.now - started
        for track in tracks { await track.release() }  // the sources go first ...
        var reports: [TrackReport] = []
        for track in tracks {
            await track.pump?.value  // ... every chunk they delivered is drained ...
            let closed = await track.writer.close(reason: reason, elapsed: elapsed)  // ... then the file closes
            track.ended = reason.rawValue
            var m4a: URL? = nil, aac: URL? = track.writer.url
            do {
                let result = try Remux.toM4A(track.writer.url, source: closed, fs: fs, log: log)
                m4a = result.m4a
                if !result.keptSource { aac = nil }
            } catch {
                log.record(LogEvent("remux_failed", level: .error, ["track": .string(track.name.logName)]))
            }
            reports.append(TrackReport(name: track.name, seconds: closed.seconds, bytes: closed.bytes,
                                       verdict: closed.verdict, lateBuffers: closed.lateBuffers, m4aURL: m4a,
                                       aacURL: aac))
        }
        log.record(LogEvent("session_stopped", ["mode": .string(kind.rawValue), "reason": .string(reason.rawValue),
                                                "ms": .double(elapsed.inSeconds * 1000)]))
        return SessionReport(folder: folder, tracks: reports)
    }
}
