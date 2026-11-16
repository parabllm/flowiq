// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-4: "Rohfassung" now lives in the correction window (ARCHITEKTUR N.2 point 2, Anhang I addition to
// `RawVersionTests`, R-034): the button replaces the whole last insertion by the recognizer text, unchanged by any
// stage; it counts as the rejection of ALL interventions of that dictation, exactly like the earlier menu way did;
// there is no separate menu entry any more; it works once per insertion.
import Foundation
import Testing
@testable import FlowIQ
@testable import FlowIQCore
@testable import FlowIQInsert
@testable import FlowIQStore
@testable import FlowIQText  // COMPILE-FIX: CanonEntry is a stored property type here; no expectation touched

@Suite(.timeLimit(.minutes(3)))
struct RawVersionWindowTests {
    private let dictation = Scripted(id: "raw-1", spoken: ["das", "ist", "flowiq", "und", "napiq", "ein", "probesatz"],
                                     final: ["das", "ist", "FlowIQ", "und", "NapIQ", "ein", "probesatz"])
    private let entries = [entry("FlowIQ", variants: [variant("flowiq", status: .active)]), entry("NapIQ", variants: [variant("napiq", status: .active)])]

    private func rawVersion(_ rig: CorrectionRig) async -> CorrectionOutcome? {  // ASSUMPTION: assumed API, see the Support header
        let session = rig.session
        return await rig.drive { await session.rawVersion() }  // ASSUMPTION: CorrectionSession.rawVersion() async -> CorrectionOutcome (the "Rohfassung" button)
    }

    @Test func theButtonReplacesTheWholeInsertionByTheUnchangedRecognizerText() async throws {
        let rig = try await CorrectionRig(lexicon: entries, prefix: "Notiz: ", clipboard: richClipboard())
        defer { rig.remove() }
        try await rig.dictate(dictation)
        _ = await rig.open()
        let clipboard = rig.pasteboard.items
        let outcome = await rawVersion(rig)
        #expect(outcome?.replace == .fieldReplaced)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.field == "Notiz: das ist flowiq und napiq ein probesatz", "raw text must be exactly what the recognizer heard")
        #expect(rig.pasteboard.items == clipboard)
    }

    @Test func itCountsAsTheRejectionOfAllInterventionsInTheJournal() async throws {
        let rig = try await CorrectionRig(lexicon: entries)
        defer { rig.remove() }
        try await rig.dictate(dictation)
        _ = await rig.open()
        _ = await rawVersion(rig)
        let lines = rig.scratch.journal().lines(of: "raw-1")
        let rejects = lines.filter { $0.event == JE.reject }
        #expect(rejects.count == 1)
        #expect(rejects.first?.number(JK.rejected) == 2)
        #expect(Array(lines.map(\.event).prefix(3)) == [JE.begin, JE.recognized, JE.inserted], "earlier lines are appended to, never rewritten")
    }

    @Test func itActsOnTheVariantsLikeAnyRejection() async throws {
        let rig = try await CorrectionRig(lexicon: entries)
        defer { rig.remove() }
        try await rig.dictate(dictation)
        _ = await rig.open()
        _ = await rawVersion(rig)
        // Two interventions in one dictation: both active variants are suspended, none is deleted (N.5).
        #expect(await rig.entry("FlowIQ")?.hearingVariants.first?.status == .suspended)
        #expect(await rig.entry("NapIQ")?.hearingVariants.first?.status == .suspended)
        #expect(await rig.entries().count == 2)
    }

    @Test func whenOnlyTheClipboardWayRemainsTheRejectionStillCounts() async throws {
        let rig = try await CorrectionRig(lexicon: entries)
        defer { rig.remove() }
        try await rig.dictate(dictation)
        rig.target.setKind(.unreadable)
        _ = await rig.open()
        let outcome = await rig.drive { [session = rig.session] in await session.rawVersion(keySinceInsert: true) }  // ASSUMPTION: rawVersion(keySinceInsert:) as in the insertion tests
        #expect(outcome?.replace == .clipboardHint)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.pasteboard.plainText == "das ist flowiq und napiq ein probesatz")
        #expect(rig.scratch.journal().filter { $0.event == JE.reject }.count == 1)
    }

    @Test func itWorksOnlyOncePerInsertion() async throws {
        let rig = try await CorrectionRig(lexicon: entries)
        defer { rig.remove() }
        try await rig.dictate(dictation)
        _ = await rig.open()
        let first = await rawVersion(rig)
        let second = await rawVersion(rig)
        #expect(first?.replace == .fieldReplaced)  // ASSUMPTION: assumed API, see the Support header
        #expect(second?.replace == .nothingToReplace)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.scratch.journal().filter { $0.event == JE.reject }.count == 1)
        #expect(rig.target.field == "das ist flowiq und napiq ein probesatz")
    }

    @Test func aDictationWithoutInterventionsRejectsNothing() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "raw-2", spoken: ["das", "ist", "gut"], final: ["das", "ist", "gut"]))
        _ = await rig.open()
        let outcome = await rawVersion(rig)
        #expect(outcome?.replace == .fieldReplaced || outcome?.replace == .nothingToReplace)  // ASSUMPTION: assumed API, see the Support header
        #expect(!rig.scratch.journal().contains { $0.event == JE.reject && ($0.number(JK.rejected) ?? 0) > 0 })
    }

    @Test func thereIsNoMenuEntryForTheRawVersionAnyMore() {
        let ids = StatusMenuModel.standardItemIDs  // ASSUMPTION: StatusMenuModel.standardItemIDs lists the identifiers of the fixed menu entries
        #expect(ids.contains("correctLastDictation"))  // ASSUMPTION: identifier of the entry that opens the window
        #expect(!ids.contains("insertRawVersion"), "the raw version is a button in the window, not a menu way (Fassung 3)")
    }

    @Test func noSoundAndNoWindowToTheFrontBeyondTheCorrectionWindowItself() async throws {
        let rig = try await CorrectionRig(lexicon: entries)
        defer { rig.remove() }
        try await rig.dictate(dictation)
        _ = await rig.open()
        _ = await rawVersion(rig)
        #expect(Set(rig.target.posted).isSubset(of: ["paste", "undo"]))
        #expect(rig.host.frontmost() == "app.target", "focus must be back at the previous app")
    }
}
