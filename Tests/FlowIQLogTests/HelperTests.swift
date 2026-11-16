import Foundation
import Testing
import FlowIQCore
@testable import FlowIQLog

/// Paket V helpers in FlowIQLog: `attempt` and `JSON`.
struct HelperTests {
    struct Boom: Error {}

    @Test func attemptTurnsAnErrorIntoAnErrorEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-attempt-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = EventLog(directory: root)
        #expect(log.attempt("never") {})
        #expect(!log.attempt("sync_failed", ["step": "a"]) { throw Boom() })
        #expect(await !log.attempt("async_failed") { try await Task.sleep(for: .milliseconds(1)); throw Boom() })
        await log.flush()
        let text = try String(contentsOf: root.appending(path: "fehler.ndjson"), encoding: .utf8)
        let kinds = try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(kinds.map { $0["kind"] as? String } == ["sync_failed", "async_failed"])
        #expect(kinds.first?["step"] as? String == "a" && kinds.allSatisfy { $0["level"] as? String == "error" })
    }

    @Test func jsonReadsMissingAsEmptyAndGarbageAsNil() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-json-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
        let fs = SafeFS(confinedTo: root), file = root.appending(path: "a/b.json")
        #expect(JSON.read(file, or: [1]) == [1])
        try fs.replace(file, json: ["b": 2, "a": 1])
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"a":1,"b":2}"#)
        #expect(JSON.read(file, or: [String: Int]()) == ["a": 1, "b": 2])
        try Data("{kaputt".utf8).write(to: file)
        #expect(JSON.read(file, or: [String: Int]()) == nil)
        let lines = [try JSON.line([1]), Data("[2".utf8), try JSON.line([3])]
        #expect(JSON.decode(lines, as: [Int].self) == [[1], [3]])
    }

    /// 16.11.: a periodic memory and CPU line, flagged idle or recording; errors carry domain and code.
    @Test func theMonitorWritesPeriodicLinesAndFailuresCarryTheirReason() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup: \(error)") }
        }
        let log = EventLog(directory: root), monitor = ResourceMonitor()
        monitor.start(log: log) { true }
        for _ in 0..<100 {
            await log.flush()
            let file = root.appending(path: "ereignisse.ndjson")
            let text = FileManager.default.fileExists(atPath: file.path)
                ? try String(contentsOf: file, encoding: .utf8) : ""
            if text.contains("periodic") { break }
            _ = await ContinuousClock().pause(.milliseconds(20))
        }
        monitor.stop()
        log.record(.failure("probe_failed", CocoaError(.fileReadNoSuchFile)))
        await log.flush()
        let text = try String(contentsOf: root.appending(path: "ereignisse.ndjson"), encoding: .utf8)
        #expect(text.contains("\"reason\":\"periodic\"") && text.contains("\"recording\":true"))
        #expect(text.contains("\"error_domain\":\"NSCocoaErrorDomain\"") && text.contains("\"error_code\":260"))
    }

    /// Review V7: a field named like the event kind never hides it; it moves to `field_kind`.
    @Test func aFieldNamedKindNeverHidesTheEventKind() throws {
        let line = try LineEncoder().line(LogEvent("session_started", ["kind": "call"]))
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["kind"] as? String == "session_started" && object["field_kind"] as? String == "call")
    }
}
