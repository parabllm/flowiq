/// `erkennen` (A.13, P2b, K-01): new recognition into `<wurzel>/FlowIQ-Dev/erkennen/<name>.jsonl`, resumable, waits
/// on `--waechter` and load 20+. Usage: `erkennen --index --quelle --waechter --wurzel [--ids] [--name]`.
enum Recognize {
    struct Line: Codable {
        let id: String, recognizer: String, result: FileRecognition?, error: String?
    }
    static func run(_ args: Args) async throws {
        let watched = try args.url("waechter"), jobs = try selection(args), out = try Output(args, "erkennen")
        let file = out.folder.appending(path: (args.values["name"] ?? "speech") + ".jsonl"), done = try finished(file)
        let handle = try out.fs.appendHandle(file)
        try handle.write(contentsOf: Data("\n".utf8)) // a torn last line of an aborted run stays alone
        print("erkennen: auftraege=\(jobs.count) schon_erledigt=\(jobs.filter { done.contains($0.id) }.count)")
        let reserved = await FileTranscriber.reserve(Locale(identifier: "de_DE"))
        say("reservierung: \(reserved.map(String.init) ?? "keine Antwort in 10 s")")
        let locale = Locale(identifier: "de_DE")
        var count = 0, failed = 0, millis = 0, seconds = 0.0
        for job in jobs where !done.contains(job.id) {
            if count % 50 == 0 { await waitUntilFree(watched) }
            let line: Line
            do {
                let result = try await FileTranscriber.recognize(job.audio, locale: locale,
                                                                 limit: .seconds(30 + 3 * job.seconds))
                line = Line(id: job.id, recognizer: "speech", result: result, error: nil)
                millis += result.millis
                seconds += result.seconds
            } catch {
                failed += 1
                line = Line(id: job.id, recognizer: "speech", result: nil,
                            error: (error as? FileTranscriber.Failure)?.reason ?? String(describing: type(of: error)))
            }
            try handle.write(contentsOf: JSON.line(line))
            count += 1
            if count % 50 == 0 { say("erkennen: \(count) fehler=\(failed) rechenzeit_s=\(millis / 1000)") }
        }
        try handle.close()
        print("erkennen: neu=\(count) fehler=\(failed) audio_s=\(Int(seconds)) rechenzeit_s=\(millis / 1000)")
        print("datei: \(file.path)")
    }
    /// Usable audio from the corpus index: path set, more than 2,048 bytes, inside the read-only source copy.
    static func selection(_ args: Args) throws -> [(id: String, audio: URL, seconds: Double)] {
        let source = try args.url("quelle").standardizedFileURL.path + "/"
        let only = try args.values["ids"].map { _ in
            Set(try String(contentsOf: args.url("ids"), encoding: .utf8).split(separator: "\n").map(String.init))
        }
        var jobs: [(id: String, audio: URL, seconds: Double)] = []
        for line in try String(contentsOf: args.url("index"), encoding: .utf8).split(separator: "\n").dropFirst() {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 14, !c[3].isEmpty, (Int(c[13]) ?? 0) > 2048, only?.contains(c[0]) ?? true else {
                continue
            }
            let audio = URL(filePath: c[3]).standardizedFileURL
            guard audio.path.hasPrefix(source) else { throw ToolError("Audio außerhalb der Quelle") }
            jobs.append((c[0], audio, Double(c[2]) ?? 60))
        }
        return jobs
    }
    /// Ids with a result in an earlier run; a torn last line is ignored.
    static func finished(_ file: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var ids = Set<String>()
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            do {
                let row = try JSONDecoder().decode(Line.self, from: Data(line.utf8))
                if row.result != nil { ids.insert(row.id) }
            } catch {
                continue // a torn line of an aborted run counts as not done
            }
        }
        return ids
    }
    /// Progress goes to standard error, which is not buffered, so a log shows it while the run lasts.
    static func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    static func waitUntilFree(_ watched: URL) async {
        while true {
            var load = [0.0, 0.0, 0.0]
            getloadavg(&load, 3)
            let age = youngest(watched)
            if age >= 90, load[0] < 20 { return }
            say("pause: laufend_juengste_s=\(Int(min(age, 1e6))) last=\(Int(load[0]))")
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
    /// Age in seconds of the youngest file below the folder (modification date only, nothing is opened).
    static func youngest(_ folder: URL) -> Double {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return .infinity
        }
        var age = Double.infinity
        for case let item as URL in items {
            do {
                let v = try item.resourceValues(forKeys: Set(keys))
                if v.isRegularFile == true, let date = v.contentModificationDate {
                    age = min(age, Date().timeIntervalSince(date))
                }
            } catch {
                continue // the file vanished between listing and reading its date
            }
        }
        return age
    }
}
