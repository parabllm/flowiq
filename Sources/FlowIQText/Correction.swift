/// What a click teaches (N.2 point 4, 11.1, I1): `learn`, `askScope` ("immer", "nur neben", once), `confusion`, `none`.
public enum CorrectionKind: String, Sendable, Codable { case learn, askScope, confusion, none }

/// A permanent case (N.4 "Dauerfall"): a recognizer text and what the stage must make of it.
public struct RegressionCase: Sendable, Codable, Hashable {
    public let input: String, expected: String
    public init(input: String, expected: String) { (self.input, self.expected) = (input, expected) }
}

public enum CorrectionRules {
    /// Proven: an active non-word variant; a click is then active at once (N.3), a real word only by scope (3.3).
    public static func proven(_ target: CanonEntry?) -> Bool {
        target?.hearingVariants.contains { $0.status == .active && !$0.replacesProtectedWord } == true
    }
    public static func clickedStatus(target: CanonEntry?, realWord: Bool) -> VariantStatus {
        realWord || proven(target) ? .active : .probation
    }
    /// The first rejection stills a variant: retired when alone, else suspended (4.4, S1, S2); nothing is deleted.
    public static func stilled(interventions: Int) -> VariantStatus { interventions > 1 ? .suspended : .retired }
    /// The pieces a hearing variant matches for a heard text: letters and digits, lower case.
    public static func pieces(of text: String) -> [String] { Pieces.split(text).map(\.lower) }
    /// `text` with every occurrence of the heard pieces replaced by `canonical` (harm probe of a candidate).
    public static func replacing(_ heard: [String], with canonical: String, in text: String) -> String {
        let pieces = Pieces.split(text)
        var out = "", cursor = text.startIndex, i = 0
        while !heard.isEmpty, i + heard.count <= pieces.count {
            guard Pieces.joinable(pieces, i, i + heard.count),
                  zip(heard, pieces[i..<i + heard.count]).allSatisfy({ $0 == $1.lower }) else {
                i += 1
                continue
            }
            out += text[cursor..<pieces[i].range.lowerBound] + canonical
            cursor = pieces[i + heard.count - 1].range.upperBound
            i += heard.count
        }
        return out + text[cursor...]
    }
}

/// One dictation in the correction window (N.2): recognizer words and today's words, flagged where the stage acted.
public struct CorrectionText: Sendable {
    public struct Segment: Sendable {
        public var words: [String], raw: Range<Int>, intervention: Intervention?
    }
    public let raw: [String]
    public private(set) var segments: [Segment] = []
    public var words: [String] { segments.flatMap(\.words) }
    public init(recognized: String, final: String, interventions: [Intervention]) {
        raw = recognized.split(separator: " ").map(String.init)
        let now = final.split(separator: " ").map(String.init)
        for op in PairAligner.align(raw, now) {
            if op.kind == .equal {
                segments += zip(op.a, op.b).map { Segment(words: [now[$1]], raw: $0..<$0 + 1, intervention: nil) }
            } else if op.kind == .delete, let last = segments.indices.last {
                segments[last].raw = segments[last].raw.lowerBound..<op.a.upperBound
            } else {
                let joined = now[op.b].joined(separator: " ")
                segments.append(Segment(words: Array(now[op.b]), raw: op.a,
                                        intervention: interventions.first { joined.contains($0.tAfter) }))
            }
        }
    }
    /// Word ranges where the stage intervened.
    public var interventionSpans: [Range<Int>] {
        var at = 0
        return segments.compactMap { s in
            defer { at += s.words.count }
            return s.intervention == nil ? nil : at..<at + s.words.count
        }
    }
    /// Indices of the segments a word range touches, and the recognizer words under them.
    public func cover(_ range: Range<Int>) -> (segments: Range<Int>, raw: Range<Int>)? {
        var at = 0, first: Int?, last = 0
        for (n, s) in segments.enumerated() {
            if !s.words.isEmpty, at < range.upperBound, at + s.words.count > range.lowerBound {
                (first, last) = (first ?? n, n)
            }
            at += s.words.count
        }
        return first.map { ($0..<last + 1, segments[$0].raw.lowerBound..<segments[last].raw.upperBound) }
    }
    /// Recognizer alternatives for raw words, per word or opposite the span in a segment alternative, at most `limit`.
    public func alternatives(_ span: Range<Int>, from all: [[String]], limit: Int = 3) -> [String] {
        let perWord = all.count == raw.count
        var found = perWord && span.count == 1 ? all[span.lowerBound] : []
        for alt in perWord ? [] : Array(all.joined()) {
            let words = alt.split(separator: " ").map(String.init)
            for op in PairAligner.align(raw, words) where op.kind == .replace && op.a == span {
                let phrase = words[op.b].joined(separator: " ")
                if !found.contains(phrase) { found.append(phrase) }
            }
        }
        return Array(found.prefix(limit))
    }
    /// The segments `covered` become one segment with `words`, no longer an intervention.
    public mutating func replace(_ covered: Range<Int>, with words: [String]) {
        let raw = segments[covered.lowerBound].raw.lowerBound..<segments[covered.upperBound - 1].raw.upperBound
        segments.replaceSubrange(covered, with: [Segment(words: words, raw: raw, intervention: nil)])
    }
}

extension TextStage {
    public func classifyCorrection(heard: String, meant: String, answers: OracleAnswers) -> CorrectionKind {
        let h = Pieces.split(heard), m = Pieces.split(meant)
        guard !h.isEmpty, !m.isEmpty, h.map(\.text) != m.map(\.text) else { return .none }
        let normal: Set<PieceClass> = [.system, .familiar, .formed]
        let isNormal = { (p: Piece) in normal.contains(shield.classify(p, answers)) }
        if index.byKey[LexiconSnapshot.key(meant)] == nil, m.allSatisfy(isNormal) { return .confusion }
        return isRealWord(h.map(\.lower), answers) ? .askScope : .learn
    }
    /// True when a heard form holds a protected piece (unanswered counts as protected).
    public func isRealWord(_ heard: [String], _ answers: OracleAnswers = OracleAnswers(known: [:])) -> Bool {
        Pieces.split(heard.joined(separator: " ")).contains { shield.classify($0, answers).isProtected }
    }
    /// Confirmed entries nearest to `text` by the sound folding, best first, names breaking ties.
    public func soundNeighbors(of text: String, limit: Int = 3, floor: Double = 0.5) -> [String] {
        let keys = Phonetics.keys(Pieces.split(text).prefix(4).map { Phonetics.readings($0.text) })
        let scored = index.spoken.compactMap { s -> (Double, String)? in
            let best = s.forms.flatMap { f in keys.map { Phonetics.similarity($0, f, floor: floor) } }.max() ?? 0
            return best > 0 ? (best, index.entries[s.entry].canonical) : nil
        }
        return Array(scored.sorted { ($1.0, $0.1) < ($0.0, $1.1) }.prefix(limit).map(\.1))
    }
    /// "immer" for a real word only when the target sounds near it (0.70), else "nur neben" only (measured).
    public func mayReplaceEverywhere(_ heard: String, by canonical: String) -> Bool {
        soundNeighbors(of: heard, limit: 3, floor: config.nearMissFloor).contains(canonical)
    }
    /// The permanent cases this stage gets wrong; every oracle question counts as unknown (worst case, N.4).
    public func failing(_ cases: [RegressionCase]) -> [RegressionCase] {
        cases.filter { c in
            let input = Recognition(text: c.input)
            let unknown = Dictionary(uniqueKeysWithValues: oracleQueries(for: input).map { ($0, false) })
            return process(input, answers: OracleAnswers(known: unknown)).text != c.expected
        }
    }
}
