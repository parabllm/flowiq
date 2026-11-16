/// The text stage (A.7): pure, deterministic, no I/O; passthrough unless source, target and match all hold.
public struct TextStage: Sendable {
    public let lexicon: LexiconSnapshot, protection: FrozenWordSet, config: TextStageConfig
    let index: LexiconIndex, shield: Protection
    public init(lexicon: LexiconSnapshot, protection: FrozenWordSet, config: TextStageConfig) {
        self.lexicon = lexicon
        self.protection = protection
        self.config = config
        index = LexiconIndex(lexicon)
        shield = Protection(frozen: protection, entryTokens: index.entryTokens, gluedEntries: index.gluedEntries)
    }
    /// Word forms and stems the frozen set cannot decide; the app answers them before `process` (L-1).
    public func oracleQueries(for input: Recognition) -> Set<OracleQuery> {
        Set(Pieces.split(Pieces.clean(input.text)).flatMap(shield.queries))
    }
    public func process(_ input: Recognition, answers: OracleAnswers) -> TextStageResult {
        let started = ContinuousClock.now, cleaned = Pieces.clean(input.text), pieces = Pieces.split(cleaned)
        let classes = pieces.map { shield.classify($0, answers) }
        var near: [NearMiss] = []
        let readings = zip(pieces, classes).map { p, c in
            config.spokenForm && (c.isOpenSource || c == .number) ? Phonetics.readings(p.text) : []
        }
        var matches = Matcher(index: index, config: config, text: cleaned, pieces: pieces, classes: classes,
                              readings: readings).scan(&near)
        // Mass brake (L-6): R3 only, share against max(pieces, 20) (project lead, 13.11.).
        let spoken = matches.filter { $0.rule == RuleName.spoken }
        let spokenPieces = spoken.reduce(0) { $0 + $1.end - $1.start }
        let braked = spoken.count > config.brakeMaxCount
            || Double(spokenPieces) > config.brakeMaxShare * Double(max(pieces.count, config.brakeMinPieces))
        if braked {
            matches.removeAll { $0.rule == RuleName.spoken }
            near += spoken.map {
                NearMiss(rule: RuleName.spoken, before: Pieces.surface(cleaned, pieces, $0.start, $0.end),
                         target: $0.replacement, score: $0.score, reason: "brake")
            }
        }
        var out = "", cursor = cleaned.startIndex, interventions: [Intervention] = []
        for m in matches {
            let range = pieces[m.start].range.lowerBound..<pieces[m.end - 1].range.upperBound
            out += cleaned[cursor..<range.lowerBound] + m.replacement
            cursor = range.upperBound
            interventions.append(Intervention(
                tRule: m.rule, tBefore: String(cleaned[range]), tAfter: m.replacement, tReason: m.reason,
                entryID: index.entries[m.entry].id, variantID: m.variantID, pieces: [m.start, m.end], score: m.score,
                margin: m.margin, sourceProtection: classes[m.start..<m.end].map(\.rawValue)))
        }
        out += cleaned[cursor...]
        var stageTexts = [input.text]
        if cleaned != input.text { stageTexts.append(cleaned) }
        if out != cleaned { stageTexts.append(out) }
        let elapsed = ContinuousClock.now - started, micros = Int(elapsed.components.seconds) * 1_000_000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000)
        let kept = Set(zip(pieces, classes).filter { $1.isProtected }.map(\.0.lower)).sorted()
        return TextStageResult(text: out, interventions: interventions, nearMisses: near, stageTexts: stageTexts,
                               droppedByBrake: braked ? spoken.count : 0, micros: micros, protectedForms: kept)
    }
}
