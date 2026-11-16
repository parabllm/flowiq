import Foundation
import Testing
@testable import flowiq_tool

/// `replay` on an artificial mini corpus (appendix G.1): three dictations, a lexicon file with one family, a
/// reference with one line of the withheld part that must be skipped.
struct ReplayTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-replay-\(UUID().uuidString)")

    private func write(_ name: String, _ text: String) throws -> String {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func replayWritesWaysAndSkipsTheWithheldPart() throws {
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
        }
        let history = try write("history.json", """
            [{"id": "a", "rawText": "wir testen Nab IQ heute", "processedText": "wir testen NabIQ heute"},
             {"id": "b", "rawText": "das Zorbel ist neu", "processedText": "das Zorbel ist neu"},
             {"id": "c", "rawText": "Nab IQ", "processedText": "Nab IQ"}]
            """)
        let entry = { (name: String, status: String) in
            """
            {"id": "e-\(name)", "canonical": "\(name)", "kind": "name", "family": "iq", "spokenForms": [],
             "hearingVariants": [], "status": "\(status)", "origin": "seed", "compound": "hyphen",
             "counters": {"benefit": 0, "harm": 0}, "createdAt": 0}
            """
        }
        let lexicon = try write("lexikon.json", """
            {"version": 1, "entries": [\(entry("NapIQ", "confirmed")), \(entry("ZorbelIQ", "proposed"))],
             "families": [{"id": "iq", "anchorWritten": "IQ", "anchorSpoken": [], "join": "concatenated"}],
             "familiar": [], "changes": [], "review": [], "cases": [], "reports": []}
            """)
        let reference = try write("referenz.jsonl", """
            {"id": "a", "teil": "einstellen", "referenz": "wir testen NapIQ heute"}
            {"id": "b", "teil": "einstellen", "referenz": "das Zorbel ist neu"}
            {"id": "c", "teil": "zurueckgehalten", "referenz": "NapIQ"}
            """)
        try Replay.run(Args(["flowiq-tool", "replay", "--history", history, "--lexikon", lexicon,
                             "--referenz", reference, "--wurzel", root.path]))
        let folder = root.appending(path: "FlowIQ-Dev/replay")
        let rows = try JSONDecoder().decode([[String: String]].self,
                                            from: Data(contentsOf: folder.appending(path: "wege.json")))
        #expect(rows.map { $0["id"] } == ["a", "b"])
        #expect(rows.first?["flowiq"] == "wir testen NapIQ heute")
        #expect(rows.first?["processedText"] == "wir testen NabIQ heute")
        #expect(rows.last?["flowiq"] == "das Zorbel ist neu")
        #expect(rows.first?["referenz"] == "wir testen NapIQ heute")
        let trace = try String(contentsOf: folder.appending(path: "spur.jsonl"), encoding: .utf8)
        #expect(trace.split(separator: "\n").count == 2 && trace.contains("\"tRule\":\"R2\""))
    }

    @Test func withheldPartNeedsTheAcceptanceFlag() throws {
        let args = Args(["flowiq-tool", "replay", "--referenz", "x.jsonl", "--teil", "zurueckgehalten"])
        #expect(throws: ToolError.self) { try Replay.loadReference(args) }
    }
}
