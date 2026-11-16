/// One run of letters and digits; a span may cross spaces or one hyphen, hyphen tails stay outside (Z1).
struct Piece: Sendable {
    let range: Range<String.Index>, text: String, lower: String
    /// The gap to the previous piece is spaces only or exactly one hyphen.
    let joinable: Bool, hasDigit: Bool, hasLetter: Bool, isUpperRun: Bool
    var capitalized: String { lower.prefix(1).uppercased() + lower.dropFirst() }
}

enum Pieces {
    static func split(_ text: String) -> [Piece] {
        var out: [Piece] = [], gapStart = text.startIndex, i = text.startIndex
        while i < text.endIndex {
            guard isWordChar(text[i]) else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, isWordChar(text[j]) { j = text.index(after: j) }
            let gap = text[gapStart..<i], word = String(text[i..<j]), letters = word.filter(\.isLetter)
            out.append(Piece(range: i..<j, text: word, lower: word.lowercased(),
                             joinable: !out.isEmpty && (gap == "-" || (!gap.isEmpty && gap.allSatisfy { $0 == " " })),
                             hasDigit: word.contains(where: \.isNumber), hasLetter: !letters.isEmpty,
                             isUpperRun: !letters.isEmpty && letters.allSatisfy(\.isUppercase)
                                && !word.contains(where: \.isNumber)))
            gapStart = j
            i = j
        }
        return out
    }
    static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    /// Pieces i..<end form one span only if every inner gap is joinable.
    static func joinable(_ pieces: [Piece], _ i: Int, _ end: Int) -> Bool {
        end <= pieces.count && (i + 1..<end).allSatisfy { pieces[$0].joinable }
    }
    static func surface(_ text: String, _ pieces: [Piece], _ i: Int, _ end: Int) -> String {
        String(text[pieces[i].range.lowerBound..<pieces[end - 1].range.upperBound])
    }
    /// Step 1 of `process`: only recognizer control residue ("K\letter", "\word") goes; hesitation stays (7.2 B2).
    static func clean(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = "", i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\\" {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isASCII, text[j].isLetter { j = text.index(after: j) }
                if j > text.index(after: i) {
                    if out.last.map({ $0 == " " }) ?? true, j == text.endIndex || text[j] == " " {
                        while out.last == " " { out.removeLast() }
                    }
                    i = j
                    continue
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }
}
