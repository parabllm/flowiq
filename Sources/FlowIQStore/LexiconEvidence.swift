/// A hearing-variant candidate from a comparison, a rule or a near miss: heard pieces for one entry.
public struct VariantCandidate: Sendable, Codable, Hashable {
    public let heard: [String], entryID: String
    public init(heard: [String], entryID: String) { (self.heard, self.entryID) = (heard, entryID) }
}

/// Evidence for hearing variants from two versions of one text (11.1 Q2); spellings only from the lexicon (I4).
extension TextStage {
    /// The entry a span of words stands for: the stage writes exactly its canonical spelling for the whole span.
    public func entry(for words: [String]) -> CanonEntry? {
        let text = process(Recognition(text: words.joined(separator: " ")), answers: OracleAnswers(known: [:])).text
        let key = LexiconSnapshot.key(text)
        return lexicon.entries.first { $0.canonical == text && LexiconSnapshot.key($0.canonical) == key }
    }
    /// Replacements of up to 3 heard words by up to 4 words around one entry; forms `exact` already fixes are left out.
    public func candidates(heard: String, against other: String, exact: TextStage) -> [VariantCandidate] {
        let a = PairAligner.words(heard), b = PairAligner.words(other)
        var out: [VariantCandidate] = []
        for op in PairAligner.align(a, b) where op.kind == .replace && op.a.count <= 3 && op.b.count <= 4 {
            let side = Array(b[op.b])
            var found: (entry: CanonEntry, start: Int, count: Int)?
            spans: for n in stride(from: side.count, through: 1, by: -1) {
                for s in 0...(side.count - n) {
                    if let e = entry(for: Array(side[s..<s + n])) {
                        found = (e, s, n)
                        break spans
                    }
                }
            }
            guard let found else { continue }
            var h = a[op.a].map { $0.lowercased() }
            var rest = (side[..<found.start] + side[(found.start + found.count)...]).map { $0.lowercased() }
            while let x = h.first, x == rest.first { (h, rest) = (Array(h.dropFirst()), Array(rest.dropFirst())) }
            while let x = h.last, x == rest.last { (h, rest) = (Array(h.dropLast()), Array(rest.dropLast())) }
            let heard = CorrectionRules.pieces(of: h.joined(separator: " "))
            guard !heard.isEmpty, rest.isEmpty, exact.entry(for: h)?.id != found.entry.id else { continue }
            out.append(VariantCandidate(heard: heard, entryID: found.entry.id))
        }
        return out
    }
}
