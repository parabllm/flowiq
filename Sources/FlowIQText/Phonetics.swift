/// Own sound folding (L-2, 1.5): German sound classes, vowel 0.5 and consonant 1.0, numbers read out; fixed tables.
enum Phonetics {
    /// Folded sound as ASCII codes: a e i o u, "A" ei/ai class, "O" eu/oi class, "S" sch, "x" ch, consonants.
    typealias Folded = [UInt8]
    /// A folded form with its weight, computed once.
    struct Form: Sendable {
        let codes: Folded
        /// 0.5 for a vowel class, 1.0 for a consonant, per code.
        let costs: [Double], weight: Double
        /// Codes in ascending order, for the bag bound.
        let sorted: Folded
        init(_ codes: Folded) {
            self.codes = codes
            costs = codes.map { isVowel($0) ? 0.5 : 1.0 }
            weight = costs.reduce(0, +)
            sorted = codes.sorted()
        }
    }
    // Multi-letter rules by first letter (Latin-1 code), longest first; single-letter rules by code.
    private static let multi: [[([UInt32], Folded)]] = table([
        ("tsch", "S"), ("dsch", "S"), ("sch", "S"), ("ch", "x"), ("ck", "k"), ("ph", "f"), ("qu", "kf"),
        ("th", "t"), ("tz", "ts"), ("ie", "i"), ("ei", "A"), ("ai", "A"), ("ey", "A"), ("ay", "A"), ("ej", "A"),
        ("äi", "A"), ("eu", "O"), ("äu", "O"), ("oi", "O"), ("oy", "O"), ("ou", "u"), ("au", "u"), ("ee", "e"),
        ("oo", "u"), ("ce", "se"), ("ci", "si"),
    ]).map { $0.map { (scalars($0.0), Array($0.1.utf8)) } }
    private static let single: [Folded?] = table([
        ("ä", "e"), ("ö", "e"), ("ü", "i"), ("ß", "s"), ("z", "ts"), ("v", "f"), ("w", "f"), ("q", "k"),
        ("x", "ks"), ("j", "i"), ("y", "i"), ("b", "p"), ("d", "t"), ("g", "k"), ("h", ""), ("c", "k"),
    ]).map { $0.first.map { Array($0.1.utf8) } }
    private static func table(_ rules: [(String, String)]) -> [[(String, String)]] {
        var out = [[(String, String)]](repeating: [], count: 256)
        for rule in rules { out[Int(scalars(rule.0)[0])].append(rule) }
        return out
    }
    private static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
    static let lettersDE: [Character: String] = [
        "a": "a", "b": "be", "c": "tse", "d": "de", "e": "e", "f": "ef", "g": "ge", "h": "ha", "i": "i",
        "j": "jot", "k": "ka", "l": "el", "m": "em", "n": "en", "o": "o", "p": "pe", "q": "ku", "r": "er",
        "s": "es", "t": "te", "u": "u", "v": "fau", "w": "we", "x": "iks", "y": "ipsilon", "z": "tset",
    ]
    static let lettersEN: [Character: String] = [
        "a": "ej", "b": "bi", "c": "si", "d": "di", "e": "i", "f": "ef", "g": "dschi", "h": "ejtsch", "i": "ai",
        "j": "dschej", "k": "kej", "l": "el", "m": "em", "n": "en", "o": "o", "p": "pi", "q": "kju", "r": "ar",
        "s": "es", "t": "ti", "u": "ju", "v": "wi", "w": "dabelju", "x": "eks", "y": "wai", "z": "set",
    ]
    static let numbersDE = ["null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun",
                            "zehn", "elf", "zwölf"]
    static let numbersEN = ["siro", "wan", "tu", "sri", "for", "faif", "siks", "sewen", "ejt", "nain", "ten"]
    static let numberWords: Set<String> = Set(numbersDE + ["hundert", "one", "two", "three", "four", "five", "six",
                                                           "seven", "eight", "nine", "ten"])
    static func fold(_ text: String) -> Folded {
        let decomposed = text.unicodeScalars.contains { (0x300...0x36F).contains($0.value) }
        let s = scalars((decomposed ? text.precomposedStringWithCanonicalMapping : text).lowercased())
        var out: Folded = [], i = 0
        outer: while i < s.count {
            let code = s[i] < 256 ? Int(s[i]) : 0
            for (from, to) in multi[code] where i + from.count <= s.count && s[i..<i + from.count].elementsEqual(from) {
                out.append(contentsOf: to)
                i += from.count
                continue outer
            }
            if let mapped = single[code] {
                out.append(contentsOf: mapped)
            } else if s[i] >= 97, s[i] <= 122 {
                out.append(UInt8(s[i]))
            }
            i += 1
        }
        var collapsed: Folded = []
        for c in out where collapsed.last != c { collapsed.append(c) }
        return collapsed
    }
    @inline(__always) static func isVowel(_ c: UInt8) -> Bool {
        c == 97 || c == 101 || c == 105 || c == 111 || c == 117 || c == 65 || c == 79
    }
    static func weight(_ f: Folded) -> Double { f.reduce(0) { $0 + (isVowel($1) ? 0.5 : 1.0) } }
    /// Weighted edit distance (equal 0, vowel pair 0.5, else 1.0); stops once a row is above `limit`.
    static func distance(_ a: Form, _ b: Form, limit: Double = .infinity) -> Double {
        let n = b.codes.count
        var rows = [Double](repeating: 0, count: 2 * (n + 1))
        return rows.withUnsafeMutableBufferPointer { r in
            b.codes.withUnsafeBufferPointer { bc in
                b.costs.withUnsafeBufferPointer { bw in
                    var prev = 0, cur = n + 1
                    for j in 0..<n { r[j + 1] = r[j] + bw[j] }
                    for (x, wx) in zip(a.codes, a.costs) {
                        r[cur] = r[prev] + wx
                        var best = r[cur]
                        for j in 0..<n {
                            let sub = x == bc[j] ? 0 : (wx + bw[j] == 1 ? 0.5 : 1.0)
                            let v = min(r[prev + j + 1] + wx, r[cur + j] + bw[j], r[prev + j] + sub)
                            r[cur + j + 1] = v
                            best = min(best, v)
                        }
                        if best > limit { return best }
                        swap(&prev, &cur)
                    }
                    return r[prev + n]
                }
            }
        }
    }
    /// Lower bound: every code without an equal partner costs its weight, one operation settles one per side.
    static func bagBound(_ a: Form, _ b: Form) -> Double {
        var i = 0, j = 0, onlyA = 0.0, onlyB = 0.0
        let x = a.sorted, y = b.sorted
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                i += 1
                j += 1
            } else if j == y.count || (i < x.count && x[i] < y[j]) {
                onlyA += isVowel(x[i]) ? 0.5 : 1.0
                i += 1
            } else {
                onlyB += isVowel(y[j]) ? 0.5 : 1.0
                j += 1
            }
        }
        return max(onlyA, onlyB)
    }
    /// 1 minus distance over the larger weight; 0 when certainly below `floor` (weight gap, bag bound, row minimum).
    static func similarity(_ a: Form, _ b: Form, floor: Double) -> Double {
        let top = max(a.weight, b.weight), limit = (1 - floor) * top
        guard top > 0, abs(a.weight - b.weight) <= limit, bagBound(a, b) <= limit else { return 0 }
        let score = 1 - distance(a, b, limit: limit) / top
        return score >= floor ? score : 0
    }
    /// Folded readings of a span from the readings of its pieces, at most 128 combinations.
    static func keys(_ readings: [[String]]) -> [Form] {
        var combos = [""]
        for options in readings { combos = Array(combos.flatMap { head in options.map { head + $0 } }.prefix(128)) }
        var seen = Set<Folded>()
        return combos.map(fold).filter { !$0.isEmpty && seen.insert($0).inserted }.map(Form.init)
    }
    /// Unfolded readings of a piece: number words, spelled digit and upper-case runs, words plain and English-read.
    static func readings(_ piece: String) -> [String] {
        if numberWords.contains(piece.lowercased()) { return [piece.lowercased()] }
        var combos = [""]
        for run in runs(piece) {
            var options: [String]
            if run.first?.isNumber == true {
                options = [number(run, numbersDE, fallback: "hundert"), number(run, numbersEN, fallback: "handred")]
            } else if run.count == 1 || (run.allSatisfy(\.isUppercase) && run.count <= 4) {
                let lower = run.lowercased()
                options = [lower.map { lettersDE[$0] ?? String($0) }.joined(),
                           lower.map { lettersEN[$0] ?? String($0) }.joined()]
                if run.count >= 3 { options.append(lower) }
            } else {
                options = [run.lowercased(), english(run.lowercased())]
            }
            var unique: [String] = []
            for o in options where !unique.contains(o) { unique.append(o) }
            combos = Array(combos.flatMap { head in unique.map { head + $0 } }.prefix(64))
        }
        return combos
    }
    /// Digit runs, upper-case runs not followed by a lower-case letter, and words with an optional capital.
    static func runs(_ piece: String) -> [String] {
        let c = Array(piece)
        var out: [String] = [], i = 0
        while i < c.count {
            var j = i + 1
            if c[i].isNumber {
                while j < c.count, c[j].isNumber { j += 1 }
            } else if c[i].isUppercase {
                while j < c.count, c[j].isUppercase { j += 1 }
                if j < c.count, c[j].isLowercase {
                    if j - i >= 2 { j -= 1 } else { while j < c.count, c[j].isLowercase { j += 1 } }
                }
            } else if c[i].isLowercase {
                while j < c.count, c[j].isLowercase { j += 1 }
            } else {
                i = j
                continue
            }
            out.append(String(c[i..<j]))
            i = j
        }
        return out
    }
    private static func number(_ digits: String, _ table: [String], fallback: String) -> String {
        if let n = Int(digits), n < table.count { return table[n] }
        if digits == "100" { return fallback }
        return digits.compactMap { $0.wholeNumberValue.map { table[$0] } }.joined()
    }
    /// A few general English reading rules: final cue and que, i-e and a-e, ee, ea, igh, silent final e.
    static func english(_ word: String) -> String {
        var s = Array(word)
        let isVowel = { (c: Character) in "aeiou".contains(c) }
        if word.hasSuffix("cue") || word.hasSuffix("que") {
            s = Array(s.dropLast(3)) + Array(word.hasSuffix("cue") ? "kju" : "k")
        } else if s.count >= 4, s[s.count - 1] == "e", !isVowel(s[s.count - 2]), !isVowel(s[s.count - 4]) {
            let k = s.count - 3
            if s[k] == "i" { s.replaceSubrange(k...k, with: Array("ai")) } else if s[k] == "a" {
                s.replaceSubrange(k...k, with: Array("ej"))
            }
        }
        var out = String(s).replacingOccurrences(of: "ee", with: "i").replacingOccurrences(of: "ea", with: "i")
        out = out.replacingOccurrences(of: "igh", with: "ai")
        if out.hasSuffix("e") { out.removeLast() }
        return out
    }
}
