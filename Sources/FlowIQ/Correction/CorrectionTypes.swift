/// One finished dictation as the correction window sees it (N.2).
nonisolated struct DictationRecord: Sendable {
    let id: String, recognition: Recognition, finalText: String, interventions: [Intervention], targetApp: String?
    var landed = true
}

nonisolated protocol DictationHistory: Sendable { func recent(limit: Int) async -> [DictationRecord] }

/// The last 50 dictations, newest first; filled from the journal at the start, so the list survives a restart.
actor RecentDictations: DictationHistory {
    private var list: [DictationRecord] = []
    func add(_ record: DictationRecord) { list = Array(([record] + list).prefix(50)) }
    func recent(limit: Int) -> [DictationRecord] { Array(list.prefix(limit)) }
    func preload(_ journal: DictationJournal) async {
        list = await journal.records(limit: 50).map { r in
            let recognition = Recognition(text: r.recognizerText, segmentAlternatives: r.alternatives)
            return DictationRecord(id: r.id, recognition: recognition, finalText: r.finalText,  // the field is gone
                                   interventions: r.interventions, targetApp: r.app, landed: false)
        } + list
    }
}

nonisolated protocol CorrectionWindowPresenting: Sendable {
    func present(_ view: CorrectionView) async; func dismiss() async
}

nonisolated protocol FrontAppActivating: Sendable { func frontmost() -> String?; func activate(_ app: String) }

/// The words of the newest dictation, the places FlowIQ changed, the recent dictations.
nonisolated struct CorrectionView: Sendable {
    let dictationID: String, words: [String], interventionSpans: [Range<Int>], recent: [DictationRecord]
}

/// What a click on a word or span offers (R-109).
nonisolated struct CorrectionOptions: Sendable, Equatable {
    var recognizerAlternatives: [String] = [], lexiconNeighbors: [String] = [], rawForm = ""
    var allowsFreeInput = true, offersWasRight = false
}

nonisolated enum CorrectionChoice: Sendable, Equatable {
    case alternative(String), lexicon(String), typed(String), raw
    /// Journal name of the kind of choice: alternative, lexicon, typed or raw.
    var name: String { String(String(describing: self).prefix { $0 != "(" }) }
}

/// `blocked`: the change would break a permanent case; it was not made and stands on "Zum Prüfen" (L7).
nonisolated enum LearningOutcome: String, Sendable { case learned, askScope, countedConfusion, none, blocked }
nonisolated enum ScopeChoice: Sendable, Equatable { case always, nextTo(String), once }
nonisolated enum OpenSource: String, Sendable { case shortcut, menu }

nonisolated struct CorrectionOutcome: Sendable, Equatable { let replace: ReplaceResult, learning: LearningOutcome }
