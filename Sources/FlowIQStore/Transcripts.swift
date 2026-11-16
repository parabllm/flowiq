@_exported import FlowIQLog
@_exported import FlowIQRecording
@_exported import FlowIQText

public struct StoreLocations: Sendable {
    public let transcripts: URL, raw: URL, archiveAudio: URL, liveLink: URL, dataFolder: URL
    public init(transcripts: URL, raw: URL, archiveAudio: URL, liveLink: URL, dataFolder: URL) {
        (self.transcripts, self.raw, self.archiveAudio, self.liveLink) = (transcripts, raw, archiveAudio, liveLink)
        self.dataFolder = dataFolder
    }
}

/// Terms for the services, only from confirmed entries (A.9, R-033, R-104), independent of the entries' order:
/// family members first, then by use in the last 30 days, then by name (LEXIKON-KONZEPT 6). ElevenLabs takes
/// 50 of at most 20 characters live and at most 50 characters per term in the after-run (its documentation).
public enum CloudTerms {
    public static func live(from entries: [CanonEntry], now: Date = Date()) -> [String] {
        pick(entries, count: 50, length: 20, now: now)
    }
    public static func post(from entries: [CanonEntry], now: Date = Date()) -> [String] {
        pick(entries, count: 100, length: 50, now: now)
    }
    static func pick(_ entries: [CanonEntry], count: Int, length: Int, now: Date) -> [String] {
        let since = now.addingTimeInterval(-30 * 86_400)
        func uses(_ e: CanonEntry) -> Int {  // counters applied in the window, weighted by their benefit
            ([e.counters] + e.hearingVariants.map(\.counters)).filter { $0.lastAppliedAt.map { $0 >= since } ?? false }
                .reduce(0) { $0 + max(1, $1.benefit) }
        }
        let ranked = entries.filter { $0.status == .confirmed && $0.canonical.count <= length }
            .map { (family: $0.family == nil ? 1 : 0, uses: -uses($0), name: $0.canonical) }
            .sorted { ($0.family, $0.uses, $0.name) < ($1.family, $1.uses, $1.name) }
        var seen = Set<String>()
        return Array(ranked.map(\.name).filter { seen.insert($0).inserted }.prefix(count))
    }
}

/// A vault transcript as the predecessor app Panotti writes it (05b 1.2, A.9, M.10): its keys, new ones, foreign ones.
struct VaultDoc {
    static let order = ["type", "status", "panotti_live", "panotti_phase", "quelle", "aufnahme", "dauer",
                        "sprecher_erkannt", "sprecher_grenze", "fachbegriffe", "sprache", "pipeline", "tracks",
                        "nachlauf", "live_quelle", "live_wechsel", "nachlauf_quelle", "cloud_minuten"]
    var fields: [String: String], lists: [String: [String]] = [:], others: [String] = [], body: String
    init(fields: [String: String], body: String) { (self.fields, self.body) = (fields, body) }
    init(_ data: Data) {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        (fields, body) = ([:], lines.joined(separator: "\n"))
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return }
        var key = ""
        for line in lines[1..<close] {
            if line.hasPrefix("  - ") { lists[key, default: []].append(String(line.dropFirst(4))) }
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            key = String(line[..<colon])
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !Self.order.contains(key) { others.append(key) }
        }
        body = lines[(close + 1)...].joined(separator: "\n")
    }
    var data: Data {
        let head = (Self.order + others).compactMap { key in
            lists[key].map { "\(key):\n" + $0.map { "  - \($0)\n" }.joined() } ?? fields[key].map { "\(key): \($0)\n" }
        }
        return Data(("---\n" + head.joined() + "---\n" + body).utf8)
    }
    /// Contribution and note lines in order, never the "spricht gerade" line.
    var lines: [String] {
        body.components(separatedBy: "\n")
            .filter { $0.hasPrefix("**[") || $0.hasPrefix("_[") && !$0.contains("spricht") }
    }
    var texts: [String] { lines.compactMap { line in line.range(of: ":** ").map { String(line[$0.upperBound...]) } } }
    var title: String {
        "\n" + (body.components(separatedBy: "\n").first { $0.hasPrefix("# ") } ?? "# Transkript") + "\n\n"
    }
    static func clock(_ s: Int) -> String {
        s >= 3600 ? String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func line(_ s: Int, _ speaker: String, _ text: String) -> String { "**[\(clock(s))] \(speaker):** \(text)" }
    static func source(_ e: LiveEngine) -> String { e == .appleLocal ? "apple-lokal" : "elevenlabs-scribe-v3-live" }
    static func minutes(_ seconds: Double) -> String { String(format: "%.1f", seconds / 60) }
    static func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }
    static func seconds(of line: String) -> Int {
        line.dropFirst(line.hasPrefix("**[") ? 3 : 2).prefix { $0 != "]" }.split(separator: ":")
            .reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
    static func date(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        (f.locale, f.timeZone, f.dateFormat) = (Locale(identifier: "en_US_POSIX"), .current, format)
        return f.string(from: d)
    }
}

/// What the live file and its journal in `laufend/` know of a recording; the journal rebuilds it after a crash.
struct LiveMeta: Codable, Sendable {
    let id: String, kind: RecordingMode, start: Date, language: String, source: LiveEngine
    var file = "", audio: String? = nil  // the recording folder or file in `laufend/`, for the recovery
    var stamp: String { VaultDoc.date(start, "yyyy-MM-dd HH:mm") }
    var title: String { "\n# Transkript: \(kind == .call ? "Call" : "Raum") \(stamp)\n\n" }
    func doc(phase: String, status: String, quelle: String, dauer: String, body: String,
             switches: [String]) -> VaultDoc {
        var doc = VaultDoc(fields: ["type": "transkript", "status": status, "panotti_live": "true", "dauer": dauer,
                                    "panotti_phase": phase, "quelle": quelle, "aufnahme": stamp, "sprache": language,
                                    "sprecher_erkannt": kind == .call ? "2" : "1", "pipeline": "panotti-live",
                                    "live_quelle": VaultDoc.source(source)], body: body)
        if !switches.isEmpty { (doc.fields["live_quelle"], doc.lists["live_wechsel"]) = ("gemischt", switches) }
        return doc
    }
}

/// Vault side of call and room (A.9, M11, G-12): one file per start minute, never overwritten; the live link moves.
public actor TranscriptStore {
    public typealias Oracle = @Sendable (Set<OracleQuery>) async -> OracleAnswers
    public nonisolated let locations: StoreLocations
    nonisolated let fs: SafeFS, log: EventLog, speakerName: String, oracle: Oracle?
    nonisolated let textStage: (@Sendable () async -> TextStage)?
    private var running: [URL] = []
    public init(locations: StoreLocations, fs: SafeFS, log: EventLog, speakerName: String,
                textStage: (@Sendable () async -> TextStage)? = nil, oracle: Oracle? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        (self.locations, self.fs, self.log, self.speakerName) = (locations, fs, log, speakerName)
        (self.textStage, self.oracle) = (textStage, oracle)
    }
    nonisolated var laufend: URL { locations.dataFolder.appending(path: "laufend", directoryHint: .isDirectory) }
    public func beginLive(kind: RecordingMode, startedAt: Date, language: String,
                          liveSource: LiveEngine = .appleLocal, audio: URL? = nil,
                          device: String? = nil) async throws -> LiveTranscript {
        log.record(LogEvent("live_session_started", ["mode": .string(kind.rawValue), "language": .string(language),
            "live_source": .string(liveSource.rawValue), "device": .string(device ?? "unbekannt")]))
        var meta = LiveMeta(id: UUID().uuidString, kind: kind, start: startedAt, language: language, source: liveSource,
                            audio: audio?.path)
        let base = VaultDoc.date(startedAt, "yyyy-MM-dd-HHmm") + (kind == .call ? "-call" : "-raum")
        var n = 1, url = locations.transcripts.appending(path: base + ".md")
        let archive = locations.transcripts.appending(path: "archive", directoryHint: .isDirectory)
        while Self.exists(url) || Self.exists(archive.appending(path: url.lastPathComponent)) {
            n += 1
            url = locations.transcripts.appending(path: "\(base)-\(n).md")
        }
        try fs.claimNew(url, with: meta.doc(phase: "live-stream", status: "live", quelle: "laufend", dauer: "laufend",
                                            body: meta.title, switches: []).data)
        meta.file = url.path
        let live = try LiveTranscript(url: url, meta: meta, store: self, stage: await textStage?())
        running.append(url)
        point(url)
        return live
    }
    func point(_ url: URL) {
        log.attempt("live_link_failed") { try fs.link(locations.liveLink, to: url) }
    }
    /// The newest still running file gets the link back; after the last one it stays on the finished file.
    func ended(_ url: URL) {
        running.removeAll { $0 == url }
        if let latest = running.last { point(latest) }
    }
    /// The text stage on one text (N.4) with the app's word oracle; without one the frozen set is the dictionary.
    nonisolated func staged(_ text: String, _ stage: TextStage?) async -> String {
        guard let stage else { return text }
        let input = Recognition(text: text), queries = stage.oracleQueries(for: input)
        let unknown = OracleAnswers(known: Dictionary(uniqueKeysWithValues: queries.map { ($0, false) }))
        return stage.process(input, answers: await oracle?(queries) ?? unknown).text
    }
    /// The text stage for a device transcript (R-064, N.4), with the lexicon as it is now.
    public func stage(_ text: String) async -> String { await staged(text, await textStage?()) }
    /// Files of a killed process rebuilt as `recovered-wal` (Z-11), the open sentence kept, a broken journal skipped.
    public func recoverOrphans() async throws -> [URL] {
        var rebuilt: [URL] = []
        for name in Self.list(laufend) where name.hasPrefix("live-") && name.hasSuffix(".jsonl") {
            do { rebuilt.append(try recover(laufend.appending(path: name))) } catch {
                log.record(LogEvent("live_recover_failed", level: .error))
            }
        }
        return rebuilt
    }
    private func recover(_ journal: URL) throws -> URL {
        let lines = try Data(contentsOf: journal).split(separator: UInt8(ascii: "\n")).map { Data($0) }
        let meta = try JSONDecoder().decode(LiveMeta.self, from: lines.first ?? Data())
        let switches = JSON.decode(Array(lines.dropFirst()), as: [String].self).compactMap(\.first)
        let url = URL(filePath: meta.file), old = VaultDoc(try Data(contentsOf: url))
        let open = old.body.components(separatedBy: "\n").last { $0.hasPrefix("_[") && $0.hasSuffix("_") }
            .flatMap { v -> String? in
                guard let close = v.firstIndex(of: "]"), let cut = v.range(of: " (spricht gerade…): ") else {
                    return nil
                }
                return VaultDoc.line(VaultDoc.seconds(of: v), String(v[v.index(close, offsetBy: 2)..<cut.lowerBound]),
                                     String(v[cut.upperBound...].dropLast()))
            }
        let kept = old.lines + (open.map { [$0] } ?? [])
        let quelle = meta.audio.map { place(URL(filePath: $0), kind: meta.kind) } ?? "recovered"
        var doc = meta.doc(phase: "recovered-wal", status: "unverarbeitet", quelle: quelle,
                           dauer: VaultDoc.clock(kept.last.map(VaultDoc.seconds(of:)) ?? 0),
                           body: old.title + kept.map { $0 + "\n" }.joined(), switches: switches)
        doc.fields["nachlauf"] = "aus"
        try fs.replace(url, with: doc.data)
        try fs.delete(journal)
        return url
    }
    func edit(_ url: URL, _ change: (inout VaultDoc) throws -> Void) throws {
        var doc = VaultDoc(try Data(contentsOf: url))
        try change(&doc)
        try fs.replace(url, with: doc.data)
    }
    /// The after-run version replaces the text (E5, N.4); without a copy in `fassungen/` first nothing is replaced.
    func upgrade(_ url: URL, with t: PostTranscript, mode: RecordingMode, terms: Int, source: String,
                 postSeconds: Double, stage: TextStage?) async throws {
        let folder = locations.dataFolder.appending(path: "fassungen", directoryHint: .isDirectory)
        let name = url.deletingPathExtension().lastPathComponent
        var n = 1
        try fs.makeFolder(folder)  // a missing copy folder must not stop every after-run (Szenarien)
        while Self.exists(folder.appending(path: "\(name).\(n).md")) { n += 1 }
        try fs.claimNew(folder.appending(path: "\(name).\(n).md"), with: try Data(contentsOf: url))
        var body = ""
        for s in t.segments {
            body += VaultDoc.line(Int(s.start), s.speaker, await staged(VaultDoc.oneLine(s.text), stage)) + "\n"
        }
        let other = Set(t.segments.map(\.speaker).filter { $0.hasPrefix("Gegenseite (") }).sorted()
            .map { $0.dropFirst(12).dropLast() }.joined(separator: ", ")
        try edit(url) { doc in
            let place = URL(filePath: doc.fields["quelle"] ?? "")
            let item = mode == .call ? place.lastPathComponent : place.deletingPathExtension().lastPathComponent
            let minutes = (Double(doc.fields["cloud_minuten"] ?? "") ?? 0) * 60 + postSeconds
            let device = mode == .device  // 05b: a device file keeps its pipeline tag and its recording name (P6)
            let via = source.hasPrefix("openrouter/") ? "+" + source.replacing("/", with: "-") : "+elevenlabs-scribe-v2"
            (doc.fields["panotti_phase"], doc.fields["pipeline"], doc.fields["nachlauf"], doc.fields["aufnahme"]) =
                ("final-elevenlabs", device ? (doc.fields["pipeline"] ?? "").replacing("+lokal", with: via)
                    : "panotti-live" + via, nil,
                 device ? doc.fields["aufnahme"] : "\"\(item)\"")
            (doc.fields["sprecher_erkannt"], doc.fields["fachbegriffe"]) = (String(t.speakersDetected), String(terms))
            (doc.fields["nachlauf_quelle"], doc.fields["cloud_minuten"], doc.body) =
                (source, VaultDoc.minutes(minutes), doc.title + body)
            if mode == .call {
                doc.fields["tracks"] = "mikrofon=\(speakerName), desktop=Gegenseite"
                    + (other.isEmpty ? "" : " (\(other))")
            } else if mode == .room { doc.fields["sprecher_grenze"] = "8" }
        }
    }
    /// Into the archive, never deleting, a clash gets " 2"; size against duration first (A.5).
    nonisolated func archive(_ item: URL, seconds: Double, mode: RecordingMode, check: Bool = true) -> URL {
        let tracks = Self.list(item).map { item.appending(path: $0) }
        for track in tracks.isEmpty ? [item] : tracks where check {
            let verdict = SizeCheck.verdict(url: track, seconds: seconds, purpose: mode == .call ? .call : .room)
            guard verdict != .ok else { continue }
            log.record(LogEvent(verdict == .lost ? "audio_lost" : "audio_verdaechtig", level: .error))
        }
        let (folder, ext) = (locations.archiveAudio, item.pathExtension.isEmpty ? "" : "." + item.pathExtension)
        var target = folder.appending(path: item.lastPathComponent), n = 1
        while Self.exists(target) {
            n += 1
            target = folder.appending(path: "\(item.deletingPathExtension().lastPathComponent) \(n)\(ext)")
        }
        do { try fs.move(item, to: target) } catch {
            log.record(LogEvent("archive_failed", level: .error))
            return item
        }
        return target
    }
    /// Where a crashed recording's audio is now (review P2): archived here or by `Rescue`, or left for review.
    nonisolated func place(_ raw: URL, kind: RecordingMode) -> String {
        if Self.exists(raw) { return archive(raw, seconds: 0, mode: kind, check: false).path }
        let review = raw.deletingLastPathComponent().deletingLastPathComponent().appending(path: "zu-pruefen")
        return [locations.archiveAudio, review].map { $0.appending(path: raw.lastPathComponent) }
            .first(where: Self.exists)?.path ?? "recovered"
    }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func list(_ folder: URL) -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() } catch { return [] }
    }
    /// The lines of a JSON-lines file; a missing one has none, an unreadable one is set aside and logged.
    static func lines(_ url: URL, fs: SafeFS, log: EventLog) -> [Data] {
        guard exists(url) else { return [] }
        do { return try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).map { Data($0) } } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("unlesbar-\(UUID().uuidString.prefix(8))")
            log.attempt("file_not_set_aside") { try fs.move(url, to: aside) }
            log.record(LogEvent("file_unreadable", level: .error))
            return []
        }
    }
}

/// The growing live file (A.9, E5, R-053): lines appended in hand-over order, one closing line "spricht gerade".
public actor LiveTranscript {
    public nonisolated let url: URL
    nonisolated let meta: LiveMeta
    private let store: TranscriptStore, stage: TextStage?, handle: FileHandle, journal: FileHandle, journalURL: URL
    private enum Entry { case said(seconds: Int, speaker: String, text: String), note(String) }
    private var entries: [Entry] = [], switches: [String] = [], end: UInt64
    private var volatile: (line: String, seconds: Int, speaker: String, text: String)?
    private var issued = 0, written = 0, ready: [Int: (Entry, String)] = [:]
    init(url: URL, meta: LiveMeta, store: TranscriptStore, stage: TextStage?) throws {
        (self.url, self.meta, self.store, self.stage) = (url, meta, store, stage)
        journalURL = store.laufend.appending(path: "live-\(meta.id).jsonl")
        handle = try store.fs.appendHandle(url)
        end = try handle.offset()
        journal = try store.fs.appendHandle(journalURL)
        try journal.write(contentsOf: JSON.line(meta))
    }
    public func append(seconds: Int, speaker: String, text: String, dictation: Bool = false,
                       from engine: LiveEngine = .appleLocal) async {
        let (n, who, flat) = (ticket(), dictation ? speaker + " (Diktat)" : speaker, VaultDoc.oneLine(text))
        if volatile?.speaker == speaker { volatile = nil }
        let line = VaultDoc.line(seconds, who, await store.staged(flat, stage))
        put(n, .said(seconds: seconds, speaker: who, text: flat), line)
    }
    public func setVolatile(seconds: Int, speaker: String, text: String) {
        let flat = VaultDoc.oneLine(text)
        volatile = ("_[\(VaultDoc.clock(seconds))] \(speaker) (spricht gerade…): \(flat)_", seconds, speaker, flat)
        write(nil)
    }
    public func clearVolatile() {
        volatile = nil
        write(nil)
    }
    /// A switch of the live source (M.3): an italic line now, the header list at the stop.
    public func noteSwitch(seconds: Int, to engine: LiveEngine, reason: SwitchReason) {
        let why = ["networkError": " (Netzfehler)", "limit": " (Monatsgrenze)"][reason.rawValue] ?? ""
        let word = ["manual": "manuell", "networkError": "netzfehler", "returnToCloud": "rueckkehr",
                    "limit": "monatsgrenze"][reason.rawValue] ?? reason.rawValue
        let (at, source) = (VaultDoc.clock(seconds), engine == .appleLocal ? "Apple lokal" + why : "ElevenLabs")
        let line = "_[\(at)] Live-Erkennung: \(source)_"
        switches.append("\(at) \(VaultDoc.source(engine)) \(word)")
        store.log.attempt("live_journal_failed") { try journal.write(contentsOf: JSON.line([switches.last ?? ""])) }
        put(ticket(), .note(line), line)
    }
    /// A visible italic line, e.g. that live recognition is out (review M4).
    public func note(seconds: Int, _ text: String) {
        let line = "_[\(VaultDoc.clock(seconds))] \(text)_"
        put(ticket(), .note(line), line)
    }
    /// The file run's contributions replace the live ones (review M4), merged with the notes by time; the stop writes.
    public func replaceSaid(with said: [(seconds: Int, speaker: String, text: String)]) {
        let notes = entries.compactMap { e -> (Int, Entry)? in
            if case .note(let line) = e { (VaultDoc.seconds(of: line), e) } else { nil }
        }
        let new = said.map {
            ($0.seconds, Entry.said(seconds: $0.seconds, speaker: $0.speaker, text: VaultDoc.oneLine($0.text)))
        }
        (entries, volatile) = ((notes + new).enumerated().sorted { ($0.1.0, $0.0) < ($1.1.0, $1.0) }.map(\.1.1), nil)
    }
    /// Lines land at once in hand-over order; nothing to wait for.
    public func flush() {}
    private func ticket() -> Int {
        defer { issued += 1 }
        return issued
    }
    /// A line waits until every line handed over before it is written (the stage may wait for the oracle).
    private func put(_ n: Int, _ entry: Entry, _ line: String) {
        ready[n] = (entry, line)
        while let (entry, line) = ready.removeValue(forKey: written) {
            entries.append(entry)
            written += 1
            write(line)
        }
    }
    private func write(_ stable: String?) {
        do {
            try handle.truncate(atOffset: end)
            if let stable { try handle.write(contentsOf: Data((stable + "\n").utf8)) }
            end = try handle.offset()
            if let volatile { try handle.write(contentsOf: Data((volatile.line + "\n").utf8)) }
        } catch { store.log.record(LogEvent("live_write_failed", level: .error)) }
    }
    /// Stop (A.9): the whole file once as `live-lokal`, the open sentence a contribution, the stage as now (N.4).
    func stop(seconds: Double, cloudSeconds: Double, quelle: String) async throws {
        if let v = volatile { entries.append(.said(seconds: v.seconds, speaker: v.speaker, text: v.text)) }
        volatile = nil
        let stage = await store.textStage?()
        var body = meta.title
        for entry in entries {
            switch entry {
            case .said(let s, let who, let text): body += VaultDoc.line(s, who, await store.staged(text, stage)) + "\n"
            case .note(let line): body += line + "\n"
            }
        }
        var doc = meta.doc(phase: "live-lokal", status: "unverarbeitet", quelle: quelle,
                           dauer: VaultDoc.clock(Int(seconds.rounded())), body: body, switches: switches)
        doc.fields["cloud_minuten"] = VaultDoc.minutes(cloudSeconds)
        try store.fs.replace(url, with: doc.data)
        try handle.close()
        try journal.close()
        try store.fs.delete(journalURL)
    }
}
