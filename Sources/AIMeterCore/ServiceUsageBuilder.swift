import Foundation
import CoreFoundation

// MARK: - Usage Preferences (read model over the app's preferences domain)

/// Snapshot of the preferences that decide which services exist and how their
/// remaining quota is calculated. Keys and defaults mirror the `@AppStorage`
/// declarations and `IntegrationSettingsObservation` in the app target, so a
/// reader outside the app process (the CLI) sees the same state the GUI uses.
/// This is a read model only; writing preferences stays with the app.
public struct UsagePreferences: Equatable {
    public var showOpenAISection: Bool
    public var showGeminiSection: Bool
    public var showAntigravitySection: Bool
    public var openaiEnabledPeriodsCSV: String
    public var geminiEnabledPeriodsCSV: String
    public var openaiLimit2h: Int
    public var openaiLimit5h: Int
    public var openaiLimitDaily: Int
    public var openaiLimitWeekly: Int
    public var openaiLimitMonthly: Int
    public var openaiBudgetUSD: Double
    public var geminiLimit2h: Int
    public var geminiLimit5h: Int
    public var geminiLimitDaily: Int
    public var geminiLimitWeekly: Int
    public var geminiLimitMonthly: Int
    public var geminiBudgetUSD: Double
    public var gcpProjectId: String
    public var hasCompletedSetupWizard: Bool

    public init(
        showOpenAISection: Bool = true,
        showGeminiSection: Bool = true,
        showAntigravitySection: Bool = false,
        openaiEnabledPeriodsCSV: String = "5h,7d,30d",
        geminiEnabledPeriodsCSV: String = "5h,1d,7d,30d",
        openaiLimit2h: Int = 20_000_000,
        openaiLimit5h: Int = 40_000_000,
        openaiLimitDaily: Int = 80_000_000,
        openaiLimitWeekly: Int = 290_000_000,
        openaiLimitMonthly: Int = 800_000_000,
        openaiBudgetUSD: Double = 600.0,
        geminiLimit2h: Int = 750_000,
        geminiLimit5h: Int = 1_500_000,
        geminiLimitDaily: Int = 4_000_000,
        geminiLimitWeekly: Int = 15_000_000,
        geminiLimitMonthly: Int = 40_000_000,
        geminiBudgetUSD: Double = 20.0,
        gcpProjectId: String = "",
        hasCompletedSetupWizard: Bool = true
    ) {
        self.showOpenAISection = showOpenAISection
        self.showGeminiSection = showGeminiSection
        self.showAntigravitySection = showAntigravitySection
        self.openaiEnabledPeriodsCSV = openaiEnabledPeriodsCSV
        self.geminiEnabledPeriodsCSV = geminiEnabledPeriodsCSV
        self.openaiLimit2h = openaiLimit2h
        self.openaiLimit5h = openaiLimit5h
        self.openaiLimitDaily = openaiLimitDaily
        self.openaiLimitWeekly = openaiLimitWeekly
        self.openaiLimitMonthly = openaiLimitMonthly
        self.openaiBudgetUSD = openaiBudgetUSD
        self.geminiLimit2h = geminiLimit2h
        self.geminiLimit5h = geminiLimit5h
        self.geminiLimitDaily = geminiLimitDaily
        self.geminiLimitWeekly = geminiLimitWeekly
        self.geminiLimitMonthly = geminiLimitMonthly
        self.geminiBudgetUSD = geminiBudgetUSD
        self.gcpProjectId = gcpProjectId
        self.hasCompletedSetupWizard = hasCompletedSetupWizard
    }

    /// Mirrors `IntegrationSettingsObservation.isEnabled` in the app target:
    /// absence keeps the product default (enabled), and a malformed persisted
    /// value is not treated as permission.
    public static func integrationEnabled(in defaults: UserDefaults, key: String) -> Bool {
        guard let value = defaults.object(forKey: key) else { return true }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    public static func load(from defaults: UserDefaults) -> UsagePreferences {
        func intValue(_ key: String, fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        func doubleValue(_ key: String, fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        let fallback = UsagePreferences()
        return UsagePreferences(
            showOpenAISection: integrationEnabled(in: defaults, key: "showOpenAISection"),
            showGeminiSection: integrationEnabled(in: defaults, key: "showGeminiSection"),
            showAntigravitySection: defaults.bool(forKey: "showAntigravitySection"),
            openaiEnabledPeriodsCSV: defaults.string(forKey: "openaiEnabledPeriodsCSV") ?? fallback.openaiEnabledPeriodsCSV,
            geminiEnabledPeriodsCSV: defaults.string(forKey: "geminiEnabledPeriodsCSV") ?? fallback.geminiEnabledPeriodsCSV,
            openaiLimit2h: intValue("openaiTokenLimit2h", fallback: fallback.openaiLimit2h),
            openaiLimit5h: intValue("openaiTokenLimit5h", fallback: fallback.openaiLimit5h),
            openaiLimitDaily: intValue("openaiTokenLimitDaily", fallback: fallback.openaiLimitDaily),
            openaiLimitWeekly: intValue("openaiTokenLimitWeekly", fallback: fallback.openaiLimitWeekly),
            openaiLimitMonthly: intValue("openaiTokenLimit", fallback: fallback.openaiLimitMonthly),
            openaiBudgetUSD: doubleValue("openaiBudgetUSD", fallback: fallback.openaiBudgetUSD),
            geminiLimit2h: intValue("geminiTokenLimit2h", fallback: fallback.geminiLimit2h),
            geminiLimit5h: intValue("geminiTokenLimit5h", fallback: fallback.geminiLimit5h),
            geminiLimitDaily: intValue("geminiTokenLimitDaily", fallback: fallback.geminiLimitDaily),
            geminiLimitWeekly: intValue("geminiTokenLimitWeekly", fallback: fallback.geminiLimitWeekly),
            geminiLimitMonthly: intValue("geminiTokenLimit", fallback: fallback.geminiLimitMonthly),
            geminiBudgetUSD: doubleValue("geminiBudgetUSD", fallback: fallback.geminiBudgetUSD),
            gcpProjectId: defaults.string(forKey: "gcpProjectId") ?? "",
            hasCompletedSetupWizard: defaults.object(forKey: "hasCompletedSetupWizard") == nil
                ? true : defaults.bool(forKey: "hasCompletedSetupWizard")
        )
    }
}

// MARK: - Per-Service Usage (read model)

/// One service's usage as the GUI presents it: identity, per-period metrics
/// built by the same rules as `UsageMonitor`, and cost context. Built purely
/// from the persisted snapshot and preferences, so any reader (GUI or CLI)
/// derives the same numbers from the same inputs.
public struct ServiceUsage: Equatable {
    public enum Kind: String, Equatable {
        case builtin
        case custom
    }

    public let id: String
    public let name: String
    public let shortName: String
    public let iconName: String
    public let unit: String
    public let kind: Kind
    public let isEnabled: Bool
    /// Whether collected data (or, for custom services, manual input) backs
    /// the numbers, as opposed to a zeroed initial state.
    public let hasData: Bool
    public let metrics: [PeriodUsageMetric]
    public let costUSD: Double
    public let budgetUSD: Double
    public let statusNote: String
    public let planType: String?

    public init(
        id: String, name: String, shortName: String, iconName: String, unit: String,
        kind: Kind, isEnabled: Bool, hasData: Bool, metrics: [PeriodUsageMetric],
        costUSD: Double, budgetUSD: Double, statusNote: String, planType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.iconName = iconName
        self.unit = unit
        self.kind = kind
        self.isEnabled = isEnabled
        self.hasData = hasData
        self.metrics = metrics
        self.costUSD = costUSD
        self.budgetUSD = budgetUSD
        self.statusNote = statusNote
        self.planType = planType
    }

    /// The frame the GUI leads with, selected by the same rule as
    /// `WidgetServiceItem.fromMetrics`: the tightest available remaining
    /// quota, falling back to the monthly frame, then the first valid frame.
    public var bottleneckMetric: PeriodUsageMetric? {
        let valid = metrics.filter(\.isValid)
        let available = valid.filter(\.isRemainingAvailable)
        return available.min(by: { $0.remainingRatio < $1.remainingRatio })
            ?? valid.first(where: { $0.period == .monthly }) ?? valid.first
    }
}

// MARK: - Builder

/// Builds the service list from the persisted local usage snapshot and
/// preferences. The per-period construction mirrors `UsageMonitor`'s
/// `openaiMetrics` / `geminiMetrics` / `metrics(for:)` so the CLI reports the
/// same frames the app displays, using only shared-core models.
public enum ServiceUsageBuilder {
    public static func services(
        data: LocalUsageData?,
        preferences: UsagePreferences,
        customSubscriptions: [CustomSubscriptionConfig]
    ) -> [ServiceUsage] {
        var result: [ServiceUsage] = [
            openAI(data: data, preferences: preferences),
            gemini(data: data, preferences: preferences),
            antigravity(preferences: preferences)
        ]
        for subscription in customSubscriptions {
            result.append(custom(subscription, data: data))
        }
        return result
    }

    public static func isPeriodEnabled(csv: String, period: LimitPeriod) -> Bool {
        let parts = csv.split(separator: ",").map(String.init)
        return parts.contains(period.rawValue)
    }

    private static func openAI(data: LocalUsageData?, preferences: UsagePreferences) -> ServiceUsage {
        let all = [
            PeriodUsageMetric(
                period: .twoHours,
                usedTokens: max(0, data?.openaiUsedByPeriod?.twoHours ?? 0),
                limitTokens: preferences.openaiLimit2h,
                serverUsedPercent: data?.openaiServerUsedPercentByPeriod?.twoHours,
                resetTimestamp: data?.openaiResetAtByPeriod?.twoHours
            ),
            PeriodUsageMetric(
                period: .fiveHours,
                usedTokens: max(0, data?.openaiUsedByPeriod?.fiveHours ?? 0),
                limitTokens: preferences.openaiLimit5h,
                serverUsedPercent: data?.openaiServerUsedPercentByPeriod?.fiveHours,
                resetTimestamp: data?.openaiResetAtByPeriod?.fiveHours
            ),
            PeriodUsageMetric(
                period: .daily,
                usedTokens: max(0, data?.openaiUsedByPeriod?.daily ?? 0),
                limitTokens: preferences.openaiLimitDaily,
                serverUsedPercent: data?.openaiServerUsedPercentByPeriod?.daily,
                resetTimestamp: data?.openaiResetAtByPeriod?.daily
            ),
            PeriodUsageMetric(
                period: .weekly,
                usedTokens: max(0, data?.openaiUsedByPeriod?.weekly ?? 0),
                limitTokens: preferences.openaiLimitWeekly,
                serverUsedPercent: data?.openaiServerUsedPercentByPeriod?.weekly,
                resetTimestamp: data?.openaiResetAtByPeriod?.weekly
            ),
            PeriodUsageMetric(
                period: .monthly,
                usedTokens: max(0, data?.openaiUsedByPeriod?.monthly ?? data?.openaiUsedTokens ?? 0),
                limitTokens: preferences.openaiLimitMonthly,
                serverUsedPercent: data?.openaiServerUsedPercentByPeriod?.monthly,
                resetTimestamp: data?.openaiResetAtByPeriod?.monthly
            )
        ]
        let filtered = all.filter { $0.period.map { isPeriodEnabled(csv: preferences.openaiEnabledPeriodsCSV, period: $0) } ?? false }
        return ServiceUsage(
            id: "openai", name: "OpenAI Codex", shortName: "OAI", iconName: "brain.head.profile",
            unit: "tokens", kind: .builtin, isEnabled: preferences.showOpenAISection,
            hasData: data != nil, metrics: filtered.isEmpty ? all : filtered,
            costUSD: data?.openaiCostUSD ?? 0, budgetUSD: preferences.openaiBudgetUSD,
            statusNote: "", planType: data?.openaiPlanType
        )
    }

    private static func gemini(data: LocalUsageData?, preferences: UsagePreferences) -> ServiceUsage {
        let all = [
            PeriodUsageMetric(period: .twoHours, usedTokens: max(0, data?.geminiUsedByPeriod?.twoHours ?? 0), limitTokens: preferences.geminiLimit2h, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .fiveHours, usedTokens: max(0, data?.geminiUsedByPeriod?.fiveHours ?? 0), limitTokens: preferences.geminiLimit5h, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .daily, usedTokens: max(0, data?.geminiUsedByPeriod?.daily ?? 0), limitTokens: preferences.geminiLimitDaily, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .weekly, usedTokens: max(0, data?.geminiUsedByPeriod?.weekly ?? 0), limitTokens: preferences.geminiLimitWeekly, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .monthly, usedTokens: max(0, data?.geminiUsedByPeriod?.monthly ?? data?.geminiUsedTokens ?? 0), limitTokens: preferences.geminiLimitMonthly, requiresOfficialQuota: true)
        ]
        let filtered = all.filter { $0.period.map { isPeriodEnabled(csv: preferences.geminiEnabledPeriodsCSV, period: $0) } ?? false }
        return ServiceUsage(
            id: "gemini", name: "Gemini", shortName: "Gem", iconName: "sparkle",
            unit: "tokens", kind: .builtin, isEnabled: preferences.showGeminiSection,
            hasData: data != nil, metrics: filtered.isEmpty ? all : filtered,
            costUSD: data?.geminiCostUSD ?? 0, budgetUSD: preferences.geminiBudgetUSD,
            statusNote: ""
        )
    }

    private static func antigravity(preferences: UsagePreferences) -> ServiceUsage {
        // Antigravity's quota lives only in the app's memory (fetched live and
        // never persisted), so a file-based reader can only report the same
        // "unavailable" frame the app shows when it has no live snapshot.
        let placeholder = PeriodUsageMetric(
            period: nil, usedTokens: 0, limitTokens: 0, requiresOfficialQuota: true,
            quotaWindowID: "antigravity-unavailable", quotaWindowLabel: "利用枠", isQuotaOnly: true
        )
        return ServiceUsage(
            id: "antigravity", name: "Antigravity", shortName: "AG", iconName: "sparkles",
            unit: "", kind: .builtin, isEnabled: preferences.showAntigravitySection,
            hasData: false, metrics: [placeholder],
            costUSD: 0, budgetUSD: 0, statusNote: ""
        )
    }

    private static func custom(_ subscription: CustomSubscriptionConfig, data: LocalUsageData?) -> ServiceUsage {
        let baseKey = subscription.id.split(separator: "_").first.map(String.init) ?? subscription.id
        let providers = data?.providers ?? [:]
        let live = providers[subscription.id] ?? providers[baseKey]
        let used2h = live?.usedByPeriod?.twoHours ?? subscription.manualUsed2h
        let used5h = live?.usedByPeriod?.fiveHours ?? subscription.manualUsed5h
        let usedDaily = live?.usedByPeriod?.daily ?? subscription.manualUsedDaily
        let usedWeekly = live?.usedByPeriod?.weekly ?? subscription.manualUsedWeekly
        let usedMonthly = live?.usedByPeriod?.monthly ?? subscription.manualUsedMonthly

        let all = [
            PeriodUsageMetric(
                period: .twoHours,
                usedTokens: max(subscription.manualUsed2h, used2h),
                limitTokens: subscription.limit2h,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.twoHours,
                resetTimestamp: live?.resetAtByPeriod?.twoHours
            ),
            PeriodUsageMetric(
                period: .fiveHours,
                usedTokens: max(subscription.manualUsed5h, used5h),
                limitTokens: subscription.limit5h,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.fiveHours,
                resetTimestamp: live?.resetAtByPeriod?.fiveHours
            ),
            PeriodUsageMetric(
                period: .daily,
                usedTokens: max(subscription.manualUsedDaily, usedDaily),
                limitTokens: subscription.limitDaily,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.daily,
                resetTimestamp: live?.resetAtByPeriod?.daily
            ),
            PeriodUsageMetric(
                period: .weekly,
                usedTokens: max(subscription.manualUsedWeekly, usedWeekly),
                limitTokens: subscription.limitWeekly,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.weekly,
                resetTimestamp: live?.resetAtByPeriod?.weekly
            ),
            PeriodUsageMetric(
                period: .monthly,
                usedTokens: max(subscription.manualUsedMonthly, usedMonthly),
                limitTokens: subscription.limitMonthly,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.monthly,
                resetTimestamp: live?.resetAtByPeriod?.monthly
            )
        ]
        let filtered = all.filter { $0.period.map { subscription.isPeriodEnabled($0) } ?? false }
        let cost: Double
        if let liveCost = live?.costUSD, liveCost > 0 {
            cost = max(subscription.usedCostUSD, liveCost)
        } else {
            cost = subscription.usedCostUSD
        }
        let hasManualInput = subscription.manualUsed2h > 0 || subscription.manualUsed5h > 0
            || subscription.manualUsedDaily > 0 || subscription.manualUsedWeekly > 0
            || subscription.manualUsedMonthly > 0
        return ServiceUsage(
            id: subscription.id, name: subscription.name, shortName: subscription.shortName,
            iconName: subscription.iconName, unit: providerUnit(for: subscription.id),
            kind: .custom, isEnabled: subscription.isEnabled,
            hasData: live != nil || hasManualInput,
            metrics: filtered.isEmpty ? [all[all.count - 1]] : filtered,
            costUSD: cost, budgetUSD: subscription.budgetUSD, statusNote: subscription.statusNote
        )
    }
}
