import Foundation

/// Any JSON value, kept as-is. Lets a synced item carry fields from a newer app build
/// through an older one without understanding them (`SavedOnIPhoneLink.unknownFields`).
/// Numbers stay `Double`: dates (seconds) and small counts round-trip exactly.
public enum OpaqueJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OpaqueJSON])
    case object([String: OpaqueJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Double is safe: JSONDecoder never reads a JSON number as Bool, nor
        // true/false as a number.
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([OpaqueJSON].self) { self = .array(v); return }
        self = .object(try c.decode([String: OpaqueJSON].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Stable text form (sorted keys), used to break merge ties the same way on every device.
    var canonicalText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode([self])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// A coding key made from any string (unknown fields, dynamic containers).
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
