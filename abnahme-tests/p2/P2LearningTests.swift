// Group: Lernen mit Bremse (Probation, CandidateDetector). (R-031, R-030)
import Testing
@testable import FlowIQText

@Suite("P2 learning with brake")
struct P2LearningTests {
    static let heard = ["tapeq"]

    @Test("a probation variant does not act in process, an active one does")
    func probationInvisibleActiveVisible() {
        let text = Fx.padded("wir testen tapeq morgen")
        let probation = Fx.lexicon(Fx.iqEntries + [Fx.entry("Kelrana", variants: [Fx.variant(heard: ["tapeq"], status: .probation)])])
        let active = Fx.lexicon(Fx.iqEntries + [Fx.entry("Kelrana", variants: [Fx.variant(heard: ["tapeq"], status: .active)])])
        #expect(Fx.out(text, lexicon: probation) == text)
        #expect(Fx.out(text, lexicon: active) == Fx.padded("wir testen Kelrana morgen"))
    }

    @Test("suspended and retired variants never act", arguments: [VariantStatus.suspended, VariantStatus.retired])
    func stilledVariantsInactive(status: VariantStatus) {
        let text = Fx.padded("wir testen tapeq morgen")
        let lexicon = Fx.lexicon(Fx.iqEntries + [Fx.entry("Kelrana", variants: [Fx.variant(heard: ["tapeq"], status: status)])])
        #expect(Fx.out(text, lexicon: lexicon) == text)
    }

    @Test("2 hits in 2 dictations on 2 days promote the variant")
    func twoHitsTwoDictations() {
        let h = [Fx.journal(day: 1, text: "wir testen tapeq heute"), Fx.journal(day: 2, text: "tapeq ist neu")]
        #expect(Fx.verdict(Fx.variant(heard: Self.heard, status: .probation), h) == Fx.promote)
    }

    @Test("2 hits in only 1 dictation keep the variant in probation")
    func twoHitsOneDictation() {
        let h = [Fx.journal(day: 1, text: "tapeq und noch ein tapeq")]
        #expect(Fx.verdict(Fx.variant(heard: Self.heard, status: .probation), h) == Fx.keepProbation)
    }

    @Test("0 or 1 hit keep the variant in probation", arguments: [0, 1])
    func tooFewHits(hits: Int) {
        var h = [Fx.journal(day: 1, text: "nur bekannte Wörter hier")]
        if hits == 1 { h.append(Fx.journal(day: 2, text: "das tapeq ist da")) }
        #expect(Fx.verdict(Fx.variant(heard: Self.heard, status: .probation), h) == Fx.keepProbation)
    }

    @Test("a hit on a protected form never promotes", arguments: [VariantOrigin.corpus, VariantOrigin.nearMiss])
    func hitOnProtectedRejected(origin: VariantOrigin) {
        let protected: Set<String> = ["tapeq"]
        let h = [Fx.journal(day: 1, text: "wir testen tapeq heute", protectedForms: protected), Fx.journal(day: 2, text: "tapeq ist neu", protectedForms: protected)]
        let v = Fx.variant(heard: Self.heard, status: .probation, origin: origin, replacesProtectedWord: true)
        #expect(Fx.verdict(v, h) == Fx.reject)
    }

    @Test("a hit on a protected form may promote only when the user clicked exactly that")
    func protectedAllowedWhenClicked() {
        let protected: Set<String> = ["tapeq"]
        let h = [Fx.journal(day: 1, text: "wir testen tapeq heute", protectedForms: protected), Fx.journal(day: 2, text: "tapeq ist neu", protectedForms: protected)]
        let v = Fx.variant(heard: Self.heard, status: .probation, origin: .userClick, replacesProtectedWord: true)
        #expect(Fx.verdict(v, h) == Fx.promote)
    }

    @Test("the first undo of a single-intervention dictation stills the variant")
    func firstUndoStillsSilently() {
        let h = [Fx.journal(day: 1, text: "wir testen tapeq heute", rejectedInterventions: 1, interventions: 1), Fx.journal(day: 2, text: "tapeq ist neu")]
        #expect(Fx.verdict(Fx.variant(heard: Self.heard, status: .active), h) == Fx.retire)
    }

    @Test("an undo of a dictation with several interventions suspends instead of retiring")
    func undoWithSeveralInterventionsSuspends() {
        let h = [Fx.journal(day: 1, text: "wir testen tapeq heute", rejectedInterventions: 1, interventions: 3)]
        #expect(Fx.verdict(Fx.variant(heard: Self.heard, status: .active), h) == Fx.suspend)
    }

    @Test("evaluate is pure: the same history gives the same verdict")
    func evaluatePure() {
        let h = [Fx.journal(day: 1, text: "wir testen tapeq heute"), Fx.journal(day: 2, text: "tapeq ist neu")]
        let v = Fx.variant(heard: Self.heard, status: .probation)
        #expect(Fx.verdict(v, h) == Fx.verdict(v, h))
    }

    // MARK: candidate detection (K1)

    static func forms(_ history: [JournalView]) -> Set<String> {
        Set(CandidateDetector().candidates(in: history).map(\.form)) // ASSUMPTION: CandidateDetector() has a plain init and Candidate has `form: String`
    }

    @Test("a recurring non-word in 3 dictations on 2 days becomes a candidate")
    func recurringNonWordCandidate() {
        let h = [Fx.journal(day: 1, text: "wir testen zumpf heute"), Fx.journal(day: 1, text: "noch ein zumpf"), Fx.journal(day: 2, text: "das zumpf ist da")]
        #expect(Self.forms(h).contains("zumpf"))
    }

    @Test("fewer than 3 dictations, or all on one day, give no candidate", arguments: [[1, 2], [1, 1, 1]])
    func notEnoughForCandidate(days: [Int]) {
        let h = days.map { Fx.journal(day: $0, text: "wir testen zumpf heute") }
        #expect(!Self.forms(h).contains("zumpf"))
    }

    @Test("protected forms are never candidates")
    func protectedNeverCandidate() {
        let p: Set<String> = ["katze"]
        let h = [Fx.journal(day: 1, text: "die katze", protectedForms: p), Fx.journal(day: 2, text: "die katze", protectedForms: p), Fx.journal(day: 3, text: "die katze", protectedForms: p)]
        #expect(!Self.forms(h).contains("katze"))
    }
}
