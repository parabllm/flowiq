@_exported import FlowIQLog
@_exported import Synchronization

/// What the focus probe sees (A.8); only `notTextField` (readable, no text field) prevents the insertion.
public enum FocusState: Sendable, Equatable { case textField(preceding: Character?), notTextField, unreadable }

public protocol FocusProbing: Sendable { func probe() async -> FocusState }

/// Every item of the clipboard with every type as bytes.
public struct PasteboardSnapshot: Sendable, Equatable {
    public let items: [[String: Data]]
    public init(items: [[String: Data]]) { self.items = items }
}

public protocol PasteboardPort: Sendable {
    var changeCount: Int { get }
    /// Throws when any item or type cannot be read: then nothing may be overwritten.
    func snapshot() throws -> PasteboardSnapshot
    /// Offers `text` as promise data; `onFetch` runs when an app asks for it. Returns the own change count.
    func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int
    /// Plain text that stays on the clipboard (correction fallback "copied for you").
    func writePlain(_ text: String) throws -> Int
    func restore(_ snapshot: PasteboardSnapshot) throws
}

extension PasteboardPort {
    public func writePlain(_ text: String) throws -> Int { throw InsertError.unsupported }
}

public protocol KeyPosting: Sendable {
    func paste() throws
    func undo() throws
}

public protocol FrontAppProbing: Sendable {
    /// Identity of the frontmost app (process), nil when unknown.
    func frontmost() -> String?
    /// The frontmost app's name as the history shows it (never a window title), nil when unknown.
    func frontmostName() -> String?
    var secureInputActive: Bool { get }
}

extension FrontAppProbing {
    public func frontmostName() -> String? { nil }
}

/// The focused field's text (nil when unreadable) and a range edit, only for a correction in place (K-35).
public protocol FieldEditing: Sendable {
    func value() async -> String?
    func replace(_ range: Range<Int>, with text: String) async throws
}

public enum ReplaceResult: String, Sendable, Equatable {
    case fieldReplaced, undoReinserted, clipboardHint, nothingToReplace
}

public enum InsertError: Error { case unsupported }

/// Only `landed` counts as inserted (R-019); the raw values go into journal and log.
public enum InsertResult: String, Sendable, Equatable { case landed, notFetched, noTextFocus, secureInput, failed }

/// Result plus the marks of appendix C in `mach_continuous_time` ticks: t12 Cmd-V posted, t13 text fetched.
public struct InsertOutcome: Sendable {
    public let result: InsertResult, frontApp: String?, pastedTicks: UInt64?, fetchedTicks: UInt64?
    /// The target app's name for the journal; `frontApp` stays the process identity for comparisons.
    public var appName: String? = nil
}
