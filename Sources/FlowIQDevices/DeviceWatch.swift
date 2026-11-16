import AppKit
import FlowIQCore
import FlowIQLog
import Foundation

/// Mount watching through `NSWorkspace` (V-l), only while the devices switch is on (R-076). The app calls
/// `refresh()` after a switch change and `scan()` once at launch for what is already plugged in. A mount is
/// scanned, an unmount only looked at; a replaced watch (new storage place) is stopped and keeps no observer.
@MainActor public final class DeviceWatch {
    let importer: DeviceImporter
    private var tokens: [any NSObjectProtocol] = [], ended = false
    public var observing: Bool { !tokens.isEmpty }
    public init(importer: DeviceImporter) { self.importer = importer }
    /// For good: the observers go (16.11.: before, every change of the storage place left two behind).
    public func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        Census.add("mount_observers", -tokens.count)
        (tokens, ended) = ([], true)
    }
    public func refresh() async {
        let center = NSWorkspace.shared.notificationCenter, on = await importer.config.enabled
        if !on || ended {
            tokens.forEach(center.removeObserver)
            Census.add("mount_observers", -tokens.count)
            tokens = []
        } else if tokens.isEmpty {
            Census.add("mount_observers", 2)
            tokens = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self, importer] _ in
                    Task {
                        guard await self?.observing == true else { return }
                        if name == NSWorkspace.didMountNotification { _ = await importer.scan() } else {
                            await importer.look(announce: true)
                        }
                    }
                }
            }
        }
    }
    /// Mounted volumes with identifier, name and write protection; reads only.
    public nonisolated static func mounted() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: .skipHiddenVolumes) ?? []
        return urls.compactMap { url in
            do {
                let v = try url.resourceValues(forKeys: Set(keys))
                guard let uuid = v.volumeUUIDString else { return nil }
                return MountedVolume(url: url, uuid: uuid, name: v.volumeName ?? "",
                                     readOnly: v.volumeIsReadOnly ?? false)
            } catch { return nil }  // a volume that went away while listing
        }
    }
}

/// Panotti's journal line as its `JSONEncoder` wrote it (05a B57), only what FlowIQ needs.
struct PanottiRecord: Decodable {
    let contentSHA256: String, deviceSHA256: String?, fastFingerprint: String, fileSizeBytes: Int64
    let deviceName: String, sourceFileName: String, recordedAt: Date, phase: String, durationSeconds: Double?
    let localRawWAVPath: String?, vaultTranscriptPath: String?
}

struct PanottiIgnored: Decodable { let device: String, name: String, size: Int64 }

/// What one click would take over (A.11, R-008); `known` counts lines whose identity FlowIQ already has.
public struct TakeoverPlan: Sendable, Equatable {
    public let entries: [ImportEntry], ignored: [ImportEntry], known: Int, failedInPanotti: Int
    public let byKind: [DeviceKind: Int], clockOffsetMinutes: Int?
}

extension DeviceImporter {
    /// Dry run: Panotti's journal and ignore list from a chosen folder, its settings from a chosen file; writes
    /// nothing. An unreadable journal throws: it is never taken over in part.
    public func takeoverPlan(from folder: URL, settings: URL?) throws -> TakeoverPlan {
        let decoder = JSONDecoder(), ignoredFile = folder.appending(path: "external-ignored-files.json")
        let records = try decoder.decode([PanottiRecord].self,
                                         from: Data(contentsOf: folder.appending(path: "external-imports.json")))
        let ignored = FileManager.default.fileExists(atPath: ignoredFile.path)
            ? try decoder.decode([PanottiIgnored].self, from: Data(contentsOf: ignoredFile)) : []
        func kind(_ device: String) -> DeviceKind { device.hasPrefix("ZEPHYR") ? .zephyr : .dvt1600 }
        // Every line counts as done, a failed one too: nothing taken over goes to the after-run again.
        let entries = records.map { r in
            ImportEntry(sha256: r.deviceSHA256 ?? r.contentSHA256, bytes: r.fileSizeBytes,
                        fingerprint: r.fastFingerprint,
                        kind: kind(r.deviceName), name: r.sourceFileName, phase: .done, recordedAt: r.recordedAt,
                        seconds: r.durationSeconds, audio: r.localRawWAVPath, transcript: r.vaultTranscriptPath,
                        copySHA256: r.deviceSHA256 == nil ? nil : r.contentSHA256, origin: "panotti")
        }
        let skipped = ignored.map {
            ImportEntry(sha256: "", bytes: $0.size, fingerprint: "", kind: kind($0.device), name: $0.name,
                        phase: .ignored, origin: "panotti")
        }
        var offset: Int?
        if let settings {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: settings), format: nil)
            offset = (plist as? [String: Any])?["zephyrClockUTCOffsetMinutes"] as? Int
        }
        return TakeoverPlan(entries: entries, ignored: skipped,
                            known: (entries + skipped).filter { journal.entries[$0.key] != nil }.count,
                            failedInPanotti: records.filter { $0.phase == "Fehler" }.count,
                            byKind: Dictionary(grouping: entries, by: \.kind).mapValues(\.count),
                            clockOffsetMinutes: offset)
    }
    /// The click: every line with a new identity goes into the journal, line for line; returns the lines written.
    @discardableResult public func takeover(_ plan: TakeoverPlan) throws -> Int {
        let have = Set(journal.entries.keys), new = (plan.entries + plan.ignored).filter { !have.contains($0.key) }
        try fs.makeFolder(folders.data)
        for entry in new { try journal.append(entry) }
        if let offset = plan.clockOffsetMinutes, offset != config.clockOffsetMinutes {
            config.clockOffsetMinutes = offset
            try save()
        }
        log.record(LogEvent("device_takeover", ["lines": .int(Int64(new.count))]))
        return new.count
    }
}
