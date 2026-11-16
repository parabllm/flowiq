import AVFoundation

/// Pieces of a closed track for the OpenRouter after-run (16.11.), seam `CloudGate.batchService(pieces:)`.
public enum AudioPieces {
    /// One window as AAC or FLAC through SafeFS, read back and deleted; an empty window measures the length.
    public static func cut(_ file: URL, _ window: Range<Double>, _ format: String, fs: SafeFS, folder: URL) throws
        -> (data: Data, seconds: Double) {
        let source = try AVAudioFile(forReading: file), pcm = source.processingFormat, rate = pcm.sampleRate
        let seconds = Double(source.length) / rate
        guard !window.isEmpty else { return (Data(), seconds) }
        source.framePosition = AVAudioFramePosition(window.lowerBound * rate)
        let end = min(source.length, AVAudioFramePosition(window.upperBound * rate))
        let out = folder.appending(path: "stueck-\(UUID().uuidString).\(format)")
        let codec: [String: Any] = format == "flac" ? [AVFormatIDKey: kAudioFormatFLAC]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC]  // default bit rate fits every source rate
        try fs.makeFolder(folder)
        try fs.createNew(out) { url in
            let writer = try AVAudioFile(forWriting: url, settings: codec.merging([AVSampleRateKey: rate,
                AVNumberOfChannelsKey: pcm.channelCount]) { a, _ in a }, commonFormat: pcm.commonFormat,
                                         interleaved: pcm.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(rate)) else {
                throw PostFailure.empty
            }
            while source.framePosition < end {
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(rate),
                                                                                end - source.framePosition)))
                try writer.write(from: buffer)
            }
        }
        let data = try Data(contentsOf: out)
        try fs.delete(out)
        return (data, seconds)
    }
}
