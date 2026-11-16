// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group F3-10: live source and after-run noted in the transcript without breaking the contract (ARCHITEKTUR M.10,
// Anhang L line 12, R-107; Anhang I additions to `ContractTests` and `LiveFileTests`). New header keys `live_quelle`,
// `live_wechsel`, `nachlauf_quelle`, `cloud_minuten`; phases, status values, `pipeline` and the contribution lines stay
// exactly as they were; switch lines are italic and not matched by the consumers' line pattern `^\*\*\[\d`; the header
// of a live file stays fixed during `live-stream` (so `live_wechsel` is written at the stop); the file only grows,
// also across switches. Three consumers are simulated: the live reader script, a strict old-schema skill reader and the
// pipeline's status reader.
import Foundation
import Testing
@testable import FlowIQCloud
@testable import FlowIQCore
@testable import FlowIQStore

@Suite(.timeLimit(.minutes(4)))
struct FrontmatterVermerkTests {
    private let when = localDate(2026, 11, 13, 10, 45)
    private let oldKeys = ["type", "status", "panotti_live", "panotti_phase", "quelle", "aufnahme", "dauer", "sprecher_erkannt", "sprache", "pipeline"]  // ASSUMPTION: Panotti's order as in the frozen ContractTests

    private func answer() -> FakeBatch { FakeBatch(fallback: .success([Line(seconds: 0, speaker: "Mara", text: "Neufassung.")], speakers: 1)) }

    /// A 6-minute room recording that started on the cloud, fell back to Apple at 02:00 and returned at 05:00.
    private func switched(_ rig: StoreRig) async throws -> LiveTranscript {
        let live = try await rig.begin(.room, at: when, live: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 3, speaker: "Raum", text: "Erster Satz."), from: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        await rig.noteSwitch(live, at: 120, to: .appleLocal, reason: .networkError)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 125, speaker: "Raum", text: "Zweiter Satz."), from: .appleLocal)  // ASSUMPTION: assumed API, see the Support header
        await rig.noteSwitch(live, at: 300, to: .elevenLabsRealtime, reason: .returnToCloud)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 305, speaker: "Raum", text: "Dritter Satz."), from: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        return live
    }

    // MARK: header keys

    @Test func theHeaderStaysFixedDuringLiveStreamAndShowsTheStartSource() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await switched(rig)
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "live-stream")
        #expect(doc.value("live_quelle") == "elevenlabs-scribe-v3-live", "while live the key shows the source the recording started with")
        #expect(doc.value("live_wechsel") == nil && doc.lists["live_wechsel"] == nil, "switches are written at the stop, the header is fixed while live")  // ASSUMPTION: assumed API, see the Support header
        #expect(doc.value("cloud_minuten") == nil)
        #expect(doc.value("nachlauf_quelle") == nil)
    }

    @Test func atTheStopTheSourceIsMixedAndTheSwitchesAreListed() async throws {
        let rig = try await StoreRig.make(batch: answer(), post: [.room: false])
        defer { rig.remove() }
        let live = try await switched(rig)
        try await rig.finish(live, seconds: 360, raw: try rig.makeRaw(.room, at: when, seconds: 360), cloudLiveSeconds: 240)  // ASSUMPTION: assumed API, see the Support header
        let doc = try readDoc(live.url)
        #expect(doc.value("live_quelle") == "gemischt")
        #expect(doc.lists["live_wechsel"] == ["02:00 apple-lokal netzfehler", "05:00 elevenlabs-scribe-v3-live rueckkehr"])  // ASSUMPTION: item format `MM:SS <quelle> <grund>` with reasons manuell, netzfehler, rueckkehr, monatsgrenze (M.10)
        #expect(abs((Double(doc.value("cloud_minuten") ?? "-1") ?? -1) - 4.0) <= 0.1, "240 s of live audio were sent: \(doc.value("cloud_minuten") ?? "nil")")
        #expect(doc.value("nachlauf_quelle") == nil)
        #expect(doc.value("panotti_phase") == "final-lokal")
    }

    @Test func theUpgradeAddsTheAfterRunSourceAndItsMinutes() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await switched(rig)
        try await rig.finish(live, seconds: 360, raw: try rig.makeRaw(.room, at: when, seconds: 360), cloudLiveSeconds: 240)  // ASSUMPTION: assumed API, see the Support header
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "final-elevenlabs")
        #expect(doc.value("nachlauf_quelle") == "elevenlabs-scribe-v3")
        #expect(abs((Double(doc.value("cloud_minuten") ?? "-1") ?? -1) - 10.0) <= 0.1, "240 s live plus 360 s after-run: \(doc.value("cloud_minuten") ?? "nil")")
        #expect(doc.value("live_quelle") == "gemischt", "the upgrade keeps what the stop wrote")
        #expect(doc.lists["live_wechsel"]?.count == 2)  // ASSUMPTION: assumed API, see the Support header
    }

    @Test func aRecordingThatNeverLeftAppleCarriesTheLocalSourceAndNoSwitches() async throws {
        let rig = try await StoreRig.make(batch: answer(), post: [.room: false])
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 3, speaker: "Raum", text: "Satz."))
        try await rig.finish(live, seconds: 60, raw: try rig.makeRaw(.room, at: when, seconds: 60))
        let doc = try readDoc(live.url)
        #expect(doc.value("live_quelle") == "apple-lokal")
        #expect(doc.lists["live_wechsel"] == nil)  // ASSUMPTION: assumed API, see the Support header
        #expect((Double(doc.value("cloud_minuten") ?? "0") ?? -1) == 0)
    }

    @Test func aLocalRecordingWithAnAfterRunCountsOnlyTheAfterRun() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: when)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 3, speaker: "Raum", text: "Satz."))
        try await rig.finish(live, seconds: 120, raw: try rig.makeRaw(.room, at: when, seconds: 120))
        #expect(abs((Double(try readDoc(live.url).value("cloud_minuten") ?? "-1") ?? -1) - 2.0) <= 0.1)
    }

    // MARK: switch lines

    @Test func switchLinesAreItalicAndNamedAsDocumented() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await switched(rig)
        await rig.noteSwitch(live, at: 330, to: .appleLocal, reason: .manual)  // ASSUMPTION: assumed API, see the Support header
        await rig.noteSwitch(live, at: 3725, to: .elevenLabsRealtime, reason: .manual)  // ASSUMPTION: assumed API, see the Support header
        let lines = try readDoc(live.url).switchLines
        #expect(lines == ["_[02:00] Live-Erkennung: Apple lokal (Netzfehler)_", "_[05:00] Live-Erkennung: ElevenLabs_",
                          "_[05:30] Live-Erkennung: Apple lokal_", "_[01:02:05] Live-Erkennung: ElevenLabs_"])  // ASSUMPTION: wording for manual and return switches; the first two are fixed by M.3; time stamps follow the contribution format
    }

    @Test func switchLinesAreInvisibleToTheContributionPattern() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await switched(rig)
        let doc = try readDoc(live.url)
        #expect(doc.switchLines.count == 2)
        #expect(doc.switchLines.allSatisfy { !isContributionLine($0) && $0.hasPrefix("_") && $0.hasSuffix("_") })
        #expect(doc.contributions.count == 3, "the reader's count of contributions is not changed by switch lines")
    }

    @Test func aSwitchLineSitsAboveTheVolatileClosingLine() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await rig.begin(.room, at: when, live: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        await rig.add(live, Line(seconds: 3, speaker: "Raum", text: "Satz."))
        await live.setVolatile(seconds: 5, speaker: "Raum", text: "halber Satz")  // ASSUMPTION: setVolatile(seconds:speaker:text:) as in the frozen P5 tests
        await rig.noteSwitch(live, at: 6, to: .appleLocal, reason: .networkError)  // ASSUMPTION: assumed API, see the Support header
        let body = try readDoc(live.url).body.filter { !$0.isEmpty }
        #expect(body.last.map(isVolatileLine) == true, "the volatile line stays the last line")
        #expect(body.dropLast().last.map(isSwitchLine) == true)
    }

    // MARK: nothing else changes

    @Test func phasesStatusPipelineAndBeitragszeilenAreTheSameWithCloudAndSwitches() async throws {
        let control = try await StoreRig.make(batch: answer())
        let cloud = try await StoreRig.make(batch: answer())
        defer { control.remove(); cloud.remove() }
        let plain = try await control.begin(.room, at: when)  // ASSUMPTION: assumed API, see the Support header
        await control.add(plain, Line(seconds: 3, speaker: "Raum", text: "Erster Satz."))
        await control.add(plain, Line(seconds: 125, speaker: "Raum", text: "Zweiter Satz."))
        await control.add(plain, Line(seconds: 305, speaker: "Raum", text: "Dritter Satz."))
        try await control.finish(plain, seconds: 360, raw: try control.makeRaw(.room, at: when, seconds: 360))
        let mixed = try await switched(cloud)
        try await cloud.finish(mixed, seconds: 360, raw: try cloud.makeRaw(.room, at: when, seconds: 360), cloudLiveSeconds: 240)  // ASSUMPTION: assumed API, see the Support header
        let a = try readDoc(plain.url), b = try readDoc(mixed.url)
        for key in oldKeys where key != "quelle" && key != "aufnahme" {
            #expect(a.value(key) == b.value(key), "\(key) changed with cloud live: \(a.value(key) ?? "nil") vs \(b.value(key) ?? "nil")")
        }
        #expect(a.contributions == b.contributions, "the contribution lines differ")
        #expect(a.value("status") == "unverarbeitet" && b.value("status") == "unverarbeitet")
    }

    @Test func theOldKeysKeepTheirOrder() async throws {
        let rig = try await StoreRig.make(batch: answer(), post: [.room: false])
        defer { rig.remove() }
        let live = try await switched(rig)
        try await rig.finish(live, seconds: 360, raw: try rig.makeRaw(.room, at: when, seconds: 360), cloudLiveSeconds: 240)  // ASSUMPTION: assumed API, see the Support header
        let keys = try readDoc(live.url).keys
        #expect(keys.filter(oldKeys.contains) == oldKeys.filter(keys.contains), "relative order of Panotti's keys changed: \(keys)")
        for new in ["live_quelle", "live_wechsel", "nachlauf_quelle", "cloud_minuten"] where keys.contains(new) {
            #expect(keys.filter { $0 == new }.count == 1, "\(new) twice in the header")
        }
    }

    // MARK: the three consumers

    @Test func theLiveReaderScriptStillCountsTheContributionsAndSeesStatusAndPhase() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await switched(rig)
        let text = String(decoding: try Data(contentsOf: live.url), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let counted = lines.filter { $0.range(of: #"^\*\*\[\d"#, options: .regularExpression) != nil }.count  // the reader's pattern (A.9)
        #expect(counted == 3)
        #expect(text.contains("status: live") && text.contains("panotti_phase: live-stream"))
    }

    @Test func aStrictReaderOfTheOldSchemaStillParsesTheHeaderAndIgnoresUnknownKeys() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await switched(rig)
        try await rig.finish(live, seconds: 360, raw: try rig.makeRaw(.room, at: when, seconds: 360), cloudLiveSeconds: 240)  // ASSUMPTION: assumed API, see the Support header
        let text = String(decoding: try Data(contentsOf: live.url), as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        #expect(lines.removeFirst() == "---")
        var header: [String] = []
        while let line = lines.first, line != "---" { header.append(lines.removeFirst()) }
        #expect(lines.first == "---", "the header must be closed")
        for line in header where !line.isEmpty {
            let isKeyLine = line.range(of: #"^[a-z_]+:( .*)?$"#, options: .regularExpression) != nil
            let isListItem = line.range(of: #"^  - .+$"#, options: .regularExpression) != nil
            #expect(isKeyLine || isListItem, "a line a simple YAML reader would choke on: \(line)")
        }
        let parsed = try readDoc(live.url)
        for key in oldKeys { #expect(parsed.value(key) != nil, "\(key) went missing") }
    }

    @Test func theStatusReaderOfThePipelineSeesOnlyKnownStatusAndDurationValues() async throws {
        let rig = try await StoreRig.make(batch: answer(), post: [.room: false])
        defer { rig.remove() }
        let live = try await switched(rig)
        let during = try readDoc(live.url)
        #expect(["live", "unverarbeitet"].contains(during.value("status") ?? ""))
        #expect(during.value("dauer") == "laufend")
        try await rig.finish(live, seconds: 360, raw: try rig.makeRaw(.room, at: when, seconds: 360), cloudLiveSeconds: 240)  // ASSUMPTION: assumed API, see the Support header
        let after = try readDoc(live.url)
        #expect(after.value("status") == "unverarbeitet", "only a skill ever writes `verarbeitet`")
        #expect(after.value("dauer")?.range(of: #"^\d\d:\d\d(:\d\d)?$"#, options: .regularExpression) != nil)
    }

    // MARK: the file only grows, also across switches

    @Test func theFileOnlyGrowsAcrossRandomContributionsAndSwitches() async throws {
        let rig = try await StoreRig.make(batch: answer())
        defer { rig.remove() }
        let live = try await rig.begin(.call, at: when, live: .elevenLabsRealtime)  // ASSUMPTION: assumed API, see the Support header
        var random = Lcg(state: 99)
        var seconds = 1
        var engine = LiveEngine.elevenLabsRealtime
        var previous: [String] = []
        for step in 0..<60 {
            seconds += 1 + random.next(8)
            if random.next(4) == 0 {
                engine = engine == .appleLocal ? .elevenLabsRealtime : .appleLocal
                await rig.noteSwitch(live, at: seconds, to: engine, reason: .manual)  // ASSUMPTION: assumed API, see the Support header
            } else {
                await rig.add(live, Line(seconds: seconds, speaker: "Mara", text: "Satz Nummer \(step)."), from: engine)  // ASSUMPTION: assumed API, see the Support header
            }
            let current = try readDoc(live.url).body.filter { isContributionLine($0) || isSwitchLine($0) }
            #expect(Array(current.prefix(previous.count)) == previous, "step \(step): an earlier line changed")
            #expect(current.count == previous.count + 1, "step \(step)")
            previous = current
        }
    }

    @Test func aRecoveredFileKeepsTheSourceAndTheSwitchesItKnew() async throws {
        let rig = try await StoreRig.make(batch: answer(), post: [.room: false])
        defer { rig.remove() }
        let live = try await switched(rig)
        let again = try await StoreRig.reopen(rig, batch: answer(), post: [.room: false])   // ASSUMPTION: assumed API, see the Support header; the app died; a new process finds the journal
        let recovered = try await again.store.recoverOrphans()  // ASSUMPTION: recoverOrphans() returns the rebuilt transcript files
        #expect(recovered.map(\.lastPathComponent) == [live.url.lastPathComponent])
        let doc = try readDoc(live.url)
        #expect(doc.value("panotti_phase") == "recovered-wal")
        #expect(doc.value("live_quelle") == "gemischt")
        #expect(doc.lists["live_wechsel"]?.count == 2)  // ASSUMPTION: assumed API, see the Support header
        #expect(doc.switchLines.count == 2)
    }
}
