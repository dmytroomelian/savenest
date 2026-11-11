import Foundation

/// JSON shared by the local automation transport and the native library owner.
public indirect enum AutomationValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AutomationValue])
    case object([String: AutomationValue])

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var int: Int? {
        guard let value = number, value.isFinite, value.rounded() == value,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
    public var array: [AutomationValue]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: AutomationValue]? { if case .object(let value) = self { return value }; return nil }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([AutomationValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: AutomationValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
}

public struct AutomationFailure: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public init(code: String, message: String) { self.init(code, message) }
    public var errorDescription: String? { message }
}
