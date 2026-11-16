/// The only place in the app that asks the system dictionary (A.7, A.12, L-1), off the main thread, 5 ms per dictation.
actor SystemWordOracle {
    nonisolated static let deadline = Duration.milliseconds(5)
    private let queue = DispatchSerialQueue(label: "de.flowiq.wordoracle", qos: .userInitiated)
    private let checker: NSSpellChecker
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    init() { checker = NSSpellChecker.shared }
    /// `since` is taken by the caller before the hop, so waiting for the queue counts against the deadline.
    func answer(_ queries: Set<OracleQuery>, since: ContinuousClock.Instant) -> OracleAnswers {
        var known: [OracleQuery: Bool] = [:]
        for q in queries.sorted(by: { ($0.form, $0.kind.rawValue) < ($1.form, $1.kind.rawValue) }) {
            guard ContinuousClock.now - since < Self.deadline else { break }
            guard q.form != q.form.uppercased() || q.form == q.form.lowercased() else { continue }
            let languages = q.kind == .word ? ["de", "en"] : q.kind == .englishStem ? ["en"] : ["de"]
            known[q] = languages.contains { language in
                checker.checkSpelling(of: q.form, startingAt: 0, language: language, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
        return OracleAnswers(known: known)
    }
}
