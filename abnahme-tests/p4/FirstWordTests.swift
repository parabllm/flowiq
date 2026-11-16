// Group 3: first word complete (R-016, Panotti finding: the beginning was missing in 3.6 % of dictations).
// Every sample from the key press on reaches the recognizer, in order, without a gap, however long the
// microphone or the recognizer needs to get ready: the audio waits in the dictation stream (B.1 step 5).
import Foundation
import Testing
@testable import FlowIQAudio
@testable import FlowIQCore
@testable import FlowIQInput

struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    let micStart: Int  // virtual ms the microphone needs to start
    let attach: Int  // virtual ms the recognizer needs before it consumes
    var testDescription: String { name }
}

@Suite(.timeLimit(.minutes(3)))
struct FirstWordTests {
    static let scenarios = [
        Scenario(name: "everything instant", micStart: 0, attach: 0),
        Scenario(name: "slow microphone", micStart: 130, attach: 0),
        Scenario(name: "slow recognizer", micStart: 0, attach: 200),
        Scenario(name: "both slow", micStart: 130, attach: 200),
        Scenario(name: "recognizer ready after a second", micStart: 60, attach: 1000),
    ]

    @Test(arguments: scenarios)
    func everySampleFromTheKeyPressReachesTheRecognizer(_ s: Scenario) async throws {
        var mic = P4Mic.Options()
        mic.startDelay = .milliseconds(s.micStart)
        var recognizer = StubRecognizer.Options()
        recognizer.prepareDelay = .milliseconds(s.attach)
        let rig = try DictationRig(mic: mic, recognizer: recognizer)
        defer { rig.remove() }

        // The microphone is not open before the key (halbwarm is off by default).
        #expect(rig.mics.all.isEmpty)
        let outcome = await rig.dictate(seconds: 1.2, step: 0.02)
        #expect(outcome.opened && outcome.finished)

        let got = try #require(rig.recognizer.runs.first)
        // The chunks the source delivered while it was starting must be in there as well: compare whole values.
        #expect(got == outcome.sent, "recognizer got \(got.count) chunks, the source delivered \(outcome.sent.count)")
        #expect(!outcome.sent.isEmpty)
        #expect(got.first?.hostTime == outcome.sent.first?.hostTime)  // the very first sample is there
        // Nothing older than the key press (no ring without halbwarm), nothing out of order.
        #expect((got.first?.hostTime ?? 0) >= outcome.pressedAt.nanos)
        for (a, b) in zip(got, got.dropFirst()) { #expect(a.hostTime < b.hostTime) }
        #expect(abs(seconds(of: got) - seconds(of: outcome.sent)) < 0.0001)
    }

    @Test func fileHoldsEverythingTheRecognizerGot() async throws {
        var mic = P4Mic.Options()
        mic.startDelay = .milliseconds(130)
        let rig = try DictationRig(mic: mic)
        defer { rig.remove() }
        let outcome = await rig.dictate(seconds: 2.0, step: 0.02)
        #expect(outcome.finished)
        let id = try #require(rig.scratch.journal().ids().first)
        let file = try #require(rig.scratch.audioFile(for: id))
        let duration = try audioDuration(file)
        #expect(abs(duration - seconds(of: outcome.sent)) <= 0.1, "file \(duration) s, audio \(seconds(of: outcome.sent)) s")
        #expect(fileSize(file) >= Int(4_000 * seconds(of: outcome.sent)))  // above the size-against-duration floor
    }

    @Test func manyRandomStartupsNeverLoseTheBeginning() async throws {
        // 40 dictations with random microphone and recognizer startup, random chunk size: 0 missing beginnings.
        var lcg = Lcg(seed: 36)
        let rig = try DictationRig()
        defer { rig.remove() }
        var lost = 0
        for run in 0..<40 {
            var mic = P4Mic.Options()
            mic.startDelay = .milliseconds(lcg.next(0...150))
            rig.mics.set(mic)
            var recognizer = StubRecognizer.Options()
            recognizer.prepareDelay = .milliseconds(lcg.next(0...300))
            rig.recognizer.set(recognizer)
            let step = [0.01, 0.02, 0.05][lcg.next(0...2)]
            let outcome = await rig.dictate(seconds: 0.5, step: step)
            guard outcome.finished, rig.recognizer.runs.count == run + 1 else {
                Issue.record("run \(run) did not finish")
                continue
            }
            if rig.recognizer.runs[run] != outcome.sent { lost += 1 }
        }
        #expect(lost == 0, "\(lost) of 40 dictations lost audio between the key press and the recognizer")
        #expect(rig.target.pasteCount == 40)
    }

    @Test func nothingIsDroppedWhenTheRecognizerIsVerySlowToAttach() async throws {
        var recognizer = StubRecognizer.Options()
        recognizer.prepareDelay = .seconds(3)  // longer than the whole dictation
        let rig = try DictationRig(recognizer: recognizer)
        defer { rig.remove() }
        let outcome = await rig.dictate(seconds: 2.0, step: 0.05)
        #expect(outcome.finished)
        #expect(rig.recognizer.runs.first == outcome.sent)
    }

    @Test func overflowIsNeverSilent() async throws {
        // The dictation stream is unbounded with a 30 s safety limit (A.4): below it nothing is counted as lost.
        let rig = try DictationRig()
        defer { rig.remove() }
        let outcome = await rig.dictate(seconds: 3, step: 0.05)
        #expect(outcome.finished)
        #expect(await rig.scratch.events("overflow").isEmpty)
        #expect(await rig.scratch.events("late_buffers").isEmpty)
        #expect(await rig.scratch.events("audio_lost").isEmpty)
    }

    @Test func shortDictationsFromHalfASecondAreInserted() async throws {
        // R-016: short dictations from 0.45 s: 20 of 20 inserted. Here with a 0.5 s hold, 10 times in a row.
        let rig = try DictationRig()
        defer { rig.remove() }
        for run in 0..<10 {
            let outcome = await rig.dictate(seconds: 0.5, step: 0.05)
            #expect(outcome.finished)
            #expect(rig.target.pasteCount == run + 1, "dictation \(run) was not inserted")
        }
        #expect(rig.target.field.contains("probesatz nummer 10"))
        let inserted = rig.scratch.journal().filter { $0.event == JE.inserted }
        #expect(inserted.count == 10)
        #expect(inserted.allSatisfy { $0.string(JK.result) == "landed" })  // ASSUMPTION: InsertResult.landed has the raw value "landed" in the journal
    }

    @Test func microphoneIsReleasedAfterEachDictation() async throws {
        // Default N = 0: the device is not held open (R-016 cold path, orange indicator goes out).
        let rig = try DictationRig()
        defer { rig.remove() }
        for _ in 0..<3 { await rig.dictate(seconds: 0.4) }
        #expect(rig.mics.all.count == 3)
        for source in rig.mics.all {
            #expect(source.counts.starts == 1)
            #expect(source.counts.stopsBegun == 1)
        }
    }
}
