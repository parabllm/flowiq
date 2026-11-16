import AVFoundation
import AudioToolbox

/// SAFETY: repacks ADTS into `.m4a` via `<track>.teil.m4a` (A.5); the `.aac` goes only when frames, format, read-back
/// duration and size verdict all pass, otherwise both stay and the log names the failed checks.
enum Remux {
    struct Result { let m4a: URL, seconds: Double, keptSource: Bool }
    static let tolerance = 0.5, batch = 4_096, maxFrame = 8_192
    static func toM4A(_ aac: URL, source: CloseReport? = nil, fs: SafeFS, log: EventLog) throws -> Result {
        let data = try Data(contentsOf: aac, options: .alwaysMapped), base = aac.deletingPathExtension()
        let (m4a, part) = (base.appendingPathExtension("m4a"), base.appendingPathExtension("teil.m4a"))
        let existing = FileManager.default.fileExists(atPath: m4a.path)  // renamed, but the abort came before cleanup
        if !existing, FileManager.default.fileExists(atPath: part.path) {
            try fs.delete(part)  // derived from the `.aac`, which is still here
            log.record(LogEvent("remux_restarted", ["track": .string(base.lastPathComponent)]))
        }
        let scan = try data.withUnsafeBytes { try frames($0, writingTo: existing ? nil : part, fs: fs) }
        if !existing { try fs.move(part, to: m4a) }
        let readBack = try AVAudioFile(forReading: m4a)
        let seconds = Double(readBack.length) / readBack.processingFormat.sampleRate
        var failed: [String] = []
        if data.count - scan.used >= (source == nil ? maxFrame : 1) { failed.append("frames") }
        if abs(seconds - scan.seconds) > tolerance { failed.append("readback") }
        if let source, abs(seconds - source.seconds) > tolerance { failed.append("samples") }
        if let source, source.verdict != .ok { failed.append("source") }
        guard failed.isEmpty else {
            let checks = failed.joined(separator: ",")
            log.record(LogEvent("remux_kept_source", level: .error,
                                ["track": .string(base.lastPathComponent), "checks": .string(checks)]))
            return Result(m4a: m4a, seconds: seconds, keptSource: true)
        }
        try fs.delete(aac)
        return Result(m4a: m4a, seconds: seconds, keptSource: false)
    }
    /// Walks the frames up to the first invalid one or a change of format; writes them to `url` when given.
    private static func frames(_ raw: UnsafeRawBufferPointer, writingTo url: URL?,
                               fs: SafeFS) throws -> (seconds: Double, used: Int) {
        guard let first = ADTSFrame(raw, at: 0), let base = raw.baseAddress else { throw RecordingError.noAudio }
        var format = first.format
        let check = ADTSFrame.check
        let file = try url.map { url in
            try fs.createNew(url) { url -> AudioFileID in
                var file: AudioFileID?
                try check(AudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, [], &file))
                guard let file else { throw RecordingError.noAudio }
                return file
            }
        }
        var (offset, start, packets) = (0, 0, Int64(0))
        var descriptions: [AudioStreamPacketDescription] = []
        func flush() throws {
            defer { descriptions = [] }
            guard let file, !descriptions.isEmpty else { return }
            var count = UInt32(descriptions.count)
            let firstPacket = packets - Int64(count)
            try check(AudioFileWritePackets(file, false, UInt32(offset - start), descriptions, firstPacket, &count,
                                            base + start))
        }
        do {
            if let file {
                let cookie = try ADTSFrame.magicCookie(for: format)
                try check(AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, UInt32(cookie.count), cookie))
            }
            while let frame = ADTSFrame(raw, at: offset), frame.rate == first.rate, frame.channels == first.channels {
                if descriptions.isEmpty { start = offset }
                descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(offset + frame.header - start),
                                                                 mVariableFramesInPacket: 0,
                                                                 mDataByteSize: UInt32(frame.length - frame.header)))
                (offset, packets) = (offset + frame.length, packets + 1)
                if descriptions.count == batch { try flush() }
            }
            try flush()
        } catch {
            if let file { AudioFileClose(file) }
            throw error
        }
        if let file { try check(AudioFileClose(file)) }
        return (Double(packets) * Double(ADTSEncoder.packetFrames) / first.rate, offset)
    }
}
