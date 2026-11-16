/// Protection class of one piece (LEXIKON-KONZEPT 2): the first five are protected, in doubt protected.
enum PieceClass: String, Sendable {
    case entry, system, familiar, formed, noAnswer
    case number, letter, abbreviation, mixed, open
    var isProtected: Bool { [.entry, .system, .familiar, .formed, .noAnswer].contains(self) }
    /// May start a spoken-form source (R3): not protected and not a number.
    var isOpenSource: Bool { [.open, .mixed, .letter, .abbreviation].contains(self) }
}

/// Three layers: P1 system dictionary, P2 familiar forms and entries, P3 regular formations; queries only (L-1).
struct Protection: Sendable {
    let frozen: FrozenWordSet, entryTokens: Set<String>, gluedEntries: [String]
    static let endings = ["ten", "tet", "est", "en", "et", "te", "st", "e", "t"]
    static let minStem = 4
    /// Class decided without the oracle; nil means the piece needs answers.
    func preclass(_ p: Piece) -> PieceClass? {
        if entryTokens.contains(p.text) { return .entry }
        if !p.hasLetter || Phonetics.numberWords.contains(p.lower) { return .number }
        if p.text.count == 1 { return .letter }
        if p.hasDigit { return .mixed }
        if frozen.familiar.contains(p.text) || frozen.familiar.contains(p.lower) { return .familiar }
        if wordQueries(p).contains(where: { frozen.lookup($0) == true }) { return .system }
        if gluedEntries.contains(where: { p.text.hasPrefix($0) && p.text.count - $0.count >= Self.minStem }) {
            return .formed
        }
        return nil
    }
    func classify(_ p: Piece, _ answers: OracleAnswers) -> PieceClass {
        if let c = preclass(p) { return c }
        let known = { (q: OracleQuery) in frozen.lookup(q) ?? answers.known[q] }
        let words = wordQueries(p).map(known)
        if words.contains(true) { return .system }
        if words.contains(nil) { return .noAnswer }
        if Self.isShortUpper(p) { return .abbreviation } // a known word in capitals ("NEIN") is protected above
        let stems = Self.stemQueries(p.lower).map(known)
        let parts = Self.compoundQueries(p.lower).map { $0.map(known) }
        if stems.contains(true) || parts.contains(where: { $0.allSatisfy { $0 == true } }) { return .formed }
        if stems.contains(nil) || parts.contains(where: { $0.contains(nil) && !$0.contains(false) }) {
            return .noAnswer
        }
        return .open
    }
    /// Questions for undecided pieces: lower and capitalized form, English stems, parts; never all upper case.
    func queries(_ p: Piece) -> [OracleQuery] {
        guard preclass(p) == nil else { return [] }
        if Self.isShortUpper(p) { return wordQueries(p).filter { frozen.lookup($0) == nil } }
        let all = wordQueries(p) + Self.stemQueries(p.lower) + Self.compoundQueries(p.lower).flatMap { $0 }
        return all.filter { frozen.lookup($0) == nil }
    }
    /// Upper-case run of 2 to 5 letters without digits: an abbreviation unless the dictionary knows the word.
    static func isShortUpper(_ p: Piece) -> Bool { p.isUpperRun && p.text.count <= 5 }
    func wordQueries(_ p: Piece) -> [OracleQuery] {
        (p.lower == p.capitalized ? [p.lower] : [p.lower, p.capitalized]).map { OracleQuery(form: $0, kind: .word) }
    }
    /// English stem plus German ending, also ge- plus stem plus -t or -et; doubled final consonant also single.
    static func stemQueries(_ lower: String) -> [OracleQuery] {
        var stems: [String] = []
        func add(_ stem: Substring) {
            guard stem.count >= minStem, stem.allSatisfy(\.isLetter) else { return }
            for s in [String(stem)] + (stem.last == stem.dropLast().last ? [String(stem.dropLast())] : [])
            where s.count >= minStem && !stems.contains(s) { stems.append(s) }
        }
        for e in endings where lower.hasSuffix(e) { add(lower.dropLast(e.count)) }
        if lower.hasPrefix("ge") {
            for e in ["et", "t"] where lower.hasSuffix(e) { add(lower.dropFirst(2).dropLast(e.count)) }
        }
        return stems.map { OracleQuery(form: $0, kind: .englishStem) }
    }
    /// Splits into two German parts of at least 4 letters, the left one optionally with a linking s.
    static func compoundQueries(_ lower: String) -> [[OracleQuery]] {
        let c = Array(lower)
        guard c.count >= 2 * minStem, c.allSatisfy(\.isLetter) else { return [] }
        var out: [[OracleQuery]] = []
        for k in minStem...(c.count - minStem) {
            let right = cap(c[k...])
            for left in [c[..<k]] + (c[k - 1] == "s" && k - 1 >= minStem ? [c[..<(k - 1)]] : []) {
                out.append([OracleQuery(form: cap(left), kind: .germanPart),
                            OracleQuery(form: right, kind: .germanPart)])
            }
        }
        return out
    }
    private static func cap(_ s: ArraySlice<Character>) -> String {
        guard let first = s.first else { return "" }
        return first.uppercased() + String(s.dropFirst())
    }
}
