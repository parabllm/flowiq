import AVFoundation

/// `bytes` on disk after closing, `seconds` written; a report with a `failure` is never `ok`.
public struct CloseReport: Sendable, Equatable {
    public let reason: EndReason, bytes: Int, seconds: Double, verdict: SizeVerdict, lateBuffers: Int, failure: String?
}

/// SAFETY: one track on disk (A.5, S1): claimed once, never reopened, erased or recreated; ADTS frame by frame;
/// closing syncs and checks size on every path; late chunks only counted; the first error stops and is visible.
public actor TrackWriter {
    public enum State: Sendable, Equatable { case open, closing, closed }
    public nonisolated let url: URL, purpose: TrackPurpose
    /// Encoding and the blocking sync run on their own queue, never on the cooperative pool.
    private nonisolated let queue = DispatchSerialQueue(label: "flowiq.track.writer", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    public private(set) var state = State.open, lateBuffers = 0, failure: String? = nil
    private let log: EventLog, encoder: ADTSEncoder
    private var handle: FileHandle? = nil, inputFrames = 0, dropped = 0, report: CloseReport? = nil
    public static func create(url: URL, purpose: TrackPurpose, sampleRate: Double, fs: SafeFS,
                              log: EventLog) async throws -> TrackWriter {
        let encoder = try ADTSEncoder(sampleRate: sampleRate, bitRate: purpose.bitRate)
        try fs.claimNew(url)  // an existing path is an error, never an overwrite
        return TrackWriter(url: url, purpose: purpose, handle: try fs.appendHandle(url), encoder: encoder, log: log)
    }
    private init(url: URL, purpose: TrackPurpose, handle: FileHandle, encoder: ADTSEncoder, log: EventLog) {
        (self.url, self.purpose, self.handle, self.encoder, self.log) = (url, purpose, handle, encoder, log)
    }
    isolated deinit { if report == nil { close(reason: .abandoned, elapsed: nil) } }
    /// Audio that is on disk.
    public var writtenSeconds: Double { Double(min(inputFrames, encoder.encodedFrames)) / encoder.rate }
    /// Test seam: the descriptor of the open file.
    var descriptor: Int32? { handle?.fileDescriptor }
    public func append(_ chunk: AudioChunk) {
        guard state == .open else { return note(&lateBuffers, "late_buffers") }
        if chunk.sampleRate != encoder.rate { fail("rate") }  // visible at the first such chunk, not at the end
        guard failure == nil else { return note(&dropped, "track_dropped") }
        if write(encoder.encode(chunk.samples)) { inputFrames += chunk.samples.count }
    }
    /// Drains a lease stream; its end closes the writer with reason `sourceEnded`.
    public func consume(_ stream: AsyncStream<AudioChunk>) async -> CloseReport {
        for await chunk in stream { append(chunk) }
        return close(reason: .sourceEnded, elapsed: nil)
    }
    /// `elapsed` is the wall-clock length of the recording; nil takes the written audio instead.
    @discardableResult
    public func close(reason: EndReason, elapsed: Duration?) -> CloseReport {
        if let report { return report }
        state = .closing
        if failure == nil { write(encoder.finish()) }
        do {  // F_FULLFSYNC reaches the drive itself; plain fsync where a volume does not support it
            if let handle, fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
            try handle?.close()
        } catch {
            fail("sync")
        }
        (handle, state) = (nil, .closed)
        let (seconds, bytes) = (Double(inputFrames) / encoder.rate, SizeCheck.fileBytes(url))
        let measured = SizeCheck.verdict(bytes: bytes, seconds: elapsed?.inSeconds ?? seconds, purpose: purpose)
        let closed = CloseReport(reason: reason, bytes: bytes, seconds: seconds,
                                 verdict: failure == nil ? measured : .lost, lateBuffers: lateBuffers, failure: failure)
        report = closed
        var fields: [String: LogValue] = [
            "purpose": .string(purpose.rawValue), "reason": .string(reason.rawValue), "bytes": .int(Int64(bytes)),
            "ms": .double(seconds * 1000), "verdict": .string(closed.verdict.rawValue),
            "late": .int(Int64(lateBuffers)),
        ]
        if let failure { fields["failure"] = .string(failure) }
        log.record(LogEvent("track_closed", fields))
        switch closed.verdict {
        case .ok: log.record(LogEvent("track_saved", fields))
        case .suspicious: log.record(LogEvent("audio_verdaechtig", level: .error, fields))
        case .lost: log.record(LogEvent("audio_lost", level: .error, fields))
        }
        return closed
    }
    @discardableResult
    private func write(_ data: Data) -> Bool {
        if encoder.failed { fail("encode") }
        guard failure == nil, let handle else { return false }
        do { try handle.write(contentsOf: data) } catch { fail("write") }
        return failure == nil
    }
    private func fail(_ step: String) {
        guard failure == nil else { return }
        failure = step
        log.record(LogEvent("track_write_failed", level: .error,
                            ["purpose": .string(purpose.rawValue), "step": .string(step)]))
    }
    /// Dropped chunks are counted and logged at 1, 2, 4, 8 ...: visible, never a flood.
    private func note(_ count: inout Int, _ kind: String) {
        count += 1
        guard count & (count - 1) == 0 else { return }
        log.record(LogEvent(kind, level: .error, ["purpose": .string(purpose.rawValue), "total": .int(Int64(count))]))
    }
}
