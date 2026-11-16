import AVFoundation
import Speech

/// One final result in file seconds: its segment and its runs (words with time and confidence).
struct Piece: Sendable {
    var segment: FileRecognition.Segment, runs: [FileRecognition.Run]
    /// The words that start inside `owned`, nil when none does; a cut result loses its whole-segment alternatives.
    func keeping(_ owned: Range<Double>) -> Piece? {
        if runs.isEmpty { return owned.contains(segment.start) ? self : nil }
        let kept = runs.filter { owned.contains($0.start) }
        if kept.count == runs.count { return self }
        guard let first = kept.first, let last = kept.last else { return nil }
        let text = kept.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return Piece(segment: .init(text: text, start: first.start, end: last.end, alternatives: []), runs: kept)
    }
}

extension Piece {
    /// `offset` is the window start; a run without time sits at the end of the run before it (stays with its word).
    init(_ text: AttributedString, _ range: CMTimeRange, _ alternatives: [AttributedString], _ offset: Double) {
        let start = range.start.seconds + offset, end = range.end.seconds + offset
        segment = .init(text: String(text.characters).trimmingCharacters(in: .whitespaces), start: start, end: end,
                        alternatives: alternatives.map { String($0.characters) })
        var previous = start
        runs = text.runs.map { run in
            let time = run.audioTimeRange.map { ($0.start.seconds + offset, $0.end.seconds + offset) }
            defer { previous = time?.1 ?? previous }
            return FileRecognition.Run(text: String(text[run.range].characters), start: time?.0 ?? previous,
                                       end: time?.1 ?? previous, confidence: run.transcriptionConfidence)
        }
    }
}

/// Final pieces of one section as they arrive; after a deadline the section reads what is there.
final class Sink: Sendable {
    private let store = Mutex<[Piece]>([])
    func add(_ piece: Piece) { store.withLock { $0.append(piece) } }
    var pieces: [Piece] { store.withLock { $0 } }
}

extension FileTranscriber {
    /// Middle of the quietest 300 ms within `within` seconds of `mark`, in 100 ms steps: the cut falls into a pause.
    static func quietest(_ file: AVAudioFile, around mark: Double, within: Double) throws -> Double {
        let rate = file.processingFormat.sampleRate, from = max(0, mark - within)
        let step = AVAudioFrameCount(rate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step) else {
            throw Failure(reason: "buffer")
        }
        file.framePosition = AVAudioFramePosition(from * rate)
        var levels: [Float] = []
        while levels.count < Int(within * 20), file.framePosition < file.length {
            try file.read(into: buffer, frameCount: step)
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            var sum: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { sum += data[c][i] * data[c][i] }
            }
            levels.append(sum)
        }
        return from + (Double(quietest(levels)) + 0.5) / 10
    }
    /// Index of the middle of the quietest three neighbouring levels (the only one when there are fewer).
    static func quietest(_ levels: [Float]) -> Int {
        guard levels.count > 2 else { return 0 }
        let sums = (1..<levels.count - 1).map { (at: $0, sum: levels[$0 - 1] + levels[$0] + levels[$0 + 1]) }
        return sums.min { $0.sum < $1.sum }?.at ?? 0
    }
}

/// One window as analyzer input, a second at a time (back pressure), stereo mixed down, then the tail silence.
struct Feed: AsyncSequence, Sendable {
    let url: URL, window: Range<Double>, format: AVAudioFormat
    func makeAsyncIterator() -> Iterator { Iterator(feed: self) }
    struct Iterator: AsyncIteratorProtocol {
        let feed: Feed
        var source: (file: AVAudioFile, converter: AVAudioConverter, end: AVAudioFramePosition)? = nil
        var stage = 0 // 0 audio, 1 tail silence, 2 done
        mutating func next() async throws -> AnalyzerInput? {
            if stage == 2 { return nil }
            if stage == 1 {
                stage = 2
                return AnalyzerInput(buffer: try silence())
            }
            let (file, converter, end) = try source ?? open()
            source = (file, converter, end)
            guard let output = AVAudioPCMBuffer(pcmFormat: feed.format,
                                                frameCapacity: AVAudioFrameCount(feed.format.sampleRate)) else {
                throw FileTranscriber.Failure(reason: "buffer")
            }
            var failure: (any Error)?
            let status = converter.convert(to: output, error: nil) { wanted, state in
                let frames = AVAudioFrameCount(Swift.min(AVAudioFramePosition(wanted), end - file.framePosition))
                state.pointee = .endOfStream
                guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                               frameCapacity: frames) else { return nil }
                do { try file.read(into: input, frameCount: frames) } catch {
                    failure = error
                    return nil
                }
                if input.frameLength > 0 { state.pointee = .haveData }
                return input.frameLength > 0 ? input : nil
            }
            if let failure { throw failure }
            guard status != AVAudioConverterOutputStatus.error else { throw FileTranscriber.Failure(reason: "convert") }
            if status == .endOfStream { stage = 1 }
            return output.frameLength > 0 ? AnalyzerInput(buffer: output) : try await next()
        }
        func open() throws -> (AVAudioFile, AVAudioConverter, AVAudioFramePosition) {
            let file = try AVAudioFile(forReading: feed.url), rate = file.processingFormat.sampleRate
            guard let converter = AVAudioConverter(from: file.processingFormat, to: feed.format) else {
                throw FileTranscriber.Failure(reason: "converter")
            }
            converter.downmix = true
            file.framePosition = AVAudioFramePosition(feed.window.lowerBound * rate)
            return (file, converter, Swift.min(file.length, AVAudioFramePosition(feed.window.upperBound * rate)))
        }
        func silence() throws -> AVAudioPCMBuffer {
            let tail = AVAudioFrameCount(feed.format.sampleRate * FileTranscriber.tailSilence)
            guard let silence = AVAudioPCMBuffer(pcmFormat: feed.format, frameCapacity: tail) else {
                throw FileTranscriber.Failure(reason: "silence")
            }
            silence.frameLength = tail
            for channel in 0..<Int(feed.format.channelCount) {
                if let p = silence.int16ChannelData { p[channel].update(repeating: 0, count: Int(tail)) }
                if let p = silence.floatChannelData { p[channel].update(repeating: 0, count: Int(tail)) }
            }
            return silence
        }
    }
}
