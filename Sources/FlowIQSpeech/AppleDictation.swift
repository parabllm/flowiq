import AVFoundation
import Speech

/// The local dictation recognizer (A.6, K-01, appendix K 2): prepared at the key press, no terms, no network.
public struct AppleDictation: DictationRecognizer {
    public let locale: Locale
    public var log: EventLog?  // gets an error event for every file section that stays without text
    public init(locale: Locale = Locale(identifier: "de-DE")) { self.locale = locale }
    public func dictate(_ chunks: AsyncStream<AudioChunk>) async -> DictationRun {
        await DictationEnding.run(chunks) { [locale] in try await AppleAnalyzer.prepare(locale) }
    }
    public func recognizeFile(_ url: URL) async -> DictationRun {
        do {
            let seconds = try AVAudioFile(forReading: url).duration  // no fixed cap for a long locked dictation
            let file = try await FileTranscriber.recognize(url, locale: locale, limit: .seconds(60 + seconds), log: log)
            return DictationRun(recognition: Recognition(text: file.text, tokens: file.runs, segmentAlternatives:
                file.segments.map(\.alternatives), recognizerProfile: "speech-file"), failure: nil)
        } catch {
            return DictationRun(recognition: nil, failure: "file_run")
        }
    }
}

final class AppleAnalyzer: DictationAnalyzer {
    private struct Final: Sendable { let text: String, alternatives: [String], tokens: [TimedWord] }
    let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation, reader: Task<[Final], any Error>, format: AVAudioFormat
    private let converter = Mutex<AVAudioConverter?>(nil)
    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation,
                 reader: Task<[Final], any Error>, format: AVAudioFormat) {
        (self.analyzer, self.input, self.reader, self.format) = (analyzer, input, reader, format)
    }
    static func prepare(_ locale: Locale, onResult: (@Sendable (SpeechTranscriber.Result) -> Void)? = nil)
        async throws -> AppleAnalyzer {
        let module = FileTranscriber.module(locale, volatile: onResult != nil)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw FileTranscriber.Failure(reason: "format")
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated,
                                                                         modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        let reader = Task {
            var finals: [Final] = []
            for try await result in module.results {
                onResult?(result)  // live gets every result, volatile ones too, and nothing is collected
                guard result.isFinal, onResult == nil else { continue }
                let tokens = result.text.runs.map { run in
                    TimedWord(text: String(result.text[run.range].characters),
                              start: run.audioTimeRange?.start.seconds ?? result.range.start.seconds,
                              end: run.audioTimeRange?.end.seconds ?? result.range.end.seconds,
                              confidence: run.transcriptionConfidence)
                }
                finals.append(Final(text: String(result.text.characters).trimmingCharacters(in: .whitespaces),
                                    alternatives: result.alternatives.map { String($0.characters) }, tokens: tokens))
            }
            return finals
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        return AppleAnalyzer(analyzer: analyzer, input: input, reader: reader, format: format)
    }
    /// Mono Float at the chunk rate into the analyzer format; the converter keeps its state across chunks.
    func feed(_ chunk: AudioChunk) throws {
        let frames = AVAudioFrameCount(chunk.samples.count)
        guard frames > 0 else { return }
        let buffer = try converter.withLock { converter -> AVAudioPCMBuffer in
            guard let source = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1),
                  let pcm = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { throw Failed() }
            pcm.frameLength = frames
            pcm.floatChannelData?[0].update(from: chunk.samples, count: Int(frames))
            if converter?.inputFormat != source { converter = AVAudioConverter(from: source, to: format) }
            let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / chunk.sampleRate) + 64
            guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw Failed()
            }
            var fed = false, error: NSError? = nil
            let status = converter.convert(to: out, error: &error) { _, state in
                state.pointee = fed ? .noDataNow : .haveData
                defer { fed = true }
                return fed ? nil : pcm
            }
            guard status != .error, error == nil else { throw Failed() }
            return out
        }
        input.yield(AnalyzerInput(buffer: buffer))
    }
    func finish() async throws -> Recognition {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let finals = try await reader.value.filter { !$0.text.isEmpty }
        return Recognition(text: finals.map(\.text).joined(separator: " "), tokens: finals.flatMap(\.tokens),
                           segmentAlternatives: finals.map(\.alternatives), recognizerProfile: "speech-live")
    }
    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        reader.cancel()
    }
    private struct Failed: Error {}
}

extension AVAudioFile { var duration: Double { Double(length) / processingFormat.sampleRate } }
