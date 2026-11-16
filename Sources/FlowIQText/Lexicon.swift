// Canon lexicon (LEXIKON-KONZEPT 1.1): no name in code (I6); the stage sees only a LexiconSnapshot.

public enum EntryKind: String, Sendable, Codable { case name, acronym, term }
public enum EntryStatus: String, Sendable, Codable { case proposed, confirmed, retired }
public enum EntryOrigin: String, Sendable, Codable {
    case seed, userClick, familyPattern, recurringNonWord, panottiImport
}
public enum CompoundPolicy: String, Sendable, Codable { case hyphen, none }
public enum SpokenLanguage: String, Sendable, Codable { case de, en }
public enum SpokenOrigin: String, Sendable, Codable { case derived, confirmed }
public enum VariantStatus: String, Sendable, Codable { case probation, active, suspended, retired }
public enum VariantOrigin: String, Sendable, Codable { case corpus, panottiRule, userClick, nearMiss }
public enum JoinStyle: String, Sendable, Codable { case concatenated }

public struct CorpusVerdict: Sendable, Codable, Equatable {
    public let runID: String, hits: Int, harm: Int, date: Date
}

public struct Counters: Sendable, Codable, Equatable {
    public var benefit: Int, harm: Int, lastAppliedAt: Date? = nil, lastCorpusRun: CorpusVerdict? = nil
    public init(benefit: Int = 0, harm: Int = 0, lastAppliedAt: Date? = nil, lastCorpusRun: CorpusVerdict? = nil) {
        (self.benefit, self.harm) = (benefit, harm)
        (self.lastAppliedAt, self.lastCorpusRun) = (lastAppliedAt, lastCorpusRun)
    }
}

public struct SpokenForm: Sendable, Codable, Equatable {
    public let language: SpokenLanguage, text: String, origin: SpokenOrigin
    public init(language: SpokenLanguage, text: String, origin: SpokenOrigin) {
        (self.language, self.text, self.origin) = (language, text, origin)
    }
}

public struct HearingVariant: Sendable, Codable, Equatable {
    public let id: String, heard: [String]
    public var context: [String], status: VariantStatus
    public let origin: VariantOrigin, replacesProtectedWord: Bool
    public var counters: Counters
    public init(id: String, heard: [String], context: [String], status: VariantStatus, origin: VariantOrigin,
                replacesProtectedWord: Bool, counters: Counters) {
        (self.id, self.heard, self.context) = (id, heard.map { $0.lowercased() }, context.map { $0.lowercased() })
        (self.status, self.origin, self.replacesProtectedWord, self.counters) = (status, origin, replacesProtectedWord,
                                                                                 counters)
    }
}

public struct CanonEntry: Sendable, Codable, Equatable {
    public let id: String
    public var canonical: String, kind: EntryKind, family: String? = nil, spokenForms: [SpokenForm]
    public var hearingVariants: [HearingVariant], status: EntryStatus, origin: EntryOrigin, compound: CompoundPolicy
    public var counters: Counters, createdAt: Date, confirmedAt: Date? = nil
    public init(id: String, canonical: String, kind: EntryKind, family: String?, spokenForms: [SpokenForm],
                hearingVariants: [HearingVariant], status: EntryStatus, origin: EntryOrigin,
                compound: CompoundPolicy, counters: Counters, createdAt: Date, confirmedAt: Date?) {
        (self.id, self.canonical, self.kind, self.family, self.spokenForms) = (id, canonical, kind, family, spokenForms)
        (self.hearingVariants, self.status, self.origin, self.compound) = (hearingVariants, status, origin, compound)
        (self.counters, self.createdAt, self.confirmedAt) = (counters, createdAt, confirmedAt)
    }
}

/// A family is an anchor ("IQ") plus the stems of its confirmed members (1.3).
public struct FamilyRule: Sendable, Codable, Equatable {
    public let id: String, anchorWritten: String, anchorSpoken: [SpokenForm], join: JoinStyle
    public init(id: String, anchorWritten: String, anchorSpoken: [SpokenForm], join: JoinStyle) {
        (self.id, self.anchorWritten, self.anchorSpoken, self.join) = (id, anchorWritten, anchorSpoken, join)
    }
}

/// What the stage sees: confirmed entries with active variants, sorted so input order never changes a result.
public struct LexiconSnapshot: Sendable, Codable, Equatable {
    public let entries: [CanonEntry], families: [FamilyRule], version: Int
    public init(entries: [CanonEntry], families: [FamilyRule], version: Int = 0) {
        self.entries = entries.filter { $0.status == .confirmed }.map { entry in
            var copy = entry
            copy.hearingVariants = entry.hearingVariants.filter { $0.status == .active }
            return copy
        }.sorted { ($0.canonical, $0.id) < ($1.canonical, $1.id) }
        self.families = families.sorted { $0.id < $1.id }
        self.version = version
    }
    /// R1 key: spelling in lower case without spaces, hyphens, dots and slashes (1.4).
    public static func key(_ text: String) -> String {
        String(text.lowercased().filter { !" -./".contains($0) })
    }
}
