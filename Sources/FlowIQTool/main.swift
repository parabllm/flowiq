// flowiq-tool (A.13): offline corpus commands; console numbers and paths only, text only through SafeFS.

let args = Args(CommandLine.arguments)
do {
    switch args.command {
    case "replay": try Replay.run(args)
    case "schutzliste": try ProtectionList.run(args)
    case "erkennen": try await Recognize.run(args)
    case "nachlauf-vergleich": try await Compare.run(args)
    case "desktop-probe": try await DesktopProbe.run(args)
    default: throw ToolError("Befehle: replay, schutzliste, erkennen, nachlauf-vergleich, desktop-probe (A.13)")
    }
} catch let error as ToolError {
    FileHandle.standardError.write(Data("flowiq-tool: \(error.text)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("flowiq-tool: \(error)\n".utf8))
    exit(1)
}

/// `schutzliste --history <json> [--wurzel <ordner>]`: freezes the system dictionary's answers (P1).
enum ProtectionList {
    static func run(_ args: Args) throws {
        let stage = TextStage(lexicon: LexiconSnapshot(entries: [], families: []),
                              protection: FrozenWordSet(german: [], english: []), config: TextStageConfig())
        var queries = Set<OracleQuery>()
        for row in try loadHistory(args.url("history")) {
            if let text = row[args.values["rohtext"] ?? "rawText"] as? String {
                queries.formUnion(stage.oracleQueries(for: Recognition(text: text)))
            }
        }
        var oracle = SpellOracle()
        let answers = oracle.answer(queries), url = try Output(args, "schutzliste").json("schutzliste.json",
                                                       FrozenWordSet(german: [], english: []).adding(answers))
        print("schutzliste: fragen=\(queries.count) bekannt=\(answers.known.values.filter { $0 }.count)")
        print("datei: \(url.path)")
    }
}
