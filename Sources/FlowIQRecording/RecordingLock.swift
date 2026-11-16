/// Exclusive `flock` on `laufend/.sperre` (A.5): a second holder is refused; a dead holder never blocks.
public final class RecordingLock: Sendable {
    public let folder: URL
    private let descriptor: Mutex<Int32>
    private init(folder: URL, descriptor: Int32) {
        self.folder = folder
        self.descriptor = Mutex(descriptor)  // noncopyable, so no tuple assignment
    }
    public static func acquire(in folder: URL) throws -> RecordingLock {
        let file = folder.appending(path: ".sperre")
        if !FileManager.default.fileExists(atPath: file.path) {
            do { try SafeFS(confinedTo: folder).claimNew(file) } catch {
                guard FileManager.default.fileExists(atPath: file.path) else { throw error }  // lost a race: fine
            }
        }
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw RecordingError.lockHeld
        }
        return RecordingLock(folder: folder, descriptor: descriptor)
    }
    public func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
    deinit { release() }
}
