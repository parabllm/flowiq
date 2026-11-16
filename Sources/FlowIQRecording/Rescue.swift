import AVFoundation

public struct RescuedTrack: Sendable { public let url: URL, seconds: Double }
public struct RescueReport: Sendable { public var rescuedTracks: [RescuedTrack] = [], failed: [URL] = [] }

/// At launch (A.5, R-039): dead folders repacked and delivered, else to `zu-pruefen/`; nothing unread deleted.
public enum Rescue {
    public static func run(laufend: URL, deliverTo: URL, fs: SafeFS, log: EventLog, lock: RecordingLock? = nil,
                           review: URL? = nil) async throws -> RescueReport {
        let own = lock == nil ? try RecordingLock.acquire(in: laufend) : nil
        defer { own?.release() }
        let review = review ?? laufend.deletingLastPathComponent().appending(path: "zu-pruefen")
        var report = RescueReport()
        for folder in try entries(laufend).filter(isFolder) {
            var (tracks, failed) = ([RescuedTrack](), [URL]())
            for file in try entries(folder) where file.pathExtension == "aac" {
                do { if try Remux.toM4A(file, fs: fs, log: log).keptSource { failed.append(file) } } catch {
                    failed.append(file)
                }
            }
            for file in try entries(folder) where file.pathExtension == "m4a" && !file.path.hasSuffix(".teil.m4a") {
                do {
                    let audio = try AVAudioFile(forReading: file)
                    tracks.append(RescuedTrack(url: file, seconds: Double(audio.length) / audio.fileFormat.sampleRate))
                } catch {
                    failed.append(file)
                }
            }
            if tracks.isEmpty && failed.isEmpty { failed.append(folder) }  // an empty folder is reported too
            var moved = false
            for parent in failed.isEmpty && !tracks.isEmpty ? [deliverTo, review] : [review] where !moved {
                let target = parent.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
                do {
                    try fs.makeFolder(parent)
                    try fs.move(folder, to: target)
                    moved = true
                    guard parent == deliverTo else { continue }
                    report.rescuedTracks += tracks.map {
                        RescuedTrack(url: target.appending(path: $0.url.lastPathComponent), seconds: $0.seconds)
                    }
                } catch {
                    failed.append(target)
                }
            }
            report.failed += failed
        }
        for file in report.failed {
            log.record(LogEvent("rescue_failed", level: .error, ["type": .string(file.pathExtension)]))
        }
        if !report.rescuedTracks.isEmpty || !report.failed.isEmpty {
            log.record(LogEvent("rescued", level: report.failed.isEmpty ? .info : .error, [
                "tracks": .int(Int64(report.rescuedTracks.count)), "failed": .int(Int64(report.failed.count)),
                "ms": .double(report.rescuedTracks.reduce(0) { $0 + $1.seconds } * 1000),
            ]))
        }
        return report
    }
    /// Built from the names: the URLs the system returns may resolve symlinks and miss the allow list.
    private static func entries(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
            .map { folder.appending(path: $0) }
    }
    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }
}
