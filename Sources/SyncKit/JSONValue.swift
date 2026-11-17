import Foundation

/// Transport-neutral JSON tree used as the mutation payload. Keeping the queue free of Firestore
/// types means the same persisted mutations can be replayed by any `RemoteGateway`.
///
/// `.date` is first-class so dates become native Firestore `Timestamp`s (sortable, queryable)
/// instead of opaque numbers. On disk it is `{"$date": <unix seconds>}`.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case date(Date)

    static let dateKey = "$date"

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        let object = try container.decode([String: JSONValue].self)
        if object.count == 1, let stamp = object[Self.dateKey] {
            switch stamp {
            case .int(let seconds): self = .date(Date(timeIntervalSince1970: Double(seconds))); return
            case .double(let seconds): self = .date(Date(timeIntervalSince1970: seconds)); return
            default: break
            }
        }
        self = .object(object)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .date(let value): try container.encode([Self.dateKey: value.timeIntervalSince1970])
        }
    }
}

public enum SyncCodingError: Error, Equatable {
    case notAnObject
    case invalidDate
}

/// Bridges `Codable` domain entities ⇄ `JSONValue`, mapping `Date` ⇄ `.date`.
public enum SyncCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            try JSONValue.date(date).encode(to: encoder)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            switch try JSONValue(from: decoder) {
            case .date(let date): return date
            case .double(let seconds): return Date(timeIntervalSince1970: seconds)
            case .int(let seconds): return Date(timeIntervalSince1970: Double(seconds))
            default: throw SyncCodingError.invalidDate
            }
        }
        return decoder
    }

    public static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try makeDecoder().decode(JSONValue.self, from: makeEncoder().encode(value))
    }

    public static func fields<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        guard case .object(let object) = try jsonValue(value) else { throw SyncCodingError.notAnObject }
        return object
    }

    public static func decode<T: Decodable>(_ type: T.Type, from fields: [String: JSONValue]) throws -> T {
        try makeDecoder().decode(T.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }

    /// Canonical byte form used for local storage and hashing.
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(T.self, from: data)
    }
}
