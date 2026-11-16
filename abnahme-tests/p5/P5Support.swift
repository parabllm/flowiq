// TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert
// Shared fixtures for the P5 acceptance tests (store contract, live file, aftercare, archive).
//
// RULE: every line that touches an API shape the architecture leaves open carries "ASSUMPTION:" in
// the same line. The build agent may change ONLY those lines (names, labels, argument order, throws).
// Expected values in the test files are fixed and must never be touched.
//
// Everything here is synthetic: temp folders only, a scripted transcriber instead of ElevenLabs, a
// manual clock instead of wall time, no network, no real vault, no real live link. The test link is
// a path inside the temp folder; the real `/tmp/panotti-live.md` is never written.
import Foundation
import Synchronization
import Testing
@testable import FlowIQCore
@testable import FlowIQLog
@testable import FlowIQCloud  // COMPILE-FIX (P5 build): FlowIQPost was renamed to FlowIQCloud (M.9, ordered rename)
@testable import FlowIQStore

// MARK: - Plain value types owned by the tests

/// One contribution as the tests see it: `**[MM:SS] Speaker:** text`.
struct Line: Sendable, Equatable {
    var seconds: Int
    var speaker: String
    var text: String
}

/// Formats a contribution exactly like the contract (05b section 1.2): MM:SS, from one hour HH:MM:SS.
func formatLine(_ l: Line) -> String {
    let stamp: String
    if l.seconds >= 3600 {
        stamp = String(format: "%02d:%02d:%02d", l.seconds / 3600, (l.seconds % 3600) / 60, l.seconds % 60)
    } else {
        stamp = String(format: "%02d:%02d", l.seconds / 60, l.seconds % 60)
    }
    return "**[\(stamp)] \(l.speaker):** \(l.text)"
}

func parseLine(_ s: String) -> Line? {
    guard s.hasPrefix("**["), let close = s.firstIndex(of: "]") else { return nil }
    let stamp = s[s.index(s.startIndex, offsetBy: 3)..<close]
    let parts = stamp.split(separator: ":").compactMap { Int($0) }
    guard stamp.allSatisfy({ $0.isNumber || $0 == ":" }), parts.count == 2 || parts.count == 3 else { return nil }
    let rest = s[s.index(after: close)...]
    guard rest.hasPrefix(" "), let end = rest.range(of: ":** ") else { return nil }
    let speaker = rest[rest.index(after: rest.startIndex)..<end.lowerBound]
    let seconds = parts.count == 2 ? parts[0] * 60 + parts[1] : parts[0] * 3600 + parts[1] * 60 + parts[2]
    return Line(seconds: seconds, speaker: String(speaker), text: String(rest[end.upperBound...]))
}

func isContributionLine(_ s: String) -> Bool {
    // The pattern the live souffleur script uses: begins with `**[` plus a digit.
    s.hasPrefix("**[") && s.dropFirst(3).first?.isNumber == true
}

func isVolatileLine(_ s: String) -> Bool { s.hasPrefix("_[") && s.contains("spricht gerade") }

// MARK: - Frontmatter reader (independent of the code under test)

struct Doc {
    let keys: [String]
    let fields: [String: String]
    let body: [String]
    let bytes: Data

    func value(_ key: String) -> String? { fields[key] }
    func unquoted(_ key: String) -> String? {
        guard var v = fields[key] else { return nil }
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        return v
    }
    var contributions: [String] { body.filter(isContributionLine) }
    var lines: [Line] { contributions.compactMap(parseLine) }
}

func readDoc(_ url: URL) throws -> Doc {
    let bytes = try Data(contentsOf: url)
    let text = String(decoding: bytes, as: UTF8.self)
    var all = text.components(separatedBy: "\n")
    var keys: [String] = []
    var fields: [String: String] = [:]
    guard all.first == "---" else { return Doc(keys: [], fields: [:], body: all, bytes: bytes) }
    all.removeFirst()
    while let line = all.first {
        all.removeFirst()
        if line == "---" { break }
        guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("-") else { continue }
        let key = String(line[..<colon])
        keys.append(key)
        fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return Doc(keys: keys, fields: fields, body: all, bytes: bytes)
}

// MARK: - Manual clock

final class TestClock: Sendable {
    private let time: Mutex<Date>
    init(_ start: Date) { time = Mutex(start) }
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    let parts = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    return Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: 0)
}

func stampString(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH-mm-ss"
    return f.string(from: date)
}

// MARK: - Assumed API surface (one place to adapt)

enum Kind: Sendable { case call, room }

/// What the scripted transcriber does on one call.
enum Outcome: Sendable {
    case success([Line], speakers: Int)
    case fail(PostFailure)
}

/// A recorded upload request, seen from the transcriber's side.
struct SeenRequest: Sendable {
    var audio: [URL]
    var audioExisted: [Bool]
    var language: String
    var terms: [String]
}

actor FakePost: PostProcessor {  // ASSUMPTION: protocol PostProcessor (Fassung 3 name of the single interface of A.10, M.2) with one async throwing method
    nonisolated let name = "elevenlabs-scribe-v2"  // COMPILE-FIX (P5 build): PostProcessor requires the service name (M.2 `var name`)
    private var script: [Outcome]
    private let fallback: Outcome
    private(set) var seen: [SeenRequest] = []

    init(script: [Outcome] = [], fallback: Outcome? = nil) {
        self.script = script
        self.fallback = fallback ?? .success(
            [Line(seconds: 0, speaker: "Mara", text: "Neufassung eins."),
             Line(seconds: 5, speaker: "Gegenseite (speaker_0)", text: "Neufassung zwei.")], speakers: 2)
    }

    var callCount: Int { seen.count }

    func process(_ request: PostJob) async throws -> PostTranscript {  // ASSUMPTION: process(_ job: PostJob) async throws -> PostTranscript (M.2)
        let urls = request.audio  // ASSUMPTION: PostRequest.audio is [URL] (call: two tracks, room: one)
        seen.append(SeenRequest(audio: urls, audioExisted: urls.map { FileManager.default.fileExists(atPath: $0.path) },
                                language: request.language,  // ASSUMPTION: PostRequest.language is the short code "de" or "en"
                                terms: request.terms))  // ASSUMPTION: PostRequest.terms is [String]
        let outcome = script.isEmpty ? fallback : script.removeFirst()
        switch outcome {
        case .success(let lines, let speakers):
            return PostTranscript(segments: lines.map { PostSegment(start: Double($0.seconds), speaker: $0.speaker, text: $0.text) },  // ASSUMPTION: PostTranscript(segments:speakersDetected:) and PostSegment(start:speaker:text:)
                              speakersDetected: speakers)
        case .fail(let failure):
            throw failure
        }
    }
}

// PostFailure cases used by the tests:
//   .networkDown, .quotaExhausted, .keyMissing, .server(status: Int)  // ASSUMPTION: these four case names of PostFailure: Error

enum Trigger { case appStart, networkBack, click, timer }

/// Everything a test needs, rooted in one temp folder.
struct Rig {
    let root: URL
    let paths: Paths
    let transcripts: URL
    let raw: URL
    let archiveAudio: URL
    let liveLink: URL
    let nachlauf: URL
    let fassungen: URL
    let logDir: URL
    let clock: TestClock
    let fs: SafeFS
    let log: EventLog
    let store: TranscriptStore
    let queue: PostQueue
    let aftercare: Aftercare
    let post: FakePost

    var queueFile: URL { nachlauf.appending(path: "warteschlange.jsonl") }  // path named in A.10

    static func make(post: FakePost = FakePost(), postEnabled: Bool = true, speaker: String = "Mara",
                     terms: [String] = [], start: Date = localDate(2026, 11, 13, 10, 0)) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p5-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = Paths(profile: .development, applicationSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory))
        let vault = root.appending(path: "vault", directoryHint: .isDirectory)
        let transcripts = vault.appending(path: "pipelines/audio/transcripts", directoryHint: .isDirectory)
        let raw = vault.appending(path: "pipelines/audio/raw", directoryHint: .isDirectory)
        let archive = root.appending(path: "Archive/audio-raw", directoryHint: .isDirectory)
        let link = root.appending(path: "links/live.md")
        for dir in [transcripts, transcripts.appending(path: "archive"), raw, archive, link.deletingLastPathComponent(),
                    paths.support, paths.laufend, paths.log, paths.support.appending(path: "nachlauf"), paths.support.appending(path: "fassungen")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fs = SafeFS(confinedTo: root)
        return try assemble(root: root, paths: paths, transcripts: transcripts, raw: raw, archive: archive, link: link,
                            fs: fs, post: post, postEnabled: postEnabled, speaker: speaker, terms: terms,
                            clock: TestClock(start))
    }

    private static func assemble(root: URL, paths: Paths, transcripts: URL, raw: URL, archive: URL, link: URL, fs: SafeFS,
                                 post: FakePost, postEnabled: Bool, speaker: String, terms: [String], clock: TestClock) throws -> Rig {
        let logDir = paths.log
        let log = EventLog(directory: logDir, fs: fs)
        let nachlauf = paths.support.appending(path: "nachlauf", directoryHint: .isDirectory)
        let fassungen = paths.support.appending(path: "fassungen", directoryHint: .isDirectory)
        let locations = StoreLocations(transcripts: transcripts, raw: raw, archiveAudio: archive, liveLink: link, dataFolder: paths.support)  // ASSUMPTION: StoreLocations(transcripts:raw:archiveAudio:liveLink:dataFolder:); dataFolder holds laufend/ and fassungen/
        let store = TranscriptStore(locations: locations, fs: fs, log: log, speakerName: speaker, now: { clock.now })  // ASSUMPTION: TranscriptStore(locations:fs:log:speakerName:now:)
        let queue = PostQueue(folder: nachlauf, fs: fs, log: log, now: { clock.now })  // ASSUMPTION: PostQueue(folder:fs:log:now:) persists to <folder>/warteschlange.jsonl
        let aftercare = Aftercare(store: store, queue: queue, processor: post, postEnabled: [.call: postEnabled, .room: postEnabled],  // ASSUMPTION: Aftercare(store:queue:processor:postEnabled:confirmedTerms:now:) with the switch per mode (M.1), the coordinator of B.2 point 8, placed in FlowIQCloud
                                  confirmedTerms: { terms }, now: { clock.now })
        return Rig(root: root, paths: paths, transcripts: transcripts, raw: raw, archiveAudio: archive, liveLink: link,
                   nachlauf: nachlauf, fassungen: fassungen, logDir: logDir, clock: clock, fs: fs, log: log,
                   store: store, queue: queue, aftercare: aftercare, post: post)
    }

    /// A fresh app process on the same folders: new store, new queue, new coordinator, new transcriber.
    func restarted(post newPost: FakePost, postEnabled: Bool = true, terms: [String] = []) throws -> Rig {
        try Rig.assemble(root: root, paths: paths, transcripts: transcripts, raw: raw, archive: archiveAudio, link: liveLink,
                         fs: fs, post: newPost, postEnabled: postEnabled, speaker: "Mara", terms: terms, clock: clock)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    // MARK: Recording helpers (the tests only use these)

    func begin(_ kind: Kind, at date: Date, language: String = "de") async throws -> LiveTranscript {  // ASSUMPTION: type LiveTranscript is the live-file handle of A.9
        try await store.beginLive(kind: kind == .call ? .call : .room, startedAt: date, language: language)  // ASSUMPTION: beginLive(kind:startedAt:language:) throws, kinds .call and .room
    }

    /// Hands one finished contribution over; `flush: true` (default) waits until it is on disk.
    func add(_ live: LiveTranscript, _ l: Line, dictation: Bool = false, flush: Bool = true) async {
        await live.append(seconds: l.seconds, speaker: l.speaker, text: l.text, dictation: dictation)  // ASSUMPTION: append(seconds:speaker:text:dictation:) adds one finished contribution; dictation adds the suffix " (Diktat)" to the speaker
        if flush { await sync(live) }
    }

    func volatile(_ live: LiveTranscript, _ l: Line) async {
        await live.setVolatile(seconds: l.seconds, speaker: l.speaker, text: l.text)  // ASSUMPTION: setVolatile(seconds:speaker:text:) sets the single "spricht gerade" closing line
        await sync(live)
    }

    func clearVolatile(_ live: LiveTranscript) async {
        await live.clearVolatile()  // ASSUMPTION: clearVolatile() removes the closing line
        await sync(live)
    }

    /// Everything handed over so far is on disk (the throttled writer must offer this; R-053 allows up to 5 s otherwise).
    func sync(_ live: LiveTranscript) async {
        await live.flush()  // ASSUMPTION: flush() writes all handed-over text to disk before returning
    }

    /// Stop: the file goes to live-lokal, the job (or final-lokal) follows; waits until background work is idle.
    func finish(_ live: LiveTranscript, seconds: Double, raw item: URL) async throws {
        try await aftercare.finish(live, durationSeconds: seconds, rawAudio: item)  // ASSUMPTION: finish(_:durationSeconds:rawAudio:) throws; rawAudio is the call folder or the raum file in raw/
        await aftercare.settle()  // ASSUMPTION: settle() returns when no attempt is running and nothing is due
    }

    func setPost(_ on: Bool) async {
        await aftercare.setPostEnabled(on)  // ASSUMPTION: setPostEnabled(_:) is the aftercare switch of A.10, changeable at run time
    }

    func settle() async {
        await aftercare.settle()  // ASSUMPTION: settle() returns when no attempt is running and nothing is due
    }

    func upgrade(_ urls: [URL]) async throws {
        throw R061Struck()  // ASSUMPTION: upgrade(_ urls: [URL]) queues finished local recordings for the same in-place aftercare (R-061); it refuses files with status verarbeitet. R-061 STRUCK (K-33, Anhang K Nr. 4): not built in v1, nothing is ever upgraded later
    }

    struct LocalEntry { var url: URL; var minutes: Int }
    struct R061Struck: Error {}  // R-061 STRUCK (K-33, Anhang K Nr. 4): what the stubs above throw

    func localOnly() async -> [LocalEntry] {
        []  // ASSUMPTION: localOnly() lists the final-lokal recordings, element fields url and minutes (whole minutes of the recorded duration). R-061 STRUCK (K-33, Anhang K Nr. 4): no such list in v1
    }

    func trigger(_ t: Trigger) async {
        switch t {
        case .appStart: await aftercare.trigger(.appStart)  // ASSUMPTION: trigger(_:) with cases appStart, networkBack, click, timer (timer = "look at what is due by the clock")
        case .networkBack: await aftercare.trigger(.networkBack)  // ASSUMPTION: see above
        case .click: await aftercare.trigger(.click)  // ASSUMPTION: see above
        case .timer: await aftercare.trigger(.timer)  // ASSUMPTION: see above
        }
        await aftercare.settle()
    }

    enum Visible: Equatable { case idle, waiting(Int), paused(Int) }

    func visible() async -> Visible {
        switch await aftercare.visibleState {  // ASSUMPTION: visibleState is what pill or menu show: .idle, .waiting(count:), .paused(count:)
        case .idle: return .idle
        case .waiting(let n): return .waiting(n)
        case .paused(let n): return .paused(n)
        }
    }

    func pending() async -> Int { await queue.count }  // ASSUMPTION: PostQueue.count = number of open jobs

    func recoverOrphans() async throws -> [URL] {
        try await store.recoverOrphans()  // ASSUMPTION: recoverOrphans() returns the transcript files rebuilt from leftover journals in laufend/
    }

    // MARK: Fixtures and probes

    /// A raw recording as the recorder leaves it in `raw/`: call folder with two tracks, raum file with one.
    func makeRaw(_ kind: Kind, at date: Date, seconds: Double, bytesPerSecond: Int = 12_000) throws -> URL {
        let stamp = stampString(date)
        let size = Int(seconds * Double(bytesPerSecond))
        func fill(_ url: URL, salt: UInt8) throws {
            var state = UInt64(salt) &+ 99
            var data = Data(capacity: size)
            for _ in 0..<size {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                data.append(UInt8(truncatingIfNeeded: state >> 33))
            }
            try data.write(to: url)
        }
        switch kind {
        case .call:
            let folder = raw.appending(path: "\(stamp) Call", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fill(folder.appending(path: "\(stamp) mikrofon.m4a"), salt: 1)
            try fill(folder.appending(path: "\(stamp) desktop.m4a"), salt: 2)
            return folder
        case .room:
            let file = raw.appending(path: "\(stamp) raum.m4a")
            try fill(file, salt: 3)
            return file
        }
    }

    var transcriptFiles: [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func events() async -> [[String: Any]] {
        await log.flush()
        var out: [[String: Any]] = []
        for name in names(in: logDir) {
            guard let text = try? String(contentsOf: logDir.appending(path: name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { out.append(obj) }
            }
        }
        return out
    }

    func errorEvents(prefix: String = "") async -> [[String: Any]] {
        await events().filter { ($0["level"] as? String) == "error" && (($0["kind"] as? String) ?? "").hasPrefix(prefix) }
    }

    /// Where the audio of one recording lies now: raw and archive, by item name.
    func locations(of item: URL) -> (inRaw: Bool, inArchive: Bool) {
        let name = item.lastPathComponent
        let fm = FileManager.default
        return (fm.fileExists(atPath: raw.appending(path: name).path), fm.fileExists(atPath: archiveAudio.appending(path: name).path))
    }

    /// Total bytes of all files below a folder (call folders count their tracks).
    func bytes(below dir: URL) -> Int {
        let own = try? dir.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])  // TEST-FIX (geprüft, Prüfnotiz Nr. 1): a room recording is one file, the enumerator yields nothing for it
        if own?.isRegularFile == true { return own?.fileSize ?? 0 }  // TEST-FIX (geprüft, Prüfnotiz Nr. 1): a regular file counts its own size
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}

/// Reads the symbolic link destination, nil when the link is missing or no link.
func linkDestination(_ link: URL) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
}

func samePath(_ a: String?, _ b: URL) -> Bool {
    guard let a else { return false }
    return URL(filePath: a).resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
}

func inode(_ url: URL) -> UInt64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64) ?? nil
}

/// Deterministic pseudo-random numbers for the property test.
struct Lcg {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

let sampleLines: [Line] = [
    Line(seconds: 3, speaker: "Mara", text: "Guten Morgen, wir starten."),
    Line(seconds: 11, speaker: "Gegenseite", text: "Hallo, Größe, Übung, Straße."),
    Line(seconds: 62, speaker: "Mara", text: "Zweite Minute."),
    Line(seconds: 3725, speaker: "Gegenseite", text: "Nach einer Stunde."),
]

// MARK: - Development-profile fixture

/// A store wired like the development profile: SafeFS from `Paths(profile: .development)`, whose allow list
/// is the support folder only (plus the dev link). `vault` lies OUTSIDE the support folder, so every
/// write there must be refused. Everything is below one temp root; no real vault path is involved.
struct DevRig {
    let root: URL
    let paths: Paths
    let outsideVault: URL
    let insideVault: URL
    let fs: SafeFS
    let log: EventLog

    static func make() throws -> DevRig {
        let root = FileManager.default.temporaryDirectory.appending(path: "flowiq-p5dev-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = Paths(profile: .development, applicationSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory))
        let outside = root.appending(path: "RealVaultStandIn/pipelines/audio", directoryHint: .isDirectory)
        let inside = paths.support.appending(path: "test-vault/pipelines/audio", directoryHint: .isDirectory)
        for dir in [outside.appending(path: "transcripts"), outside.appending(path: "raw"),
                    inside.appending(path: "transcripts"), inside.appending(path: "raw"), paths.laufend, paths.log,
                    paths.support.appending(path: "nachlauf"), paths.support.appending(path: "fassungen")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fs = SafeFS(paths: paths, vault: [outside])
        return DevRig(root: root, paths: paths, outsideVault: outside, insideVault: inside, fs: fs,
                      log: EventLog(directory: paths.log, fs: fs))
    }

    func store(vault: URL, link: URL) -> TranscriptStore {
        let locations = StoreLocations(transcripts: vault.appending(path: "transcripts"), raw: vault.appending(path: "raw"),  // ASSUMPTION: same StoreLocations as in Rig
                                       archiveAudio: root.appending(path: "Archive/audio-raw"), liveLink: link, dataFolder: paths.support)
        return TranscriptStore(locations: locations, fs: fs, log: log, speakerName: "Mara", now: { localDate(2026, 11, 13, 10, 45) })  // ASSUMPTION: same TranscriptStore init as in Rig
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// What lstat says about a path that the tests must never change (name, kind, size, modification time).
struct PathFingerprint: Equatable {
    var exists: Bool
    var target: String?
    var modified: Date?
    var inode: UInt64?

    init(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        exists = attrs != nil
        target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        modified = attrs?[.modificationDate] as? Date
        inode = attrs?[.systemFileNumber] as? UInt64
    }
}
