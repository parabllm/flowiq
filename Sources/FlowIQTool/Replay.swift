/// `replay` (A.13, G-REPLAY): the stage over stored recognizer text with R3 off and on; ways and `spur.jsonl`
/// into the private output folder, the lexicon from `lexikon.json`. Console: paths only.
enum Replay {
    struct Trace: Encodable {
        let id: String, flowiq: TextStageResult, flowiqR3: TextStageResult
    }
    static func run(_ args: Args) throws {
        let (lexicon, familiar) = try LexiconStore.load(file: args.url("lexikon"))
        let reference = try loadReference(args)
        var protection = try args.values["schutz"] == nil ? FrozenWordSet(german: [], english: [])
            : JSONDecoder().decode(FrozenWordSet.self, from: Data(contentsOf: args.url("schutz")))
        protection.familiar.formUnion(familiar)
        let stages = [false, true].map { spoken in
            var config = TextStageConfig(spokenForm: spoken)
            config.spokenMinScore = args.values["r3-schwelle"].flatMap(Double.init) ?? config.spokenMinScore
            return TextStage(lexicon: lexicon, protection: protection, config: config)
        }
        let recognized = try args.values["erkannt"] == nil ? nil : loadRecognized(args.url("erkannt"))
        var oracle = SpellOracle(), rows: [[String: String]] = [], traces = Data()
        for entry in try loadHistory(args.url("history")) {
            guard let id = entry["id"] as? String, let raw = recognized.map({ $0[id] })
                    ?? (entry[args.values["rohtext"] ?? "rawText"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            else { continue }
            let ref = reference.map { $0[id] } ?? (entry["elevenLabsText"] as? String)
            if reference != nil, ref == nil { continue }
            let input = Recognition(text: raw), answers = oracle.answer(stages[0].oracleQueries(for: input))
            let results = stages.map { $0.process(input, answers: answers) }
            var row = ["id": id, "rawText": raw, "processedText": entry["processedText"] as? String ?? raw,
                       "panottiRawText": entry["rawText"] as? String ?? "",
                       "flowiq": results[0].text, "flowiqR3": results[1].text]
            if let ref { row["referenz"] = ref }
            rows.append(row)
            traces += try JSONEncoder().encode(Trace(id: id, flowiq: results[0], flowiqR3: results[1]))
            traces += Data("\n".utf8)
        }
        let out = try Output(args, "replay")
        print("replay: diktate=\(rows.count) orakelfragen=\(oracle.cache.count)")
        for file in [try out.json("wege.json", rows), try out.data("spur.jsonl", traces)] {
            print("datei: \(file.path)")
        }
    }
    /// Gold reference lines of one part (default "einstellen"). The vault part needs `--abnahme`.
    static func loadReference(_ args: Args) throws -> [String: String]? {
        guard args.values["referenz"] != nil else { return nil }
        let url = try args.url("referenz"), part = args.values["teil"] ?? "einstellen"
        guard (part == "einstellen" && !url.path.contains("/tresor/")) || args.flags.contains("abnahme") else {
            throw ToolError("zurückgehaltener Teil nur bei der Abnahme (--abnahme)")
        }
        var out: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  row["teil"] as? String == part, let id = row["id"] as? String,
                  let text = row["referenz"] as? String else { continue }
            out[id] = text
        }
        return out
    }
    /// Texts of a new recognition (`erkennen`), failed lines left out.
    static func loadRecognized(_ url: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let row = try JSONDecoder().decode(Recognize.Line.self, from: Data(line.utf8))
            if let text = row.result?.text { out[row.id] = text }
        }
        return out
    }
}

func loadHistory(_ url: URL) throws -> [[String: Any]] {
    guard let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
        throw ToolError("Verlauf ist keine Liste")
    }
    return rows
}
