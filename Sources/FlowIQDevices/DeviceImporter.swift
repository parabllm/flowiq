import CryptoKit
import FlowIQCore
import FlowIQLog
import Foundation

/// Import from recorders (A.11, B.4): read only on the device, checked copy, archive, journal per phase, filing.
public actor DeviceImporter {
    public struct Folders: Sendable {
        public let data: URL, archive: URL  // journal, `geraete.json`, staging; the audio archive
        public init(data: URL, archive: URL) { (self.data, self.archive) = (data, archive) }
    }
    public struct Report: Sendable, Equatable { public var imported = 0, failed = 0, refused = 0, blocked = false }
    enum Outcome { case skipped, imported, failed(ImportProblem) }
    /// Development never touches a volume named like a real device, whatever its identifier (A.11, G.2).
    static let realNames: Set<String> = ["DVT1600", "ZEPHYR", "NO NAME"]
    static let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey,
                                            .isRegularFileKey]
    public nonisolated let profile: Profile
    let folders: Folders, fs: SafeFS, log: EventLog, gate: ThrottleGate, busy: BusyState?
    let transcriber: any DeviceTranscriber, filing: any DeviceFiling, post: @Sendable () async -> Bool
    let volumes: @Sendable () async -> [MountedVolume], now: @Sendable () -> Date, settle: Duration
    public internal(set) var config = DeviceConfig(), current = ImportProgress.hidden
    public private(set) var notice: DeviceNotice?
    private var said: Set<String> = []  // volumes the log already named in this run
    public nonisolated let progress: AsyncStream<ImportProgress>
    let sink: AsyncStream<ImportProgress>.Continuation
    var journal: ImportJournal
    private var running = false, again = false, listed: [String] = [], problems: [String: ImportProblem] = [:]
    public init(profile: Profile, folders: Folders, fs: SafeFS, log: EventLog, transcriber: any DeviceTranscriber,
                filing: any DeviceFiling, post: @escaping @Sendable () async -> Bool, gate: ThrottleGate = .open,
                busy: BusyState? = nil,
                volumes: @escaping @Sendable () async -> [MountedVolume] = { DeviceWatch.mounted() },
                now: @escaping @Sendable () -> Date = { Date() }, settle: Duration = .milliseconds(300)) {
        (self.profile, self.folders, self.fs, self.log, self.gate, self.busy) = (profile, folders, fs, log, gate, busy)
        (self.transcriber, self.filing, self.post, self.volumes, self.now) = (transcriber, filing, post, volumes, now)
        (self.settle, (progress, sink)) = (settle, AsyncStream.makeStream())
        journal = ImportJournal(url: folders.data.appending(path: "journal.jsonl"), fs: fs)
        let file = folders.data.appending(path: "geraete.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { config = try JSONDecoder().decode(DeviceConfig.self, from: Data(contentsOf: file)) } catch {
            log.record(LogEvent("devices_config_unreadable", level: .error))  // stays off, the file stays as it is
        }
    }
    /// The importer was replaced (new storage place): the progress stream ends, and with it its reader.
    public nonisolated func close() { sink.finish() }
    public func setEnabled(_ on: Bool) throws {
        config.enabled = on
        try save()
    }
    /// Makes a plugged-in volume a known device, by identifier, never by name.
    public func register(_ volume: MountedVolume, as kind: DeviceKind, folders: [String]? = nil) throws {
        config.profiles.removeAll { $0.volumeUUID == volume.uuid }
        config.profiles.append(DeviceProfile(kind: kind, volumeUUID: volume.uuid, folders: folders))
        try save()
    }
    func save() throws {
        try fs.makeFolder(folders.data)
        let coder = JSONEncoder()
        coder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.replace(folders.data.appending(path: "geraete.json"), with: coder.encode(config))
    }
    /// The journal folded per identity, oldest first.
    public func entries() -> [ImportEntry] { journal.order.compactMap { journal.entries[$0] } }
    /// Without importing (16.11.): switched off, whether a recorder is plugged in, asked at launch and when the
    /// menu or the Geräte tab opens, never by an observer (R-076); switched on, a line whose device is gone goes.
    public func look(announce: Bool = false) async {
        let mounted = await volumes()
        var next = notice
        if config.enabled {
            if let n = notice, n.what == .off || !mounted.contains(where: { $0.uuid == n.uuid }) { next = nil }
        } else {
            next = profile != .production ? nil : mounted.lazy.compactMap { v in
                DeviceKind.recognize(v).flatMap { $0.sure ? DeviceNotice(.off, $0.kind, name: v.name, uuid: v.uuid)
                    : nil } }.first
            if let next, said.insert(next.uuid).inserted {
                log.record(LogEvent("device_import_off", ["kind": .string(next.kind.rawValue)]))
            }
        }
        guard announce || next != notice else { return }
        notice = next
        sink.yield(current)
    }
    /// Looks at every mounted volume; a mount during a run is looked at right after it. Every way out is logged
    /// and ends with a sign on `progress`, so menu and list follow.
    public func scan() async -> Report {
        var report = Report(), problem: ImportProblem?, found: DeviceNotice?
        guard config.enabled else { await look(); return report }
        guard !running else { again = true; return report }
        guard !journal.unreadable else {
            log.record(LogEvent("device_import_blocked", level: .error))
            show(.failed(.journalUnreadable))
            report.blocked = true
            return report
        }
        (running, notice) = (true, nil)
        await mark(true)
        repeat {
            again = false
            for volume in await volumes() {
                if profile == .development, Self.realNames.contains(volume.name.uppercased()) {
                    report.refused += 1
                    log.record(LogEvent("device_refused", level: .error))
                    continue
                }
                var device = config.profiles.first { $0.volumeUUID == volume.uuid }
                // A fresh install knows no identifier: name plus layout make the volume this device at once.
                if device == nil, profile == .production, let guess = DeviceKind.recognize(volume) {
                    do { if guess.sure { try register(volume, as: guess.kind) } } catch {
                        log.record(LogEvent("devices_config_unwritable", level: .error))
                    }
                    device = config.profiles.first { $0.volumeUUID == volume.uuid }
                    log.record(LogEvent(device == nil ? "device_unknown" : "device_adopted",
                                        ["kind": .string(guess.kind.rawValue)]))
                    if device == nil {
                        found = DeviceNotice(.unknown, guess.kind, name: volume.name, uuid: volume.uuid)
                    }
                }
                guard let device, (device.kind == .test) == (profile == .development) else {
                    if device == nil, volume.url.path.hasPrefix("/Volumes/"), said.insert(volume.uuid).inserted {
                        log.record(LogEvent("device_unknown", ["kind": "none"]))
                    }
                    continue
                }
                var (new, bad) = (0, 0)
                for outcome in await importAll(volume.url, device) {
                    if case .imported = outcome { new += 1 }
                    if case .failed(let p) = outcome { (bad, problem) = (bad + 1, p) }
                }
                (report.imported, report.failed) = (report.imported + new, report.failed + bad)
                if new == 0 && bad == 0 {
                    log.record(LogEvent("device_nothing_new", ["kind": .string(device.kind.rawValue),
                                                               "files": .int(Int64(listed.count))]))
                }
                if bad == 0, found == nil || new > 0 && found?.what == .nothingNew {
                    found = DeviceNotice(new > 0 ? .imported(new) : .nothingNew, device.kind, name: volume.name,
                                         uuid: volume.uuid)
                }
            }
        } while again
        running = false
        await mark(false)
        (notice, current) = (found, problem.map { .failed($0) } ?? .hidden)
        sink.yield(current)
        return report
    }
    private func importAll(_ root: URL, _ device: DeviceProfile) async -> [Outcome] {
        var files: [(url: URL, values: URLResourceValues)] = []
        for folder in device.folders {
            let dir = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
            do {
                for url in try FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: Array(Self.keys), options: .skipsHiddenFiles)
                where url.pathExtension.lowercased() == "wav" {
                    let v = try url.resourceValues(forKeys: Self.keys)
                    if v.isRegularFile == true, Int64(v.fileSize ?? 0) >= device.minimumBytes { files.append((url, v)) }
                }
            } catch { continue }  // a folder this device does not have
        }
        files.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        let latest = files.compactMap(\.values.contentModificationDate).max() ?? now(), mount = now()
        var outcomes: [Outcome] = []
        listed = files.map(\.url.lastPathComponent)
        for (i, file) in files.enumerated() {
            let share = { (part: Double) in (Double(i) + part) / Double(files.count) }
            let outcome = await importOne(file.url, file.values, device, latest: latest, mount: mount, share: share)
            if case .failed(let p) = outcome { problems[listed[i]] = p } else { problems[listed[i]] = nil }
            outcomes.append(outcome)
        }
        return outcomes
    }
    /// One pen file as the Geräte list shows it (R-072): the failed one offers "Erneut versuchen" (= `scan()`).
    public struct FileRow: Sendable, Equatable { public let name: String, state: String, retry: Bool }
    public func fileRows() -> [FileRow] {
        listed.map { name in
            if problems[name] != nil { return FileRow(name: name, state: "fehlgeschlagen", retry: true) }
            let phase = entries().last { $0.name == name }?.phase
            let state = switch phase {
            case nil: "wartet"
            case .copied?: "kopiert"
            case .transcribed?: "erkannt"
            case .done?: "abgelegt"
            case .failed?: "fehlgeschlagen"
            case .ignored?: "ignoriert"
            }
            return FileRow(name: name, state: state, retry: phase == .failed)
        }
    }
    private func importOne(_ url: URL, _ values: URLResourceValues, _ device: DeviceProfile, latest: Date,
                           mount: Date, share: (Double) -> Double) async -> Outcome {
        let (name, bytes) = (url.lastPathComponent, Int64(values.fileSize ?? 0))
        guard !journal.ignored(device.kind, name, bytes) else { return .skipped }
        let fingerprint: String
        do { fingerprint = try DeviceFiles.fingerprint(url, bytes: bytes) } catch { return fail(nil, .unreadable) }
        var known = journal.known(fingerprint, bytes)
        if let phase = known?.phase, [.done, .ignored].contains(phase) { return .skipped }
        if known?.audio.map({ FileManager.default.fileExists(atPath: $0) }) != true {
            guard await stable(url, bytes), let wav = DeviceFiles.inspect(url, bytes: bytes) else {
                return fail(nil, .unreadable)
            }
            let start = RecordingTime.start(name: name, created: values.creationDate,
                                            modified: values.contentModificationDate, seconds: wav.seconds,
                                            latestModified: latest, mount: mount, nameClock: device.nameClock,
                                            offsetMinutes: config.clockOffsetMinutes)
            let fresh = ImportEntry(sha256: "", bytes: bytes, fingerprint: fingerprint, kind: device.kind, name: name,
                                    phase: .copied, recordedAt: start, seconds: wav.seconds)
            do { known = try await secure(url, fresh, repair: wav.repair, share: share) } catch {
                return fail(nil, .copy)
            }
            if known?.phase == .done { return .skipped }  // the fast fingerprint missed a known file
        }
        guard var entry = known, let audio = entry.audio.map({ URL(filePath: $0) }) else { return fail(nil, .copy) }
        show(.transcribing)
        let segments: [LiveSegment]
        do { segments = try await transcriber.transcribe(audio, language: config.language) } catch {
            return fail(entry, .transcribe)
        }
        entry.phase = .transcribed
        do {
            try journal.append(entry)
            let recording = DeviceRecording(
                kind: entry.kind, originalName: name, sha256: entry.copySHA256 ?? entry.sha256,
                deviceSHA256: entry.sha256, bytes: bytes, recordedAt: entry.recordedAt ?? mount,
                seconds: entry.seconds ?? 0, audio: audio, segments: segments, language: config.language,
                post: await post())
            (entry.transcript, entry.phase) = (try await filing.file(recording).path, .done)
            try journal.append(entry)
        } catch { return fail(entry, .filing) }
        log.record(LogEvent("device_imported", ["kind": .string(entry.kind.rawValue),
                                                "seconds": .double(entry.seconds ?? 0)]))
        return .imported
    }
    /// Size unchanged over `settle`: the device may still be writing.
    private func stable(_ url: URL, _ bytes: Int64) async -> Bool {
        do {
            try await Task.sleep(for: settle)
            return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == bytes
        } catch { return false }
    }
    /// Copy to staging, counter check, into the archive as `<stamp>-<label>.wav`, journal `copied`.
    private func secure(_ url: URL, _ fresh: ImportEntry, repair: Bool, share: (Double) -> Double) async throws
        -> ImportEntry {
        let staging = folders.data.appending(path: "import/\(UUID().uuidString).wav")
        try fs.makeFolder(staging.deletingLastPathComponent())
        try fs.makeFolder(folders.archive)
        var entry = fresh
        do {
            let (device, written) = try await copy(url, to: staging, bytes: entry.bytes, repair: repair, share: share)
            guard try DeviceFiles.hash(staging) == written else { throw CocoaError(.fileReadCorruptFile) }
            (entry.sha256, entry.copySHA256) = (device, written == device ? nil : written)
            if let done = journal.entries[entry.key], done.phase == .done {
                try fs.delete(staging)
                return done
            }
            let f = DateFormatter()
            (f.locale, f.timeZone, f.dateFormat) = (Locale(identifier: "en_US_POSIX"), .current, "yyyy-MM-dd-HHmm")
            let stem = f.string(from: entry.recordedAt ?? now()) + "-"
                + DeviceRecording.label(entry.kind, entry.name, entry.copySHA256 ?? entry.sha256)
            var target = folders.archive.appending(path: stem + ".wav"), n = 1
            while FileManager.default.fileExists(atPath: target.path) {
                n += 1
                target = folders.archive.appending(path: "\(stem)-\(n).wav")
            }
            try fs.move(staging, to: target)
            entry.audio = target.path
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) { try fs.delete(staging) }
            throw error
        }
        try journal.append(entry)
        return entry
    }
    /// 64 KB blocks, SHA-256 over what was read and what was written; the header repair is in the first block.
    private func copy(_ source: URL, to target: URL, bytes: Int64, repair: Bool, share: (Double) -> Double)
        async throws -> (device: String, written: String) {
        let input = try FileHandle(forReadingFrom: source)
        _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
        try fs.claimNew(target)
        let output = try fs.appendHandle(target)
        var (read, written, done) = (SHA256(), SHA256(), Int64(0))
        while let chunk = try input.read(upToCount: DeviceFiles.block), !chunk.isEmpty {
            guard await gate.pass() else { throw CancellationError() }
            let out = repair && done == 0 && chunk.count >= 44 ? DeviceFiles.repaired(chunk, bytes: bytes) : chunk
            read.update(data: chunk)
            written.update(data: out)
            try output.write(contentsOf: out)
            done += Int64(chunk.count)
            show(.copying(share(min(1, Double(done) / Double(max(bytes, 1))))))
        }
        try output.synchronize()
        try output.close()
        guard done == bytes else { throw CocoaError(.fileReadCorruptFile) }
        return (DeviceFiles.hex(read.finalize()), DeviceFiles.hex(written.finalize()))
    }
    private func fail(_ entry: ImportEntry?, _ problem: ImportProblem) -> Outcome {
        log.record(LogEvent("device_import_failed", level: .error, ["problem": .string(problem.rawValue)]))
        if var entry {
            entry.phase = .failed
            do { try journal.append(entry) } catch { log.record(LogEvent("device_journal_failed", level: .error)) }
        }
        return .failed(problem)
    }
    func show(_ state: ImportProgress) {
        guard state != current else { return }
        current = state
        sink.yield(state)
    }
    private func mark(_ on: Bool) async {
        do { if on { try await busy?.begin(.import) } else { try await busy?.end(.import) } } catch {
            log.record(LogEvent("busy_mark_failed", level: .error))
        }
    }
}
