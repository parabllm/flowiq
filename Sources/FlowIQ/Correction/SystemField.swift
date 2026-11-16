/// The focused field over the accessibility API (K-35): its text is compared only, never kept.
nonisolated struct SystemField: FieldEditing, FrontAppActivating {
    static let pollSeconds = 0.01, pollTries = 30
    func value() async -> String? {
        var value: CFTypeRef?
        guard let e = SystemFocus.focused(), AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &value)
            == .success else { return nil }
        return value as? String
    }
    func replace(_ range: Range<Int>, with text: String) async throws {
        guard let e = SystemFocus.focused(), let value = await value(), range.upperBound <= value.count else {
            throw InsertError.unsupported
        }
        let start = value.index(value.startIndex, offsetBy: range.lowerBound)
        let end = value.index(start, offsetBy: range.count)
        var span = CFRange(location: value.utf16.distance(from: value.startIndex, to: start),
                           length: value.utf16.distance(from: start, to: end))
        guard let selection = AXValueCreate(.cfRange, &span),
              AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, selection) == .success,
              AXUIElementSetAttributeValue(e, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { throw InsertError.unsupported }
    }
    func frontmost() -> String? { SystemFocus().frontmost() }
    func activate(_ app: String) {
        guard let pid = Int32(app.dropFirst(4)) else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
        for _ in 0..<Self.pollTries where frontmost() != app { Thread.sleep(forTimeInterval: Self.pollSeconds) }
    }
}
