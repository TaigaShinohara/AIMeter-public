import Foundation

/// Ordered, JSON-native value used for every CLI payload. Command results are
/// built as `JSONValue` so the JSON envelope and tests share one shape, and
/// serialization is deterministic (sorted keys).
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value.isFinite ? value : NSNull()
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let pairs):
            var dictionary: [String: Any] = [:]
            for (key, value) in pairs { dictionary[key] = value.foundationObject }
            return dictionary
        }
    }

    public func serializedString() -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: foundationObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

extension JSONValue: Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

extension JSONValue {
    /// Convenience accessor used by tests and human rendering.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }
}
