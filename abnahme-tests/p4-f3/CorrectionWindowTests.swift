// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-1: the window "Letztes Diktat korrigieren" (ARCHITEKTUR N.2, R-109, Anhang I new file
// `CorrectionWindowTests`): opens in at most 300 ms, shows the last dictation as a word sequence, a click on a word or
// a span offers the recognizer alternatives (up to 3), the nearest confirmed lexicon entries (up to 3), the raw form
// and free input; one click adopts; "war richtig" only where FlowIQ intervened; the focus goes back to the previous app.
// The dictation text appears in this window only (R-021): never in the protocol.
import Foundation
import Testing
@testable import FlowIQ
@testable import FlowIQCore
@testable import FlowIQInsert
@testable import FlowIQStore
@testable import FlowIQText

@Suite(.timeLimit(.minutes(3)))
struct CorrectionWindowTests {
    private let sample = Scripted(id: "d-1", spoken: ["wir", "treffen", "uns", "napik", "morgen"], final: ["wir", "treffen", "uns", "NapIQ", "morgen"],
                                  alternatives: [4: ["morgan", "morgen", "morgens", "mohren", "mogen"]])

    @Test func opensInAtMost300msWithLongHistory() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        for i in 0..<50 { try await rig.dictate(Scripted(id: "h-\(i)", spoken: ["wir", "treffen", "uns"], final: ["wir", "treffen", "uns"])) }
        var millis: [Double] = []
        for _ in 0..<10 {
            let started = ContinuousClock.now
            let view = await rig.session.open()  // ASSUMPTION: CorrectionSession.open() async -> CorrectionView
            millis.append((ContinuousClock.now - started).ms)
            #expect(view.words.count == 3)  // ASSUMPTION: CorrectionView.words is the final text of the newest dictation, word by word
            await rig.session.close()  // ASSUMPTION: CorrectionSession.close() async
        }
        #expect(millis.max() ?? 0 <= 300, "window needed \(millis.max() ?? 0) ms")
        #expect(rig.host.presented.count == 10)
    }

    @Test func showsTheNewestDictationFirstAsWordSequence() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "d-0", spoken: ["das", "ist", "alt"], final: ["das", "ist", "alt"]))
        try await rig.dictate(sample)
        let view = try #require(await rig.open())
        #expect(view.dictationID == "d-1")  // ASSUMPTION: CorrectionView.dictationID
        #expect(view.words == ["wir", "treffen", "uns", "NapIQ", "morgen"])  // ASSUMPTION: assumed API, see the Support header
        #expect(view.interventionSpans == [3..<4])  // ASSUMPTION: CorrectionView.interventionSpans are the word ranges FlowIQ changed
        #expect(view.recent.count == 2)  // ASSUMPTION: CorrectionView.recent lists the earlier dictations for choosing an older one
    }

    @Test func alternativesAreCappedAtThreeInTheRecognizersOrder() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        let options = await rig.options(4..<5)
        #expect(options.recognizerAlternatives == ["morgan", "morgen", "morgens"])  // ASSUMPTION: CorrectionOptions.recognizerAlternatives
        #expect(options.allowsFreeInput)  // ASSUMPTION: CorrectionOptions.allowsFreeInput
    }

    @Test func nearestConfirmedEntriesAreCappedAtThreeAndSkipUnconfirmedOnes() async throws {
        let names = ["Brimvolt", "Brimfeld", "Brinvolk", "Primvolt", "Brimvelt"].map { entry($0) }
        let others = [entry("Kelrana"), entry("Brimvoldt", status: .proposed), entry("Brimvalt", status: .retired)]
        let rig = try await CorrectionRig(lexicon: names + others)
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "d-2", spoken: ["bitte", "brimvold", "kommt"], final: ["bitte", "brimvold", "kommt"]))
        _ = await rig.open()
        let near = await rig.options(1..<2).lexiconNeighbors  // ASSUMPTION: CorrectionOptions.lexiconNeighbors, nearest first by sound
        #expect(near.count == 3)
        #expect(Set(near).isSubset(of: Set(names.map(\.canonical))))
        #expect(!near.contains("Kelrana"))
        #expect(!near.contains("Brimvoldt") && !near.contains("Brimvalt"))
        #expect(near.first == "Brimvolt")
    }

    @Test func rawFormIsWhatTheRecognizerHeardAtAnInterventionPlace() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        let options = await rig.options(3..<4)
        #expect(options.rawForm == "napik")  // ASSUMPTION: CorrectionOptions.rawForm
        let plain = await rig.options(1..<2)
        #expect(plain.rawForm == "treffen")  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func aSpanOfSeveralWordsOffersItsRawFormAndFreeInput() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        let span = await rig.options(2..<4)
        #expect(span.rawForm == "uns napik")  // ASSUMPTION: assumed API, see the Support header
        #expect(span.allowsFreeInput)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func wasRightIsOfferedOnlyAtInterventionsOfFlowIQ() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.dictate(sample)
        _ = await rig.open()
        let changed = await rig.options(3..<4)
        let untouched = await rig.options(1..<2)
        #expect(changed.offersWasRight)  // ASSUMPTION: CorrectionOptions.offersWasRight
        #expect(!untouched.offersWasRight)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func oneClickAdoptsTenOfTen() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")], prefix: "Notiz: ")
        defer { rig.remove() }
        for i in 0..<10 {
            let d = Scripted(id: "c-\(i)", spoken: ["wir", "treffen", "uns", "morgen"], final: ["wir", "treffen", "uns", "morgen"],
                             alternatives: [3: ["übermorgen"]])
            try await rig.dictate(d)
            _ = await rig.open()
            let outcome = await rig.apply(.alternative("übermorgen"), to: 3..<4)  // ASSUMPTION: CorrectionChoice.alternative(String)
            #expect(outcome?.replace == .fieldReplaced, "run \(i)")  // ASSUMPTION: CorrectionOutcome.replace is the ReplaceResult
            #expect(rig.target.field.hasSuffix("wir treffen uns übermorgen"), "run \(i): \(rig.target.field)")
            await rig.session.close()  // ASSUMPTION: assumed API, see the Support header
        }
    }

    @Test func lexiconChoiceAndTypedInputAdoptLikeAnAlternative() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("Brimvolt")])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "t-1", spoken: ["bitte", "brimvold", "kommt"], final: ["bitte", "brimvold", "kommt"]))
        _ = await rig.open()
        let a = await rig.apply(.lexicon("Brimvolt"), to: 1..<2)  // ASSUMPTION: CorrectionChoice.lexicon(String)
        #expect(a?.replace == .fieldReplaced)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.field == "bitte Brimvolt kommt")
        _ = await rig.open()
        let b = await rig.apply(.typed("sofort"), to: 2..<3)  // ASSUMPTION: CorrectionChoice.typed(String)
        #expect(b?.replace == .fieldReplaced)  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.field == "bitte Brimvolt sofort")
    }

    @Test func focusGoesBackToThePreviousAppTenOfTen() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        for i in 0..<10 {
            try await rig.dictate(Scripted(id: "f-\(i)", spoken: ["wir", "treffen"], final: ["wir", "treffen"], alternatives: [1: ["treffe"]]))
            rig.host.activate("app.target")
            _ = await rig.open()
            #expect(rig.host.frontmost() == "flowiq.window", "run \(i): window must be in front while open")
            #expect(rig.host.windowIsKey)  // typing is allowed, so the window is key
            if i % 2 == 0 {
                _ = await rig.apply(.alternative("treffe"), to: 1..<2)  // ASSUMPTION: assumed API, see the Support header
            } else {
                await rig.session.close()  // ASSUMPTION: assumed API, see the Support header
            }
            #expect(rig.host.frontmost() == "app.target", "run \(i): focus not back")
            #expect(!rig.host.windowIsKey)
        }
    }

    @Test func openingAndClosingChangesNothing() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.dictate(sample)
        let field = rig.target.field
        let clipboard = rig.pasteboard.items
        let before = await rig.entries()
        _ = await rig.open()
        _ = await rig.options(3..<4)
        await rig.session.close()  // ASSUMPTION: assumed API, see the Support header
        #expect(rig.target.field == field)
        #expect(rig.pasteboard.items == clipboard)
        #expect(await rig.entries() == before)
        #expect(!rig.scratch.journal().events().contains(JE.correction))
    }

    @Test func dictationTextNeverReachesTheProtocol() async throws {
        let rig = try await CorrectionRig(lexicon: [entry("NapIQ")])
        defer { rig.remove() }
        try await rig.dictate(Scripted(id: "s-1", spoken: ["das", "ist", "ein", "zebrafisch"], final: ["das", "ist", "ein", "zebrafisch"], alternatives: [3: ["zebrafische"]]))
        _ = await rig.open()
        _ = await rig.options(3..<4)
        _ = await rig.apply(.typed("Quarkspeise"), to: 3..<4)  // ASSUMPTION: assumed API, see the Support header
        await rig.session.close()  // ASSUMPTION: assumed API, see the Support header
        let log = await rig.scratch.logText()
        #expect(!log.contains("zebrafisch") && !log.contains("Quarkspeise"), "dictation words in the text-free protocol")
    }

    @Test func shortcutAndMenuOpenTheSameWindow() async throws {
        let rig = try await CorrectionRig()
        defer { rig.remove() }
        try await rig.dictate(sample)
        let session = rig.session
        let viaShortcut = await rig.drive { await session.open(from: .shortcut) }  // ASSUMPTION: open(from:) with OpenSource { shortcut, menu }
        await rig.session.close()  // ASSUMPTION: assumed API, see the Support header
        let viaMenu = await rig.drive { await session.open(from: .menu) }  // ASSUMPTION: OpenSource.menu
        #expect(viaShortcut?.words == viaMenu?.words)  // ASSUMPTION: assumed API, see the Support header
        #expect(viaShortcut?.dictationID == viaMenu?.dictationID)  // ASSUMPTION: assumed API, see the Support header
    }
}
