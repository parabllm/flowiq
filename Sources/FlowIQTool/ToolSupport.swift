@_exported import FlowIQSpeech
@_exported import FlowIQStore
@_exported import FlowIQText
import AppKit

/// Command line: `flowiq-tool <befehl> --schluessel wert ... [--schalter]`.
struct Args {
    let command: String, values: [String: String], flags: Set<String>
    init(_ argv: [String]) {
        command = argv.dropFirst().first ?? ""
        var values: [String: String] = [:], flags = Set<String>(), rest = Array(argv.dropFirst(2))
        while let key = rest.first, key.hasPrefix("--") {
            rest.removeFirst()
            if let value = rest.first, !value.hasPrefix("--") {
                values[String(key.dropFirst(2))] = value
                rest.removeFirst()
            } else {
                flags.insert(String(key.dropFirst(2)))
            }
        }
        self.values = values
        self.flags = flags
    }
    func url(_ key: String) throws(ToolError) -> URL {
        guard let value = values[key] else { throw ToolError("--\(key) fehlt") }
        return URL(filePath: (value as NSString).expandingTildeInPath)
    }
}

struct ToolError: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

/// Writes only below `<wurzel>/FlowIQ-Dev/` through SafeFS; corpus runs pass a folder under the private `local/`.
struct Output {
    let folder: URL, fs: SafeFS
    init(_ args: Args, _ sub: String) throws {
        try self.init(root: args.values["wurzel"] == nil ? nil : args.url("wurzel"), sub)
    }
    init(root: URL?, _ sub: String) throws {
        let paths = root.map { Paths(profile: .development, applicationSupport: $0) } ?? Paths(profile: .development)
        fs = SafeFS(paths: paths)
        folder = paths.support.appending(path: sub, directoryHint: .isDirectory)
        try fs.makeFolder(folder)
    }
    func json(_ name: String, _ value: some Encodable) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try data(name, encoder.encode(value))
    }
    func data(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appending(path: name)
        try fs.replace(url, with: data)
        return url
    }
}

/// The tool's own oracle (check.sh allows NSSpellChecker here): answers every query, cached, never all upper case.
struct SpellOracle {
    private let checker = NSSpellChecker.shared
    private(set) var cache: [OracleQuery: Bool] = [:]
    mutating func answer(_ queries: Set<OracleQuery>) -> OracleAnswers {
        var known: [OracleQuery: Bool] = [:]
        for q in queries.sorted(by: { ($0.form, $0.kind.rawValue) < ($1.form, $1.kind.rawValue) }) {
            if cache[q] == nil { cache[q] = Self.ask(checker, q) }
            known[q] = cache[q]
        }
        return OracleAnswers(known: known)
    }
    static func ask(_ checker: NSSpellChecker, _ q: OracleQuery) -> Bool {
        guard q.form != q.form.uppercased() || q.form == q.form.lowercased() else { return false }
        let languages = q.kind == .word ? ["de", "en"] : q.kind == .englishStem ? ["en"] : ["de"]
        return languages.contains { language in
            checker.checkSpelling(of: q.form, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}
