@_exported import FlowIQCore
@_exported import Foundation

/// One line in the event log: `ts`, `kind`, `level` plus flat fields (NDJSON, A.2).
public struct LogEvent: Sendable, Equatable {
    public enum Level: String, Sendable { case info, error }
    public let time: Date, kind: String, level: Level, fields: [String: LogValue]
    public init(_ kind: String, level: Level = .info, time: Date = .now, _ fields: [String: LogValue] = [:]) {
        (self.time, self.kind, self.level, self.fields) = (time, kind, level, fields)
    }
}

public enum LogValue: Sendable, Equatable, Encodable, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String), int(Int64), double(Double), bool(Bool)
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
}

/// Encodes one event as one JSON line terminated by `\n`.
struct LineEncoder {
    private let json: JSONEncoder
    private static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    init() {
        json = JSONEncoder()
        json.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    func line(_ event: LogEvent) throws -> Data {
        var object = event.fields
        object["ts"] = .string(event.time.formatted(Self.timeFormat))
        if let clash = object["kind"] { object["field_kind"] = clash }  // a field may never hide the event kind
        object["kind"] = .string(event.kind)
        object["level"] = .string(event.level.rawValue)
        var data = try json.encode(object)
        data.append(0x0A)
        return data
    }
}

extension LogEvent {
    /// An error event with the error's domain, code and short description, the home folder masked (keine Inhalte).
    public static func failure(_ kind: String, _ error: any Error, _ fields: [String: LogValue] = [:]) -> LogEvent {
        let e = error as NSError, text = String(describing: error).replacing(NSHomeDirectory(), with: "~")
        return LogEvent(kind, level: .error, fields.merging(["error_domain": .string(e.domain),
            "error_code": .int(Int64(e.code)), "error": .string(String(text.prefix(160)))]) { a, _ in a })
    }
}
