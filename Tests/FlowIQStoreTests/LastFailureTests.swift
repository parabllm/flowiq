import FlowIQCore
import Foundation
import Testing
@testable import FlowIQStore

/// The menu's "Erneut erkennen" (16.11.): which dictation failed last and whether its audio is kept.
struct LastFailureTests {
    typealias Rig = AftercareReviewTests.Rig

    @Test func theNewestFailureIsFoundUntilADictationIsRecognizedAgain() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let paths = Paths(profile: .development, applicationSupport: rig.root)
        try rig.fs.makeFolder(paths.diktate)
        let j = DictationJournal(paths: paths, fs: rig.fs, log: rig.log)
        #expect(await j.lastFailure() == nil)
        try await j.append(.begin(id: "a"))
        try await j.append(.recognized(id: "a", recognizerText: "ein satz", finalText: "Ein Satz",
                                       interventions: [String]()))
        #expect(await j.lastFailure() == nil)
        // the recognizer failed, the audio is kept
        try await j.append(.begin(id: "b"))
        try Data("ton".utf8).write(to: try await j.audioURL(for: "b"))
        try await j.append(JournalEntry("recognized", id: "b", ["failure": .string("timeout")]))
        let failed = await j.lastFailure()
        #expect(failed?.id == "b" && failed?.audio?.lastPathComponent == "b.aac")
        try await j.append(.begin(id: "c"))  // a next dictation that only began (or was cancelled) changes nothing
        #expect(await j.lastFailure()?.id == "b")
        // the microphone was refused: a failure without audio
        try await j.append(.begin(id: "d", ["mic": .string("refused")]))
        let refused = await j.lastFailure()
        #expect(refused?.id == "d" && refused?.audio == nil)
        // recognized again (the menu's step writes this line for the failed id): the failure is over
        try await j.append(.recognized(id: "d", recognizerText: "x", finalText: "X", interventions: [String]()))
        #expect(await j.lastFailure() == nil)
    }
}
