/// A JSON value for journal lines: Sendable, encodable, no `Any`.
public enum JSONValue: Sendable, Equatable, Encodable {
    case string(String), number(Double), bool(Bool), list([JSONValue]), object([String: JSONValue])
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .list(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    /// Any encodable value with its own keys, so the store decodes it again (journal traces).
    public static func encoding(_ value: some Encodable) -> JSONValue {
        func convert(_ any: Any) -> JSONValue {
            switch any {
            case let s as String: .string(s)
            case let n as NSNumber: .number(n.doubleValue)
            case let l as [Any]: .list(l.map(convert))
            case let o as [String: Any]: .object(o.mapValues(convert))
            default: .string("")
            }
        }
        do { return convert(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) } catch {
            return .list([])
        }
    }
}

/// One journal line: the event name of A.9 plus fields. The factories name the events.
public struct JournalEntry: Sendable {
    public let event: String, id: String, fields: [String: JSONValue]
    public init(_ event: String, id: String, _ fields: [String: JSONValue] = [:]) {
        (self.event, self.id, self.fields) = (event, id, fields)
    }
    public static func begin(id: String, _ fields: [String: JSONValue] = [:]) -> Self { Self("begin", id: id, fields) }
    public static func recognized(id: String, recognizerText: String, finalText: String, interventions: [String],
                                  _ more: [String: JSONValue] = [:]) -> Self {
        let core: [String: JSONValue] = ["recognizer_text": .string(recognizerText), "final_text": .string(finalText),
                                         "interventions": .list(interventions.map(JSONValue.string))]
        return Self("recognized", id: id, more.merging(core) { _, own in own })
    }
    /// The same with the interventions themselves: rule names plus the detail the window and probation read.
    public static func recognized(id: String, recognizerText: String, finalText: String, interventions: [Intervention],
                                  _ more: [String: JSONValue] = [:]) -> Self {
        let names = interventions.map(\.tRule)
        return recognized(id: id, recognizerText: recognizerText, finalText: finalText, interventions: names,
                          more.merging(["intervention_detail": .encoding(interventions)]) { a, _ in a })
    }
    public static func inserted(id: String, result: String, _ more: [String: JSONValue] = [:]) -> Self {
        Self("inserted", id: id, more.merging(["result": .string(result)]) { a, _ in a })
    }
}

/// One dictation of the journal as the correction window needs it after a restart.
public struct JournalRecord: Sendable {
    public let id: String, recognizerText: String, alternatives: [[String]], finalText: String
    public let interventions: [Intervention], app: String?
}

/// The private dictation journal (A.9, R-022, R-023): only appended, before the insertion; nothing here deletes.
public actor DictationJournal {
    let paths: Paths, fs: SafeFS, log: EventLog, encoder: JSONEncoder
    var handle: (month: String, file: FileHandle)?, unsynced = false  // forget closes it before a replace
    /// Lines appended in this run and when the last one came: the idle probation runs only after a quiet spell.
    public private(set) var appended = 0, lastAppend = Date.distantPast
    public init(paths: Paths, fs: SafeFS, log: EventLog) {
        (self.paths, self.fs, self.log) = (paths, fs, log)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    public func append(_ entry: JournalEntry) throws {
        let now = Date.now
        var object = entry.fields
        (object["event"], object["id"], object["ts"]) = (.string(entry.event), .string(entry.id),
                                                         .number(now.timeIntervalSince1970))
        let line = try encoder.encode(object) + Data([0x0A])
        if entry.event == "recognized", case .string(let text)? = entry.fields["final_text"] {  // counts, never text
            let n = { (v: JSONValue?) -> Int64 in if case .list(let l)? = v { Int64(l.count) } else { 0 } }
            log.record(LogEvent("dictation_counts", ["words": .int(Int64(text.split(separator: " ").count)),
                                                     "interventions": .int(n(entry.fields["interventions"]))]))
        }
        let month = Self.month(now)
        if handle?.month != month {
            try handle?.file.close()
            handle = (month, try fs.appendHandle(paths.diktate.appending(path: "journal-\(month).jsonl")))
        }
        try handle?.file.write(contentsOf: line)
        (unsynced, appended, lastAppend) = (true, appended + 1, now)
    }
    /// Bundled `fsync` after the insertion (A.9).
    public func sync() {
        guard unsynced else { return }
        log.attempt("journal_sync_failed") { try handle?.file.synchronize() }
        unsynced = false
    }
    /// Where the audio of dictation `id` goes; the month folder is created on demand.
    public func audioURL(for id: String, at date: Date = .now) throws -> URL {
        let parts = Self.month(date).split(separator: "-")
        let folder = paths.diktate.appending(path: "\(parts[0])/\(parts[1])", directoryHint: .isDirectory)
        try fs.makeFolder(folder)
        return folder.appending(path: "\(id).aac")
    }
    /// Every line of every month, oldest first; a torn last line is skipped.
    func lines() -> [[String: Any]] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: paths.diktate.path) } catch { return [] }
        return names.sorted().filter { $0.hasPrefix("journal-") && $0.hasSuffix(".jsonl") }.flatMap { name in
            (FileManager.default.contents(atPath: paths.diktate.appending(path: name).path) ?? Data())
                .split(separator: 0x0A).compactMap { line -> [String: Any]? in
                    do { return try JSONSerialization.jsonObject(with: line) as? [String: Any] } catch { return nil }
                }
        }
    }
    /// What probation and candidates see of the journal (A.7); `classified` only with journaled protected forms (L5).
    public func views(classified: Bool = false) -> [JournalView] {
        let all = lines()
        var rejected: [String: Int] = [:], only: [String: [String]] = [:], every = Set<String>()
        for o in all {
            guard let id = o["id"] as? String else { continue }
            if o["event"] as? String == "reject" {
                rejected[id, default: 0] += o["interventions_rejected"] as? Int ?? 0
                every.insert(id)
            } else if o["event"] as? String == "reject_intervention" {
                rejected[id, default: 0] += 1
                only[id, default: []].append(o["variant_id"] as? String ?? "")
            }
        }
        return all.filter { $0["event"] as? String == "recognized" && (!classified || $0["protected"] != nil) }
            .compactMap { o in
                guard let id = o["id"] as? String, let text = o["recognizer_text"] as? String else { return nil }
                let acted = Self.decode([Intervention].self, o["intervention_detail"])?.compactMap(\.variantID)
                return JournalView(day: Int((o["ts"] as? Double ?? 0) / 86_400), recognizerText: text,
                                   protectedForms: Set(o["protected"] as? [String] ?? []),
                                   rejectedInterventions: rejected[id] ?? 0,
                                   interventionCount: (o["interventions"] as? [Any])?.count ?? 0,
                                   nearMisses: Self.decode([NearMiss].self, o["near_miss_detail"]) ?? [],
                                   alternatives: (o["alternatives"] as? [[String]] ?? []).flatMap { $0 },
                                   variants: every.contains(id) ? acted : only[id] ?? acted)
            }
    }
    /// The newest `limit` dictations for the correction window after a restart, newest first.
    public func records(limit: Int) -> [JournalRecord] {
        lines().reversed().filter { $0["event"] as? String == "recognized" }.prefix(limit).compactMap { o in
            guard let id = o["id"] as? String, let text = o["recognizer_text"] as? String,
                  let final = o["final_text"] as? String else { return nil }
            return JournalRecord(id: id, recognizerText: text, alternatives: o["alternatives"] as? [[String]] ?? [],
                                 finalText: final, interventions: Self.decode([Intervention].self,
                                                                              o["intervention_detail"]) ?? [],
                                 app: o["app"] as? String)
        }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value)) } catch {
            return nil
        }
    }
    static func month(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
