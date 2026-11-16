import Foundation

/// True start despite a wrong device clock (R-071, C-053): an unset clock counts back from the mount, assuming the
/// latest file ended there; the ZEPHYR names its files in its own zone.
public enum RecordingTime {
    static let calendar = Calendar(identifier: .gregorian)
    public static func start(name: String, created: Date?, modified: Date?, seconds: Double, latestModified: Date,
                             mount: Date, nameClock: Bool, offsetMinutes: Int) -> Date {
        if nameClock, let named = fromName(name, offsetMinutes: offsetMinutes),
           named.addingTimeInterval(seconds) <= mount.addingTimeInterval(600) { return named }
        if !nameClock, let created, plausible(created) { return created }
        if !nameClock, let modified, plausible(modified) { return modified.addingTimeInterval(-seconds) }
        let age = modified.map { max(0, latestModified.timeIntervalSince($0)) } ?? 0
        return mount.addingTimeInterval(-age - seconds)
    }
    static func plausible(_ date: Date) -> Bool { calendar.component(.year, from: date) >= 2025 }
    /// `yyyy_MM_dd_HH_mm_ss.wav`, only exact dates (no 30 February rolled into March).
    static func fromName(_ name: String, offsetMinutes: Int) -> Date? {
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        let parts = stem.split(separator: "_").compactMap { Int($0) }
        guard stem.count == 19, parts.count == 6, parts[0] >= 2025,
              let zone = TimeZone(secondsFromGMT: offsetMinutes * 60) else { return nil }
        var cal = calendar
        cal.timeZone = zone
        let wanted = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4],
                                    second: parts[5])
        guard let date = cal.date(from: wanted) else { return nil }
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let got = [back.year, back.month, back.day, back.hour, back.minute, back.second]
        return got == parts.map { Optional($0) } ? date : nil
    }
}
