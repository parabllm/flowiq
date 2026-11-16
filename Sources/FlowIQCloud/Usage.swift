/// Seconds sent per source, kind and month (M.8, R-101) plus dollars per service; unreadable is set aside.
public actor UsageMeter: CloudUsage {
    private let file: URL, fs: SafeFS, now: @Sendable () -> Date, limit: Int?, log: EventLog?
    private var months: [String: [String: Double]] = [:], saved: Date?, blocked = false
    public init(folder: URL, fs: SafeFS, now: @escaping @Sendable () -> Date = { Date() },
                monthLimitMinutes: Int? = nil, log: EventLog? = nil) {
        (file, self.fs, self.now, limit) = (folder.appending(path: "verbrauch.json"), fs, now, monthLimitMinutes)
        self.log = log
        if let read = JSON.read(file, or: months) { months = read } else {
            let aside = folder.appending(path: "verbrauch.unlesbar-\(Int(now().timeIntervalSince1970)).json")
            do { try fs.move(file, to: aside) } catch { blocked = true }
            log?.record(LogEvent("usage_unreadable", level: .error, ["set_aside": .bool(!blocked)]))
        }
    }
    var month: String { now().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month()) }
    public func record(_ source: UsageSource, _ kind: UsageKind, seconds: Double) {
        months[month, default: [:]]["\(source.rawValue)/\(kind.rawValue)", default: 0] += seconds
        if saved.map({ now().timeIntervalSince($0) >= 10 }) ?? true { flush() }
    }
    public func seconds(_ source: UsageSource, _ kind: UsageKind, month: String? = nil) -> Double {
        months[month ?? self.month]?["\(source.rawValue)/\(kind.rawValue)"] ?? 0
    }
    public func monthTotalSeconds() -> Double {
        months[month]?.filter { !$0.key.hasPrefix("cost/") }.values.reduce(0, +) ?? 0
    }
    /// Estimated or reported US dollars of a service this month (OpenRouter's model price, 16.11.).
    public func recordCost(_ service: String, usd: Double) {
        months[month, default: [:]]["cost/\(service)", default: 0] += usd
    }
    public func costUSD(_ service: String, month: String? = nil) -> Double {
        months[month ?? self.month]?["cost/\(service)"] ?? 0
    }
    public var limitReached: Bool { limit.map { monthTotalSeconds() >= Double($0) * 60 } ?? false }
    public var hasAnyUsage: Bool {
        months.values.contains { $0.contains { !$0.key.hasPrefix("cost/") && $0.value > 0 } }
    }
    public func flush() {
        guard !blocked else { return }
        saved = now()
        do {  // the folder is made here: nothing else creates it (16.11.: every save failed, `usage_unsaved`)
            try fs.makeFolder(file.deletingLastPathComponent())
            try fs.replace(file, with: JSONEncoder().encode(months))
        } catch { log?.record(LogEvent("usage_unsaved", level: .error)) }  // the next try follows in 10 s
    }
    public func menuLine() -> String {
        let reached = limitReached ? ", Monatsgrenze erreicht" : limit.map { ", Grenze \($0) min" } ?? ""
        return "Cloud diesen Monat: \(Int((monthTotalSeconds() / 60).rounded())) min" + reached
    }
    public func detailLines() -> [String] {
        (months[month] ?? [:]).filter { $0.value > 0 }.sorted { $0.key < $1.key }.map {
            $0.key.hasPrefix("cost/") ? String(format: "%@: %.2f USD", $0.key, $0.value)
                : "\($0.key): \(Int(($0.value / 60).rounded())) min"
        }
    }
}

public enum BadgeSurface: Sendable { case pill, menuBar }
public enum BadgeState: Sendable { case sending, fallback, waitingForNetwork }

/// The cloud mark follows the sending (M.6, R-099): live on pill and menu bar, an upload on the menu bar only.
public final class CloudBadge: Sendable {
    private let now: @Sendable () -> Date
    private let state = Mutex<(packets: [String: Date], uploads: Set<String>)>(([:], []))
    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }
    public func packetSent(stream: String) { state.withLock { [t = now()] in $0.packets[stream] = t } }
    public func streamClosed(_ stream: String) { state.withLock { _ = $0.packets.removeValue(forKey: stream) } }
    public func uploadStarted(id: String, mode: RecordingMode) { state.withLock { _ = $0.uploads.insert(id) } }
    public func uploadFinished(id: String) { state.withLock { _ = $0.uploads.remove(id) } }
    public func isVisible(on surface: BadgeSurface) -> Bool {
        let t = now()
        return state.withLock { s in
            s.packets.values.contains { t.timeIntervalSince($0) <= 1 } || surface == .menuBar && !s.uploads.isEmpty
        }
    }
    public func menuLine(for state: BadgeState, cloudSeconds: Double) -> String {
        let minutes = "\(Int((cloudSeconds / 60).rounded())) min Cloud"
        switch state {
        case .sending: return "Live über ElevenLabs, sendet, \(minutes)"
        case .fallback: return "Live über Apple lokal (Rückfall), \(minutes)"
        case .waitingForNetwork: return "Wartet auf Netz, \(minutes)"
        }
    }
}

/// The usage meter with a limit that may change while running (R-101) and a counter per source for `cloud_minuten`.
public actor MonthUsage: CloudUsage {
    public let meter: UsageMeter
    public var limitMinutes: Int?
    private var sent: [UsageSource: Double] = [:]
    public init(meter: UsageMeter, limitMinutes: Int?) { (self.meter, self.limitMinutes) = (meter, limitMinutes) }
    public func record(_ source: UsageSource, _ kind: UsageKind, seconds: Double) async {
        sent[source, default: 0] += seconds
        await meter.record(source, kind, seconds: seconds)
    }
    public var limitReached: Bool {
        get async { if let l = limitMinutes { await meter.monthTotalSeconds() >= Double(l * 60) } else { false } }
    }
    public func setLimit(_ minutes: Int?) { limitMinutes = minutes }
    public func seconds(_ sources: [UsageSource]) -> Double { sources.reduce(0) { $0 + (sent[$1] ?? 0) } }
}
