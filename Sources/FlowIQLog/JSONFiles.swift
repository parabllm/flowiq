extension SafeFS {
    /// A store file as JSON with sorted keys, atomically, its folder made first (Paket V, A3).
    public func replace<T: Encodable>(_ url: URL, json value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try makeFolder(url.deletingLastPathComponent())
        try replace(url, with: encoder.encode(value))
    }
}

/// Reading the JSON files of the stores (Paket V, A3).
public enum JSON {
    /// `empty` when the file is missing, nil when it exists but does not decode: then it is never overwritten.
    public static func read<T: Decodable>(_ url: URL, or empty: T) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) } catch { return nil }
    }
    /// One JSON line with its `\n`, for append-only files.
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value) + Data("\n".utf8)
    }
    /// What a service's error answer says: code, field and message under `detail` or `error`, as one line.
    public static func errorText(_ body: Data) -> String {
        var json: Any = [:]
        do { json = try JSONSerialization.jsonObject(with: body) } catch { json = [:] }
        let top = json as? [String: Any] ?? [:], inner = top["detail"] ?? top["error"] ?? ""
        let d = inner as? [String: Any] ?? (inner as? [[String: Any]])?.first ?? ["message": inner]
        func text(_ value: Any?) -> String? { value.map { "\($0)" } }
        let field = text(d["param"]) ?? (d["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".")
        return [text(d["code"] ?? d["type"]), field, text(d["message"] ?? d["msg"])].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Every line that decodes as `T`; a torn line costs only itself.
    public static func decode<T: Decodable>(_ lines: [Data], as type: T.Type) -> [T] {
        lines.compactMap { line in
            do { return try JSONDecoder().decode(type, from: line) } catch { return nil }
        }
    }
}
