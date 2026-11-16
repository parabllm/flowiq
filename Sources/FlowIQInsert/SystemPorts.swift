import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The general pasteboard (A.8): promise data plus the transient marker; the provider call proves the fetch (t13).
public final class SystemPasteboard: PasteboardPort {
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let provider = Mutex<PromiseProvider?>(nil)
    public init() {}
    public var changeCount: Int { NSPasteboard.general.changeCount }
    public func snapshot() throws -> PasteboardSnapshot {
        let items = try (NSPasteboard.general.pasteboardItems ?? []).map { item in
            try item.types.reduce(into: [String: Data]()) { out, type in
                guard let data = item.data(forType: type) else { throw InsertError.unsupported }
                out[type.rawValue] = data
            }
        }
        return PasteboardSnapshot(items: items)
    }
    public func writePromise(_ text: String, onFetch: @escaping @Sendable () -> Void) throws -> Int {
        let promise = PromiseProvider(text: text, onFetch: onFetch)
        let item = NSPasteboardItem()
        guard item.setDataProvider(promise, forTypes: [.string]), item.setData(Data(), forType: Self.transient)
        else { throw InsertError.unsupported }
        provider.withLock { $0 = promise }  // kept alive until the next write
        return try write([item])
    }
    public func writePlain(_ text: String) throws -> Int {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { throw InsertError.unsupported }
        return try write([item])
    }
    public func restore(_ snapshot: PasteboardSnapshot) throws {
        let items = snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        _ = try write(items)
        provider.withLock { $0 = nil }
    }
    private func write(_ items: [NSPasteboardItem]) throws -> Int {
        let board = NSPasteboard.general
        board.clearContents()
        guard items.isEmpty || board.writeObjects(items) else { throw InsertError.unsupported }
        return board.changeCount
    }
}

final class PromiseProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    let text: String
    let onFetch: @Sendable () -> Void
    init(text: String, onFetch: @escaping @Sendable () -> Void) { (self.text, self.onFetch) = (text, onFetch) }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        onFetch()
    }
}

/// Focus over the accessibility API, 15 ms per call (A.8, B35, B36): text role, settable value or range = text field.
public struct SystemFocus: FocusProbing, FrontAppProbing, KeyPosting {
    public init() {}
    public func probe() async -> FocusState {
        guard let element = Self.focused() else { return .unreadable }
        var role: CFTypeRef?, range: CFTypeRef?, settable = DarwinBoolean(false)
        let hasRole = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] as [String]
        let hasRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range)
            == .success
        let isText = textRoles.contains(role as? String ?? "") || hasRange
            || (AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                && settable.boolValue)
        guard isText else { return hasRole ? .notTextField : .unreadable }
        guard hasRange, let value = range, CFGetTypeID(value) == AXValueGetTypeID() else {
            return .textField(preceding: nil)
        }
        var span = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &span), span.location > 0 else {
            return .textField(preceding: nil)
        }
        var previous = CFRange(location: span.location - 1, length: 1), text: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &previous),
              AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &text) == .success else {
            return .textField(preceding: nil)
        }
        return .textField(preceding: (text as? String)?.last)  // compared only, never stored
    }
    public func frontmost() -> String? {
        var app: CFTypeRef?, pid: pid_t = 0
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.timeout)
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let app, CFGetTypeID(app) == AXUIElementGetTypeID(),
              AXUIElementGetPid(unsafeDowncast(app, to: AXUIElement.self), &pid) == .success else { return nil }
        return "pid-\(pid)"
    }
    /// Without the accessibility API: the system-wide focus query fails in many apps (kAXErrorCannotComplete).
    public func frontmostName() -> String? { NSWorkspace.shared.frontmostApplication?.localizedName }
    public var secureInputActive: Bool { IsSecureEventInputEnabled() }
    public func paste() throws { try Self.post(CGKeyCode(kVK_ANSI_V)) }
    public func undo() throws { try Self.post(CGKeyCode(kVK_ANSI_Z)) }
    static let timeout: Float = 0.015
    /// The focused element with the 15 ms limit; also the correction field's (A9).
    public static func focused() -> AXUIElement? {
        var element: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &element) == .success,
              let element, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeDowncast(element, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, timeout)
        return focused
    }
    /// Command plus `key`, tagged so the own tap skips it; no sound, no window to the front (R-018).
    private static func post(_ key: CGKeyCode) throws {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
                throw InsertError.unsupported
            }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: PostedEvents.tag)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
