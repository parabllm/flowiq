/// The dictation recognizer (A.6): every chunk from the key press on; `recognizeFile` runs over the spool file.
public protocol DictationRecognizer: Sendable {
    func dictate(_ chunks: AsyncStream<AudioChunk>) async -> DictationRun
    func recognizeFile(_ url: URL) async -> DictationRun
}

extension DictationRecognizer {
    public func recognizeFile(_ url: URL) async -> DictationRun {
        DictationRun(recognition: nil, failure: "no_file_run")
    }
}

public struct DictationRun: Sendable {
    public let recognition: Recognition?, failure: String?  // one word (`prepare`, `deadline`, ...), never text
    public init(recognition: Recognition?, failure: String?) {
        (self.recognition, self.failure) = (recognition, failure)
    }
}

/// One prepared analyzer for one dictation: the seam between the ending rules and Apple's API (G.1).
protocol DictationAnalyzer: Sendable {
    func feed(_ chunk: AudioChunk) throws
    func finish() async throws -> Recognition
    func cancel() async
}

/// Dictation ending (A.6): chunks, 160 ms silence, finalize within 1.35 s, else `deadline` and the file run.
enum DictationEnding {
    static let deadline = Duration.milliseconds(1_350)
    static func run(_ chunks: AsyncStream<AudioChunk>, deadline: Duration = deadline,
                    prepare: @Sendable () async throws -> any DictationAnalyzer) async -> DictationRun {
        let analyzer: any DictationAnalyzer
        do { analyzer = try await prepare() } catch { return DictationRun(recognition: nil, failure: "prepare") }
        var last: AudioChunk?
        do {
            for await chunk in chunks {
                try analyzer.feed(chunk)
                last = chunk
            }
            let rate = last?.sampleRate ?? AudioChunk.channelRate
            let silence = [Float](repeating: 0, count: Int(rate * FileTranscriber.tailSilence))
            try analyzer.feed(AudioChunk(hostTime: last?.endTime ?? 0, sampleRate: rate, samples: silence))
        } catch {
            await analyzer.cancel()
            return DictationRun(recognition: nil, failure: "feed")
        }
        let recognition: Recognition?  // `within` is unstructured: a finalize ignoring cancellation never holds it up
        do { recognition = try await within(deadline) { try await analyzer.finish() } } catch {
            await analyzer.cancel()
            return DictationRun(recognition: nil, failure: "finish")
        }
        guard let recognition else {
            await analyzer.cancel()
            return DictationRun(recognition: nil, failure: "deadline")
        }
        return DictationRun(recognition: recognition, failure: nil)
    }
}
