/// The two profiles of one binary (A.1, appendix D): production needs its bundle identifier and Info.plist value.
public enum Profile: String, Sendable, CaseIterable {
    case production, development
    /// Info.plist key written by scripts/bundle.sh.
    public static let infoKey = "FlowIQProfile"
    public var bundleIdentifier: String { self == .production ? "de.flowiq.app" : "de.flowiq.app.dev" }
    public var displayName: String { self == .production ? "FlowIQ" : "FlowIQ Dev" }
    public var supportFolderName: String { self == .production ? "FlowIQ" : "FlowIQ-Dev" }
    /// Launch at login is on by default in production and never registered in development.
    public var launchAtLoginDefault: Bool { self == .production }
    public static func resolve(bundleIdentifier: String?, declared: String?) -> Profile {
        let isProduction = bundleIdentifier == Profile.production.bundleIdentifier
            && declared == Profile.production.rawValue
        return isProduction ? .production : .development
    }
    public static func resolve(_ bundle: Bundle) -> Profile {
        resolve(bundleIdentifier: bundle.bundleIdentifier,
                declared: bundle.object(forInfoDictionaryKey: infoKey) as? String)
    }
}

/// Tag in `eventSourceUserData` of the own Cmd-V and Cmd-Z: the tap ignores them, never "a key since" (A.3, A.8).
public enum PostedEvents { public static let tag: Int64 = 0x464C_4951 }
