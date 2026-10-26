import Foundation
import CoreFoundation

/// Counts are bounded to the largest integer represented exactly by JSON's common
/// Double consumers. Never narrow NSNumber with intValue (it can wrap).
public enum UsageNumber {
    public static let maximumCount = 9_007_199_254_740_991

    public enum Invalid: LocalizedError {
        case number, overflow
        public var errorDescription: String? {
            switch self {
            case .number: return "利用データに範囲外または不正な数値があります"
            case .overflow: return "利用データの合計が安全に扱える範囲を超えました"
            }
        }
    }

    public static func count(_ value: Any?, default fallback: Int = 0) throws -> Int {
        guard let value, !(value is NSNull) else { return try checked(fallback) }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { throw Invalid.number }
        if let text = value as? String {
            if let integer = Int(text) { return try checked(integer) }
            guard let number = Double(text) else { throw Invalid.number }
            return try roundedCount(number)
        }
        if let number = value as? NSNumber { return try roundedCount(number.doubleValue) }
        throw Invalid.number
    }

    public static func checked(_ value: Int) throws -> Int {
        guard (0...maximumCount).contains(value) else { throw Invalid.number }
        return value
    }

    public static func roundedCount(_ value: Double, rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) throws -> Int {
        guard value.isFinite, value >= 0, value <= Double(maximumCount),
              let result = Int(exactly: value.rounded(rule)) else { throw Invalid.number }
        return try checked(result)
    }

    public static func nonnegative(_ value: Any?, default fallback: Double = 0) throws -> Double {
        guard let value, !(value is NSNull) else { return try finite(fallback) }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { throw Invalid.number }
        let result: Double?
        if let text = value as? String { result = Double(text) }
        else { result = (value as? NSNumber)?.doubleValue }
        guard let result else { throw Invalid.number }
        return try finite(result)
    }

    public static func finite(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0, value <= Double(maximumCount) else { throw Invalid.number }
        return value
    }

    public static func sum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { try add($0, $1) }
    }

    public static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        _ = try checked(lhs)
        _ = try checked(rhs)
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, result <= maximumCount else { throw Invalid.overflow }
        return result
    }

    public static func add(_ lhs: Double, _ rhs: Double) throws -> Double {
        _ = try finite(lhs)
        _ = try finite(rhs)
        return try finite(lhs + rhs)
    }

    public static func difference(_ lhs: Int, _ rhs: Int) throws -> Int {
        _ = try checked(lhs)
        _ = try checked(rhs)
        return lhs >= rhs ? lhs - rhs : 0
    }
}
