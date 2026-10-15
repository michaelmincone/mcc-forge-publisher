import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public subscript(_ index: Int) -> JSONValue {
        guard let a = array, a.indices.contains(index) else { return .null }
        return a[index]
    }
    public var object: [String: JSONValue]? { if case .object(let x) = self { return x }; return nil }
    public var array: [JSONValue]? { if case .array(let x) = self { return x }; return nil }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    public var number: Double? { if case .number(let x) = self { return x }; return nil }
    public var int: Int? { guard let n = number, n.isFinite, n >= Double(Int.min), n < Double(Int.max) else { return nil }; return Int(n) }
    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

public enum PublisherError: LocalizedError, Sendable {
    case invalidMap(String), protocolError(String), service(String), authentication(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidMap(let s), .protocolError(let s), .service(let s), .authentication(let s): return s
        case .cancelled: return "Sign-in was cancelled."
        }
    }
}
