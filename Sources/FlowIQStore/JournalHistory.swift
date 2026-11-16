/// One dictation of the history window (16.11.): text, raw form, changed words, target app, outcome.
public struct HistoryItem: Sendable, Identifiable, Equatable {
    public let id: String, date: Date, text: String, rawText: String, changed: [String], app: String?
    public let result: String?, seconds: Double?, msToText: Double?
    public let renewed: Bool  // `text` is the ElevenLabs version asked for in the history; `rawText` stays local
    public init(id: String, date: Date, text: String, rawText: String, changed: [String], app: String?,
                result: String?, seconds: Double?, msToText: Double?, renewed: Bool = false) {
        (self.id, self.date, self.text, self.rawText, self.changed, self.app) = (id, date, text, rawText, changed, app)
        (self.result, self.seconds, self.msToText, self.renewed) = (result, seconds, msToText, renewed)
    }
}
/// What the history card counts, from the journal only (no protocol text).
public struct HistoryStats: Sendable, Equatable {
    public var words = 0, wordsToday = 0, dictations = 0, msToText = 0.0, corrections = 0
    public init(dictations: Int = 0) { self.dictations = dictations }
}

extension DictationJournal {
    /// Newest first; `before` pages back, `query` matches the text without case.
    public func history(before: Date? = nil, limit: Int = 50, matching query: String = "") -> [HistoryItem] {
        Array(items().reversed().filter { item in
            (before.map { item.date < $0 } ?? true) && (query.isEmpty || item.text.localizedStandardContains(query))
        }.prefix(limit))
    }
    public func stats(now: Date = .now) -> HistoryStats {
        let all = items(), timed = all.compactMap(\.msToText), day = Calendar.current
        var s = HistoryStats(dictations: all.count)
        s.msToText = timed.isEmpty ? 0 : timed.reduce(0, +) / Double(timed.count)
        for item in all {
            let n = item.text.split(separator: " ").count
            s.words += n
            if day.isDate(item.date, inSameDayAs: now) { s.wordsToday += n }
        }
        s.corrections = lines().filter { $0["event"] as? String == "correction" }.count
        return s
    }
    /// The saved audio of a dictation, if it is still there.
    public func audio(of item: HistoryItem) -> URL? {
        let parts = Self.month(item.date).split(separator: "-")
        let url = paths.diktate.appending(path: "\(parts[0])/\(parts[1])/\(item.id).aac")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// The newest dictation's end if it failed (not recognized, or the microphone refused), with its kept audio;
    /// nil once a dictation was recognized after it. For the menu's "Erneut erkennen".
    public func lastFailure() -> (id: String, audio: URL?)? {
        let last = lines().last { $0["event"] as? String == "recognized" || $0["mic"] as? String == "refused" }
        guard let last, let id = last["id"] as? String, last["final_text"] == nil else { return nil }
        return (id, audio(of: HistoryItem(id: id, date: Date(timeIntervalSince1970: last["ts"] as? Double ?? 0),
            text: "", rawText: "", changed: [], app: nil, result: nil, seconds: nil, msToText: nil)))
    }
    /// Deletes text and audio of these dictations on the user's click: each month file is replaced without them.
    @discardableResult public func forget(_ ids: Set<String>) throws -> Int {
        let audio = items().filter { ids.contains($0.id) }.compactMap(audio(of:))  // before the lines go
        try handle?.file.close()
        handle = nil
        var gone = 0
        for name in journalFiles() {
            let url = paths.diktate.appending(path: name)
            let lines = (FileManager.default.contents(atPath: url.path) ?? Data()).split(separator: 0x0A)
            let marks = ids.map { Data("\"id\":\"\($0)\"".utf8) }
            let kept = lines.filter { line in !marks.contains { line.range(of: $0) != nil } }
            guard kept.count != lines.count else { continue }
            gone += lines.count - kept.count
            try fs.replace(url, with: kept.isEmpty ? Data() : Data(kept.joined(separator: [0x0A])) + Data([0x0A]))
        }
        for url in audio { try fs.delete(url) }
        log.record(LogEvent("history_forgotten", ["dictations": .int(Int64(ids.count)), "lines": .int(Int64(gone))]))
        return gone
    }
    /// "Verlauf aufbewahren": dictations older than `days` go, text and audio.
    @discardableResult public func prune(olderThan days: Int, now: Date = .now) throws -> Int {
        let cut = now.addingTimeInterval(-Double(days) * 86_400)
        let old = Set(items().filter { $0.date < cut }.map(\.id))
        return old.isEmpty ? 0 : try forget(old)
    }
    func journalFiles() -> [String] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: paths.diktate.path) } catch { return [] }
        return names.filter { $0.hasPrefix("journal-") && $0.hasSuffix(".jsonl") }.sorted()
    }
    /// Every recognized dictation, oldest first, with its last insertion result and audio length.
    func items() -> [HistoryItem] {
        var result: [String: String] = [:], app: [String: String] = [:], seconds: [String: Double] = [:]
        var renewed: [String: String] = [:]  // the newest "renewed" line replaces the shown text (16.11.)
        let all = lines()
        for o in all {
            guard let id = o["id"] as? String else { continue }
            if o["event"] as? String == "inserted" {
                result[id] = o["result"] as? String
                if let a = o["app"] as? String { app[id] = a }
            }
            if o["event"] as? String == "audio", let s = o["seconds"] as? Double { seconds[id] = s }
            if o["event"] as? String == "renewed" { renewed[id] = o["final_text"] as? String }
        }
        return all.filter { $0["event"] as? String == "recognized" }.compactMap { o in
            guard let id = o["id"] as? String, let text = o["final_text"] as? String else { return nil }
            let changed = Self.decode([Intervention].self, o["intervention_detail"])?.map(\.tAfter) ?? []
            let ms = [o["recognize_ms"], o["stage_ms"]].compactMap { $0 as? Double }.filter { $0 >= 0 }
            return HistoryItem(id: id, date: Date(timeIntervalSince1970: o["ts"] as? Double ?? 0),
                               text: renewed[id] ?? text, rawText: o["recognizer_text"] as? String ?? text,
                               changed: renewed[id] == nil ? changed : [],
                               app: app[id] ?? o["app"] as? String, result: result[id], seconds: seconds[id],
                               msToText: ms.count == 2 ? ms.reduce(0, +) : nil, renewed: renewed[id] != nil)
        }
    }
}
