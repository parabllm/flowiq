import Speech

/// Apple live for call and room (A.6, M.2), netfree: finals as segments, volatiles as partials, finalize every 3 s.
public final class AppleLiveRecognizer: LiveRecognizer {
    public let engine = LiveEngine.appleLocal, events: AsyncStream<LiveEvent>
    private let out: AsyncStream<LiveEvent>.Continuation
    private let state = Mutex<(analyzer: AppleAnalyzer?, fed: Double, finalized: Double)>((nil, 0, 0))
    public init() { (events, out) = AsyncStream.makeStream() }
    public func start(_ setup: LiveSetup) async throws {
        let (out, anchor) = (out, setup.anchor)
        let analyzer = try await AppleAnalyzer.prepare(Locale(identifier: setup.language.rawValue)) { r in
            guard r.isFinal else { out.yield(.partial(String(r.text.characters))); return }
            let words = Piece(r.text, r.range, [], anchor).runs.compactMap { run in
                let t = run.text.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : TimedWord(text: t, start: run.start, end: run.end, confidence: run.confidence)
            }
            if !words.isEmpty { out.yield(.committed(LiveSegment(words: words, speaker: nil))) }
        }
        state.withLock { $0.analyzer = analyzer }
        setup.backlog.forEach(feed)
    }
    public func feed(_ chunk: AudioChunk) {
        let (analyzer, due) = state.withLock { s -> (AppleAnalyzer?, CMTime?) in
            s.fed += chunk.seconds
            defer { if s.fed - s.finalized >= 3 { s.finalized = s.fed } }
            return (s.analyzer, s.fed - s.finalized >= 3 ? CMTime(seconds: s.fed - 1, preferredTimescale: 1000) : nil)
        }
        do { try analyzer?.feed(chunk) } catch { fail() }
        guard let analyzer, let due else { return }
        Task { do { try await analyzer.analyzer.finalize(through: due) } catch { self.fail() } }
    }
    public func finish() async {
        do { _ = try await state.withLock({ $0.analyzer })?.finish() } catch { fail() }
        out.finish()
    }
    private func fail() { out.yield(.failure(.transcriberError)) }
}
