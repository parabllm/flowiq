import FlowIQCore
import Foundation
import Testing
@testable import FlowIQStore
@testable import FlowIQText

/// Paket V1 guard: an unreadable lexikon.json or kontobuch.json makes every change throw and stays byte for byte.
struct UnreadableStoreTests {
    typealias Rig = LexiconStoreTests.Rig

    static func garbage(_ rig: Rig, _ name: String) throws -> (URL, Data) {
        try FileManager.default.createDirectory(at: rig.lexicon.folder, withIntermediateDirectories: true)
        let file = rig.lexicon.folder.appending(path: name), data = Data("{kaputt".utf8)
        try data.write(to: file)
        return (file, data)
    }

    @Test func everyLexiconChangeThrowsAndTheFileStays() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let (file, data) = try Self.garbage(rig, "lexikon.json")
        await #expect(throws: LexiconStore.Unreadable.self) {
            try await rig.lexicon.addRegressionCase(input: "a", expected: "b")
        }
        await #expect(throws: LexiconStore.Unreadable.self) {
            try await rig.lexicon.review(entry: "e", variant: nil, reason: "r")
        }
        await #expect(throws: LexiconStore.Unreadable.self) { try await rig.lexicon.runProbation(over: []) }
        await #expect(throws: LexiconStore.Unreadable.self) { try await rig.lexicon.decide(0, .retire) }
        await #expect(throws: LexiconStore.Unreadable.self) { try await rig.lexicon.apply(.protect(form: "x")) }
        #expect(await rig.lexicon.importable() == false)
        #expect(await rig.lexicon.stage().lexicon.entries.isEmpty)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func everyLedgerChangeThrowsAndTheFileStays() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let (file, data) = try Self.garbage(rig, "kontobuch.json")
        #expect(await rig.ledger.pairs().isEmpty)
        #expect(await rig.ledger.confusionCount() == 0)
        await #expect(throws: LexiconStore.Unreadable.self) { try await rig.ledger.countConfusion() }
        await #expect(throws: LexiconStore.Unreadable.self) {
            try await rig.ledger.record(heard: ["zorbal"], entry: "e", source: .click, ref: "a", day: 1,
                                        realWord: false)
        }
        #expect(try Data(contentsOf: file) == data)
    }
}
