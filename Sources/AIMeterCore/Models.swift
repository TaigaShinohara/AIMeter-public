import Foundation

// MARK: - Limit Period Type
public enum LimitPeriod: String, CaseIterable, Codable, Identifiable {
    case twoHours = "2h"
    case fiveHours = "5h"
    case daily = "1d"
    case weekly = "7d"
    case monthly = "30d"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .twoHours: return "2時間"
        case .fiveHours: return "5時間"
        case .daily: return "1日"
        case .weekly: return "週次"
        case .monthly: return "月次"
        }
    }

    public var shortLabel: String {
        switch self {
        case .twoHours: return "2h"
        case .fiveHours: return "5h"
        case .daily: return "1d"
        case .weekly: return "1w"
        case .monthly: return "1m"
        }
    }
}

// MARK: - MenuBar Display Mode
public enum MenuBarDisplayMode: String, CaseIterable, Codable, Identifiable {
    case smart = "smart"       // 最も逼迫しているサービス1つ（推奨: ノッチ衝突完全回避）
    case compact = "compact"   // 上位2サービス
    case iconOnly = "iconOnly" // 残り数値のみ
    case all = "all"           // 従来の全表示

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .smart: return "最逼迫のみ (推奨)"
        case .compact: return "コンパクト (2つ)"
        case .iconOnly: return "数値のみ"
        case .all: return "すべて表示"
        }
    }
}

// MARK: - Service Bottleneck Snapshot
public enum RemainingQuotaSource: String, Codable {
    case official
    case configuredLimit
    case unavailable

    public func percentText(_ percent: Int) -> String {
        switch self {
        case .official: return "\(percent)%"
        case .configuredLimit: return "約\(percent)%"
        case .unavailable: return "未取得"
        }
    }
}

public struct ServiceBottleneck: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let shortName: String
    public let iconName: String
    public let remainingPercent: Int
    public let remainingRatio: Double
    public let bottleneckPeriod: LimitPeriod
    public let remainingSource: RemainingQuotaSource

    public init(
        id: String,
        name: String,
        shortName: String,
        iconName: String,
        remainingPercent: Int,
        remainingRatio: Double,
        bottleneckPeriod: LimitPeriod,
        remainingSource: RemainingQuotaSource = .configuredLimit
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.iconName = iconName
        self.remainingPercent = remainingPercent
        self.remainingRatio = remainingRatio
        self.bottleneckPeriod = bottleneckPeriod
        self.remainingSource = remainingSource
    }
}

// MARK: - Per-Period Usage & Limit Snapshot
public struct PeriodUsageMetric: Equatable, Identifiable {
    public let period: LimitPeriod
    public var usedTokens: Int
    public var limitTokens: Int
    public var serverUsedPercent: Double?
    public var resetTimestamp: Int?
    public var requiresOfficialQuota: Bool

    public var id: String { period.rawValue }

    public init(
        period: LimitPeriod,
        usedTokens: Int,
        limitTokens: Int,
        serverUsedPercent: Double? = nil,
        resetTimestamp: Int? = nil,
        requiresOfficialQuota: Bool = false
    ) {
        self.period = period
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.serverUsedPercent = serverUsedPercent
        self.resetTimestamp = resetTimestamp
        self.requiresOfficialQuota = requiresOfficialQuota
    }

    private var validatedValues: (limit: Int, remaining: Int, ratio: Double)? {
        do {
            _ = try UsageNumber.checked(usedTokens)
            _ = try UsageNumber.checked(limitTokens)
            var limit = limitTokens
            if let pct = serverUsedPercent {
                _ = try UsageNumber.finite(pct)
                if pct > 0.5, usedTokens > 0 {
                    limit = max(usedTokens, try UsageNumber.roundedCount(Double(usedTokens) / (pct / 100)))
                }
                let ratio = min(1, max(0, (100 - pct) / 100))
                let remaining = usedTokens > 0 && pct > 0.5
                    ? try UsageNumber.difference(limit, usedTokens)
                    : try UsageNumber.roundedCount(Double(limitTokens) * ratio)
                return (limit, remaining, ratio)
            }
            let remaining = try UsageNumber.difference(limit, usedTokens)
            return (limit, remaining, limit > 0 ? min(1, Double(remaining) / Double(limit)) : 0)
        } catch { return nil }
    }

    /// Computed on every access because this public model can be mutated after initialization.
    public var isValid: Bool { validatedValues != nil }
    public var remainingSource: RemainingQuotaSource {
        if serverUsedPercent != nil { return .official }
        return requiresOfficialQuota ? .unavailable : .configuredLimit
    }
    public var isRemainingAvailable: Bool { isValid && remainingSource != .unavailable }
    public var effectiveLimitTokens: Int { validatedValues?.limit ?? 0 }
    public var remainingTokens: Int { validatedValues?.remaining ?? 0 }
    public var remainingRatio: Double { validatedValues?.ratio ?? 0 }
    public var remainingPercent: Int { Int((remainingRatio * 100).rounded()) }

}

// MARK: - Custom Subscription / Provider Configuration
public struct CustomSubscriptionConfig: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var shortName: String
    public var iconName: String
    public var isEnabled: Bool
    public var showInMenuBar: Bool
    public var enabledPeriodRawValues: [String]

    public var limit2h: Int
    public var limit5h: Int
    public var limitDaily: Int
    public var limitWeekly: Int
    public var limitMonthly: Int

    public var manualUsed2h: Int
    public var manualUsed5h: Int
    public var manualUsedDaily: Int
    public var manualUsedWeekly: Int
    public var manualUsedMonthly: Int

    public var usedCostUSD: Double
    public var budgetUSD: Double
    public var statusNote: String

    enum CodingKeys: String, CodingKey {
        case id, name, shortName, iconName, isEnabled, showInMenuBar, enabledPeriodRawValues
        case limit2h, limit5h, limitDaily, limitWeekly, limitMonthly
        case manualUsed2h, manualUsed5h, manualUsedDaily, manualUsedWeekly, manualUsedMonthly
        case usedCostUSD, budgetUSD, statusNote
    }

    public init(
        id: String,
        name: String,
        shortName: String,
        iconName: String,
        isEnabled: Bool,
        showInMenuBar: Bool,
        enabledPeriodRawValues: [String],
        limit2h: Int = 500_000,
        limit5h: Int,
        limitDaily: Int,
        limitWeekly: Int,
        limitMonthly: Int,
        manualUsed2h: Int = 0,
        manualUsed5h: Int,
        manualUsedDaily: Int,
        manualUsedWeekly: Int,
        manualUsedMonthly: Int,
        usedCostUSD: Double,
        budgetUSD: Double,
        statusNote: String
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.iconName = iconName
        self.isEnabled = isEnabled
        self.showInMenuBar = showInMenuBar
        self.enabledPeriodRawValues = enabledPeriodRawValues
        self.limit2h = limit2h
        self.limit5h = limit5h
        self.limitDaily = limitDaily
        self.limitWeekly = limitWeekly
        self.limitMonthly = limitMonthly
        self.manualUsed2h = manualUsed2h
        self.manualUsed5h = manualUsed5h
        self.manualUsedDaily = manualUsedDaily
        self.manualUsedWeekly = manualUsedWeekly
        self.manualUsedMonthly = manualUsedMonthly
        self.usedCostUSD = usedCostUSD
        self.budgetUSD = budgetUSD
        self.statusNote = statusNote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        shortName = try c.decode(String.self, forKey: .shortName)
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName) ?? "cpu.fill"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? false
        enabledPeriodRawValues = try c.decodeIfPresent([String].self, forKey: .enabledPeriodRawValues) ?? ["30d"]
        limit5h = try c.decodeIfPresent(Int.self, forKey: .limit5h) ?? 500_000
        limit2h = try c.decodeIfPresent(Int.self, forKey: .limit2h) ?? max(1, limit5h / 2)
        limitDaily = try c.decodeIfPresent(Int.self, forKey: .limitDaily) ?? 2_000_000
        limitWeekly = try c.decodeIfPresent(Int.self, forKey: .limitWeekly) ?? 10_000_000
        limitMonthly = try c.decodeIfPresent(Int.self, forKey: .limitMonthly) ?? 30_000_000
        manualUsed2h = try c.decodeIfPresent(Int.self, forKey: .manualUsed2h) ?? 0
        manualUsed5h = try c.decodeIfPresent(Int.self, forKey: .manualUsed5h) ?? 0
        manualUsedDaily = try c.decodeIfPresent(Int.self, forKey: .manualUsedDaily) ?? 0
        manualUsedWeekly = try c.decodeIfPresent(Int.self, forKey: .manualUsedWeekly) ?? 0
        manualUsedMonthly = try c.decodeIfPresent(Int.self, forKey: .manualUsedMonthly) ?? 0
        usedCostUSD = try c.decodeIfPresent(Double.self, forKey: .usedCostUSD) ?? 0.0
        budgetUSD = try c.decodeIfPresent(Double.self, forKey: .budgetUSD) ?? 20.0
        statusNote = try c.decodeIfPresent(String.self, forKey: .statusNote) ?? ""
    }

    public func isPeriodEnabled(_ period: LimitPeriod) -> Bool {
        enabledPeriodRawValues.contains(period.rawValue)
    }

    public mutating func setPeriod(_ period: LimitPeriod, enabled: Bool) {
        if enabled {
            if !enabledPeriodRawValues.contains(period.rawValue) {
                enabledPeriodRawValues.append(period.rawValue)
            }
        } else if enabledPeriodRawValues.count > 1 {
            enabledPeriodRawValues.removeAll { $0 == period.rawValue }
        }
    }

    public mutating func sanitize() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "Custom AI" }
        if shortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { shortName = "AI" }
        if enabledPeriodRawValues.isEmpty { enabledPeriodRawValues = [LimitPeriod.monthly.rawValue] }
        if limit2h < 1 { limit2h = 1 }
        if limit5h < 1 { limit5h = 1 }
        if limitDaily < 1 { limitDaily = 1 }
        if limitWeekly < 1 { limitWeekly = 1 }
        if limitMonthly < 1 { limitMonthly = 1 }
        if manualUsed2h < 0 { manualUsed2h = 0 }
        if manualUsed5h < 0 { manualUsed5h = 0 }
        if manualUsedDaily < 0 { manualUsedDaily = 0 }
        if manualUsedWeekly < 0 { manualUsedWeekly = 0 }
        if manualUsedMonthly < 0 { manualUsedMonthly = 0 }
        if usedCostUSD < 0 { usedCostUSD = 0 }
        if budgetUSD < 0 { budgetUSD = 0 }
    }

    // MARK: - Presets
    public static func grokbotPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "grokbot",
            name: "Grok / GrokBot",
            shortName: "Grok",
            iconName: "sparkles",
            isEnabled: true,
            showInMenuBar: true,
            enabledPeriodRawValues: ["2h", "1d", "7d"],
            limit2h: 200_000,
            limit5h: 500_000,
            limitDaily: 1_500_000,
            limitWeekly: 10_000_000,
            limitMonthly: 40_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 30.0,
            statusNote: "SuperGrok / Bot"
        )
    }

    public static func claudePreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "claude",
            name: "Anthropic Claude",
            shortName: "Cld",
            iconName: "brain.head.profile",
            isEnabled: true,
            showInMenuBar: true,
            enabledPeriodRawValues: ["5h", "7d"],
            limit2h: 600_000,
            limit5h: 1_500_000,
            limitDaily: 4_000_000,
            limitWeekly: 15_000_000,
            limitMonthly: 45_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: "Pro / Max"
        )
    }

    public static func cursorPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "cursor",
            name: "Cursor",
            shortName: "Cur",
            iconName: "terminal.fill",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 25,
            limit5h: 50,
            limitDaily: 50,
            limitWeekly: 200,
            limitMonthly: 500,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: "Pro / Ultra"
        )
    }

    public static func windsurfPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "windsurf",
            name: "Windsurf",
            shortName: "Wind",
            iconName: "wind",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["30d"],
            limit2h: 1_500,
            limit5h: 3_000,
            limitDaily: 5_000,
            limitWeekly: 20_000,
            limitMonthly: 50_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: "Pro"
        )
    }

    public static func copilotPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "copilot",
            name: "GitHub Copilot",
            shortName: "Cop",
            iconName: "chevron.left.forwardslash.chevron.right",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["30d"],
            limit2h: 30,
            limit5h: 50,
            limitDaily: 100,
            limitWeekly: 150,
            limitMonthly: 300,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 10.0,
            statusNote: "Premium Reqs"
        )
    }

    public static func devinPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "devin",
            name: "Devin",
            shortName: "Dev",
            iconName: "cpu",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "7d", "30d"],
            limit2h: 5,
            limit5h: 10,
            limitDaily: 20,
            limitWeekly: 60,
            limitMonthly: 200,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: "ACU Pool"
        )
    }

    public static func perplexityPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "perplexity",
            name: "Perplexity Pro",
            shortName: "Pplx",
            iconName: "globe",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 60,
            limit5h: 150,
            limitDaily: 300,
            limitWeekly: 1_500,
            limitMonthly: 6_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: "Pro Search"
        )
    }

    public static func deepseekPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "deepseek",
            name: "DeepSeek",
            shortName: "DS",
            iconName: "wave.3.right",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 1_000_000,
            limit5h: 2_500_000,
            limitDaily: 10_000_000,
            limitWeekly: 50_000_000,
            limitMonthly: 150_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: "V3 / R1 API"
        )
    }

    public static func poePreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "poe",
            name: "Poe",
            shortName: "Poe",
            iconName: "bubble.left.and.bubble.right",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 20_000,
            limit5h: 50_000,
            limitDaily: 100_000,
            limitWeekly: 300_000,
            limitMonthly: 1_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: "Compute Pts"
        )
    }

    public static func traePreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "trae",
            name: "Trae AI",
            shortName: "Trae",
            iconName: "bolt.horizontal",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["30d"],
            limit2h: 30,
            limit5h: 60,
            limitDaily: 100,
            limitWeekly: 250,
            limitMonthly: 600,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 10.0,
            statusNote: "Fast Queue"
        )
    }

    public static func preset(forId id: String) -> CustomSubscriptionConfig? {
        switch id {
        case "grokbot": return .grokbotPreset()
        case "claude": return .claudePreset()
        case "cursor": return .cursorPreset()
        case "windsurf": return .windsurfPreset()
        case "copilot": return .copilotPreset()
        case "devin": return .devinPreset()
        case "perplexity": return .perplexityPreset()
        case "deepseek": return .deepseekPreset()
        case "poe": return .poePreset()
        case "trae": return .traePreset()
        default: return nil
        }
    }

    public static func blankCustom() -> CustomSubscriptionConfig {
        let shortId = String(UUID().uuidString.prefix(6)).lowercased()
        return CustomSubscriptionConfig(
            id: "custom_\(shortId)",
            name: "新規サービス",
            shortName: "Sub",
            iconName: "cpu.fill",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["5h", "1d", "7d", "30d"],
            limit2h: 200_000,
            limit5h: 500_000,
            limitDaily: 2_000_000,
            limitWeekly: 10_000_000,
            limitMonthly: 30_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 0.0,
            budgetUSD: 20.0,
            statusNote: ""
        )
    }
}

// MARK: - Local JSON Models
public struct ProviderPeriodUsageJSON: Codable, Equatable {
    public var twoHours: Int?
    public var fiveHours: Int?
    public var daily: Int?
    public var weekly: Int?
    public var monthly: Int?

    enum CodingKeys: String, CodingKey {
        case twoHours = "2h"
        case fiveHours = "5h"
        case daily = "1d"
        case weekly = "7d"
        case monthly = "30d"
    }

    public init(
        twoHours: Int? = nil,
        fiveHours: Int? = nil,
        daily: Int? = nil,
        weekly: Int? = nil,
        monthly: Int? = nil
    ) {
        self.twoHours = twoHours
        self.fiveHours = fiveHours
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
    }
}

public struct ProviderPeriodPercentJSON: Codable, Equatable {
    public var twoHours: Double?
    public var fiveHours: Double?
    public var daily: Double?
    public var weekly: Double?
    public var monthly: Double?

    enum CodingKeys: String, CodingKey {
        case twoHours = "2h"
        case fiveHours = "5h"
        case daily = "1d"
        case weekly = "7d"
        case monthly = "30d"
    }

    public init(
        twoHours: Double? = nil,
        fiveHours: Double? = nil,
        daily: Double? = nil,
        weekly: Double? = nil,
        monthly: Double? = nil
    ) {
        self.twoHours = twoHours
        self.fiveHours = fiveHours
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
    }
}

public struct CustomProviderUsageJSON: Codable, Equatable {
    public var usedByPeriod: ProviderPeriodUsageJSON?
    public var serverUsedPercentByPeriod: ProviderPeriodPercentJSON?
    public var resetAtByPeriod: ProviderPeriodUsageJSON?
    public var costUSD: Double?
    public var status: String?

    public init(
        usedByPeriod: ProviderPeriodUsageJSON? = nil,
        serverUsedPercentByPeriod: ProviderPeriodPercentJSON? = nil,
        resetAtByPeriod: ProviderPeriodUsageJSON? = nil,
        costUSD: Double? = nil,
        status: String? = nil
    ) {
        self.usedByPeriod = usedByPeriod
        self.serverUsedPercentByPeriod = serverUsedPercentByPeriod
        self.resetAtByPeriod = resetAtByPeriod
        self.costUSD = costUSD
        self.status = status
    }
}

public struct LocalUsageData: Codable, Equatable {
    public var openaiUsedTokens: Int?
    public var openaiCostUSD: Double?
    public var geminiUsedTokens: Int?
    public var geminiCostUSD: Double?

    public var openaiUsedByPeriod: ProviderPeriodUsageJSON?
    public var geminiUsedByPeriod: ProviderPeriodUsageJSON?

    public var openaiServerUsedPercentByPeriod: ProviderPeriodPercentJSON?
    public var openaiResetAtByPeriod: ProviderPeriodUsageJSON?
    public var openaiPlanType: String?
    public var openaiCreditBalance: Double?

    public var providers: [String: CustomProviderUsageJSON]?
    public var detectedProviders: [String]?
    public var source: String?
    public var updatedAt: String?

    public init(
        openaiUsedTokens: Int? = nil,
        openaiCostUSD: Double? = nil,
        geminiUsedTokens: Int? = nil,
        geminiCostUSD: Double? = nil,
        openaiUsedByPeriod: ProviderPeriodUsageJSON? = nil,
        geminiUsedByPeriod: ProviderPeriodUsageJSON? = nil,
        openaiServerUsedPercentByPeriod: ProviderPeriodPercentJSON? = nil,
        openaiResetAtByPeriod: ProviderPeriodUsageJSON? = nil,
        openaiPlanType: String? = nil,
        openaiCreditBalance: Double? = nil,
        providers: [String: CustomProviderUsageJSON]? = nil,
        detectedProviders: [String]? = nil,
        source: String? = nil,
        updatedAt: String? = nil
    ) {
        self.openaiUsedTokens = openaiUsedTokens
        self.openaiCostUSD = openaiCostUSD
        self.geminiUsedTokens = geminiUsedTokens
        self.geminiCostUSD = geminiCostUSD
        self.openaiUsedByPeriod = openaiUsedByPeriod
        self.geminiUsedByPeriod = geminiUsedByPeriod
        self.openaiServerUsedPercentByPeriod = openaiServerUsedPercentByPeriod
        self.openaiResetAtByPeriod = openaiResetAtByPeriod
        self.openaiPlanType = openaiPlanType
        self.openaiCreditBalance = openaiCreditBalance
        self.providers = providers
        self.detectedProviders = detectedProviders
        self.source = source
        self.updatedAt = updatedAt
    }
}

// Validate persisted snapshots too; they do not necessarily originate in our collector.
extension LocalUsageData {
    public func validateNumbers() throws {
        for value in [openaiUsedTokens, geminiUsedTokens].compactMap({ $0 }) { _ = try UsageNumber.checked(value) }
        for value in [openaiCostUSD, geminiCostUSD, openaiCreditBalance].compactMap({ $0 }) { _ = try UsageNumber.finite(value) }
        try openaiUsedByPeriod?.validateNumbers()
        try geminiUsedByPeriod?.validateNumbers()
        try openaiResetAtByPeriod?.validateNumbers()
        try openaiServerUsedPercentByPeriod?.validateNumbers()
        for provider in (providers ?? [:]).values {
            try provider.usedByPeriod?.validateNumbers()
            try provider.resetAtByPeriod?.validateNumbers()
            try provider.serverUsedPercentByPeriod?.validateNumbers()
            if let cost = provider.costUSD { _ = try UsageNumber.finite(cost) }
        }
    }
}

extension ProviderPeriodUsageJSON {
    func validateNumbers() throws {
        for value in [twoHours, fiveHours, daily, weekly, monthly].compactMap({ $0 }) {
            _ = try UsageNumber.checked(value)
        }
    }
}

extension ProviderPeriodPercentJSON {
    func validateNumbers() throws {
        for value in [twoHours, fiveHours, daily, weekly, monthly].compactMap({ $0 }) {
            _ = try UsageNumber.finite(value)
        }
    }
}
