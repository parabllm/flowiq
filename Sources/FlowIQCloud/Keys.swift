import Security

public protocol KeychainPort: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ secret: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// The two cloud accounts (16.11.), one keychain item each under the profile's service name (M.7, R-100).
public enum CloudProvider: String, Sendable, CaseIterable { case elevenLabs = "elevenlabs", openRouter = "openrouter"
    public var keyPrefix: String { self == .elevenLabs ? "sk_" : "sk-or-" }  // an id pasted as the key lacks it
}

/// The key lives only in the keychain; this type is its only reader and writer.
public struct CloudKeys: Sendable {
    public let keychain: any KeychainPort, service: String, provider: CloudProvider
    public init(keychain: any KeychainPort, profile: Profile, provider: CloudProvider = .elevenLabs) {
        (self.keychain, service, self.provider) = (keychain, profile.bundleIdentifier + ".elevenlabs", provider)
    }
    var current: String? {  // an unreadable keychain counts as no key
        do { return try key() } catch { return nil }
    }
    public var hasKey: Bool { current != nil }
    func key() throws -> String? {
        try keychain.read(service: service, account: provider.rawValue + "-api-key").flatMap { $0.isEmpty ? nil : $0 }
    }
    public func store(_ secret: String) throws {
        try keychain.write(secret, service: service, account: provider.rawValue + "-api-key")
    }
    public func remove() throws { try keychain.delete(service: service, account: provider.rawValue + "-api-key") }
    /// Takes the key over from Panotti's `.env` text, only on a click (R-066).
    public func importFromEnv(_ text: String, userClicked: Bool) throws -> Bool {
        let prefix = "ELEVENLABS_API_KEY="
        guard userClicked, let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        try store(line.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
        return true
    }
}

/// The macOS keychain behind `KeychainPort` (generic password items).
public struct SystemKeychain: KeychainPort {
    public init() {}
    func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    public func read(service: String, account: String) throws -> String? {
        var item: CFTypeRef? = nil, q = query(service, account)
        (q[kSecReturnData as String], q[kSecMatchLimit as String]) = (true, kSecMatchLimitOne)
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: data, as: UTF8.self)
    }
    public func write(_ secret: String, service: String, account: String) throws {
        try delete(service: service, account: account)
        var q = query(service, account)
        q[kSecValueData as String] = Data(secret.utf8)
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    }
    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CocoaError(.fileWriteUnknown) }
    }
}
