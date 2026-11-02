import Foundation
import CoreFoundation

/// Only quota information is retained. Account identity, credentials and model
/// conversation content are deliberately excluded from this presentation model.
public struct AntigravityQuotaSnapshot: Equatable, Codable, Sendable {
    public var windows: [AntigravityQuotaWindow]
    public var fetchedAt: Date

    public init(windows: [AntigravityQuotaWindow], fetchedAt: Date = Date()) {
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

public struct AntigravityQuotaWindow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var period: LimitPeriod?
    public var remainingFraction: Double?
    public var resetAt: Date?
    public var resetDescription: String?
    public var isDisabled: Bool

    public init(id: String, title: String, period: LimitPeriod? = nil,
                remainingFraction: Double? = nil, resetAt: Date? = nil,
                resetDescription: String? = nil, isDisabled: Bool = false) {
        self.id = id
        self.title = title
        self.period = period
        self.remainingFraction = remainingFraction
        self.resetAt = resetAt
        self.resetDescription = resetDescription
        self.isDisabled = isDisabled
    }
}

/// Parses measured local-service quota responses, never model availability or
/// conversation-token totals. Missing quota values remain unknown rather than
/// becoming zero or a fabricated full allowance.
public enum AntigravityQuotaParser {
    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Antigravityの残量を取得できませんでした"
            case .invalidResponse: return "Antigravityの残量データを確認できませんでした"
            }
        }
    }

    public static let maximumResponseBytes = 1_048_576
    public static let maximumWindows = 64

    public static func parseSummary(data: Data, fetchedAt: Date = Date()) throws -> AntigravityQuotaSnapshot {
        let root = try object(data)
        try checkCode(root)
        let payload = try nestedObject(root, key: "response") ?? root
        try checkCode(payload)
        var windows: [AntigravityQuotaWindow] = []
        var seen = Set<String>()
        if let groupsValue = payload["groups"] {
            guard let groups = groupsValue as? [[String: Any]], groups.count <= maximumWindows else {
                throw Failure.invalidResponse
            }
            for group in groups {
                let groupTitle = try text(group["displayName"], fallback: "Antigravity")
                guard let buckets = group["buckets"] as? [[String: Any]], buckets.count <= maximumWindows else {
                    throw Failure.invalidResponse
                }
                for bucket in buckets {
                    try appendSummaryBucket(bucket, groupTitle: groupTitle, to: &windows, seen: &seen)
                }
            }
        } else if let bucketsValue = payload["buckets"] {
            // Early local-service versions returned a flat bucket list.
            guard let buckets = bucketsValue as? [[String: Any]], buckets.count <= maximumWindows else {
                throw Failure.invalidResponse
            }
            for bucket in buckets {
                try appendSummaryBucket(bucket, groupTitle: "Antigravity", to: &windows, seen: &seen)
            }
        } else {
            throw Failure.unavailable
        }
        return try snapshot(windows, fetchedAt: fetchedAt)
    }

    public static func parseUserStatus(data: Data, fetchedAt: Date = Date()) throws -> AntigravityQuotaSnapshot {
        let root = try object(data)
        try checkCode(root)
        guard let status = try nestedObject(root, key: "userStatus"),
              let modelData = try nestedObject(status, key: "cascadeModelConfigData"),
              let configs = modelData["clientModelConfigs"] as? [[String: Any]] else {
            throw Failure.unavailable
        }
        guard configs.count <= maximumWindows else { throw Failure.invalidResponse }
        var windows: [AntigravityQuotaWindow] = []
        var seen = Set<String>()
        for config in configs {
            guard let quota = try nestedObject(config, key: "quotaInfo") else { continue }
            let alias = try nestedObject(config, key: "modelOrAlias")
            let rawID = alias?["model"] ?? config["modelId"] ?? config["model"]
            let modelID = try identifier(rawID)
            let id = "model:" + modelID
            guard seen.insert(id).inserted else { throw Failure.invalidResponse }
            let label = try text(config["label"], fallback: modelID)
            let disabled = try boolean(quota["disabled"])
            let fraction = try remainingFraction(quota["remainingFraction"])
            let resetAt = try timestamp(quota["resetTime"])
            // Legacy model quota payloads do not say which cadence is measured.
            // A reset date alone is not evidence for a five-hour or weekly limit.
            windows.append(.init(id: id, title: label,
                                 remainingFraction: disabled ? nil : fraction,
                                 resetAt: resetAt, isDisabled: disabled))
        }
        return try snapshot(windows, fetchedAt: fetchedAt)
    }

    private static func appendSummaryBucket(_ bucket: [String: Any], groupTitle: String,
                                            to windows: inout [AntigravityQuotaWindow],
                                            seen: inout Set<String>) throws {
        guard windows.count < maximumWindows else { throw Failure.invalidResponse }
        let bucketID = try identifier(bucket["bucketId"])
        let id = "bucket:" + bucketID
        guard seen.insert(id).inserted else { throw Failure.invalidResponse }
        let bucketTitle = try text(bucket["displayName"], fallback: bucketID)
        let description = try optionalText(bucket["description"])
        let disabled = try boolean(bucket["disabled"])
        let remaining = try nestedObject(bucket, key: "remaining")
        let rawFraction = bucket["remainingFraction"] ?? remaining?["remainingFraction"]
        let fraction = try remainingFraction(rawFraction)
        // Absolute AI-credit balances are not percentages. Validate an amount
        // when present, but do not invent a denominator for it.
        if let amount = bucket["remainingAmount"] ?? remaining?["remainingAmount"] {
            _ = try nonnegativeNumber(amount)
        }
        let rawWindow = try optionalText(bucket["window"])
        let period = cadence(explicitWindow: rawWindow, bucketID: bucketID, displayName: bucketTitle)
        let title = String((groupTitle + " · " + bucketTitle).prefix(160))
        windows.append(.init(id: id, title: title, period: period,
                             remainingFraction: disabled ? nil : fraction,
                             resetAt: try timestamp(bucket["resetTime"]),
                             resetDescription: description, isDisabled: disabled))
    }

    private static func snapshot(_ windows: [AntigravityQuotaWindow], fetchedAt: Date) throws -> AntigravityQuotaSnapshot {
        guard fetchedAt.timeIntervalSince1970.isFinite else { throw Failure.invalidResponse }
        guard windows.contains(where: { !$0.isDisabled && $0.remainingFraction != nil }) else {
            throw Failure.unavailable
        }
        return .init(windows: windows, fetchedAt: fetchedAt)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumResponseBytes else { throw Failure.invalidResponse }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.invalidResponse
            }
            return root
        } catch { throw Failure.invalidResponse }
    }

    private static func nestedObject(_ object: [String: Any], key: String) throws -> [String: Any]? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let nested = value as? [String: Any] else { throw Failure.invalidResponse }
        return nested
    }

    private static func checkCode(_ root: [String: Any]) throws {
        guard let code = root["code"] else { return }
        if let text = code as? String {
            guard ["0", "OK", "ok"].contains(text) else { throw Failure.unavailable }
        } else {
            guard try nonnegativeNumber(code) == 0 else { throw Failure.unavailable }
        }
    }

    private static func remainingFraction(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        let fraction = try nonnegativeNumber(value)
        guard fraction <= 1 else { throw Failure.invalidResponse }
        return fraction
    }

    private static func nonnegativeNumber(_ value: Any) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue <= Double(UsageNumber.maximumCount) else {
            throw Failure.invalidResponse
        }
        return number.doubleValue
    }

    private static func boolean(_ value: Any?) throws -> Bool {
        guard let value, !(value is NSNull) else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw Failure.invalidResponse
        }
        return number.boolValue
    }

    private static func identifier(_ value: Any?) throws -> String {
        guard let raw = value as? String, !raw.isEmpty, raw.utf8.count <= 256,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidResponse
        }
        return raw
    }

    private static func text(_ value: Any?, fallback: String) throws -> String {
        try optionalText(value) ?? String(fallback.prefix(160))
    }

    private static func optionalText(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String, raw.utf8.count <= 8_192 else { throw Failure.invalidResponse }
        let clean = raw.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format {
                return " "
            }
            return String(scalar)
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(160))
    }

    private static func timestamp(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        let seconds: Double
        if let raw = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
                seconds = date.timeIntervalSince1970
            } else if let epoch = Double(raw) {
                seconds = epoch
            } else { throw Failure.invalidResponse }
        } else if let timestamp = value as? [String: Any] {
            let base: Double
            if let raw = timestamp["seconds"] as? String, let parsed = Double(raw) {
                base = parsed
            } else if let raw = timestamp["seconds"] {
                base = try nonnegativeNumber(raw)
            } else { throw Failure.invalidResponse }
            let nanos = try timestamp["nanos"].map(nonnegativeNumber) ?? 0
            guard base.rounded(.towardZero) == base, nanos < 1_000_000_000,
                  nanos.rounded(.towardZero) == nanos else { throw Failure.invalidResponse }
            seconds = base + nanos / 1_000_000_000
        } else {
            seconds = try nonnegativeNumber(value)
        }
        guard seconds.isFinite, seconds >= 0, seconds <= 253_402_300_799 else { throw Failure.invalidResponse }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func cadence(explicitWindow: String?, bucketID: String, displayName: String) -> LimitPeriod? {
        let candidates = explicitWindow.map { [$0] } ?? [bucketID, displayName]
        for candidate in candidates {
            let normalized = candidate.lowercased().replacingOccurrences(of: "_", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = normalized.hasSuffix(" limit") ? String(normalized.dropLast(6)) : normalized
            if ["weekly", "week", "7d"].contains(value) || value.hasSuffix("-weekly") { return .weekly }
            if ["session", "5h", "5-hour", "five-hour", "five hour"].contains(value)
                || value.hasSuffix("-session") || value.hasSuffix("-5h") { return .fiveHours }
        }
        return nil
    }
}
