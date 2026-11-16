/// Word alignment of two versions of a text (N.3): LCS over folded words, gaps as replace, delete, insert.
public enum PairAligner {
    public struct Op: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case equal, replace, delete, insert }
        public let kind: Kind, a: Range<Int>, b: Range<Int>
    }
    static let hesitations: Set<String> = ["äh", "ähm", "öhm", "ehm", "hm", "hmm", "mhm", "mh", "eh", "uh", "um"]
    /// Words of a text: split at white space, edge punctuation off, sound tags and hesitation marks dropped.
    public static func words(_ text: String) -> [String] {
        var plain = "", depth = 0
        for c in text {
            if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { depth = max(0, depth - 1) }
            plain.append(depth > 0 || c == ")" || c == "]" ? " " : c)
        }
        return plain.split(whereSeparator: \.isWhitespace).map(trim).filter {
            !$0.isEmpty && !hesitations.contains($0.lowercased())
        }
    }
    static func trim(_ word: Substring) -> String {
        let keep = { (c: Character) in c.isLetter || c.isNumber }
        guard let first = word.firstIndex(where: keep), let last = word.lastIndex(where: keep) else { return "" }
        return String(word[first...last])
    }
    /// Alignment of `a` against `b` as a list of blocks covering both completely, in order.
    public static func align(_ a: [String], _ b: [String]) -> [Op] {
        let ka = a.map { trim(Substring($0)).lowercased() }, kb = b.map { trim(Substring($0)).lowercased() }
        var head = 0, tail = 0
        while head < ka.count, head < kb.count, ka[head] == kb[head] { head += 1 }
        while tail < ka.count - head, tail < kb.count - head, ka[ka.count - 1 - tail] == kb[kb.count - 1 - tail] {
            tail += 1
        }
        let x = Array(ka[head..<(ka.count - tail)]), y = Array(kb[head..<(kb.count - tail)]), w = y.count + 1
        var table = [Int32](repeating: 0, count: (x.count + 1) * w)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                table[i * w + j] = x[i] == y[j] ? table[(i + 1) * w + j + 1] + 1
                    : max(table[(i + 1) * w + j], table[i * w + j + 1])
            }
        }
        var matches = (0..<head).map { ($0, $0) }
        var i = 0, j = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] {
                matches.append((head + i, head + j))
                (i, j) = (i + 1, j + 1)
            } else if table[(i + 1) * w + j] >= table[i * w + j + 1] { i += 1 } else { j += 1 }
        }
        matches += (0..<tail).map { (ka.count - tail + $0, kb.count - tail + $0) }
        var ops: [Op] = []
        var (pa, pb) = (0, 0)
        func gap(_ ea: Int, _ eb: Int) {
            guard pa < ea || pb < eb else { return }
            ops.append(Op(kind: pa == ea ? .insert : pb == eb ? .delete : .replace, a: pa..<ea, b: pb..<eb))
        }
        for (ma, mb) in matches {
            gap(ma, mb)
            if let last = ops.last, last.kind == .equal, last.a.upperBound == ma, last.b.upperBound == mb {
                ops[ops.count - 1] = Op(kind: .equal, a: last.a.lowerBound..<ma + 1, b: last.b.lowerBound..<mb + 1)
            } else {
                ops.append(Op(kind: .equal, a: ma..<ma + 1, b: mb..<mb + 1))
            }
            (pa, pb) = (ma + 1, mb + 1)
        }
        gap(a.count, b.count)
        return ops
    }
}
