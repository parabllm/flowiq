/// What learning sees of one journal record (LEXIKON-KONZEPT 4, 5); `variants` nil counts for every fitting one.
public struct JournalView: Sendable, Codable, Equatable {
    public let day: Int, recognizerText: String, protectedForms: Set<String>
    public let rejectedInterventions: Int, interventionCount: Int
    public let nearMisses: [NearMiss], alternatives: [String], variants: [String]?
    public init(day: Int, recognizerText: String, protectedForms: Set<String>, rejectedInterventions: Int,
                interventionCount: Int, nearMisses: [NearMiss] = [], alternatives: [String] = [],
                variants: [String]? = nil) {
        let lowered = Set(protectedForms.map { $0.lowercased() })
        (self.day, self.recognizerText, self.protectedForms) = (day, recognizerText, lowered)
        (self.rejectedInterventions, self.interventionCount) = (rejectedInterventions, interventionCount)
        (self.nearMisses, self.alternatives, self.variants) = (nearMisses, alternatives, variants)
    }
}

public struct Candidate: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable { case recurringNonWord, familyPattern, nearMiss }
    /// Most frequent recognizer form; the spelling proposal, never from ElevenLabs (I4).
    public let form: String, source: Source, target: String?, dictations: Int, days: Int
}

/// K1 recurring non-word (3 dictations, 2 days), K2 family pattern, K3 near miss (twice in 2); never known forms.
public struct CandidateDetector: Sendable {
    public var minDictations = 3, minDays = 2, minRepeats = 2
    let known: Set<String>
    public init(lexicon: LexiconSnapshot = LexiconSnapshot(entries: [], families: [])) {
        known = Set(lexicon.entries.flatMap { e in
            e.canonical.lowercased().split(separator: " ").map(String.init) + e.hearingVariants.flatMap(\.heard)
        })
    }
    public func candidates(in history: [JournalView]) -> [Candidate] {
        var words: [String: (forms: [String: Int], dictations: Int, days: Set<Int>)] = [:]
        var hits: [String: (source: Candidate.Source, target: String, dictations: Int, days: Set<Int>)] = [:]
        for j in history {
            var seen = Set<String>()
            for p in Pieces.split(j.recognizerText) where p.hasLetter && !p.hasDigit && p.text.count > 1
                && !p.isUpperRun && !Phonetics.numberWords.contains(p.lower)
                && !j.protectedForms.contains(p.lower) && !known.contains(p.lower) {
                words[p.lower, default: ([:], 0, [])].forms[p.text, default: 0] += 1
                if seen.insert(p.lower).inserted {
                    words[p.lower]?.dictations += 1
                    words[p.lower]?.days.insert(j.day)
                }
            }
            for m in Set(j.nearMisses.map { "\($0.rule)\t\($0.before.lowercased())\t\($0.target)" }) {
                let parts = m.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let source: Candidate.Source = parts[0] == RuleName.family ? .familyPattern : .nearMiss
                hits[parts[1] + "\t" + parts[2], default: (source, parts[2], 0, [])].dictations += 1
                hits[parts[1] + "\t" + parts[2]]?.days.insert(j.day)
            }
        }
        let k1 = words.filter { $0.value.dictations >= minDictations && $0.value.days.count >= minDays }.map { w in
            let form = w.value.forms.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.first?.key ?? w.key
            return Candidate(form: form, source: .recurringNonWord, target: nil, dictations: w.value.dictations,
                             days: w.value.days.count)
        }
        let k23 = hits.filter { $0.value.dictations >= minRepeats }.map { h in
            Candidate(form: String(h.key.prefix { $0 != "\t" }), source: h.value.source, target: h.value.target,
                      dictations: h.value.dictations, days: h.value.days.count)
        }
        return (k1 + k23).sorted { ($0.source.rawValue, $0.form) < ($1.source.rawValue, $1.form) }
    }
}

public enum ProbationVerdict: String, Sendable, Codable {
    case promote, keepProbation, reject, retire, suspend
}

/// Pure probation (4.3, 4.4): 2 hits in 2 dictations, no protected hit, an undo stills at once; one hit suffices
/// for a proven target (N.3) or when the recognizer offered the target as alternative.
public enum Probation {
    public static let minHits = 2
    public static let minDictations = 2
    public static func evaluate(_ v: HearingVariant, over history: [JournalView], target: String? = nil,
                                proven: Bool = false) -> ProbationVerdict {
        if v.status == .retired { return .retire }
        if v.status == .suspended { return .suspend }
        var hits = 0, dictations = 0, offered = false
        for j in history {
            let n = fits(v, j)
            guard n > 0 else { continue }
            if v.status == .active, j.rejectedInterventions > 0, j.variants?.contains(v.id) ?? true {
                return j.interventionCount > 1 ? .suspend : .retire
            }
            let clicked = v.origin == .userClick && v.replacesProtectedWord
            if !clicked, v.heard.contains(where: j.protectedForms.contains) { return .reject }
            (hits, dictations) = (hits + n, dictations + 1)
            offered = offered || target.map { t in j.alternatives.contains { spells($0, t) } } == true
        }
        let enough = hits >= minHits && dictations >= minDictations
        return enough || hits > 0 && !v.replacesProtectedWord && (proven || offered) ? .promote : .keepProbation
    }
    /// How often the variant fits the recognizer text of one record.
    public static func fits(_ v: HearingVariant, _ j: JournalView) -> Int {
        let pieces = Pieces.split(j.recognizerText)
        return pieces.indices.filter { LexiconIndex.fits(v, pieces, $0) }.count
    }
    /// True when some run of up to 4 pieces of an alternative has the key of `target`.
    static func spells(_ alternative: String, _ target: String) -> Bool {
        let p = Pieces.split(alternative).map(\.lower), key = LexiconSnapshot.key(target)
        return p.indices.contains { i in (i..<min(i + 4, p.count)).contains { p[i...$0].joined() == key } }
    }
}
