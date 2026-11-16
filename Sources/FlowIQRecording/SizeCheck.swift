public typealias TrackName = TrackKind
public enum SizeVerdict: String, Sendable { case ok, suspicious, lost }
public enum RecordingError: Error, Equatable { case noAudio, lockHeld, notLocked, coreAudio(Int32) }

/// Every way a track can end (A.5 point 4); each one closes the writer the same way.
public enum EndReason: String, Sendable, CaseIterable {
    case normal, noRecognizerSession, escape, deadline, recognizerFailed, appQuit, sourceEnded, diskFull, abandoned
}

/// AAC bit rate (A.5): call and room 96 kbit/s mono (about 43 MB per hour), dictation 64 kbit/s.
public enum TrackPurpose: String, Sendable, CaseIterable {
    case dictation, call, room
    public var bitRate: Int { self == .dictation ? 64_000 : 96_000 }
}

/// Size against duration (A.5 point 5): under half the rate `suspicious`, under a tenth `lost` (Panotti 8,474 B/s).
public enum SizeCheck {
    public static func verdict(bytes: Int, seconds: Double, purpose: TrackPurpose) -> SizeVerdict {
        guard bytes > 7 else { return .lost }  // one ADTS header, no frame
        guard seconds > 0 else { return .ok }
        let (rate, nominal) = (Double(bytes) / seconds, Double(purpose.bitRate) / 8)
        return rate < nominal / 10 ? .lost : rate < nominal / 2 ? .suspicious : .ok
    }
    /// Reads the size from disk, so a file shortened by anyone after closing is caught too.
    public static func verdict(url: URL, seconds: Double, purpose: TrackPurpose) -> SizeVerdict {
        verdict(bytes: fileBytes(url), seconds: seconds, purpose: purpose)
    }
    static func fileBytes(_ url: URL) -> Int {
        do { return try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0 } catch { return 0 }
    }
}
