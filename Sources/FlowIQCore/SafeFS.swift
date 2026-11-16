@_exported import Foundation

/// The only code that writes to disk (A.1, appendix F): an allow list checked before the disk is touched.
public struct SafeFS: Sendable {
    public struct Denied: Error, Equatable { public let path: String }
    private let folders: [String], files: [String]
    public init(paths: Paths, vault: [URL] = []) {
        let roots = [paths.support] + (paths.profile == .production ? vault : [])
        (folders, files) = (roots.map(Self.folderPath), [Self.filePath(paths.liveLink)])
    }
    /// Allows writes only below `folder`: a lock or log that lives on its own.
    public init(confinedTo folder: URL) {
        (folders, files) = ([Self.folderPath(folder)], [])
    }
    init(files: [URL]) { (folders, self.files) = ([], files.map(Self.filePath)) }  // a link that lives alone (tests)
    public func allows(_ url: URL) -> Bool {
        files.contains(Self.filePath(url)) || folders.contains { Self.folderPath(url).hasPrefix($0) }
    }
    public func check(_ url: URL) throws(Denied) { guard allows(url) else { throw Denied(path: Self.filePath(url)) } }
    public func makeFolder(_ url: URL) throws {
        try check(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    /// Atomic replace (temporary file plus rename).
    public func replace(_ url: URL, with data: Data) throws {
        try check(url)
        try data.write(to: url, options: .atomic)
    }
    /// Creates the file only if nothing exists at the path; never overwrites.
    public func claimNew(_ url: URL, with data: Data = Data()) throws {
        try check(url)
        try data.write(to: url, options: .withoutOverwriting)
    }
    /// SAFETY: a file through a foreign API (Core Audio) only where nothing exists; `make` itself must refuse to
    /// overwrite (no erase flag), so a race ends in an error, never in an emptied file.
    public func createNew<T>(_ url: URL, _ make: (URL) throws -> T) throws -> T {
        try check(url)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        return try make(url)
    }
    /// Handle positioned at the end of the file; the file is created if it is missing.
    public func appendHandle(_ url: URL) throws -> FileHandle {
        try check(url)
        if !FileManager.default.fileExists(atPath: url.path) { try claimNew(url) }
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        return handle
    }
    public func move(_ source: URL, to destination: URL) throws {
        try check(source)
        try check(destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }
    /// Points `link` at `target` through a fresh link and an atomic rename: a reader never finds it missing.
    public func link(_ link: URL, to target: URL) throws {
        let fresh = link.deletingLastPathComponent().appending(path: ".\(link.lastPathComponent).neu")
        try check(link)  // the fresh sibling comes from the allowed link (an own entry was missing: live_link_failed)
        var info = stat()
        if lstat(fresh.path, &info) == 0 { try FileManager.default.removeItem(at: fresh) }
        try FileManager.default.createSymbolicLink(at: fresh, withDestinationURL: target)
        guard rename(fresh.path, link.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    public func delete(_ url: URL) throws {
        try check(url)
        try FileManager.default.removeItem(at: url)
    }
    static func filePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    /// Trailing slash: the folder itself counts as inside, a sibling like "FlowIQ-Dev2" does not.
    static func folderPath(_ url: URL) -> String { filePath(url) + "/" }
}
