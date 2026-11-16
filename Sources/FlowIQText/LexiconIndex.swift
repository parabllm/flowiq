/// Built once per lexicon version (7.2 B3): R1 keys, family stems, spoken forms, variants, protected tokens.
struct LexiconIndex: Sendable {
    struct Family: Sendable {
        let anchor: String, anchorWritten: String, stems: [Phonetics.Folded: Int]
    }
    struct Spoken: Sendable {
        let entry: Int, forms: [Phonetics.Form], acronym: Bool, family: String?
    }
    let entries: [CanonEntry], byKey: [String: Int], families: [Family], spoken: [Spoken]
    /// Lightest and heaviest folded form of all entries: a key outside the band can never reach the floor.
    let spokenWeights: ClosedRange<Double>, variants: [String: [(entry: Int, variant: HearingVariant)]]
    let entryTokens: Set<String>, gluedEntries: [String]
    init(_ lexicon: LexiconSnapshot) {
        entries = lexicon.entries
        var byKey: [String: Int] = [:], variants: [String: [(entry: Int, variant: HearingVariant)]] = [:]
        var tokens = Set<String>()
        for (n, e) in entries.enumerated() {
            if byKey[LexiconSnapshot.key(e.canonical)] == nil { byKey[LexiconSnapshot.key(e.canonical)] = n }
            for v in e.hearingVariants where !v.heard.isEmpty { variants[v.heard[0], default: []].append((n, v)) }
            for t in e.canonical.split(separator: " ") { tokens.formUnion([String(t), t + "s"]) }
        }
        self.byKey = byKey
        self.variants = variants
        entryTokens = tokens
        gluedEntries = entries.map { $0.canonical.filter { $0 != " " } }.filter { $0.count >= 4 }
        families = lexicon.families.map { rule in
            let anchor = rule.anchorWritten.lowercased()
            var stems: [Phonetics.Folded: Int] = [:]
            for (n, e) in lexicon.entries.enumerated() where e.family == rule.id
                && e.canonical.lowercased().hasSuffix(anchor) && e.canonical.count > anchor.count {
                let stem = Phonetics.fold(String(e.canonical.dropLast(anchor.count)))
                if !stem.isEmpty, stems[stem] == nil { stems[stem] = n }
            }
            return Family(anchor: anchor, anchorWritten: rule.anchorWritten, stems: stems)
        }
        spoken = entries.enumerated().map { n, e in
            var forms = Phonetics.keys(Pieces.split(e.canonical).map { Phonetics.readings($0.text) })
            for s in e.spokenForms {
                let f = Phonetics.fold(s.text)
                if !f.isEmpty, !forms.contains(where: { $0.codes == f }) { forms.append(Phonetics.Form(f)) }
            }
            return Spoken(entry: n, forms: forms, acronym: e.kind == .acronym, family: e.family)
        }
        let weights = spoken.flatMap { $0.forms.map(\.weight) }
        spokenWeights = (weights.min() ?? 0)...(weights.max() ?? 0)
    }
    /// True when the hearing variant fits the pieces at i exactly, context included.
    static func fits(_ v: HearingVariant, _ pieces: [Piece], _ i: Int) -> Bool {
        let end = i + v.heard.count
        guard Pieces.joinable(pieces, i, end), zip(v.heard, pieces[i..<end]).allSatisfy({ $0 == $1.lower })
        else { return false }
        guard !v.context.isEmpty else { return true }
        let around = [i > 0 ? pieces[i - 1].lower : "", end < pieces.count ? pieces[end].lower : ""]
        return around.contains { v.context.contains($0) }
    }
}
