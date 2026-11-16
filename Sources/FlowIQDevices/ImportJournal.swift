import CryptoKit
import FlowIQCore
import Foundation

/// One line of `journal.jsonl` per phase (B.4). Identity is SHA-256 of the device file plus size (C-052); the fast
/// fingerprint only spares reading a known file again; the name is information, except in Panotti's ignore list.
public struct ImportEntry: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable { case copied, transcribed, done, failed, ignored }
    public var sha256: String, bytes: Int64, fingerprint: String, kind: DeviceKind, name: String, phase: Phase
    public var recordedAt: Date? = nil, seconds: Double? = nil, audio: String? = nil, transcript: String? = nil
    public var copySHA256: String? = nil, origin: String? = nil  // copy hash after a header repair; "panotti"
    var key: String { sha256.isEmpty ? "\(kind.rawValue)|\(name)|\(bytes)" : "\(sha256)|\(bytes)" }
}

/// Append only (G12); a torn last line is cut before the next, any other unreadable line stops the import (B61).
struct ImportJournal {
    let url: URL, fs: SafeFS
    private(set) var entries: [String: ImportEntry] = [:], order: [String] = [], unreadable = false
    private var tornAt: UInt64?
    init(url: URL, fs: SafeFS) {
        (self.url, self.fs) = (url, fs)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url), lines = data.split(separator: 10, omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() where !line.isEmpty {
                do { absorb(try JSONDecoder().decode(ImportEntry.self, from: Data(line))) } catch {
                    if i == lines.count - 1 { tornAt = UInt64(data.count - line.count) } else { unreadable = true }
                }
            }
        } catch { unreadable = true }
    }
    mutating func absorb(_ e: ImportEntry) {
        if entries[e.key] == nil { order.append(e.key) }
        entries[e.key] = e
    }
    mutating func append(_ e: ImportEntry) throws {
        let handle = try fs.appendHandle(url)
        if let cut = tornAt { try handle.truncate(atOffset: cut) }
        tornAt = nil
        try handle.write(contentsOf: JSONEncoder().encode(e) + Data("\n".utf8))
        try handle.close()
        absorb(e)
    }
    func known(_ fingerprint: String, _ bytes: Int64) -> ImportEntry? {
        entries.values.first { $0.fingerprint == fingerprint && $0.bytes == bytes && !$0.sha256.isEmpty }
    }
    func ignored(_ kind: DeviceKind, _ name: String, _ bytes: Int64) -> Bool {
        entries["\(kind.rawValue)|\(name)|\(bytes)"]?.phase == .ignored
    }
}

/// Reading on the device (Panotti B64): header check, fast fingerprint, hash. Nothing here writes.
enum DeviceFiles {
    static let block = 65_536
    /// Length in seconds and whether the header's sizes lie (ZEPHYR always, the pen after an empty battery).
    static func inspect(_ url: URL, bytes: Int64) -> (seconds: Double, repair: Bool)? {
        let head: Data
        do { head = try FileHandle(forReadingFrom: url).read(upToCount: 44) ?? Data() } catch { return nil }
        guard bytes >= 44, head.count == 44, head.prefix(4) == Data("RIFF".utf8),
              head.dropFirst(8).prefix(4) == Data("WAVE".utf8) else { return nil }
        func u32(_ at: Int) -> Int64 {
            Int64(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) })
        }
        func u16(_ at: Int) -> Int64 { u32(at) & 0xFFFF }
        let (channels, rate, bits) = (u16(22), u32(24), u16(34))
        guard rate >= 8000, channels >= 1, bits >= 8 else { return nil }
        let perSecond = u32(28) > 0 ? u32(28) : rate * channels * bits / 8
        let seconds = Double(bytes - 44) / Double(perSecond)
        let (riff, data) = (u32(4) - (bytes - 8), u32(40) - (bytes - 44))
        guard seconds >= 0.5 else { return nil }
        return (seconds, u32(4) == 0 || u32(40) == 0 || riff > 0 || data > 0 || abs(riff) > 4096 || abs(data) > 4096)
    }
    /// Panotti's fast fingerprint (ExternalRecorder 1180), so taken over journal lines match: size, then SHA-256
    /// of the first and, above 128 KB, the last 64 KB.
    static func fingerprint(_ url: URL, bytes: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: block) ?? Data())
        if bytes > 2 * Int64(block) {
            try handle.seek(toOffset: UInt64(bytes) - UInt64(block))
            hasher.update(data: try handle.read(upToCount: block) ?? Data())
        }
        return "\(bytes)-" + hex(hasher.finalize()).prefix(16)
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: block), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }
    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    static func repaired(_ block: Data, bytes: Int64) -> Data {
        var out = block
        withUnsafeBytes(of: UInt32(clamping: bytes - 8).littleEndian) { out.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: UInt32(clamping: bytes - 44).littleEndian) { out.replaceSubrange(40..<44, with: $0) }
        return out
    }
}
