// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-5: journal events of the correction (Anhang I addition to `JournalTests`, A.9): `correction` with the kind of
// choice and the result of the replacement, `reject_intervention` for "war richtig". The journal only grows, carries
// no field content of the target app, and the text-free protocol sees none of it.
import Foundation
import Testing
@testable import FlowIQ
@testable import FlowIQCore
@testable import FlowIQInsert
@testable import FlowIQStore
@testable import FlowIQText  // COMPILE-FIX: CanonEntry is a stored property type here; no expectation touched

@Suite(.timeLimit(.minutes(3)))
struct CorrectionJournalTests {
    private let sample = Scripted(id: "j-1", spoken: ["das", "ist", "napik", "morgen"], final: ["das", "ist", "NapIQ", "morgen"], alternatives: [3: ["morgens"]])
    private let lexicon = [entry("NapIQ", variants: [variant("napik", status: .active)])]

    @Test func aCorrectionAppendsOneEventWithChoiceAndResult() async throws {
        let rig = try await CorrectionRig(lexicon: lexicon)
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        _ = await rig.apply(.alternative("morgens"), to: 3..<4)  // ASSUMPTION: assumed API, see the Support header
        let lines = rig.scratch.journal().lines(of: "j-1")
        #expect(lines.map(\.event) == [JE.begin, JE.recognized, JE.inserted, JE.correction])
        let correction = try #require(lines.last)
        #expect(correction.string(JK.choice) == "alternative")
        #expect(correction.string(JK.replaceResult) == "fieldReplaced")  // ASSUMPTION: raw value of ReplaceResult is the case name
        #expect(correction.number(JK.time) != nil)  // ASSUMPTION: JK.time as a number on every line
    }

    @Test(arguments: [("alternative", 0), ("lexicon", 1), ("typed", 2)])
    func everyKindOfChoiceIsNamed(_ pair: (String, Int)) async throws {
        let rig = try await CorrectionRig(lexicon: lexicon + [entry("Morgenstern")])
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        let choices: [CorrectionChoice] = [.alternative("morgens"), .lexicon("Morgenstern"), .typed("übermorgen")]  // ASSUMPTION: assumed API, see the Support header
        _ = await rig.apply(choices[pair.1], to: 3..<4)
        let last = try #require(rig.scratch.journal().last)
        #expect(last.event == JE.correction)
        #expect(last.string(JK.choice) == pair.0)
    }

    @Test func wasRightWritesARejectionOfExactlyThatIntervention() async throws {
        let rig = try await CorrectionRig(lexicon: lexicon)
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        _ = await rig.drive { [session = rig.session] in await session.markWasRight(2..<3) }  // ASSUMPTION: assumed API, see the Support header
        let lines = rig.scratch.journal().lines(of: "j-1")
        let rejection = try #require(lines.first { $0.event == JE.rejectIntervention })
        #expect(rejection.string(JK.entryID) == "e-napiq")  // ASSUMPTION: assumed API, see the Support header
        #expect(rejection.string(JK.variantID) == "v-napik")  // ASSUMPTION: assumed API, see the Support header
        #expect(lines.filter { $0.event == JE.rejectIntervention }.count == 1)
    }

    @Test(arguments: [FieldTarget.Kind.text, .unreadable])
    func theResultOfTheReplacementIsRecordedForEachWay(_ kind: FieldTarget.Kind) async throws {
        let rig = try await CorrectionRig(lexicon: lexicon)
        defer { rig.remove() }
        try await rig.dictate(sample)
        rig.target.setKind(kind)
        _ = await rig.open()
        _ = await rig.apply(.alternative("morgens"), to: 3..<4)  // ASSUMPTION: assumed API, see the Support header
        let result = rig.scratch.journal().last?.string(JK.replaceResult)
        #expect(result == (kind == .text ? "fieldReplaced" : "undoReinserted"))
    }

    @Test func theClipboardWayIsRecordedToo() async throws {
        let rig = try await CorrectionRig(lexicon: lexicon)
        defer { rig.remove() }
        try await rig.dictate(sample)
        rig.target.setKind(.unreadable)
        _ = await rig.open()
        let session = rig.session
        _ = await rig.drive { await session.apply(.alternative("morgens"), to: 3..<4, keySinceInsert: true) }  // ASSUMPTION: apply(_:to:keySinceInsert:) with a default of false in the two-argument form
        #expect(rig.scratch.journal().last?.string(JK.replaceResult) == "clipboardHint")
    }

    @Test func theJournalOnlyGrowsAcrossCorrections() async throws {
        let rig = try await CorrectionRig(lexicon: lexicon)
        defer { rig.remove() }
        try await rig.dictate(sample)
        let before = rig.scratch.journalBytes()
        _ = await rig.open()
        _ = await rig.apply(.alternative("morgens"), to: 3..<4)  // ASSUMPTION: assumed API, see the Support header
        let middle = rig.scratch.journalBytes()
        _ = await rig.open()
        _ = await rig.drive { [session = rig.session] in await session.markWasRight(2..<3) }  // ASSUMPTION: assumed API, see the Support header
        let after = rig.scratch.journalBytes()
        #expect(middle.starts(with: before) && middle.count > before.count)
        #expect(after.starts(with: middle) && after.count > middle.count, "an earlier journal line was rewritten or removed")
    }

    @Test func neitherJournalNorProtocolHoldFieldContentOfTheTargetApp() async throws {
        let secret = "Passwort-Zitronenbaum-0815"
        let rig = try await CorrectionRig(lexicon: lexicon, prefix: secret + " ")
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        _ = await rig.apply(.alternative("morgens"), to: 3..<4)  // ASSUMPTION: assumed API, see the Support header
        _ = await rig.drive { [session = rig.session] in await session.rawVersion() }  // ASSUMPTION: assumed API, see the Support header
        #expect(!String(decoding: rig.scratch.journalBytes(), as: UTF8.self).contains(secret))
        #expect(!(await rig.scratch.logText()).contains(secret))
    }

    @Test func theProtocolSeesNoCorrectionText() async throws {
        let rig = try await CorrectionRig(lexicon: lexicon)
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        _ = await rig.apply(.typed("Schmetterling"), to: 3..<4)  // ASSUMPTION: assumed API, see the Support header
        let log = await rig.scratch.logText()
        #expect(!log.contains("Schmetterling") && !log.contains("napik"), "text-free protocol (A.2) holds corrected words")
    }
}
