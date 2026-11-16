/// One possible change of pieces start..<end, before the brake.
struct Match: Sendable {
    let start: Int, end: Int, rule: String, reason: String, entry: Int, variantID: String?, replacement: String
    let score: Double, margin: Double
}

/// The four rule kinds (3.2): a suspicious source, a confirmed target and a strong match; nothing else changes a word.
struct Matcher {
    let index: LexiconIndex, config: TextStageConfig, text: String, pieces: [Piece], classes: [PieceClass]
    /// Readings of every piece that may sit in a spoken-form source, computed once per dictation.
    let readings: [[String]]
    /// Left to right, longest span first, no overlap. An exact confirmed spelling is consumed unchanged.
    func scan(_ near: inout [NearMiss]) -> [Match] {
        var matches: [Match] = [], memo: [String: Ranked] = [:], i = 0
        while i < pieces.count {
            var step = 1
            spans: for n in stride(from: min(config.maxFormSpan, pieces.count - i), through: 1, by: -1)
            where Pieces.joinable(pieces, i, i + n) {
                let end = i + n, surface = Pieces.surface(text, pieces, i, end)
                let key = pieces[i..<end].map(\.lower).joined()
                if let e = index.byKey[key], index.entries[e].canonical == surface {
                    step = n
                    break spans
                }
                if let m = variant(i, end, surface, &near) ?? form(i, end, surface, key, &near)
                    ?? family(i, end, surface, &near) ?? spoken(i, end, surface, &near, &memo) {
                    matches.append(m)
                    step = n
                    break spans
                }
            }
            i += step
        }
        return matches
    }
    private func match(_ i: Int, _ end: Int, _ rule: String, _ reason: String, _ entry: Int,
                       _ replacement: String, variant: String? = nil, score: Double = 1, margin: Double = 1) -> Match {
        Match(start: i, end: end, rule: rule, reason: reason, entry: entry, variantID: variant,
              replacement: replacement, score: score, margin: margin)
    }
    /// Confirmed hearing variant: exact tokens; a protected word only with `replacesProtectedWord` from a click.
    private func variant(_ i: Int, _ end: Int, _ surface: String, _ near: inout [NearMiss]) -> Match? {
        for (e, v) in index.variants[pieces[i].lower] ?? [] where v.heard.count == end - i
            && LexiconIndex.fits(v, pieces, i) && surface != index.entries[e].canonical {
            let clicked = v.replacesProtectedWord && v.origin == .userClick
            if classes[i..<end].contains(where: \.isProtected) && !clicked {
                near.append(NearMiss(rule: RuleName.variant, before: surface, target: index.entries[e].canonical,
                                     score: 1, reason: "protected"))
                continue
            }
            return match(i, end, RuleName.variant, "heard", e, index.entries[e].canonical, variant: v.id)
        }
        return nil
    }
    /// R1: same letters, other spelling; a protected word only from a capitalized variant, protected runs only by
    /// an active variant (1.4); a lower-case canonical stays capitalized; a plural s is kept.
    private func form(_ i: Int, _ end: Int, _ surface: String, _ key: String, _ near: inout [NearMiss]) -> Match? {
        var plural = "", found = index.byKey[key]
        if found == nil, key.hasSuffix("s"), let e = index.byKey[String(key.dropLast())],
           !index.entries[e].canonical.lowercased().hasSuffix("s") {
            found = e
            plural = "s"
        }
        guard let e = found else { return nil }
        let canonical = index.entries[e].canonical, target = canonical + plural
        guard surface != target else { return nil }
        if end - i > 1, index.entries[e].kind == .acronym {  // several pieces are a spelled reading: R3 only (A.7)
            near.append(NearMiss(rule: RuleName.form, before: surface, target: target, score: 1, reason: "acronym"))
            return nil
        }
        if end - i == 1, classes[i].isProtected,
           surface.lowercased() != target.lowercased() || surface.first?.isUppercase != true { return nil }
        if end - i > 1, classes[i..<end].allSatisfy(\.isProtected) {
            near.append(NearMiss(rule: RuleName.form, before: surface, target: target, score: 1, reason: "protected"))
            return nil
        }
        if canonical.first?.isLowercase == true, surface == target.prefix(1).uppercased() + target.dropFirst() {
            return nil
        }
        return match(i, end, RuleName.form, "spelling", e, target)
    }
    /// R2: family anchor after one stem piece folding to a confirmed member's stem; an unknown stem is a near miss.
    private func family(_ i: Int, _ end: Int, _ surface: String, _ near: inout [NearMiss]) -> Match? {
        let n = end - i
        for fam in index.families {
            var stem: String?
            if n == 2, pieces[i + 1].lower == fam.anchor {
                stem = pieces[i].text
            } else if n == fam.anchor.count + 1,
                      zip(fam.anchor, pieces[i + 1..<end]).allSatisfy({ String($0) == $1.lower }) {
                stem = pieces[i].text
            } else if n == 1, pieces[i].lower.hasSuffix(fam.anchor), pieces[i].text.count >= fam.anchor.count + 2 {
                stem = String(pieces[i].text.dropLast(fam.anchor.count))
            }
            guard let stem, stem.count >= 2, stem.lowercased() != fam.anchor else { continue }
            if let e = fam.stems[Phonetics.fold(stem)] {
                return match(i, end, RuleName.family, "stem", e, index.entries[e].canonical)
            }
            if stem.contains(where: \.isLetter), !stem.contains(where: \.isNumber) {
                near.append(NearMiss(rule: RuleName.family, before: surface, target: stem + fam.anchorWritten,
                                     score: 0, reason: "stem"))
            }
        }
        return nil
    }
    /// Best and second-best entry for the readings of a span; repeated spans of one dictation are ranked once.
    struct Ranked {
        let top: LexiconIndex.Spoken?, score: Double, second: LexiconIndex.Spoken?, secondScore: Double, weight: Double
    }
    private func rank(_ i: Int, _ end: Int, spelled: Bool) -> Ranked {
        let all = Phonetics.keys(Array(readings[i..<end])), floor = config.nearMissFloor, band = index.spokenWeights
        let keys = all.filter { $0.weight >= band.lowerBound * floor && $0.weight * floor <= band.upperBound }
        var scored: [(score: Double, spoken: LexiconIndex.Spoken)] = []
        for s in index.spoken where !s.acronym || spelled {
            var best = 0.0
            for k in keys { for f in s.forms { best = max(best, Phonetics.similarity(k, f, floor: floor)) } }
            if best >= floor { scored.append((best, s)) }
        }
        let ranked = scored.sorted {
            ($1.score, index.entries[$0.spoken.entry].canonical) < ($0.score, index.entries[$1.spoken.entry].canonical)
        }
        let second = ranked.dropFirst().first
        return Ranked(top: ranked.first?.spoken, score: ranked.first?.score ?? 0, second: second?.spoken,
                      secondScore: second?.score ?? 0, weight: all.map(\.weight).max() ?? 0)
    }
    /// R3: spoken-form match on unprotected pieces only, with every guard of LEXIKON-KONZEPT 1.6.
    private func spoken(_ i: Int, _ end: Int, _ surface: String, _ near: inout [NearMiss],
                        _ memo: inout [String: Ranked]) -> Match? {
        guard config.spokenForm, end - i <= config.maxSpokenSpan else { return nil }
        let cls = classes[i..<end], span = pieces[i..<end]
        guard cls.contains(where: \.isOpenSource), cls.allSatisfy({ $0.isOpenSource || $0 == .number }) else {
            return nil
        }
        let spelled = zip(cls, span).allSatisfy { c, p in
            c == .number || c == .letter || (p.text.count <= 5 && p.text.allSatisfy { $0.isNumber || $0.isUppercase })
        }
        let memoKey = span.map(\.text).joined(separator: " ") + (spelled ? "|spelled" : "|word")
        let r = memo[memoKey] ?? rank(i, end, spelled: spelled)
        memo[memoKey] = r
        guard let top = r.top else { return nil }
        let margin = r.score - r.secondScore
        let sibling = top.family != nil && r.second?.family == top.family && r.secondScore >= config.siblingBlock
        let reason: String? = cls.contains(.abbreviation) ? "abbreviation"
            : r.score >= 0.999 && r.weight >= config.spokenExactMinWeight ? nil
            : r.score < config.spokenMinScore ? "threshold"
            : r.weight < config.spokenMinWeight ? "short"
            : sibling ? "sibling"
            : margin < config.spokenMinMargin ? "margin" : nil
        let target = index.entries[top.entry].canonical
        if let reason {
            near.append(NearMiss(rule: RuleName.spoken, before: surface, target: target, score: r.score,
                                 reason: reason))
            return nil
        }
        return match(i, end, RuleName.spoken, "sound", top.entry, target, score: r.score, margin: margin)
    }
}
