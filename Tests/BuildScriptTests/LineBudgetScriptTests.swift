import Foundation
import Testing

/// Runs scripts/zeilenbudget.sh against a throwaway source tree and the repo's budget.tsv,
/// with deliberate violations. No build, no network, no permissions.
struct LineBudgetScriptTests {
    static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources: URL

    init() throws {
        sources = FileManager.default.temporaryDirectory.appending(path: "flowiq-budget-\(UUID().uuidString)/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    private func cleanup() {
        do { try FileManager.default.removeItem(at: sources.deletingLastPathComponent()) } catch {
            Issue.record("cleanup failed: \(error)")
        }
    }

    /// Grenze of one module from the real budget.tsv.
    private func limit(of module: String) throws -> Int {
        let table = try String(contentsOf: Self.repo.appending(path: "budget.tsv"), encoding: .utf8)
        let rows = table.split(separator: "\n").map { $0.split(separator: "\t") }
        let row = try #require(rows.first { $0.first.map(String.init) == module })
        return try #require(Int(row[2]))
    }

    private func write(_ lines: Int, to module: String, file: String = "A.swift") throws {
        let folder = sources.appending(path: module)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = String(repeating: "let x = 0\n", count: lines)
        try text.write(to: folder.appending(path: file), atomically: true, encoding: .utf8)
    }

    private func run(table: URL? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [Self.repo.appending(path: "scripts/zeilenbudget.sh").path, sources.path]
            + (table.map { [$0.path] } ?? [])
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func exactlyAtTheLimitPasses() throws {
        defer { cleanup() }
        try write(try limit(of: "FlowIQCore"), to: "FlowIQCore")
        let result = try run()
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func oneLineOverTheLimitFails() throws {
        defer { cleanup() }
        try write(try limit(of: "FlowIQCore") + 1, to: "FlowIQCore")
        let result = try run()
        #expect(result.status == 1)
        #expect(result.output.contains("FlowIQCore"))
        #expect(result.output.contains("ÜBER DER GRENZE"))
    }

    @Test func splitAcrossFilesStillCounts() throws {
        defer { cleanup() }
        let limit = try limit(of: "FlowIQLog")
        try write(limit / 2 + 1, to: "FlowIQLog", file: "A.swift")
        try write(limit / 2 + 1, to: "FlowIQLog", file: "B.swift")
        #expect(try run().status == 1)
    }

    @Test func fileOver800LinesFails() throws {
        defer { cleanup() }
        try write(801, to: "FlowIQAudio")
        let result = try run()
        #expect(result.status == 1)
        #expect(result.output.contains("Datei über 800 Zeilen"))
    }

    @Test func folderWithoutBudgetFails() throws {
        defer { cleanup() }
        try write(1, to: "FlowIQExtra")
        let result = try run()
        #expect(result.status == 1)
        #expect(result.output.contains("Modul ohne Budget: FlowIQExtra"))
    }

    @Test func nonNumericValueFails() throws {
        defer { cleanup() }
        let table = sources.deletingLastPathComponent().appending(path: "budget.tsv")
        let rows = "modul\tbudget\tgrenze\nFlowIQCore\tviel\t400\nSumme\t10\t20\n"
        try rows.write(to: table, atomically: true, encoding: .utf8)
        let result = try run(table: table)
        #expect(result.status == 1)
        #expect(result.output.contains("Ungültige Zeile"))
    }

    @Test func missingSumRowFails() throws {
        defer { cleanup() }
        let table = sources.deletingLastPathComponent().appending(path: "budget.tsv")
        try "modul\tbudget\tgrenze\nFlowIQCore\t10\t20\n".write(to: table, atomically: true, encoding: .utf8)
        let result = try run(table: table)
        #expect(result.status == 1)
        #expect(result.output.contains("Zeile GESAMT fehlt"))
    }

    @Test func totalOverTheGesamtLimitFailsEvenIfEveryModuleFits() throws {
        defer { cleanup() }
        let table = sources.deletingLastPathComponent().appending(path: "budget.tsv")
        let rows = "modul\tbudget\tgrenze\nFlowIQCore\t100\t120\nFlowIQLog\t100\t120\nGESAMT\t150\t180\n"
        try rows.write(to: table, atomically: true, encoding: .utf8)
        try write(95, to: "FlowIQCore")
        try write(95, to: "FlowIQLog")
        let result = try run(table: table)
        #expect(result.status == 1)
        #expect(result.output.contains("GESAMT             190 Zeilen"))
        #expect(result.output.contains("Warnung: ab 85 % des Budgets"))
    }

    @Test func realSourcesStayWithinBudget() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [Self.repo.appending(path: "scripts/zeilenbudget.sh").path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
