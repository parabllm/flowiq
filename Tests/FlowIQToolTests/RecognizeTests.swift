import Foundation
import Testing
@testable import flowiq_tool

/// `erkennen` without audio: selection from the corpus index and resuming after an abort. Artificial rows only.
struct RecognizeTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-erkennen-\(UUID().uuidString)")

    private func write(_ name: String, _ text: String) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func cleanup() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
    }

    private func row(_ id: String, _ path: String, _ bytes: Int) -> String {
        ([id] + ["", ""] + [path] + Array(repeating: "", count: 9) + [String(bytes)]).joined(separator: "\t")
    }

    @Test func selectionTakesOnlyUsableAudioInsideTheSource() throws {
        defer { cleanup() }
        let source = root.appending(path: "quelle").path
        let index = try write("index.tsv", (["kopf"] + [
            row("a", source + "/a.aac", 5000), row("b", source + "/b.aac", 2048), row("c", "", 9000),
            row("d", source + "/d.aac", 3000),
        ]).joined(separator: "\n"))
        let ids = try write("ids.txt", "a\nb\nc\n")
        let all = try Recognize.selection(Args(["t", "erkennen", "--index", index, "--quelle", source]))
        #expect(all.map(\.id) == ["a", "d"])
        let some = try Recognize.selection(Args(["t", "erkennen", "--index", index, "--quelle", source, "--ids", ids]))
        #expect(some.map(\.id) == ["a"])
        let outside = try write("aussen.tsv", "kopf\n" + row("e", "/anderswo/e.aac", 5000))
        #expect(throws: ToolError.self) {
            try Recognize.selection(Args(["t", "erkennen", "--index", outside, "--quelle", source]))
        }
    }

    @Test func resumeSkipsFinishedAndRetriesFailedAndTornLines() throws {
        defer { cleanup() }
        let done = #"{"id":"a","recognizer":"speech","#
            + #""result":{"text":"x","segments":[],"runs":[],"seconds":1,"millis":2}}"#
        let failed = #"{"id":"b","recognizer":"speech","error":"Failure"}"#
        let file = try write("speech.jsonl", "\n" + done + "\n" + failed + "\n" + #"{"id":"c","recog"#)
        #expect(try Recognize.finished(URL(filePath: file)) == ["a"])
        #expect(try Recognize.finished(root.appending(path: "fehlt.jsonl")).isEmpty)
    }
}
