import SwiftUI
import AppKit
import Foundation
import Security
import ServiceManagement
import AIMeterCore
import Combine

// MARK: - Notifications
extension Notification.Name {
    static let showDesktopWidgetRequest = Notification.Name("com.local.AIMeter.showDesktopWidgetRequest")
}

// MARK: - Launch at Login Manager
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        if #available(macOS 13.0, *) {
            isEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    func setEnabled(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                isEnabled = (SMAppService.mainApp.status == .enabled)
            } catch {
                print("[AIMeter] Failed to update Launch at Login: \(error)")
                refresh()
            }
        }
    }
}

// MARK: - Usage Monitor
@MainActor
final class UsageMonitor: ObservableObject {
    @AppStorage("didCalibrateRealLimitsV1") var didCalibrateRealLimitsV1: Bool = false
    @AppStorage("didAutoSeedLocalProvidersV2") var didAutoSeedLocalProvidersV2: Bool = false
    @AppStorage("didMigrateHonestCostsV3") var didMigrateHonestCostsV3: Bool = false
    @AppStorage("hasCompletedSetupWizard") var hasCompletedSetupWizard: Bool = true
    @AppStorage("autoShowWidgetOnLaunch") var autoShowWidgetOnLaunch: Bool = true
    @Published var hasAutoOpenedWidgetOnLaunch: Bool = false
    @AppStorage("customProviderPathsJSON") var customProviderPathsJSON: String = "{}"
    @AppStorage("openaiAdminKey") var legacyOpenaiAdminKey: String = ""
    @Published var openaiAdminKey: String = "" {
        didSet {
            KeychainHelper.save(key: "openaiAdminKey", value: openaiAdminKey)
        }
    }

    var customProviderPaths: [String: String] {
        get {
            guard let data = customProviderPathsJSON.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                customProviderPathsJSON = str
            }
        }
    }

    func setCustomPath(for providerId: String, path: String) {
        var current = customProviderPaths
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            current.removeValue(forKey: providerId)
        } else {
            current[providerId] = trimmed
        }
        customProviderPaths = current
    }

    // Built-in Provider Visibility & Period Toggles
    @AppStorage("showOpenAISection") var showOpenAISection: Bool = true
    @AppStorage("showGeminiSection") var showGeminiSection: Bool = true
    @AppStorage("showOpenAIInMenuBar") var showOpenAIInMenuBar: Bool = true
    @AppStorage("showGeminiInMenuBar") var showGeminiInMenuBar: Bool = true
    @AppStorage("openaiEnabledPeriodsCSV") var openaiEnabledPeriodsCSV: String = "5h,7d,30d"
    @AppStorage("geminiEnabledPeriodsCSV") var geminiEnabledPeriodsCSV: String = "5h,1d,7d,30d"

    // OpenAI Token Limits per Period
    @AppStorage("openaiTokenLimit2h") var openaiTokenLimit2h: Int = 20_000_000
    @AppStorage("openaiTokenLimit5h") var openaiTokenLimit5h: Int = 40_000_000
    @AppStorage("openaiTokenLimitDaily") var openaiTokenLimitDaily: Int = 80_000_000
    @AppStorage("openaiTokenLimitWeekly") var openaiTokenLimitWeekly: Int = 290_000_000
    @AppStorage("openaiTokenLimit") var openaiTokenLimit: Int = 800_000_000
    @AppStorage("openaiBudgetUSD") var openaiBudgetUSD: Double = 600.0

    // Gemini Token Limits per Period
    @AppStorage("gcpProjectId") var gcpProjectId: String = ""
    @AppStorage("geminiTokenLimit2h") var geminiTokenLimit2h: Int = 750_000
    @AppStorage("geminiTokenLimit5h") var geminiTokenLimit5h: Int = 1_500_000
    @AppStorage("geminiTokenLimitDaily") var geminiTokenLimitDaily: Int = 4_000_000
    @AppStorage("geminiTokenLimitWeekly") var geminiTokenLimitWeekly: Int = 15_000_000
    @AppStorage("geminiTokenLimit") var geminiTokenLimit: Int = 40_000_000
    @AppStorage("geminiBudgetUSD") var geminiBudgetUSD: Double = 20.0

    // Custom Subscriptions JSON persistence
    @AppStorage("customSubscriptionsJSON") var customSubscriptionsJSON: String = "[]"
    @Published var customSubscriptions: [CustomSubscriptionConfig] = [] {
        didSet {
            saveCustomSubscriptions()
        }
    }
    @Published var customProviderLiveUsage: [String: CustomProviderUsageJSON] = [:]
    @Published var detectedProviderIds: [String] = []

    // MenuBar Display Period Mode ("min" = bottleneck or LimitPeriod.rawValue)
    @AppStorage("menuBarPeriodMode") var menuBarPeriodMode: String = "min"
    @AppStorage("menuBarDisplayMode") var menuBarDisplayMode: String = "smart"
    @AppStorage("isDetailedView") var isDetailedView: Bool = false
    @AppStorage("showUsageAmounts") var showUsageAmounts: Bool = false
    @AppStorage("isWidgetPinned") var isWidgetPinned: Bool = true
    @Published var isDesktopWidgetOpen: Bool = false

    // OpenAI Used Tokens per Period
    @Published var openaiUsed2h: Int = 0
    @Published var openaiUsed5h: Int = 0
    @Published var openaiUsedDaily: Int = 0
    @Published var openaiUsedWeekly: Int = 0
    @Published var openaiUsedTokens: Int = 0
    @Published var openaiServerPct: ProviderPeriodPercentJSON? = nil
    @Published var openaiResetAt: ProviderPeriodUsageJSON? = nil
    @Published var openaiCostUSD: Double = 0.0
    @Published var openaiStatus: String = "実ログ"

    // Gemini Used Tokens per Period
    @Published var geminiUsed2h: Int = 0
    @Published var geminiUsed5h: Int = 0
    @Published var geminiUsedDaily: Int = 0
    @Published var geminiUsedWeekly: Int = 0
    @Published var geminiUsedTokens: Int = 0
    @Published var geminiCostUSD: Double = 0.0
    @Published var geminiStatus: String = "実ログ"

    @Published var lastUpdated: Date?
    @Published var isRefreshing: Bool = false
    @Published var collectionError: String?

    private var settingsObserver: AnyCancellable?
    private var hasUsageSnapshot = false
    private var widgetUpdatedAt: Date?
    @Published var widgetSharingError: String?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let urlSession: URLSession
    private var isLoadingSubscriptions: Bool = false

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true) {
        _didCalibrateRealLimitsV1 = AppStorage(wrappedValue: false, "didCalibrateRealLimitsV1", store: defaults)
        _didAutoSeedLocalProvidersV2 = AppStorage(wrappedValue: false, "didAutoSeedLocalProvidersV2", store: defaults)
        _didMigrateHonestCostsV3 = AppStorage(wrappedValue: false, "didMigrateHonestCostsV3", store: defaults)
        _hasCompletedSetupWizard = AppStorage(wrappedValue: true, "hasCompletedSetupWizard", store: defaults)
        _autoShowWidgetOnLaunch = AppStorage(wrappedValue: true, "autoShowWidgetOnLaunch", store: defaults)
        _customProviderPathsJSON = AppStorage(wrappedValue: "{}", "customProviderPathsJSON", store: defaults)
        _legacyOpenaiAdminKey = AppStorage(wrappedValue: "", "openaiAdminKey", store: defaults)
        _showOpenAISection = AppStorage(wrappedValue: true, "showOpenAISection", store: defaults)
        _showGeminiSection = AppStorage(wrappedValue: true, "showGeminiSection", store: defaults)
        _showOpenAIInMenuBar = AppStorage(wrappedValue: true, "showOpenAIInMenuBar", store: defaults)
        _showGeminiInMenuBar = AppStorage(wrappedValue: true, "showGeminiInMenuBar", store: defaults)
        _openaiEnabledPeriodsCSV = AppStorage(wrappedValue: "5h,7d,30d", "openaiEnabledPeriodsCSV", store: defaults)
        _geminiEnabledPeriodsCSV = AppStorage(wrappedValue: "5h,1d,7d,30d", "geminiEnabledPeriodsCSV", store: defaults)
        _openaiTokenLimit2h = AppStorage(wrappedValue: 20_000_000, "openaiTokenLimit2h", store: defaults)
        _openaiTokenLimit5h = AppStorage(wrappedValue: 40_000_000, "openaiTokenLimit5h", store: defaults)
        _openaiTokenLimitDaily = AppStorage(wrappedValue: 80_000_000, "openaiTokenLimitDaily", store: defaults)
        _openaiTokenLimitWeekly = AppStorage(wrappedValue: 290_000_000, "openaiTokenLimitWeekly", store: defaults)
        _openaiTokenLimit = AppStorage(wrappedValue: 800_000_000, "openaiTokenLimit", store: defaults)
        _openaiBudgetUSD = AppStorage(wrappedValue: 600.0, "openaiBudgetUSD", store: defaults)
        _gcpProjectId = AppStorage(wrappedValue: "", "gcpProjectId", store: defaults)
        _geminiTokenLimit2h = AppStorage(wrappedValue: 750_000, "geminiTokenLimit2h", store: defaults)
        _geminiTokenLimit5h = AppStorage(wrappedValue: 1_500_000, "geminiTokenLimit5h", store: defaults)
        _geminiTokenLimitDaily = AppStorage(wrappedValue: 4_000_000, "geminiTokenLimitDaily", store: defaults)
        _geminiTokenLimitWeekly = AppStorage(wrappedValue: 15_000_000, "geminiTokenLimitWeekly", store: defaults)
        _geminiTokenLimit = AppStorage(wrappedValue: 40_000_000, "geminiTokenLimit", store: defaults)
        _geminiBudgetUSD = AppStorage(wrappedValue: 20.0, "geminiBudgetUSD", store: defaults)
        _customSubscriptionsJSON = AppStorage(wrappedValue: "[]", "customSubscriptionsJSON", store: defaults)
        _menuBarPeriodMode = AppStorage(wrappedValue: "min", "menuBarPeriodMode", store: defaults)
        _menuBarDisplayMode = AppStorage(wrappedValue: "smart", "menuBarDisplayMode", store: defaults)
        _isDetailedView = AppStorage(wrappedValue: false, "isDetailedView", store: defaults)
        _showUsageAmounts = AppStorage(wrappedValue: false, "showUsageAmounts", store: defaults)
        _isWidgetPinned = AppStorage(wrappedValue: true, "isWidgetPinned", store: defaults)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 30.0
        self.urlSession = URLSession(configuration: config)
        guard startMonitoring else { return }

        let restoredKey = KeychainHelper.restore(key: "openaiAdminKey", legacyValue: legacyOpenaiAdminKey)
        if let value = restoredKey.value { self.openaiAdminKey = value }
        if restoredKey.canClearLegacy { legacyOpenaiAdminKey = "" }

        if !didCalibrateRealLimitsV1 {
            if openaiTokenLimit == 5_000_000 { openaiTokenLimit = 800_000_000 }
            if openaiTokenLimitWeekly == 2_000_000 { openaiTokenLimitWeekly = 290_000_000 }
            if openaiTokenLimitDaily == 500_000 { openaiTokenLimitDaily = 80_000_000 }
            if openaiTokenLimit5h == 150_000 { openaiTokenLimit5h = 40_000_000 }
            if openaiBudgetUSD == 20.0 { openaiBudgetUSD = 600.0 }

            if geminiTokenLimit == 10_000_000 { geminiTokenLimit = 40_000_000 }
            if geminiTokenLimitWeekly == 4_000_000 { geminiTokenLimitWeekly = 15_000_000 }
            if geminiTokenLimitDaily == 1_000_000 { geminiTokenLimitDaily = 4_000_000 }
            if geminiTokenLimit5h == 300_000 { geminiTokenLimit5h = 1_500_000 }
            menuBarPeriodMode = "min"
            didCalibrateRealLimitsV1 = true
        }

        loadCustomSubscriptions()
        sanitizeSettings()
        restoreLocalSnapshot()
        observeWidgetSettings()

        Task {
            await refresh()
        }

        let scheduledTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        scheduledTimer.tolerance = 6.0
        self.timer = scheduledTimer

        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    private func loadCustomSubscriptions() {
        isLoadingSubscriptions = true
        defer { isLoadingSubscriptions = false }
        guard let data = customSubscriptionsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CustomSubscriptionConfig].self, from: data) else {
            customSubscriptions = []
            return
        }
        customSubscriptions = decoded
    }

    private func saveCustomSubscriptions() {
        guard !isLoadingSubscriptions else { return }
        if let data = try? JSONEncoder().encode(customSubscriptions),
           let str = String(data: data, encoding: .utf8) {
            customSubscriptionsJSON = str
        }
    }

    func addSubscription(_ preset: CustomSubscriptionConfig) {
        var newSub = preset
        if customSubscriptions.contains(where: { $0.id == newSub.id }) {
            let suffix = String(UUID().uuidString.prefix(4)).lowercased()
            newSub.id = "\(newSub.id)_\(suffix)"
        }
        newSub.sanitize()
        customSubscriptions.append(newSub)
    }

    func autoAddDetectedSubscriptions() {
        let candidateIds = detectedProviderIds.isEmpty
            ? ["grokbot", "claude", "windsurf", "copilot", "cursor"]
            : detectedProviderIds
        for pid in candidateIds where pid != "trae" {
            if !customSubscriptions.contains(where: { $0.id == pid || $0.id.hasPrefix("\(pid)_") }),
               let preset = CustomSubscriptionConfig.preset(forId: pid) {
                var newSub = preset
                newSub.sanitize()
                customSubscriptions.append(newSub)
            }
        }
    }

    func removeSubscription(id: String) {
        customSubscriptions.removeAll { $0.id == id }
    }

    func isBuiltInPeriodEnabled(csv: String, period: LimitPeriod) -> Bool {
        let parts = csv.split(separator: ",").map(String.init)
        return parts.contains(period.rawValue)
    }

    func setBuiltInPeriod(isOpenAI: Bool, period: LimitPeriod, enabled: Bool) {
        let currentCSV = isOpenAI ? openaiEnabledPeriodsCSV : geminiEnabledPeriodsCSV
        var parts = currentCSV.split(separator: ",").map(String.init)
        if enabled {
            if !parts.contains(period.rawValue) {
                parts.append(period.rawValue)
            }
        } else if parts.count > 1 {
            parts.removeAll { $0 == period.rawValue }
        }
        let ordered = LimitPeriod.allCases.map(\.rawValue).filter { parts.contains($0) }.joined(separator: ",")
        if isOpenAI {
            openaiEnabledPeriodsCSV = ordered.isEmpty ? "30d" : ordered
        } else {
            geminiEnabledPeriodsCSV = ordered.isEmpty ? "30d" : ordered
        }
        isDetailedView = true
    }

    func sanitizeSettings() {
        if openaiTokenLimit2h < 1 { openaiTokenLimit2h = 1 }
        if openaiTokenLimit5h < 1 { openaiTokenLimit5h = 1 }
        if openaiTokenLimitDaily < 1 { openaiTokenLimitDaily = 1 }
        if openaiTokenLimitWeekly < 1 { openaiTokenLimitWeekly = 1 }
        if openaiTokenLimit < 1 { openaiTokenLimit = 1 }
        if openaiBudgetUSD < 0 { openaiBudgetUSD = 0 }

        if geminiTokenLimit2h < 1 { geminiTokenLimit2h = 1 }
        if geminiTokenLimit5h < 1 { geminiTokenLimit5h = 1 }
        if geminiTokenLimitDaily < 1 { geminiTokenLimitDaily = 1 }
        if geminiTokenLimitWeekly < 1 { geminiTokenLimitWeekly = 1 }
        if geminiTokenLimit < 1 { geminiTokenLimit = 1 }
        if geminiBudgetUSD < 0 { geminiBudgetUSD = 0 }

        for idx in customSubscriptions.indices {
            customSubscriptions[idx].sanitize()
        }
    }

    var openaiMetrics: [PeriodUsageMetric] {
        let all = [
            PeriodUsageMetric(
                period: .twoHours,
                usedTokens: openaiUsed2h,
                limitTokens: openaiTokenLimit2h,
                serverUsedPercent: openaiServerPct?.twoHours,
                resetTimestamp: openaiResetAt?.twoHours
            ),
            PeriodUsageMetric(
                period: .fiveHours,
                usedTokens: openaiUsed5h,
                limitTokens: openaiTokenLimit5h,
                serverUsedPercent: openaiServerPct?.fiveHours,
                resetTimestamp: openaiResetAt?.fiveHours
            ),
            PeriodUsageMetric(
                period: .daily,
                usedTokens: openaiUsedDaily,
                limitTokens: openaiTokenLimitDaily,
                serverUsedPercent: openaiServerPct?.daily,
                resetTimestamp: openaiResetAt?.daily
            ),
            PeriodUsageMetric(
                period: .weekly,
                usedTokens: openaiUsedWeekly,
                limitTokens: openaiTokenLimitWeekly,
                serverUsedPercent: openaiServerPct?.weekly,
                resetTimestamp: openaiResetAt?.weekly
            ),
            PeriodUsageMetric(
                period: .monthly,
                usedTokens: openaiUsedTokens,
                limitTokens: openaiTokenLimit,
                serverUsedPercent: openaiServerPct?.monthly,
                resetTimestamp: openaiResetAt?.monthly
            )
        ]
        let filtered = all.filter { isBuiltInPeriodEnabled(csv: openaiEnabledPeriodsCSV, period: $0.period) }
        return filtered.isEmpty ? all : filtered
    }

    var geminiMetrics: [PeriodUsageMetric] {
        let all = [
            PeriodUsageMetric(period: .twoHours, usedTokens: geminiUsed2h, limitTokens: geminiTokenLimit2h, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .fiveHours, usedTokens: geminiUsed5h, limitTokens: geminiTokenLimit5h, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .daily, usedTokens: geminiUsedDaily, limitTokens: geminiTokenLimitDaily, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .weekly, usedTokens: geminiUsedWeekly, limitTokens: geminiTokenLimitWeekly, requiresOfficialQuota: true),
            PeriodUsageMetric(period: .monthly, usedTokens: geminiUsedTokens, limitTokens: geminiTokenLimit, requiresOfficialQuota: true)
        ]
        let filtered = all.filter { isBuiltInPeriodEnabled(csv: geminiEnabledPeriodsCSV, period: $0.period) }
        return filtered.isEmpty ? all : filtered
    }

    func metrics(for sub: CustomSubscriptionConfig) -> [PeriodUsageMetric] {
        let baseKey = sub.id.split(separator: "_").first.map(String.init) ?? sub.id
        let live = customProviderLiveUsage[sub.id] ?? customProviderLiveUsage[baseKey]
        let u2h = live?.usedByPeriod?.twoHours ?? sub.manualUsed2h
        let u5h = live?.usedByPeriod?.fiveHours ?? sub.manualUsed5h
        let u1d = live?.usedByPeriod?.daily ?? sub.manualUsedDaily
        let u7d = live?.usedByPeriod?.weekly ?? sub.manualUsedWeekly
        let u30d = live?.usedByPeriod?.monthly ?? sub.manualUsedMonthly

        let all = [
            PeriodUsageMetric(
                period: .twoHours,
                usedTokens: max(sub.manualUsed2h, u2h),
                limitTokens: sub.limit2h,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.twoHours,
                resetTimestamp: live?.resetAtByPeriod?.twoHours
            ),
            PeriodUsageMetric(
                period: .fiveHours,
                usedTokens: max(sub.manualUsed5h, u5h),
                limitTokens: sub.limit5h,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.fiveHours,
                resetTimestamp: live?.resetAtByPeriod?.fiveHours
            ),
            PeriodUsageMetric(
                period: .daily,
                usedTokens: max(sub.manualUsedDaily, u1d),
                limitTokens: sub.limitDaily,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.daily,
                resetTimestamp: live?.resetAtByPeriod?.daily
            ),
            PeriodUsageMetric(
                period: .weekly,
                usedTokens: max(sub.manualUsedWeekly, u7d),
                limitTokens: sub.limitWeekly,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.weekly,
                resetTimestamp: live?.resetAtByPeriod?.weekly
            ),
            PeriodUsageMetric(
                period: .monthly,
                usedTokens: max(sub.manualUsedMonthly, u30d),
                limitTokens: sub.limitMonthly,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.monthly,
                resetTimestamp: live?.resetAtByPeriod?.monthly
            )
        ]
        let filtered = all.filter { sub.isPeriodEnabled($0.period) }
        return filtered.isEmpty ? [all.last!] : filtered
    }

    func effectiveCostUSD(for sub: CustomSubscriptionConfig) -> Double {
        let baseKey = sub.id.split(separator: "_").first.map(String.init) ?? sub.id
        let live = customProviderLiveUsage[sub.id] ?? customProviderLiveUsage[baseKey]
        if let liveCost = live?.costUSD, liveCost > 0 {
            return max(sub.usedCostUSD, liveCost)
        }
        return sub.usedCostUSD
    }

    var totalCostUSD: Double {
        var sum = 0.0
        if showOpenAISection { sum += openaiCostUSD }
        if showGeminiSection { sum += geminiCostUSD }
        for sub in customSubscriptions where sub.isEnabled {
            sum += effectiveCostUSD(for: sub)
        }
        return sum
    }

    func activeMetric(for metrics: [PeriodUsageMetric]) -> PeriodUsageMetric? {
        if menuBarPeriodMode == "min" {
            return metrics.filter(\.isRemainingAvailable).min(by: { $0.remainingRatio < $1.remainingRatio })
        }
        if let period = LimitPeriod(rawValue: menuBarPeriodMode),
           let matched = metrics.first(where: { $0.period == period }) {
            return matched.isRemainingAvailable ? matched : nil
        }
        return metrics.filter(\.isRemainingAvailable).min(by: { $0.remainingRatio < $1.remainingRatio })
    }

    var activeBottlenecks: [ServiceBottleneck] {
        var list: [ServiceBottleneck] = []
        if showOpenAISection && showOpenAIInMenuBar, !openaiMetrics.isEmpty {
            if let minMetric = openaiMetrics.filter(\.isRemainingAvailable).min(by: { $0.remainingRatio < $1.remainingRatio }) {
                list.append(ServiceBottleneck(
                    id: "openai",
                    name: "OpenAI",
                    shortName: "GPT",
                    iconName: "brain.head.profile",
                    remainingPercent: minMetric.remainingPercent,
                    remainingRatio: minMetric.remainingRatio,
                    bottleneckPeriod: minMetric.period,
                    remainingSource: minMetric.remainingSource
                ))
            }
        }
        if showGeminiSection && showGeminiInMenuBar, !geminiMetrics.isEmpty {
            if let minMetric = geminiMetrics.filter(\.isRemainingAvailable).min(by: { $0.remainingRatio < $1.remainingRatio }) {
                list.append(ServiceBottleneck(
                    id: "gemini",
                    name: "Gemini",
                    shortName: "Gem",
                    iconName: "sparkle",
                    remainingPercent: minMetric.remainingPercent,
                    remainingRatio: minMetric.remainingRatio,
                    bottleneckPeriod: minMetric.period,
                    remainingSource: minMetric.remainingSource
                ))
            }
        }
        for sub in customSubscriptions where sub.isEnabled && sub.showInMenuBar {
            let m = metrics(for: sub)
            if let minMetric = m.filter(\.isRemainingAvailable).min(by: { $0.remainingRatio < $1.remainingRatio }) {
                list.append(ServiceBottleneck(
                    id: sub.id,
                    name: sub.name,
                    shortName: sub.shortName,
                    iconName: sub.iconName,
                    remainingPercent: minMetric.remainingPercent,
                    remainingRatio: minMetric.remainingRatio,
                    bottleneckPeriod: minMetric.period,
                    remainingSource: minMetric.remainingSource
                ))
            }
        }
        return list.sorted(by: { $0.remainingRatio < $1.remainingRatio })
    }

    var menuBarTitle: String {
        let bottlenecks = activeBottlenecks
        var services: [(String, [PeriodUsageMetric])] = []
        if showOpenAISection && showOpenAIInMenuBar { services.append(("GPT", openaiMetrics)) }
        if showGeminiSection && showGeminiInMenuBar { services.append(("Gem", geminiMetrics)) }
        for sub in customSubscriptions where sub.isEnabled && sub.showInMenuBar {
            services.append((sub.shortName, metrics(for: sub)))
        }
        func display(_ metrics: [PeriodUsageMetric]) -> String {
            guard let metric = activeMetric(for: metrics) else {
                return metrics.contains(where: { !$0.isValid }) ? "数値エラー" : "未取得"
            }
            return metric.remainingSource.percentText(metric.remainingPercent)
        }
        let fallback = services.first.map { "\($0.0) \(display($0.1))" } ?? "AIMeter"

        let mode = MenuBarDisplayMode(rawValue: menuBarDisplayMode) ?? .smart
        switch mode {
        case .smart:
            if let first = bottlenecks.first {
                let prefix = first.remainingPercent < 15 ? "⚠️ " : ""
                return "\(prefix)\(first.shortName) 残\(first.remainingSource.percentText(first.remainingPercent))"
            }
            return fallback
        case .compact:
            let topTwo = bottlenecks.prefix(2)
            return topTwo.isEmpty ? fallback : topTwo.map { "\($0.shortName) 残\($0.remainingSource.percentText($0.remainingPercent))" }.joined(separator: " · ")
        case .iconOnly:
            if let first = bottlenecks.first {
                return "残\(first.remainingSource.percentText(first.remainingPercent))"
            }
            return fallback
        case .all:
            let segments = services.map { "\($0.0):\(display($0.1))" }
            return segments.isEmpty ? "AIMeter" : segments.joined(separator: " ")
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        collectionError = nil
        sanitizeSettings()
        defer {
            if collectionError == nil {
                lastUpdated = Date()
                widgetUpdatedAt = lastUpdated
            }
            isRefreshing = false
            publishWidgetSnapshot()
        }

        let error = await RefreshSequence.run(local: {
            try await runLocalCollectorScript()
            applyLocalSnapshot(loadLocalJSON())
        }, remote: {
            await refreshConfiguredAPIs()
        })
        if let error {
            collectionError = "収集エラー: \(error.localizedDescription)"
        }
    }

    /// Both the floating window and WidgetKit use these exact, resolved metrics.
    func widgetSnapshot() -> AIMeterWidgetSnapshot {
        var services: [WidgetServiceItem] = []
        if showOpenAISection, let item = WidgetServiceItem.fromMetrics(
            id: "openai", name: "OpenAI Codex", shortName: "OAI", iconName: "brain.head.profile",
            unit: "tokens", metrics: openaiMetrics
        ) { services.append(item) }
        if showGeminiSection, let item = WidgetServiceItem.fromMetrics(
            id: "gemini", name: "Gemini", shortName: "Gem", iconName: "sparkle",
            unit: "tokens", metrics: geminiMetrics
        ) { services.append(item) }
        for sub in customSubscriptions where sub.isEnabled {
            if let item = WidgetServiceItem.fromMetrics(
                id: sub.id, name: sub.name, shortName: sub.shortName, iconName: sub.iconName,
                unit: providerUnit(for: sub.id), metrics: metrics(for: sub)
            ) { services.append(item) }
        }
        return .make(services: services, totalCostUSD: totalCostUSD,
                     updatedAt: widgetUpdatedAt, hasData: hasUsageSnapshot,
                     updateFailed: collectionError != nil, showUsageAmounts: showUsageAmounts)
    }

    func observeWidgetSettings(to customURL: URL? = nil) {
        settingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isRefreshing else { return }
                self.publishWidgetSnapshot(to: customURL)
            }
    }

    func publishWidgetSnapshot(to customURL: URL? = nil) {
        do {
            try SharedStore.saveWidgetSnapshot(widgetSnapshot(), to: customURL)
            widgetSharingError = nil
            if customURL == nil { SharedStore.reloadWidgetTimelines() }
        } catch {
            widgetSharingError = "Widgetの表示情報を保存できませんでした。更新を再試行してください"
        }
    }

    func recordUsageUpdate(at date: Date = Date()) {
        hasUsageSnapshot = true
        widgetUpdatedAt = date
        lastUpdated = date
    }

    func restoreLocalSnapshot(from customURL: URL? = nil) {
        applyLocalSnapshot(loadLocalJSON(from: customURL))
    }

    func applyLocalSnapshot(_ localData: LocalUsageData?) {
        if let localData {
            recordUsageUpdate(at: localData.updatedAt.flatMap(LocalUsageCollector.parseISODate) ?? Date())
            let monthlyOpenAI = max(0, localData.openaiUsedByPeriod?.monthly ?? localData.openaiUsedTokens ?? 0)
            openaiUsedTokens = monthlyOpenAI
            openaiUsedWeekly = max(0, localData.openaiUsedByPeriod?.weekly ?? 0)
            openaiUsedDaily = max(0, localData.openaiUsedByPeriod?.daily ?? 0)
            openaiUsed5h = max(0, localData.openaiUsedByPeriod?.fiveHours ?? 0)
            openaiUsed2h = max(0, localData.openaiUsedByPeriod?.twoHours ?? 0)
            openaiServerPct = localData.openaiServerUsedPercentByPeriod
            openaiResetAt = localData.openaiResetAtByPeriod
            openaiCostUSD = max(0.0, localData.openaiCostUSD ?? 0.0)

            let monthlyGemini = max(0, localData.geminiUsedByPeriod?.monthly ?? localData.geminiUsedTokens ?? 0)
            geminiUsedTokens = monthlyGemini
            geminiUsedWeekly = max(0, localData.geminiUsedByPeriod?.weekly ?? 0)
            geminiUsedDaily = max(0, localData.geminiUsedByPeriod?.daily ?? 0)
            geminiUsed5h = max(0, localData.geminiUsedByPeriod?.fiveHours ?? 0)
            geminiUsed2h = max(0, localData.geminiUsedByPeriod?.twoHours ?? 0)
            geminiCostUSD = max(0.0, localData.geminiCostUSD ?? 0.0)

            customProviderLiveUsage = localData.providers ?? [:]
            detectedProviderIds = localData.detectedProviders ?? []

            // Automatically seed and clean up detected local accounts on first V2/V3 run
            if !didAutoSeedLocalProvidersV2 || !didMigrateHonestCostsV3 {
                var seenBaseIds = Set<String>()
                var cleaned: [CustomSubscriptionConfig] = []
                for var item in customSubscriptions {
                    let base = item.id.split(separator: "_").first.map(String.init) ?? item.id
                    if !base.hasPrefix("custom") {
                        if seenBaseIds.contains(base) {
                            continue
                        }
                        seenBaseIds.insert(base)
                        item.id = base
                    }
                    if base == "copilot" && item.manualUsedMonthly == 80 {
                        item.manualUsedDaily = 0
                        item.manualUsedWeekly = 0
                        item.manualUsedMonthly = 0
                    }
                    // Clear legacy hardcoded preset costs (10/20/30)
                    if item.usedCostUSD == item.budgetUSD && (item.usedCostUSD == 10.0 || item.usedCostUSD == 20.0 || item.usedCostUSD == 30.0) {
                        item.usedCostUSD = 0.0
                    }
                    // Update Windsurf periods to honest monthly only if still at legacy preset
                    if base == "windsurf" && item.enabledPeriodRawValues == ["1d", "7d", "30d"] {
                        item.enabledPeriodRawValues = ["30d"]
                    }
                    cleaned.append(item)
                }
                customSubscriptions = cleaned
                autoAddDetectedSubscriptions()
                didAutoSeedLocalProvidersV2 = true
                didMigrateHonestCostsV3 = true
                hasCompletedSetupWizard = true
            }

            if let plan = localData.openaiPlanType, !plan.isEmpty {
                openaiStatus = plan
            } else {
                openaiStatus = "実ログ"
            }
            geminiStatus = "実ログ"
        } else {
            hasUsageSnapshot = false
            widgetUpdatedAt = nil
            lastUpdated = nil
            openaiUsed2h = 0
            openaiUsed5h = 0
            openaiUsedDaily = 0
            openaiUsedWeekly = 0
            openaiUsedTokens = 0
            openaiServerPct = nil
            openaiResetAt = nil
            openaiCostUSD = 0.0

            geminiUsed2h = 0
            geminiUsed5h = 0
            geminiUsedDaily = 0
            geminiUsedWeekly = 0
            geminiUsedTokens = 0
            geminiCostUSD = 0.0
            customProviderLiveUsage = [:]

            openaiStatus = "未取得"
            geminiStatus = "未取得"
        }

    }

    private func refreshConfiguredAPIs() async {
        let trimmedOpenAIKey = openaiAdminKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOpenAIKey.isEmpty {
            await fetchOpenAIUsage(apiKey: trimmedOpenAIKey)
        }

        let trimmedProjectId = gcpProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProjectId.isEmpty {
            await fetchGeminiUsage(projectId: trimmedProjectId)
        }
    }

    private func runLocalCollectorScript() async throws {
        // Collect natively in Swift with zero external Python dependency
        try await LocalUsageCollector.collectAndSave(customPaths: customProviderPaths)
    }

    func loadLocalJSON(from customURL: URL? = nil) -> LocalUsageData? {
        let url = customURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
        return SharedStore.loadLocalUsageData(from: url)
    }

    private func fetchOpenAIUsage(apiKey: String) async {
        let now = Date()
        let monthStart = UsageParser.startTimestamp(for: .monthly, now: now)
        let weekStart = UsageParser.startTimestamp(for: .weekly, now: now)
        let dayStart = UsageParser.startTimestamp(for: .daily, now: now)
        let fiveHoursStart = UsageParser.startTimestamp(for: .fiveHours, now: now)
        let twoHoursStart = UsageParser.startTimestamp(for: .twoHours, now: now)

        let queryStart = min(monthStart, weekStart)

        do {
            let dailyBuckets = try await fetchPaginatedOpenAIBuckets(
                apiKey: apiKey,
                startTime: queryStart,
                bucketWidth: "1d",
                limit: 31
            )

            let monthTotal = try UsageParser.totalTokens(in: dailyBuckets, since: monthStart)
            let weekTotal = try UsageParser.totalTokens(in: dailyBuckets, since: weekStart)
            let dayTotal = try UsageParser.totalTokens(in: dailyBuckets, since: dayStart)
            self.openaiUsedTokens = monthTotal
            self.openaiUsedWeekly = weekTotal
            self.openaiUsedDaily = dayTotal

            if let hourlyBuckets = try? await fetchPaginatedOpenAIBuckets(
                apiKey: apiKey,
                startTime: fiveHoursStart,
                bucketWidth: "1h",
                limit: 6
            ) {
                let fiveHourTotal = try UsageParser.totalTokens(in: hourlyBuckets)
                let twoHourTotal = try UsageParser.totalTokens(in: hourlyBuckets, since: twoHoursStart)
                self.openaiUsed5h = fiveHourTotal
                self.openaiUsed2h = twoHourTotal
            }

            if let totalCost = try? await fetchPaginatedOpenAICosts(apiKey: apiKey, startTime: monthStart) {
                self.openaiCostUSD = totalCost
            }
            recordUsageUpdate()
            openaiStatus = "API"
        } catch {
            // Keep local log status
        }
    }

    private func fetchPaginatedOpenAIBuckets(
        apiKey: String,
        startTime: Int,
        bucketWidth: String,
        limit: Int
    ) async throws -> [UsageParser.BucketTokenRecord] {
        var allBuckets: [UsageParser.BucketTokenRecord] = []
        var nextPage: String? = nil
        var pageCount = 0

        repeat {
            pageCount += 1
            var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")
            var queryItems = [
                URLQueryItem(name: "start_time", value: "\(startTime)"),
                URLQueryItem(name: "bucket_width", value: bucketWidth),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            if let page = nextPage {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw URLError(.badURL) }

            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await urlSession.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let parsed = try UsageParser.parseOpenAIUsagePageWithBuckets(data: data)
            allBuckets.append(contentsOf: parsed.buckets)
            nextPage = parsed.nextPage
        } while nextPage != nil && pageCount < 10

        return allBuckets
    }

    private func fetchPaginatedOpenAICosts(apiKey: String, startTime: Int) async throws -> Double {
        var totalCost = 0.0
        var nextPage: String? = nil
        var pageCount = 0

        repeat {
            pageCount += 1
            var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")
            var queryItems = [
                URLQueryItem(name: "start_time", value: "\(startTime)"),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let page = nextPage {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw URLError(.badURL) }

            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await urlSession.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let parsed = try UsageParser.parseOpenAICostsPage(data: data)
            totalCost = try UsageNumber.add(totalCost, parsed.costUSD)
            nextPage = parsed.nextPage
        } while nextPage != nil && pageCount < 10

        return totalCost
    }

    private func fetchGeminiUsage(projectId: String) async {
        guard let token = await fetchGcloudAccessToken() else {
            return
        }

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let endStr = isoFormatter.string(from: now)
        let monthStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .monthly, now: now))))

        let tokenFilter = #"metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count""#
        let requestCountFilter = #"metric.type="serviceruntime.googleapis.com/api/request_count" AND (resource.labels.service="generativelanguage.googleapis.com" OR resource.labels.service="aiplatform.googleapis.com")"#

        do {
            if let monthTokens = try? await queryCloudMonitoring(
                projectId: projectId,
                token: token,
                filter: tokenFilter,
                startStr: monthStartStr,
                endStr: endStr
            ), monthTokens > 0 {
                self.geminiUsedTokens = monthTokens

                let weekStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .weekly, now: now))))
                let dayStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .daily, now: now))))
                let fiveHStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .fiveHours, now: now))))
                let twoHStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .twoHours, now: now))))

                if let w = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: weekStartStr, endStr: endStr) {
                    self.geminiUsedWeekly = w
                }
                if let d = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: dayStartStr, endStr: endStr) {
                    self.geminiUsedDaily = d
                }
                if let h = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: fiveHStartStr, endStr: endStr) {
                    self.geminiUsed5h = h
                }
                if let h2 = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: twoHStartStr, endStr: endStr) {
                    self.geminiUsed2h = h2
                }

                recordUsageUpdate()
                geminiStatus = "GCP"
                return
            }

            let reqCount = try await queryCloudMonitoring(
                projectId: projectId,
                token: token,
                filter: requestCountFilter,
                startStr: monthStartStr,
                endStr: endStr
            )
            if reqCount > 0 {
                geminiStatus = "GCP (\(reqCount) reqs)"
            }
        } catch {
            // Keep local log status
        }
    }

    private func queryCloudMonitoring(
        projectId: String,
        token: String,
        filter: String,
        startStr: String,
        endStr: String
    ) async throws -> Int {
        guard UsageParser.isValidGCPProjectReference(projectId),
              var components = URLComponents(string: "https://monitoring.googleapis.com") else {
            throw URLError(.badURL)
        }
        components.path = "/v3/projects/\(projectId)/timeSeries"
        components.queryItems = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "interval.startTime", value: startStr),
            URLQueryItem(name: "interval.endTime", value: endStr)
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try UsageParser.parseGeminiMonitoringSeries(data: data)
    }

    private func fetchGcloudAccessToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let candidatePaths = [
                    "/opt/homebrew/bin/gcloud",
                    "/usr/local/bin/gcloud",
                    "\(home)/google-cloud-sdk/bin/gcloud",
                    "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"
                ]
                guard let execPath = candidatePaths.first(where: { UsageParser.isTrustedExecutable(atPath: $0) }) else {
                    continuation.resume(returning: nil)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = ["auth", "print-access-token", "--quiet"]

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                env["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
                process.environment = env

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8.0, execute: timeoutWorkItem)

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (token?.isEmpty == false) ? token : nil)
            }
        }
    }
}

// MARK: - Formatting Helpers

func gaugeColor(for remainingRatio: Double) -> Color {
    if remainingRatio < 0.15 {
        return .red
    } else if remainingRatio < 0.35 {
        return .orange
    } else {
        return Color.primary.opacity(0.68)
    }
}

func percentageTextColor(for remainingRatio: Double) -> Color {
    if remainingRatio < 0.15 {
        return .red
    } else if remainingRatio < 0.35 {
        return .orange
    } else {
        return .primary
    }
}

func gaugeWarningSymbol(for remainingRatio: Double) -> String? {
    if remainingRatio < 0.15 {
        return "exclamationmark.octagon.fill"
    } else if remainingRatio < 0.35 {
        return "exclamationmark.triangle.fill"
    } else {
        return nil
    }
}

// MARK: - Single Period Limit Row View (macOS Tahoe Liquid Glass Design)
struct PeriodLimitRowView: View {
    let metric: PeriodUsageMetric
    let isHighlighted: Bool
    var unit: String = "tokens"
    var accent: Color = .accentColor
    var showUsageAmounts: Bool = false

    var accessibilityUsageValue: String {
        guard metric.isValid else { return "数値エラー" }
        guard metric.isRemainingAvailable else {
            let status = "公式残量は未取得"
            return showUsageAmounts
                ? "\(status)、推定使用量 \(formatCompactUsage(metric.usedTokens, unit: unit)) \(unit)"
                : status
        }
        let prefix = metric.remainingSource == .configuredLimit ? "設定上限からの目安、" : ""
        let percentage = "\(prefix)残り \(metric.remainingPercent)パーセント"
        guard showUsageAmounts else { return percentage }
        return "\(percentage)、残量の目安 \(formatCompactUsage(metric.remainingTokens, unit: unit)) \(unit)"
    }

    var body: some View {
        let ratio = metric.remainingRatio
        let pct = metric.remainingPercent
        let usageText = metric.isValid ? formatCompactUsage(metric.remainingTokens, unit: unit) : "数値エラー"

        HStack(spacing: 8) {
            // 1. Period Label
            Text(metric.period.label)
                .font(.caption.weight(isHighlighted ? .semibold : .regular))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .frame(width: 38, alignment: .leading)

            // 2. Refined Liquid Glass Progress Bar
            if metric.isRemainingAvailable {
                LiquidGlassProgressBar(
                    ratio: ratio,
                    accent: accent,
                    height: 6.0
                )

                // Optional amount; percentages remain the default presentation.
                if showUsageAmounts {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("約 \(usageText)")
                        Text(unit == "tokens" ? "トークン" : unit)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 76, alignment: .trailing)
                        .help("残量の目安: \(usageText) \(unit)")
                }
            } else if metric.isValid {
                Spacer(minLength: 0)
                if showUsageAmounts {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("推定使用量")
                            .font(.system(size: 9))
                        Text("\(formatCompactUsage(metric.usedTokens, unit: unit)) \(unit == "tokens" ? "トークン" : unit)")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            } else {
                Text("数値エラー")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // 4. Remaining Percentage
            Text(metric.isValid ? metric.remainingSource.percentText(pct) : "—")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(metric.isRemainingAvailable ? percentageTextColor(for: ratio) : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.period.label)制限")
        .accessibilityValue(accessibilityUsageValue)
    }
}

// MARK: - Provider Section View (macOS Control Center Liquid Glass Module Style)
struct ProviderUsageSection: View {
    let title: String
    let subtitle: String
    let usedCostUSD: Double
    let budgetUSD: Double
    let metrics: [PeriodUsageMetric]
    var selectedFilter: LimitPeriod? = nil
    let highlightedPeriod: LimitPeriod?
    var unit: String = "tokens"
    var isDetailed: Bool = true
    var showUsageAmounts: Bool = false
    var iconName: String? = nil
    var serviceID: String = ""

    @State private var isHovered: Bool = false
    @State private var isShowingDetails: Bool = false

    var displayedMetrics: [PeriodUsageMetric] {
        if let filter = selectedFilter {
            return metrics.filter { $0.period == filter }
        }
        if isDetailed {
            return metrics
        }
        // Progressive Disclosure (Summary mode): Show bottleneck + monthly
        guard !metrics.isEmpty else { return [] }
        if let bottleneck = metrics.filter(\.isRemainingAvailable).min(by: { $0.remainingRatio < $1.remainingRatio }) {
            let monthly = metrics.first(where: { $0.period == .monthly })
            if let monthly, monthly.period != bottleneck.period {
                return [bottleneck, monthly]
            }
            return [bottleneck]
        }
        return metrics
    }

    private var accent: Color {
        providerAccentColor(for: title)
    }

    private var resolvedIconName: String {
        if let iconName, !iconName.isEmpty {
            return iconName
        }
        return providerIconName(for: title)
    }

    var body: some View {
        if displayedMetrics.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Section Header (Control Center Module Header Style)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(spacing: 5) {
                        ServiceIcon(serviceID: serviceID, fallbackSystemName: resolvedIconName)

                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if subtitle == "未取得" {
                            Text("未取得")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 6)

                    Button {
                        isShowingDetails.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("\(title)のデータ元・参考額・リセット日時")
                    .accessibilityLabel("\(title)の利用詳細")
                    .popover(isPresented: $isShowingDetails) {
                        usageDetails
                    }

                    Text("残り")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }

                // Period Rows
                VStack(spacing: 3) {
                    ForEach(displayedMetrics) { metric in
                        PeriodLimitRowView(
                            metric: metric,
                            isHighlighted: highlightedPeriod == metric.period && selectedFilter == nil,
                            unit: unit,
                            accent: accent,
                            showUsageAmounts: showUsageAmounts
                        )
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8.5)
            .background(
                FrostedGlassCardBackground(
                    cornerRadius: 12,
                    accentTint: accent,
                    isHovered: isHovered
                )
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isHovered = hovering
                }
            }
        }
    }

    private var usageDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title)の利用詳細")
                .font(.headline)

            if metrics.contains(where: \.requiresOfficialQuota) {
                Text("公式残量は未取得です。ローカルログやGCPの使用量を、公式の残り％に換算していません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("推定使用量には、キャッシュの重み付けや本文の文字数からの推計が含まれます。契約の消費量・残量とは一致しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if metrics.contains(where: { $0.remainingSource == .configuredLimit }) {
                Text("『約』の残り％は設定した上限から算出した目安です。サービスから取得した公式残量ではありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !subtitle.isEmpty {
                LabeledContent("データ元・プランの補足", value: subtitle)
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("データ元・プランの補足")
                    .accessibilityValue(subtitle)
                if title == "OpenAI" {
                    Text("ログ内のプラン識別子やデータの取得元です。識別子は契約プラン名と異なる場合があります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if usedCostUSD > 0 {
                LabeledContent("API換算額（参考）", value: String(format: "$%.2f", usedCostUSD))
                    .font(.caption.monospacedDigit())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("API換算額、参考")
                    .accessibilityValue(String(format: "%.2f米ドル", usedCostUSD))
                Text("取得した利用量のAPI料金相当額です。契約料金や実際の請求額を示すものではありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let resetMetrics = metrics.filter { formatResetTimestamp($0.resetTimestamp) != nil }
            if !resetMetrics.isEmpty {
                Divider()
                ForEach(resetMetrics) { metric in
                    if let reset = formatResetTimestamp(metric.resetTimestamp) {
                        LabeledContent("\(metric.period.label)枠のリセット", value: reset)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(metric.period.label)枠のリセット")
                            .accessibilityValue(reset)
                    }
                }
            }

            Text("公式の利用率を取得できた枠はその値を表示します。設定上限からの計算値には『約』、公式残量を取得できない枠には『未取得』を表示します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 310)
    }
}

// MARK: - Window Accessor for Reliable Floating Window Configuration
final class FirstMouseHostingHelperView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

func closeDesktopWidgetWindow(monitor: UsageMonitor? = nil) {
    DispatchQueue.main.async {
        for window in NSApp.windows where window.identifier?.rawValue.contains("desktop-widget") == true || window.title == "AI Meter Widget" {
            window.close()
        }
        monitor?.isDesktopWidgetOpen = false
    }
}

func miniaturizeDesktopWidgetWindow(monitor: UsageMonitor? = nil) {
    DispatchQueue.main.async {
        for window in NSApp.windows where window.identifier?.rawValue.contains("desktop-widget") == true || window.title == "AI Meter Widget" {
            window.miniaturize(nil)
        }
        monitor?.isDesktopWidgetOpen = false
    }
}

func openOrRestoreDesktopWidgetWindow(monitor: UsageMonitor? = nil, openWindow: @escaping (String) -> Void) {
    DispatchQueue.main.async {
        var found = false
        for window in NSApp.windows where window.identifier?.rawValue.contains("desktop-widget") == true || window.title == "AI Meter Widget" {
            found = true
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if !found {
            openWindow("desktop-widget")
        }
        monitor?.isDesktopWidgetOpen = true
    }
}

struct DesktopWidgetWindowAccessor: NSViewRepresentable {
    var allowBackgroundDrag: Bool = true
    var isPinned: Bool = true
    var onVisibilityChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = FirstMouseHostingHelperView()
        DispatchQueue.main.async {
            if let window = view.window {
                Self.configure(window: window, allowBackgroundDrag: allowBackgroundDrag, isPinned: isPinned)
                onVisibilityChange?(window.isVisible && !window.isMiniaturized)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                Self.configure(window: window, allowBackgroundDrag: allowBackgroundDrag, isPinned: isPinned)
                onVisibilityChange?(window.isVisible && !window.isMiniaturized)
            }
        }
    }

    static func configure(window: NSWindow, allowBackgroundDrag: Bool, isPinned: Bool) {
        window.styleMask.insert([.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable])
        window.level = isPinned ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = allowBackgroundDrag
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        // ネイティブ macOS トラフィックライト（標準の閉じる・最小化・ズームの3連ボタン）を完全に有効化
        if let closeBtn = window.standardWindowButton(.closeButton) {
            closeBtn.isHidden = false
            closeBtn.isEnabled = true
        }
        if let miniBtn = window.standardWindowButton(.miniaturizeButton) {
            miniBtn.isHidden = false
            miniBtn.isEnabled = true
        }
        if let zoomBtn = window.standardWindowButton(.zoomButton) {
            zoomBtn.isHidden = false
            zoomBtn.isEnabled = true
        }

        window.setFrameAutosaveName("AIMeterDesktopWidgetFrame")
        if !allowBackgroundDrag {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

func openSettingsWindow(openWindow: OpenWindowAction) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    openWindow(id: "settings")
}

// MARK: - Main Card View (macOS Tahoe Default App Liquid Glass Harmony)
struct AIMeterCardView: View {
    @ObservedObject var monitor: UsageMonitor
    var isMenuBar: Bool = false
    @Environment(\.openWindow) private var openWindow

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var highlightedMenuBarPeriod: LimitPeriod? {
        LimitPeriod(rawValue: monitor.menuBarPeriodMode)
    }

    private var visibleCustomSubscriptions: [CustomSubscriptionConfig] {
        monitor.customSubscriptions.filter(\.isEnabled)
    }

    private var totalVisibleProvidersCount: Int {
        (monitor.showOpenAISection ? 1 : 0) + (monitor.showGeminiSection ? 1 : 0) + visibleCustomSubscriptions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header (Finder / Control Center Unified Liquid Glass Header)
            HStack(spacing: 8) {
                if !isMenuBar {
                    // ネイティブ macOS トラフィックライト（赤・黄・緑の3連）用のインセット
                    Color.clear
                        .frame(width: 70, height: 26)
                        .accessibilityHidden(true)
                }

                Text("AIMeter")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Native macOS Tahoe Liquid Glass Capsule Toolbar
                LiquidGlassToolbarPill {
                    // 更新ボタン
                    LiquidGlassToolbarIconButton(
                        systemName: "arrow.clockwise",
                        isLoading: monitor.isRefreshing,
                        helpText: "今すぐ更新"
                    ) {
                        Task {
                            await monitor.refresh()
                        }
                    }

                    // ウィジェット専用: 最前面ピン留めトグル
                    if !isMenuBar {
                        LiquidGlassToolbarIconButton(
                            systemName: monitor.isWidgetPinned ? "pin.fill" : "pin",
                            isActive: monitor.isWidgetPinned,
                            helpText: monitor.isWidgetPinned ? "最前面固定中 (クリックで解除)" : "通常ウィンドウ (クリックで最前面固定)"
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                monitor.isWidgetPinned.toggle()
                            }
                        }
                    }

                    // 設定ボタン
                    LiquidGlassToolbarIconButton(
                        systemName: "gearshape",
                        helpText: "設定を開く (⌘,)"
                    ) {
                        openSettingsWindow(openWindow: openWindow)
                    }
                }
            }
            .frame(height: 26)

            Divider()
                .opacity(0.35)
                .padding(.horizontal, -14)

            Picker("表示モード", selection: $monitor.isDetailedView.animation(.easeInOut(duration: 0.16))) {
                Text("要点表示").tag(false)
                Text("全枠表示").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .help("要点表示は残量の割合が最も少ない枠と月間枠、全枠表示は有効なすべての枠を表示します")

            // Provider Sections
            if totalVisibleProvidersCount == 0 {
                ContentUnavailableView {
                    Label("表示するAIサービスがありません", systemImage: "slider.horizontal.3")
                } description: {
                    Text("設定からサービスを有効化してください")
                } actions: {
                    Button("設定を開く...") {
                        openSettingsWindow(openWindow: openWindow)
                    }
                    .buttonStyle(GlassCapsuleButtonStyle(isProminent: true))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if isMenuBar && totalVisibleProvidersCount > 3 {
                ScrollView {
                    providerSectionsStack
                        .padding(.trailing, 2)
                }
                .frame(maxHeight: 380)
            } else if !isMenuBar && totalVisibleProvidersCount > 5 {
                ScrollView {
                    providerSectionsStack
                        .padding(.trailing, 2)
                }
                .frame(maxHeight: 520)
            } else {
                providerSectionsStack
            }

            if let error = monitor.collectionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = monitor.widgetSharingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Quiet Control Center Style Footer
            HStack {
                Group {
                    if let date = monitor.lastUpdated {
                        Text("\(Self.timeFormatter.string(from: date)) 更新")
                    } else {
                        Text("データ未取得")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 2)

            if isMenuBar {
                Divider()
                    .opacity(0.35)
                menuBarFooterButtons
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, isMenuBar ? 14 : 9)
        .padding(.bottom, 14)
        .frame(width: 348)
        .background(
            LiquidGlassBackground(
                cornerRadius: 18,
                material: .popover,
                blendingMode: .behindWindow
            )
        )
        .background(
            Group {
                if !isMenuBar {
                    DesktopWidgetWindowAccessor(
                        allowBackgroundDrag: true,
                        isPinned: monitor.isWidgetPinned,
                        onVisibilityChange: { visible in
                            if monitor.isDesktopWidgetOpen != visible {
                                monitor.isDesktopWidgetOpen = visible
                            }
                        }
                    )
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let win = note.object as? NSWindow,
               win.identifier?.rawValue.contains("desktop-widget") == true || win.title == "AI Meter Widget" {
                monitor.isDesktopWidgetOpen = false
            }
        }
        .onAppear {
            if isMenuBar && monitor.autoShowWidgetOnLaunch && !monitor.hasAutoOpenedWidgetOnLaunch {
                monitor.hasAutoOpenedWidgetOnLaunch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                        openWindow(id: id)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDesktopWidgetRequest)) { _ in
            openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                openWindow(id: id)
            }
        }
        .onOpenURL { _ in
            openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                openWindow(id: id)
            }
        }
        .background(
            Group {
                Button("") {
                    openSettingsWindow(openWindow: openWindow)
                }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)

                if !isMenuBar {
                    // メイン画面での ⌘W / ESC: ウィジェットを閉じる
                    Button("") {
                        closeDesktopWidgetWindow(monitor: monitor)
                    }
                    .keyboardShortcut("w", modifiers: .command)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)

                    // ⌘M: ウィジェットを最小化
                    Button("") {
                        miniaturizeDesktopWidgetWindow(monitor: monitor)
                    }
                    .keyboardShortcut("m", modifiers: .command)
                    .opacity(0)
                }
            }
        )
    }

    @ViewBuilder
    private var menuBarFooterButtons: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(monitor.isDesktopWidgetOpen ? "ウィジェットを非表示" : "ウィジェットを表示") {
                        if monitor.isDesktopWidgetOpen {
                            closeDesktopWidgetWindow(monitor: monitor)
                        } else {
                            openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                                openWindow(id: id)
                            }
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Spacer()

                    Button("設定...") {
                        openSettingsWindow(openWindow: openWindow)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button("終了") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        } else {
            HStack(spacing: 8) {
                Button(monitor.isDesktopWidgetOpen ? "ウィジェットを非表示" : "ウィジェットを表示") {
                    if monitor.isDesktopWidgetOpen {
                        closeDesktopWidgetWindow(monitor: monitor)
                    } else {
                        openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                            openWindow(id: id)
                        }
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(isSelected: monitor.isDesktopWidgetOpen))

                Spacer()

                Button("設定...") {
                    openSettingsWindow(openWindow: openWindow)
                }
                .buttonStyle(GlassCapsuleButtonStyle())

                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(GlassCapsuleButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var providerSectionsStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.showOpenAISection {
                ProviderUsageSection(
                    title: "OpenAI",
                    subtitle: monitor.openaiStatus,
                    usedCostUSD: monitor.openaiCostUSD,
                    budgetUSD: monitor.openaiBudgetUSD,
                    metrics: monitor.openaiMetrics,
                    highlightedPeriod: highlightedMenuBarPeriod,
                    unit: "tokens",
                    isDetailed: monitor.isDetailedView,
                    showUsageAmounts: monitor.showUsageAmounts,
                    iconName: "brain.head.profile",
                    serviceID: "openai"
                )
            }

            if monitor.showGeminiSection {
                ProviderUsageSection(
                    title: "Gemini",
                    subtitle: monitor.geminiStatus,
                    usedCostUSD: monitor.geminiCostUSD,
                    budgetUSD: monitor.geminiBudgetUSD,
                    metrics: monitor.geminiMetrics,
                    highlightedPeriod: highlightedMenuBarPeriod,
                    unit: "tokens",
                    isDetailed: monitor.isDetailedView,
                    showUsageAmounts: monitor.showUsageAmounts,
                    iconName: "sparkle",
                    serviceID: "gemini"
                )
            }

            ForEach(visibleCustomSubscriptions) { sub in
                let baseKey = sub.id.split(separator: "_").first.map(String.init) ?? sub.id
                let liveStatus = monitor.customProviderLiveUsage[sub.id]?.status ?? monitor.customProviderLiveUsage[baseKey]?.status
                ProviderUsageSection(
                    title: sub.name,
                    subtitle: liveStatus ?? sub.statusNote,
                    usedCostUSD: monitor.effectiveCostUSD(for: sub),
                    budgetUSD: sub.budgetUSD,
                    metrics: monitor.metrics(for: sub),
                    highlightedPeriod: highlightedMenuBarPeriod,
                    unit: providerUnit(for: sub.id),
                    isDetailed: monitor.isDetailedView,
                    showUsageAmounts: monitor.showUsageAmounts,
                    iconName: sub.iconName,
                    serviceID: sub.id
                )
            }
        }
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .showDesktopWidgetRequest, object: nil)
        return true
    }
}

// MARK: - App Entrypoint
@main
struct AIMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = UsageMonitor()

    init() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("AI Meter Widget", id: "desktop-widget") {
            AIMeterCardView(monitor: monitor, isMenuBar: false)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            AIMeterCardView(monitor: monitor, isMenuBar: true)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.needle.fill")
                Text(monitor.menuBarTitle)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .menuBarExtraStyle(.window)

        Window("AIMeter 設定", id: "settings") {
            SettingsView(monitor: monitor)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(monitor: monitor)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
    }
}
