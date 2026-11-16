/// What keeps FlowIQ from being replaced (A.1, R-050), mirrored to `laufend/.belegt` for `scripts/bundle.sh`.
public actor BusyState {
    public enum Reason: String, Sendable, CaseIterable { case recording, dictation, `import`, post }
    public nonisolated let file: URL
    private let fs: SafeFS, pid: Int32
    private var counts: [Reason: Int] = [:]
    private var since = Date.now
    public init(paths: Paths, fs: SafeFS, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        (file, self.fs, self.pid) = (paths.laufend.appending(path: ".belegt"), fs, pid)
    }
    public var reasons: Set<Reason> { Set(counts.filter { $0.value > 0 }.keys) }
    /// Reasons may overlap (room plus call): every `begin` needs its own `end`.
    public func begin(_ reason: Reason) throws {
        if reasons.isEmpty { since = .now }
        counts[reason, default: 0] += 1
        try mirror()
    }
    public func end(_ reason: Reason) throws {
        guard let count = counts[reason], count > 0 else { return }
        counts[reason] = count - 1
        try mirror()
    }
    private func mirror() throws {
        guard !reasons.isEmpty else {
            if FileManager.default.fileExists(atPath: file.path) { try fs.delete(file) }
            return
        }
        let body: [String: Any] = ["pid": Int(pid), "since": since.formatted(.iso8601),
                                   "reasons": reasons.map(\.rawValue).sorted()]
        try fs.replace(file, with: JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
    }
}
