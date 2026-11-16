import AVFoundation
import FlowIQLog
import Foundation
import Speech
import Synchronization
import Testing
@testable import FlowIQSpeech

/// The file run cuts long files into sections with a fresh analyzer each (rotation), merges them at their seams,
/// pulls audio a second at a time (back pressure) and gives every section a deadline. Here an artificial recognizer
/// sits behind the seam `SectionRecognizer`: word `wK` lies at K+0.1 to K+0.6 s of the file, so every whole second
/// plus 0.6 to 1.1 is a pause. Seven words make one result, with one alternative.
struct FileRunTests {
    final class Log: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    final class Fake: SectionRecognizer {
        /// Words from this file second on are never delivered; the run then hangs, ignoring cancel and stop.
        let hangAt: Double?
        let jitter: Double
        /// The run fails at once with this reason.
        let fails: String?
        let log: Log

        init(hangAt: Double? = nil, jitter: Double = 0, fails: String? = nil, log: Log) {
            self.hangAt = hangAt
            self.jitter = jitter
            self.fails = fails
            self.log = log
        }

        func run(_ window: Range<Double>, into sink: Sink) async throws {
            log.add("run \(window.lowerBound)..<\(window.upperBound)")
            if let fails { throw FileTranscriber.Failure(reason: fails) }
            let seconds = Array(Int(window.lowerBound.rounded(.up))..<Int(window.upperBound.rounded(.up)))
            for at in stride(from: 0, to: seconds.count, by: 7) {
                let group = seconds[at..<min(at + 7, seconds.count)]
                let words = group.filter { second in hangAt.map { Double(second) < $0 } ?? true }
                guard let first = words.first, let last = words.last else { break }
                let runs = words.map {
                    FileRecognition.Run(text: " w\($0)", start: Double($0) + 0.1 + jitter,
                                        end: Double($0) + 0.6 + jitter, confidence: 0.9)
                }
                let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                sink.add(Piece(segment: .init(text: text, start: Double(first) + 0.1, end: Double(last) + 0.6,
                                              alternatives: ["alt"]), runs: runs))
                if words.count < group.count { break }
            }
            if hangAt != nil {
                await withCheckedContinuation { done in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { done.resume() }
                }
            }
        }

        func stop() async { log.add("stop") }
    }

    static func words(_ pieces: [Piece]) -> [String] {
        pieces.flatMap { $0.segment.text.split(separator: " ").map(String.init) }
    }

    @Test func seamsKeepEveryWordOnceAndInOrder() async throws {
        let log = Log()
        var made = 0
        let owned = Sections.plan(1_500, every: 600) { $0 + 0.8 }
        #expect(owned == [0..<600.8, 600.8..<Double.infinity])
        let (pieces, sections) = try await FileTranscriber.transcribe(owned, seconds: 1_500,
                                                                      limit: { _ in .seconds(5) }) {
            made += 1
            return Fake(jitter: made == 2 ? 0.04 : 0, log: log)
        }
        #expect(sections.map(\.state) == [.complete, .complete] && sections.allSatisfy { $0.missingFrom == nil })
        #expect(Self.words(pieces) == (0..<1_500).map { "w\($0)" })
        #expect(pieces.flatMap(\.runs).map(\.text) == (0..<1_500).map { " w\($0)" })
        #expect(log.all == ["run 0.0..<610.8", "run 590.8..<1500.0"])
        let cut = try #require(pieces.first { $0.segment.text.hasPrefix("w595") || $0.segment.text.hasSuffix("w600") })
        #expect(cut.segment.alternatives.isEmpty, "a result cut at the seam loses its whole-text alternatives")
        #expect(pieces.first?.segment.alternatives == ["alt"])
    }

    @Test func aShortFileIsOneSectionAsBefore() async throws {
        let log = Log()
        let owned = Sections.plan(30, every: 600) { $0 }
        let pieces = try await FileTranscriber.transcribe(owned, seconds: 30, limit: { _ in .seconds(5) }) {
            Fake(log: log)
        }.pieces
        #expect(owned == [0..<Double.infinity])
        #expect(Self.words(pieces) == (0..<30).map { "w\($0)" })
        #expect(log.all == ["run 0.0..<30.0"])
        #expect(Sections.plan(899, every: 600) { $0 }.count == 1)
        #expect(Sections.plan(901, every: 600) { $0 }.count == 2)
        #expect(Sections.plan(7_200, every: 600) { $0 }.count == 12)
    }

    @Test func aSectionCutShortByItsDeadlineIsRetriedOnceFromItsLastFinalWord() async throws {
        let log = Log()
        var made = 0
        let started = ContinuousClock.now
        let (pieces, sections) = try await FileTranscriber.transcribe([0..<Double.infinity], seconds: 100,
                                                                      limit: { _ in .milliseconds(300) }) {
            made += 1
            return Fake(hangAt: made == 1 ? 40 : nil, log: log)
        }
        #expect(ContinuousClock.now - started < .seconds(1.4), "the hanging run is left behind, not awaited")
        #expect(sections.map(\.state) == [.retried] && sections[0].missingFrom == nil && sections[0].end == 100)
        #expect(Self.words(pieces) == (0..<100).map { "w\($0)" })
        #expect(log.all == ["run 0.0..<100.0", "stop", "run 29.6..<100.0"])
    }

    @Test func aSectionThatHangsAgainKeepsWhatWasFinalAndEnds() async throws {
        let log = Log()
        let (pieces, sections) = try await FileTranscriber.transcribe([0..<Double.infinity], seconds: 100,
                                                                      limit: { _ in .milliseconds(200) }) {
            Fake(hangAt: 60, log: log)
        }
        #expect(Self.words(pieces) == (0..<60).map { "w\($0)" }, "what was final before the hang, no doubles")
        #expect(log.all.filter { $0.hasPrefix("run") }.count == 2)
        #expect(sections.map(\.state) == [.incomplete] && sections[0].missingFrom == 59.6)
        let text = FileTranscriber.transcript(pieces.map(\.segment), sections)
        #expect(text.hasSuffix("w58 w59 [Abschnitt 00:00:59 bis 00:01:40 nicht erkannt]"))
    }

    @Test func aRetryKeepsItsSeamToTheNextSection() async throws {
        let log = Log()
        var made = 0
        let owned = Sections.plan(1_500, every: 600) { $0 + 0.8 }
        let pieces = try await FileTranscriber.transcribe(owned, seconds: 1_500, limit: { _ in .milliseconds(300) }) {
            made += 1
            return Fake(hangAt: made == 1 ? 300 : nil, log: log)
        }.pieces
        #expect(Self.words(pieces) == (0..<1_500).map { "w\($0)" })
        #expect(log.all == ["run 0.0..<610.8", "stop", "run 289.6..<610.8", "run 590.8..<1500.0"])
    }

    @Test func theFilesOwnLimitStartsNoFurtherSection() async throws {
        let log = Log()
        let owned: [Range<Double>] = [0..<50, 50..<100, 100..<Double.infinity]
        let outcome = try await within(.milliseconds(200)) {
            try await FileTranscriber.transcribe(owned, seconds: 150, limit: { _ in .seconds(5) }) {
                Fake(hangAt: 0, log: log)
            }
        }
        #expect(outcome?.pieces.count == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.all == ["run 0.0..<60.0", "stop"])
    }

    /// A section that fails twice is reported with state, stretch and reason, marked in the transcript at its
    /// place and in the log; the sections around it stay whole.
    @Test func aFailingSectionIsMarkedNeverDropped() async throws {
        let log = Log()
        var made = 0
        let owned: [Range<Double>] = [0..<2_400.5, 2_400.5..<3_000.5, 3_000.5..<Double.infinity]
        let (pieces, sections) = try await FileTranscriber.transcribe(owned, seconds: 3_100,
                                                                      limit: { _ in .seconds(5) }) {
            made += 1
            return Fake(fails: made == 2 || made == 3 ? "kaputt" : nil, log: log)
        }
        #expect(sections.map(\.state) == [.complete, .failed, .complete])
        #expect(sections[1].missingFrom == 2_400.5 && sections[1].end == 3_000.5 && sections[1].reason == "kaputt")
        #expect(Self.words(pieces) == (0...2_400).map { "w\($0)" } + (3_001..<3_100).map { "w\($0)" })
        let text = FileTranscriber.transcript(pieces.map(\.segment), sections)
        #expect(text.contains("w2400 [Abschnitt 00:40:00 bis 00:50:00 nicht erkannt] w3001"))
        let recognition = FileRecognition(text: text, segments: [], runs: [], seconds: 3_100, millis: 0,
                                          sections: sections)
        #expect(recognition.unrecognized.count == 1)
        let events = FileTranscriber.events(recognition.unrecognized)
        #expect(events.map(\.kind) == ["file_section_unrecognized"] && events.first?.level == .error)
        #expect(events.first?.fields["start"] == .double(2_400.5) && events.first?.fields["reason"] == "kaputt")
        #expect(log.all.filter { $0.hasPrefix("run") }.count == 4, "one retry for the failing section")
    }

    @Test func analyzerTimesBecomeFileTimesAndASeamCutsBetweenWords() throws {
        var first = AttributedString("Guten")
        first.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1_000),
                                           end: CMTime(seconds: 1.5, preferredTimescale: 1_000))
        var second = AttributedString(" Morgen")
        second.audioTimeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 1_000),
                                            end: CMTime(seconds: 2.4, preferredTimescale: 1_000))
        let whole = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1_000),
                                end: CMTime(seconds: 2.4, preferredTimescale: 1_000))
        let piece = Piece(first + second + AttributedString("."), whole, [AttributedString("Guten Morgan")], 590)
        #expect(piece.runs.map(\.start) == [591, 592, 592.4], "the untimed full stop stays behind its word")
        #expect(piece.segment.start == 591 && piece.segment.end == 592.4)
        #expect(piece.keeping(500..<600)?.segment.alternatives == ["Guten Morgan"])
        let tail = try #require(piece.keeping(591.7..<700))
        #expect(tail.segment.text == "Morgen." && tail.segment.start == 592 && tail.segment.alternatives.isEmpty)
        #expect(piece.keeping(593..<700) == nil)
    }

    @Test func quietestFindsThePause() throws {
        #expect(FileTranscriber.quietest([5, 5, 5, 1, 0, 1, 5, 5]) == 4)
        #expect(FileTranscriber.quietest([3]) == 0)
        let url = try Self.audio(seconds: 20) { t in (t >= 12 && t < 12.4) ? 0 : Float(sin(t * 1_700)) * 0.3 }
        defer { Self.remove(url) }
        let cut = try FileTranscriber.quietest(AVAudioFile(forReading: url), around: 10, within: 5)
        #expect(cut > 12 && cut < 12.4)
    }

    static let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                              interleaved: false)

    /// Everything the feed delivers for one window, as Int16 samples; `first` is the frame position of the file
    /// after the first pull.
    static func pull(_ url: URL, _ window: Range<Double>) async throws -> (samples: [Int16], first: Int64?) {
        var iterator = Feed(url: url, window: window, format: try #require(analyzerFormat)).makeAsyncIterator()
        var samples: [Int16] = []
        var first: Int64?
        while let piece = try await iterator.next() {
            first = first ?? iterator.source?.file.framePosition
            let data = try #require(piece.buffer.int16ChannelData)
            samples += (0..<Int(piece.buffer.frameLength)).map { data[0][$0] }
        }
        return (samples, first)
    }

    @Test func feedPullsOneSecondAtATimeMixesStereoAndKeepsWindowTime() async throws {
        let url = try Self.audio(seconds: 4, right: { t in (t >= 2.5 && t < 2.52) ? 0.8 : 0 }) { _ in 0 }
        defer { Self.remove(url) }
        let (samples, first) = try await Self.pull(url, 1..<3)
        #expect((96_000...100_800).contains(first ?? 0), "about one second read, nothing far ahead of the analyzer")
        #expect(abs(samples.count - 34_560) < 64, "two seconds of window plus 160 ms of tail silence")
        let loudest = try #require(samples.indices.max { abs(Int(samples[$0])) < abs(Int(samples[$1])) })
        #expect(abs(Int(samples[loudest])) > 3_000, "a click on the right channel only survives the mixdown")
        #expect(abs(Double(loudest) / 16_000 - 1.51) < 0.015, "the click at 2.5 s sits at 1.5 s of the window")
        #expect(samples.suffix(2_560).allSatisfy { $0 == 0 })
    }

    /// At the analyzer's own rate every sample arrives unchanged and in order across the one-second pulls (what
    /// the old slice test guarded); an empty window gives the tail silence only.
    @Test func feedKeepsEverySampleInOrderAtTheSameRate() async throws {
        let url = try Self.audio(seconds: 3.5, rate: 16_000) { Float(Int(($0 * 16_000).rounded()) % 1_000) / 32_768 }
        defer { Self.remove(url) }
        let (samples, _) = try await Self.pull(url, 0.5..<2.75)
        #expect(Array(samples.prefix(36_000)) == (8_000..<44_000).map { Int16($0 % 1_000) })
        #expect(samples.count == 36_000 + 2_560)
        #expect(try await Self.pull(url, 3.5..<3.5).samples == [Int16](repeating: 0, count: 2_560))
    }

    /// A stereo test file in the temporary folder; `right` defaults to the same signal as the left channel.
    static func audio(seconds: Double, rate: Double = 48_000, right: ((Double) -> Float)? = nil,
                      _ signal: (Double) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "flowiq-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            data[0][i] = signal(Double(i) / rate)
            data[1][i] = right.map { $0(Double(i) / rate) } ?? data[0][i]
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        return url
    }

    static func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch { Issue.record("temporary file stays: \(error)") }
    }
}
