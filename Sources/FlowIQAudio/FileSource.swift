import AVFoundation

/// An audio file as microphone (development, tests, A.12): mono 48 kHz in 100 ms chunks, then silence until `stop`.
public final class FileSource: CaptureSource {
    public let kind: SourceKind
    private let url: URL, speed: Double, player = Mutex<Task<Void, Never>?>(nil)
    public init(url: URL, speed: Double = 1) {
        self.url = url
        self.speed = speed
        kind = .file(url)
    }
    public func start(deliver: @escaping @Sendable (AudioChunk) -> Void,
                      onEnd: @escaping @Sendable (CaptureEnd) -> Void) async throws {
        _ = try AVAudioFile(forReading: url)  // unreadable files fail here, not later in the player
        let (url, speed, rate) = (url, speed, AudioChunk.channelRate)
        let task = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let (begin, origin) = (clock.now, DispatchTime.now().uptimeNanoseconds)
            var reader: FileReader?
            do { reader = try FileReader(url) } catch { return onEnd(.failed("file unreadable")) }
            var position = 0
            while !Task.isCancelled {
                var samples = reader?.next() ?? []
                if samples.isEmpty { reader = nil }
                samples += [Float](repeating: 0, count: max(0, FileReader.step - samples.count))
                deliver(AudioChunk(hostTime: origin + UInt64(Double(position) / rate * 1e9), sampleRate: rate,
                                   samples: samples))
                position += samples.count
                do { try await clock.sleep(until: begin + .seconds(Double(position) / rate / speed)) } catch { return }
            }
        }
        player.withLock { $0 = task }
    }
    public func stop() async {
        let task = player.withLock { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        task?.cancel()
        await task?.value
    }
}

/// Reads a file block by block and converts it to Float32 mono at the channel rate.
private final class FileReader {
    static let step = Int(AudioChunk.channelRate / 10)
    private let file: AVAudioFile, converter: AVAudioConverter, target: AVAudioFormat
    private var ended = false
    init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.channelRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioError.rejected
        }
        converter.downmix = true
        (self.target, self.converter) = (target, converter)
    }
    /// The next block, empty at the end of the file.
    func next() -> [Float] {
        guard !ended, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Self.step)) else {
            return []
        }
        let (file, frames) = (file, AVAudioFrameCount(Self.step))
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                state.pointee = .endOfStream
                return nil
            }
            do { try file.read(into: block, frameCount: frames) } catch { block.frameLength = 0 }
            state.pointee = block.frameLength == 0 ? .endOfStream : .haveData
            return block.frameLength == 0 ? nil : block
        }
        if status == .endOfStream || status == .error { ended = true }
        guard let channel = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
