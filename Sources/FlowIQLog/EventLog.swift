import os

/// Rolling NDJSON event log (A.2, R-089): `record` never blocks, one utility task does all I/O; errors also go to
/// `fehler.ndjson`.
public final class EventLog: Sendable {
    /// Defaults keep the whole log at 50 MB or less (R-089): 4 x 10 MB events plus 2 x 5 MB errors.
    public struct Limits: Sendable {
        public var eventBytes = 10_000_000, eventFiles = 4, errorBytes = 5_000_000, errorFiles = 2
        public init() {}
    }
    private enum Item: Sendable { case event(LogEvent), flush(CheckedContinuation<Void, Never>) }
    private let input: AsyncStream<Item>.Continuation
    public init(directory: URL, fs: SafeFS, limits: Limits = Limits()) {
        let (stream, input) = AsyncStream<Item>.makeStream(bufferingPolicy: .unbounded)
        self.input = input
        Task.detached(priority: .utility) {
            var events = RotatingFile(fs: fs, directory: directory, base: "ereignisse",
                                      maxBytes: limits.eventBytes, keep: limits.eventFiles)
            var errors = RotatingFile(fs: fs, directory: directory, base: "fehler",
                                      maxBytes: limits.errorBytes, keep: limits.errorFiles)
            let encoder = LineEncoder()
            let fallback = Logger(subsystem: "de.flowiq", category: "log")
            for await item in stream {
                switch item {
                case .event(let event):
                    do {
                        let line = try encoder.line(event)
                        try events.append(line)
                        if event.level == .error { try errors.append(line) }
                    } catch {
                        fallback.error("event log write failed: \(error.localizedDescription, privacy: .public)")
                    }
                case .flush(let done):
                    done.resume()
                }
            }
            events.close()
            errors.close()
        }
    }
    /// A log that may write only into its own folder.
    public convenience init(directory: URL, limits: Limits = Limits()) {
        self.init(directory: directory, fs: SafeFS(confinedTo: directory), limits: limits)
    }
    deinit { input.finish() }
    public func record(_ event: LogEvent) { input.yield(.event(event)) }
    /// Runs `work`; a thrown error becomes the error event `kind` (Leitsatz 5, Paket V A10). False on an error.
    @discardableResult public func attempt(_ kind: String, _ fields: [String: LogValue] = [:],
                                           _ work: () throws -> Void) -> Bool {
        do { try work() } catch { record(.failure(kind, error, fields)); return false }
        return true
    }
    @discardableResult nonisolated(nonsending) public func attempt(_ kind: String, _ fields: [String: LogValue] = [:],
                                                                   _ work: () async throws -> Void) async -> Bool {
        do { try await work() } catch { record(.failure(kind, error, fields)); return false }
        return true
    }
    /// Returns once every event recorded before this call is on disk (tests, shutdown).
    public func flush() async {
        await withCheckedContinuation { input.yield(.flush($0)) }
    }
}

/// `<base>.ndjson` is current, `<base>-1.ndjson` the one before, up to `keep` files in total.
struct RotatingFile {
    let fs: SafeFS, directory: URL, base: String, maxBytes: Int, keep: Int
    private var handle: FileHandle?, size = 0
    init(fs: SafeFS, directory: URL, base: String, maxBytes: Int, keep: Int) {
        (self.fs, self.directory, self.base, self.maxBytes, self.keep) = (fs, directory, base, maxBytes, max(1, keep))
    }
    func url(_ index: Int) -> URL {
        directory.appending(path: index == 0 ? "\(base).ndjson" : "\(base)-\(index).ndjson")
    }
    mutating func append(_ line: Data) throws {
        if handle == nil { try open() }
        if size > 0, size + line.count > maxBytes { try rotate() }
        guard let handle else { return }
        try handle.write(contentsOf: line)
        size += line.count
    }
    mutating func close() {
        do { try handle?.close() } catch {
            Logger(subsystem: "de.flowiq", category: "log")
                .error("close failed: \(error.localizedDescription, privacy: .public)")
        }
        handle = nil
    }
    private mutating func open() throws {
        let opened = try fs.appendHandle(url(0))
        size = Int(try opened.offset())
        handle = opened
    }
    private mutating func rotate() throws {
        close()
        let exists = { (file: URL) in FileManager.default.fileExists(atPath: file.path) }
        if exists(url(keep - 1)) { try fs.delete(url(keep - 1)) }
        for index in stride(from: keep - 2, through: 0, by: -1) where exists(url(index)) {
            try fs.move(url(index), to: url(index + 1))
        }
        try open()
    }
}
