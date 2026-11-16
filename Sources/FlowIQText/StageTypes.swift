@_exported import FlowIQCore

/// Neutral recognizer output (A.6): text, tokens with time and confidence, alternatives; the last two weigh 0.
public struct Recognition: Sendable, Codable, Equatable {
    public typealias Token = TimedWord  // Paket V A5: one word type
    public let text: String, tokens: [Token], segmentAlternatives: [[String]], recognizerProfile: String
    public init(text: String, tokens: [Token] = [], segmentAlternatives: [[String]] = [],
                recognizerProfile: String = "") {
        (self.text, self.tokens) = (text, tokens)
        (self.segmentAlternatives, self.recognizerProfile) = (segmentAlternatives, recognizerProfile)
    }
}

/// One question to the system dictionary (L-1). Forms are lower case or capitalized, never all upper case.
public struct OracleQuery: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case word          // known in German or English
        case englishStem   // English stem of a German-ending form (P3)
        case germanPart    // part of a German compound (P3)
    }
    public let form: String, kind: Kind
    public init(form: String, kind: Kind) { (self.form, self.kind) = (form, kind) }
}

/// Answers for one dictation. A missing query means "no answer" and counts as protected.
public struct OracleAnswers: Sendable, Codable, Equatable {
    public let known: [OracleQuery: Bool]
    public init(known: [OracleQuery: Bool]) { self.known = known }
}

/// Frozen protection list: system words seen so far, familiar forms (P2) and earlier oracle answers.
public struct FrozenWordSet: Sendable, Codable, Equatable {
    public var german: Set<String>, english: Set<String>, familiar: Set<String>, answered: [OracleQuery: Bool]
    public var version: Int
    public init(german: Set<String>, english: Set<String>, familiar: Set<String> = [],
                answered: [OracleQuery: Bool] = [:], version: Int = 0) {
        (self.german, self.english, self.familiar, self.answered, self.version) = (german, english, familiar, answered,
                                                                                    version)
    }
    /// The app freezes every answer so a replay takes the same decisions (A.7).
    public func adding(_ answers: OracleAnswers) -> FrozenWordSet {
        guard !answers.known.isEmpty else { return self }
        var copy = self
        copy.answered.merge(answers.known) { _, new in new }
        copy.version += 1
        return copy
    }
    func lookup(_ query: OracleQuery) -> Bool? {
        switch query.kind {
        case .word: if german.contains(query.form) || english.contains(query.form) { return true }
        case .englishStem: if english.contains(query.form) { return true }
        case .germanPart: if german.contains(query.form) { return true }
        }
        return answered[query]
    }
}

/// All thresholds are preliminary (L-4) until tuned on the gold set part "einstellen" with newly recognized text.
public struct TextStageConfig: Sendable, Codable, Equatable {
    public var version = 1
    /// R3 spoken-form match. Off until the three-way run on newly recognized audio shows its value (appendix K 3).
    public var spokenForm = false, spokenMinScore = 0.85, spokenMinWeight = 5.0, spokenExactMinWeight = 3.0
    public var spokenMinMargin = 0.10, siblingBlock = 0.70, nearMissFloor = 0.70, maxFormSpan = 4, maxSpokenSpan = 3
    public var brakeMaxCount = 6, brakeMaxShare = 0.15
    /// The share counts against at least this many pieces, so a dictation that is only a name may be corrected.
    public var brakeMinPieces = 20
    public init(spokenForm: Bool = false) { self.spokenForm = spokenForm }
}

/// One applied change (5): rule, source, target, reason, entry, range, score, margin, protection of each piece.
public struct Intervention: Sendable, Codable, Equatable {
    public let tRule: String, tBefore: String, tAfter: String, tReason: String, entryID: String, variantID: String?
    public let pieces: [Int], score: Double, margin: Double, sourceProtection: [String]
}

/// A hit that was not applied: below the threshold, stopped by a guard, an unknown family stem, or the brake.
public struct NearMiss: Sendable, Codable, Equatable {
    public let rule: String, before: String, target: String, score: Double, reason: String
}

public struct TextStageResult: Sendable, Codable, Equatable {
    public let text: String, interventions: [Intervention], nearMisses: [NearMiss]
    /// The recognizer text first, then the text after every step that changed something.
    public let stageTexts: [String], droppedByBrake: Int, micros: Int
    /// Lower-case forms of the input the protection list kept (journal, probation, candidates; L5).
    public var protectedForms: [String] = []
}

enum RuleName {
    static let variant = "variant"
    static let form = "R1"
    static let family = "R2"
    static let spoken = "R3"
}
