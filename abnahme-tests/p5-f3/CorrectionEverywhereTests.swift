// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-11: a confirmed correction acts everywhere, and the text stage runs on every text (ARCHITEKTUR N.4, F3-11,
// R-112; Anhang I addition to `LiveFileTests`: "Textstufe je fertigem Beitrag vor dem Anhängen"). The same wrong form
// is fixed in the live contributions of BOTH recognizers, in the local end version, in the after-run text and in a
// device transcript (5 of 5 each, file source); the stage runs before a contribution is appended; a lexicon change
// that breaks a stored regression case does not become active and is reported (N.4 "Dauerfälle").
// The dictation path itself is covered by the P4 tests; stored vault transcripts are never rewritten afterwards.
import Foundation
import Testing
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQStore
@testable import FlowIQText

@Suite(.timeLimit(.minutes(4)))
struct CorrectionEverywhereTests {
    private let known = entry("NapIQ", variants: [variant("napik", status: .active)])
    private let when = localDate(2026, 11, 13, 10, 45)

    private func sentence(_ i: Int) -> String { "das ist napik gut \(i)" }
    private func fixed(_ i: Int) -> String { "das ist NapIQ gut \(i)" }

    @Test(arguments: [LiveEngine.appleLocal, .elevenLabsRealtime])
    func liveContributionsOfBothRecognizersAreFixedFiveOfFive(_ engine: LiveEngine) async throws {
        let rig = try await StoreRig.make(lexicon: [known])
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when, live: engine)  // ASSUMPTION: assumed API, see the Support header
        for i in 0..<5 { await rig.add(live, Line(seconds: 3 + i * 5, speaker: "Mara", text: sentence(i)), from: engine) }  // ASSUMPTION: assumed API, see the Support header
        let texts = try readDoc(live.url).contributions
        for i in 0..<5 { #expect(texts.contains { $0.hasSuffix(fixed(i)) }, "\(engine) contribution \(i): \(texts)") }
    }

    @Test func theStageRunsBeforeTheContributionIsAppended() async throws {
        let rig = try await StoreRig.make(lexicon: [known])
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 3, speaker: "Mara", text: "das ist napik"))
        let onDisk = String(decoding: try Data(contentsOf: live.url), as: UTF8.self)
        #expect(!onDisk.contains("napik"), "the unprocessed form was on disk, even for a moment")
        #expect(onDisk.contains("das ist NapIQ"))
    }

    @Test func aContributionWithoutAnInterventionIsAppendedUnchanged() async throws {
        let rig = try await StoreRig.make(lexicon: [known])
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when)  // ASSUMPTION: assumed API, see the Support header
        let plain = "Guten Morgen, wir starten. Größe, Übung, Straße."
        await rig.add(live, Line(seconds: 3, speaker: "Mara", text: plain))
        #expect(try readDoc(live.url).lines.first?.text == plain, "passthrough is the normal case (Leitsatz 4)")
    }

    @Test func theLocalEndVersionUsesTheLexiconAsItIsAtTheStop() async throws {
        let rig = try await StoreRig.make(post: [.call: false], lexicon: [entry("NapIQ")])  // COMPILE-FIX (P5 build): argument order of StoreRig.make
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when)  // ASSUMPTION: assumed API, see the Support header
        for i in 0..<5 { await rig.add(live, Line(seconds: 3 + i * 5, speaker: "Mara", text: sentence(i))) }
        #expect(try readDoc(live.url).contributions.allSatisfy { $0.contains("napik") }, "no variant yet: unchanged")
        try await rig.lexicon.seed([known])   // ASSUMPTION: assumed API, see the Support header; the user confirms the correction while the recording runs
        try await rig.finish(live, seconds: 60, raw: try rig.makeRaw(.call, at: when, seconds: 60))
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-lokal")
        for i in 0..<5 { #expect(doc.contributions.contains { $0.hasSuffix(fixed(i)) }, "end version \(i): \(doc.contributions)") }
    }

    @Test func theAfterRunTextIsFixedFiveOfFive() async throws {
        let lines = (0..<5).map { Line(seconds: $0 * 5, speaker: "Mara", text: sentence($0)) }
        let rig = try await StoreRig.make(batch: FakeBatch(fallback: .success(lines, speakers: 1)), lexicon: [known])
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 1, speaker: "Mara", text: "Platzhalter."))
        try await rig.finish(live, seconds: 60, raw: try rig.makeRaw(.call, at: when, seconds: 60))
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        for i in 0..<5 { #expect(doc.contributions.contains { $0.hasSuffix(fixed(i)) }, "after-run \(i): \(doc.contributions)") }
    }

    @Test func aDeviceTranscriptIsFixedFiveOfFive() async throws {
        let rig = try await StoreRig.make(lexicon: [known])
        defer { rig.remove() }
        for i in 0..<5 {
            let text = await rig.store.stage(sentence(i))  // ASSUMPTION: TranscriptStore.stage(_:) is the one entry through which a device transcript (R-064) gets the text stage
            #expect(text == fixed(i))
        }
    }

    @Test func theStageSeesTheSameLexiconSnapshotForEveryTextOfOneRecording() async throws {
        let rig = try await StoreRig.make(lexicon: [known])
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 3, speaker: "Mara", text: sentence(1)), from: .appleLocal)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 8, speaker: "Mara", text: sentence(1)), from: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        let lines = try readDoc(live.url).lines
        #expect(lines.count == 2 && lines[0].text == lines[1].text, "the two recognizers' identical texts came out differently")
    }

    @Test func storedTranscriptsAreNeverRewrittenWhenTheLexiconChangesLater() async throws {
        let rig = try await StoreRig.make(post: [.call: false], lexicon: [entry("NapIQ")])  // COMPILE-FIX (P5 build): argument order of StoreRig.make
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 3, speaker: "Mara", text: "das ist napik"))
        try await rig.finish(live, seconds: 60, raw: try rig.makeRaw(.call, at: when, seconds: 60))
        let stored = try Data(contentsOf: live.url)
        try await rig.lexicon.seed([known])   // ASSUMPTION: assumed API, see the Support header; a later correction
        await rig.trigger(.appStart)
        #expect(try Data(contentsOf: live.url) == stored, "an earlier transcript was rewritten (N.4)")
    }

    // MARK: regression cases

    @Test func aChangeThatBreaksAStoredRegressionCaseDoesNotBecomeActiveAndIsReported() async throws {
        let rig = try await StoreRig.make(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.lexicon.addRegressionCase(input: "wir treffen uns dann", expected: "wir treffen uns dann")  // ASSUMPTION: LexiconStore.addRegressionCase(input:expected:) stores a "Dauerfall" (every confirmed correction does this)
        let before = await rig.lexicon.entries()  // ASSUMPTION: assumed API, see the Support header
        let result = try await rig.lexicon.apply(.addVariant(entry: "e-napiq", heard: ["dann"], status: .active))  // ASSUMPTION: LexiconStore.apply(_:) returns ChangeResult { applied, blocked(cases) }; LexiconChangeRequest.addVariant(entry:heard:status:)
        guard case .blocked(let cases) = result else { Issue.record("a variant that rewrites a normal word was accepted"); return }  // ASSUMPTION: assumed API, see the Support header COMPILE-FIX (P5 build): Issue.record returns a value, `return` of it in a Void function does not compile
        #expect(cases.count == 1)
        #expect(await rig.lexicon.entries() == before, "a blocked change must not be active")  // ASSUMPTION: assumed API, see the Support header
        #expect(await rig.lexicon.pendingReports().count == 1, "the user is told")  // ASSUMPTION: pendingReports() lists blocked changes for the menu
    }

    @Test func aHarmlessChangeIsAppliedAndTheCaseStaysGreen() async throws {
        let rig = try await StoreRig.make(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.lexicon.addRegressionCase(input: "wir treffen uns dann", expected: "wir treffen uns dann")  // ASSUMPTION: assumed API, see the Support header
        let result = try await rig.lexicon.apply(.addVariant(entry: "e-napiq", heard: ["napik"], status: .active))  // ASSUMPTION: assumed API, see the Support header
        guard case .applied = result else { Issue.record("a harmless variant was blocked"); return }  // ASSUMPTION: assumed API, see the Support header COMPILE-FIX (P5 build): Issue.record returns a value, `return` of it in a Void function does not compile
        #expect(await rig.lexicon.pendingReports().isEmpty)  // ASSUMPTION: assumed API, see the Support header
    }
}
