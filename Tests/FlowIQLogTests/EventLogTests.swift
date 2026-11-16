import Foundation
import Testing
import FlowIQCore
@testable import FlowIQLog

struct EventLogTests {
    let root: URL
    let folder: URL
    let fs: SafeFS

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flowiq-log-\(UUID().uuidString)")
        let paths = Paths(profile: .development, applicationSupport: root)
        fs = SafeFS(paths: paths)
        try paths.prepare(using: fs)
        folder = paths.log
    }

    private func cleanup() {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("cleanup failed: \(error)") }
    }

    private func lines(_ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
        return try text.split(separator: "\n").map {
            let object = try JSONSerialization.jsonObject(with: Data($0.utf8))
            return try #require(object as? [String: Any])
        }
    }

    @Test func writesOneJSONObjectPerLineWithTimeKindLevel() async throws {
        defer { cleanup() }
        let log = EventLog(directory: folder, fs: fs)
        log.record(LogEvent("app.start", ["profile": "development", "pid": 42, "ok": true, "ms": 1.5]))
        await log.flush()
        let rows = try lines("ereignisse.ndjson")
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["kind"] as? String == "app.start")
        #expect(row["level"] as? String == "info")
        #expect(row["profile"] as? String == "development")
        #expect(row["pid"] as? Int == 42)
        #expect(row["ok"] as? Bool == true)
        #expect(row["ms"] as? Double == 1.5)
        let stamp = try #require(row["ts"] as? String)
        #expect(try Date(stamp, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) <= .now)
    }

    @Test func errorsAlsoLandInTheErrorFile() async throws {
        defer { cleanup() }
        let log = EventLog(directory: folder, fs: fs)
        log.record(LogEvent("a"))
        log.record(LogEvent("b", level: .error, ["code": 5]))
        await log.flush()
        #expect(try lines("ereignisse.ndjson").map { $0["kind"] as? String } == ["a", "b"])
        #expect(try lines("fehler.ndjson").map { $0["kind"] as? String } == ["b"])
    }

    @Test func rotatesAndKeepsAtMostTheConfiguredFiles() async throws {
        defer { cleanup() }
        var limits = EventLog.Limits()
        limits.eventBytes = 400
        limits.eventFiles = 3
        let log = EventLog(directory: folder, fs: fs, limits: limits)
        for index in 0..<100 { log.record(LogEvent("tick", ["n": .int(Int64(index))])) }
        await log.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["ereignisse-1.ndjson", "ereignisse-2.ndjson", "ereignisse.ndjson"])
        for name in names {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)
            let size = try #require(attributes[.size] as? Int)
            #expect(size <= 400)
        }
        // Newest event is last in the current file, oldest surviving one first in the last backup.
        let current = try lines("ereignisse.ndjson").compactMap { $0["n"] as? Int }
        let oldest = try lines("ereignisse-2.ndjson").compactMap { $0["n"] as? Int }
        let firstKept = try #require(oldest.first)
        let lastOld = try #require(oldest.last)
        let firstCurrent = try #require(current.first)
        #expect(current.last == 99)
        #expect(firstKept > 0)
        #expect(lastOld < firstCurrent)
    }

    @Test func writesOutsideTheAllowListAreRefused() async throws {
        defer { cleanup() }
        let outside = root.appending(path: "elsewhere")
        let log = EventLog(directory: outside, fs: fs)
        log.record(LogEvent("lost"))
        await log.flush()
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func defaultLimitsStayWithin50MB() {
        let limits = EventLog.Limits()
        #expect(limits.eventBytes * limits.eventFiles + limits.errorBytes * limits.errorFiles <= 50_000_000)
    }

    @Test func appendsToAnExistingFileAfterRestart() async throws {
        defer { cleanup() }
        let first = EventLog(directory: folder, fs: fs)
        first.record(LogEvent("one"))
        await first.flush()
        let second = EventLog(directory: folder, fs: fs)
        second.record(LogEvent("two"))
        await second.flush()
        #expect(try lines("ereignisse.ndjson").map { $0["kind"] as? String } == ["one", "two"])
    }
}

struct FnTimelineTests {
    @Test func millisecondsBetweenMarks() throws {
        var timeline = FnTimeline(dictationID: "d1")
        let start = MachTime.now()
        timeline.mark(.keyDown, at: start)
        timeline.mark(.pillShown, at: start + UInt64((24_000_000 / MachTime.nanosPerTick).rounded()))
        let ms = try #require(timeline.milliseconds(from: .keyDown, to: .pillShown))
        #expect(abs(ms - 24) < 0.01)
        #expect(MachTime.milliseconds(from: start + 10, to: start) < 0)
        #expect(timeline.milliseconds(from: .keyDown, to: .pasted) == nil)
    }

    @Test func oneEventPerDictationRelativeToKeyDown() {
        var timeline = FnTimeline(dictationID: "d2")
        timeline.mark(.callback, at: 1_000)
        timeline.mark(.keyDown, at: 1_000)
        let event = timeline.event()
        #expect(event.kind == "fn.timeline")
        #expect(event.fields["id"] == "d2")
        #expect(event.fields["t0_ms"] == .double(0))
        #expect(event.fields["t1_ms"] == .double(0))
        #expect(FnMark.allCases.count == 14)
    }
}

struct ResourceProbeTests {
    @MainActor
    @Test func samplesOffTheMainThread() async throws {
        // Called from the main actor; the probe asserts it is not on the main thread.
        let sample = try await ResourceProbe.sample()
        #expect(sample.footprintBytes > 1_000_000)
        #expect(sample.residentBytes > 1_000_000)
        #expect(sample.cpuNanos > 0)
        #expect(sample.threads > 0)  // 16.11.: threads and pid joined the line (leak watch)
        #expect(sample.fields.keys.sorted() == ["cpu_ms", "footprint_mb", "pid", "resident_mb", "threads"])
    }

    @Test func cpuTimeGrowsWithWork() async throws {
        let before = try await ResourceProbe.sample()
        var x = 0.0
        for i in 0..<2_000_000 { x += Double(i).squareRoot() }
        #expect(x > 0)
        let after = try await ResourceProbe.sample()
        #expect(after.cpuNanos > before.cpuNanos)
    }
}
