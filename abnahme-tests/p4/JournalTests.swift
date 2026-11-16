// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Group 9: journal and files (A.9, Leitsatz 2, R-019, R-022, R-023). Every dictation has the recognizer text,
// the interventions, the final text, the result and the times; the journal only grows; no audio file is ever
// deleted, empty or too small; the text-free protocol never carries a word of the dictation.
import Foundation
import Synchronization
import Testing
@testable import FlowIQCore
@testable import FlowIQInput
@testable import FlowIQRecording

@Suite(.timeLimit(.minutes(5)))
struct JournalTests {
    private let sentences = [
        "das ist flowiq und napiq ein probesatz", "nur ein kurzer satz ohne eingriff", "napiq kommt zuerst dann flowiq",
        "heute ist der zwölfte probelauf", "kein name hier",
    ]

    @Test func everyDictationHasTheFullEntry() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        rig.recognizer.script(sentences + sentences + sentences + sentences + sentences)
        var interventionCounts: [Int] = []
        for index in 0..<25 {
            let heard = sentences[index % sentences.count]
            interventionCounts.append(["flowiq", "napiq"].filter { heard.contains($0) }.count)
            let outcome = await rig.dictate(seconds: 0.4, step: 0.05)
            #expect(outcome.finished)
        }
        let journal = rig.scratch.journal()
        let ids = journal.ids()
        #expect(ids.count == 25)
        #expect(Set(ids).count == 25)
        for (index, id) in ids.enumerated() {
            let lines = journal.lines(of: id)
            #expect(lines.map(\.event) == [JE.begin, JE.audio, JE.recognized, JE.inserted], "dictation \(index)")
            let heard = sentences[index % sentences.count]
            let recognized = try #require(lines.first { $0.event == JE.recognized })
            #expect(recognized.string(JK.recognizerText) == heard)  // the text before any stage
            #expect(recognized.list(JK.interventions)?.count == interventionCounts[index], "interventions of \(id)")
            let stage = heard.replacingOccurrences(of: "flowiq", with: "FlowIQ").replacingOccurrences(of: "napiq", with: "NapIQ")
            #expect(recognized.string(JK.finalText) == stage)
            #expect((recognized.number(JK.recognizeMs) ?? -1) >= 0)
            #expect((recognized.number(JK.stageMs) ?? -1) >= 0)
            let inserted = try #require(lines.first { $0.event == JE.inserted })
            #expect(inserted.string(JK.result) == "landed")  // ASSUMPTION: raw value of InsertResult.landed
            let audio = try #require(lines.first { $0.event == JE.audio })
            #expect((audio.number(JK.bytes) ?? 0) > 0 && (audio.number(JK.seconds) ?? 0) > 0)
            #expect(audio.string(JK.verdict) == SizeVerdict.ok.rawValue)
            let times = lines.compactMap(\.time)
            #expect(times.count == lines.count, "a line without a time in \(id)")
            #expect(times == times.sorted())
        }
    }

    @Test func journalOnlyGrowsAndNeverLosesALine() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        var previous = Data()
        for _ in 0..<12 {
            await rig.dictate(seconds: 0.4, step: 0.05)
            let now = rig.scratch.journalBytes()
            #expect(now.count > previous.count)
            #expect(now.prefix(previous.count) == previous, "earlier journal bytes changed")
            #expect(now.last == UInt8(ascii: "\n"))  // never a cut-off last line
            previous = now
        }
    }

    @Test func nothingIsDeletedAndNoFileIsEmptyOrTooSmall() async throws {
        // R-022/R-023 at the seam: 30 dictations, 30 audio files, none deleted, none under 4,000 bytes per second.
        let rig = try DictationRig()
        defer { rig.remove() }
        var seen = Set<URL>()
        var durations: [String: Double] = [:]
        for _ in 0..<30 {
            let outcome = await rig.dictate(seconds: 0.5, step: 0.05)
            durations[String(durations.count)] = seconds(of: outcome.sent)
            let now = Set(rig.scratch.audioFiles())
            #expect(seen.isSubset(of: now), "an audio file disappeared")
            seen = now
        }
        #expect(seen.count == 30)
        let ids = rig.scratch.journal().ids()
        for (index, id) in ids.enumerated() {
            let file = try #require(rig.scratch.audioFile(for: id))
            let size = fileSize(file)
            #expect(size > 0)
            #expect(Double(size) >= 4_000 * (durations[String(index)] ?? 0), "\(file.lastPathComponent): \(size) bytes")
        }
        #expect(ids.count == 30)
        #expect(await rig.scratch.events("audio_lost").isEmpty)
        #expect(await rig.scratch.events("audio_verdaechtig").isEmpty)
    }

    @Test func protocolIsTextFreeWhileTheJournalHoldsTheText() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        rig.recognizer.script(["der prueflingswort quarzstaub ist nur ein künstlicher satz"])
        rig.target.configure { $0.field = "FELD-GEHEIMNIS-77 " }
        await rig.dictate()
        let logged = await rig.scratch.logText()
        for word in ["quarzstaub", "prueflingswort", "FELD-GEHEIMNIS-77", "künstlicher"] {
            #expect(!logged.contains(word), "the protocol contains dictation or field text: \(word)")
        }
        #expect(!logged.contains("FlowIQ probesatz"))
        #expect(String(decoding: rig.scratch.journalBytes(), as: UTF8.self).contains("quarzstaub"))  // the journal is private and has it
        #expect(!(await rig.scratch.events("fn.timeline")).isEmpty)
    }

    @Test func journalLineExistsBeforeEveryInsertionAcrossManyDictations() async throws {
        let rig = try DictationRig()
        defer { rig.remove() }
        let scratch = rig.scratch
        let checks = Mutex<[Bool]>([])
        rig.target.onPaste {
            let lines = scratch.journal()
            let last = lines.last { $0.event == JE.recognized }
            let inserted = lines.filter { $0.event == JE.inserted }.count
            checks.withLock { $0.append(last != nil && inserted == $0.count) }
        }
        for _ in 0..<8 { await rig.dictate(seconds: 0.4, step: 0.05) }
        let flags = checks.withLock { $0 }
        #expect(flags.count == 8)
        #expect(flags.allSatisfy { $0 }, "a text was inserted before its journal line was written")
    }
}
