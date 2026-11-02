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
                print("[AIMeter] Failed to update Launch at Login.")
                refresh()
            }
        }
    }
}

// MARK: - Usage Monitor
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var requiresCollectionIntroduction: Bool
    @AppStorage("didCalibrateRealLimitsV1") var didCalibrateRealLimitsV1: Bool = false
    @AppStorage("didAutoSeedLocalProvidersV2") var didAutoSeedLocalProvidersV2: Bool = false
    @AppStorage("didMigrateHonestCostsV3") var didMigrateHonestCostsV3: Bool = false
    @AppStorage("hasCompletedSetupWizard") var hasCompletedSetupWizard: Bool = true
    @AppStorage("autoShowWidgetOnLaunch") var autoShowWidgetOnLaunch: Bool = true
    @Published var hasAutoOpenedWidgetOnLaunch: Bool = false
    @AppStorage("customProviderPathsJSON") var customProviderPathsJSON: String = "{}"
    // Read a legacy plaintext preference only at an enabled, explicit restore
    // boundary; constructing the monitor must not eagerly materialize it.
    private let credentialDefaults: UserDefaults
    var legacyOpenaiAdminKey: String {
        credentialDefaults.object(forKey: "openaiAdminKey") as? String ?? ""
    }
    @Published private(set) var openAICredential: OpenAICredentialState
    @Published var openaiCredentialMaintenanceStatus: CredentialMaintenance.Status = .unverified
    var openaiAdminKey: String { openAICredential.committedValue ?? "" }
    var openaiAdminKeyDraft: String {
        get { openAICredential.draft }
        set {
            // Re-enabling the same form may not trigger onAppear. Restore
            // before accepting a new draft so a timer cannot overwrite it.
            loadOpenAICredentialIfEnabled()
            openAICredential.draft = newValue
        }
    }
    var openaiCredentialError: String? { openAICredential.error }
    private var openAIIntegrationEnabled: Bool {
        IntegrationSettingsObservation.isEnabled(in: credentialDefaults, key: "showOpenAISection")
    }
    private var geminiIntegrationEnabled: Bool {
        IntegrationSettingsObservation.isEnabled(in: credentialDefaults, key: "showGeminiSection")
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
            let normalized = newValue.mapValues { ProviderPathPreferences.stored($0) }
            if let data = try? JSONEncoder().encode(normalized),
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
    var showOpenAISection: Bool {
        get { openAIIntegrationEnabled }
        set {
            objectWillChange.send()
            credentialDefaults.set(newValue, forKey: "showOpenAISection")
            invalidateLocalCollection()
            if !newValue { stopOpenAIIntegration() }
        }
    }
    var showGeminiSection: Bool {
        get { geminiIntegrationEnabled }
        set {
            objectWillChange.send()
            credentialDefaults.set(newValue, forKey: "showGeminiSection")
            invalidateLocalCollection()
            if !newValue { stopGeminiIntegration() }
        }
    }
    @AppStorage("showOpenAIInMenuBar") var showOpenAIInMenuBar: Bool = true
    @AppStorage("showGeminiInMenuBar") var showGeminiInMenuBar: Bool = true
    @AppStorage("showAntigravitySection") var showAntigravitySection: Bool = false
    @AppStorage("showAntigravityInMenuBar") var showAntigravityInMenuBar: Bool = true
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
    @AppStorage("gcpProjectId") var gcpProjectId: String = "" {
        didSet { if oldValue != gcpProjectId { stopGeminiIntegration() } }
    }
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
            if Self.localIDs(in: oldValue) != Self.localIDs(in: customSubscriptions) {
                invalidateLocalCollection()
            }
            saveCustomSubscriptions()
        }
    }
    @Published var customProviderLiveUsage: [String: CustomProviderUsageJSON] = [:]
    @Published var detectedProviderIds: [String] = []

    // MenuBar Display Period Mode ("min" = bottleneck or LimitPeriod.rawValue)
    @AppStorage("menuBarPeriodMode") var menuBarPeriodMode: String = "min"
    @AppStorage("menuBarDisplayMode") var menuBarDisplayMode: String = "smart"
    @AppStorage("isDetailedView") var isDetailedView: Bool = false
    @AppStorage("showUsageAmounts") private var storedShowUsageAmounts: Bool = false
    var showUsageAmounts: Bool {
        get { storedShowUsageAmounts }
        set { _ = setUsageAmountVisibility(newValue) }
    }
    @Published private(set) var widgetAmountChangePending = false
    private var requestedUsageAmounts: Bool?
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
    @Published var antigravityQuota: AntigravityQuotaSnapshot?
    @Published var antigravityStatus: String = "Antigravityを起動してログイン後、更新してください"

    @Published var lastUpdated: Date?
    @Published var isRefreshing: Bool = false
    @Published var collectionError: String?

    private var settingsObserver: AnyCancellable?
    private var hasUsageSnapshot = false
    private var widgetUpdatedAt: Date?
    @Published var widgetSharingError: String?
    @Published private(set) var temporaryDataCleanupError: String?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let apiClient: BoundedAPIClient
    private let gcloudTokenProvider: ((APIReadBudget, IntegrationPermit) async -> String?)?
    private var openAITask: Task<Void, Never>?
    private var geminiTask: Task<Void, Never>?
    private var openAIPermit: IntegrationPermit?
    private var geminiPermit: IntegrationPermit?
    private let openAIPermitSlot = IntegrationPermitSlot()
    private let geminiPermitSlot = IntegrationPermitSlot()
    private var integrationSettingsObservation: IntegrationSettingsObservation?
    private var isLoadingSubscriptions: Bool = false
    private let automaticallyPublishSnapshots: Bool
    private var automaticMonitoringStarted = false
    private let localCollector: ((Set<String>, IntegrationPermit) async throws -> LocalUsageData)?
    private var localCollectionTask: Task<LocalUsageData, Error>?
    private var localCollectionPermit: IntegrationPermit?
    private let localCollectionPermitSlot = IntegrationPermitSlot()
    private var localCollectionGeneration = UUID()
    private var refreshAfterPolicyChange = false

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true,
         requiresCollectionIntroduction: Bool? = nil,
         apiClient: BoundedAPIClient = BoundedAPIClient(),
         keychainOperations: KeychainHelper.Operations = .live,
         gcloudTokenProvider: ((APIReadBudget, IntegrationPermit) async -> String?)? = nil,
         localCollector: ((Set<String>, IntegrationPermit) async throws -> LocalUsageData)? = nil) {
        // Detached models do not start monitoring; a test can explicitly enable
        // the new-install boundary without starting live collection or timers.
        self.requiresCollectionIntroduction = requiresCollectionIntroduction
            ?? (startMonitoring && !CollectionIntroduction.hasAcknowledged(in: defaults))
        _didCalibrateRealLimitsV1 = AppStorage(wrappedValue: false, "didCalibrateRealLimitsV1", store: defaults)
        _didAutoSeedLocalProvidersV2 = AppStorage(wrappedValue: false, "didAutoSeedLocalProvidersV2", store: defaults)
        _didMigrateHonestCostsV3 = AppStorage(wrappedValue: false, "didMigrateHonestCostsV3", store: defaults)
        _hasCompletedSetupWizard = AppStorage(wrappedValue: true, "hasCompletedSetupWizard", store: defaults)
        _autoShowWidgetOnLaunch = AppStorage(wrappedValue: true, "autoShowWidgetOnLaunch", store: defaults)
        _customProviderPathsJSON = AppStorage(wrappedValue: "{}", "customProviderPathsJSON", store: defaults)
        self.credentialDefaults = defaults
        _showOpenAIInMenuBar = AppStorage(wrappedValue: true, "showOpenAIInMenuBar", store: defaults)
        _showGeminiInMenuBar = AppStorage(wrappedValue: true, "showGeminiInMenuBar", store: defaults)
        _showAntigravitySection = AppStorage(wrappedValue: false, "showAntigravitySection", store: defaults)
        _showAntigravityInMenuBar = AppStorage(wrappedValue: true, "showAntigravityInMenuBar", store: defaults)
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
        _storedShowUsageAmounts = AppStorage(wrappedValue: false, "showUsageAmounts", store: defaults)
        _isWidgetPinned = AppStorage(wrappedValue: true, "isWidgetPinned", store: defaults)
        self.apiClient = apiClient
        self.gcloudTokenProvider = gcloudTokenProvider
        self.localCollector = localCollector
        self.automaticallyPublishSnapshots = startMonitoring
        self.openAICredential = OpenAICredentialState(operations: keychainOperations)
        self.integrationSettingsObservation = IntegrationSettingsObservation(
            defaults: defaults, openAI: openAIPermitSlot, gemini: geminiPermitSlot,
            local: localCollectionPermitSlot
        ) { [weak self] key, enabled in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.integrationSettingChanged(key, enabled: enabled) }
            } else {
                Task { @MainActor [weak self] in self?.integrationSettingChanged(key, enabled: enabled) }
            }
        }
        guard startMonitoring, !self.requiresCollectionIntroduction else { return }
        startAutomaticMonitoring()
    }

    func beginCollection() {
        guard requiresCollectionIntroduction else { return }
        credentialDefaults.set(true, forKey: CollectionIntroduction.acknowledgmentPreference)
        requiresCollectionIntroduction = false
        if automaticallyPublishSnapshots { startAutomaticMonitoring() }
    }

    private func startAutomaticMonitoring() {
        guard !requiresCollectionIntroduction, !automaticMonitoringStarted else { return }
        automaticMonitoringStarted = true

        cleanupTemporarySnapshots()

        let paths = customProviderPaths
        let minimizedPaths = paths.mapValues { ProviderPathPreferences.stored($0) }
        if paths != minimizedPaths { customProviderPaths = minimizedPaths }

        loadOpenAICredentialIfEnabled()

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
        publishWidgetSnapshot()

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
        let filtered = all.filter { $0.period.map { isBuiltInPeriodEnabled(csv: openaiEnabledPeriodsCSV, period: $0) } ?? false }
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
        let filtered = all.filter { $0.period.map { isBuiltInPeriodEnabled(csv: geminiEnabledPeriodsCSV, period: $0) } ?? false }
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
        let filtered = all.filter { $0.period.map { sub.isPeriodEnabled($0) } ?? false }
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
           metrics.contains(where: { $0.period == period }) {
            return metrics.filter { $0.period == period && $0.isRemainingAvailable }
                .min(by: { $0.remainingRatio < $1.remainingRatio })
        }
        if menuBarPeriodMode != "min", metrics.allSatisfy(\.isQuotaOnly) { return nil }
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
        if showAntigravitySection && showAntigravityInMenuBar,
           let metric = activeMetric(for: antigravityMetrics) {
            list.append(.init(id: "antigravity", name: "Antigravity", shortName: "AG", iconName: "sparkles",
                              remainingPercent: metric.remainingPercent, remainingRatio: metric.remainingRatio,
                              bottleneckPeriod: metric.period, remainingSource: metric.remainingSource))
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
        guard !requiresCollectionIntroduction else { return "AIMeter 初期設定" }
        let bottlenecks = activeBottlenecks
        var services: [(String, [PeriodUsageMetric])] = []
        if showOpenAISection && showOpenAIInMenuBar { services.append(("GPT", openaiMetrics)) }
        if showGeminiSection && showGeminiInMenuBar { services.append(("Gem", geminiMetrics)) }
        if showAntigravitySection && showAntigravityInMenuBar { services.append(("AG", antigravityMetrics)) }
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
        guard !requiresCollectionIntroduction, !isRefreshing else { return }
        isRefreshing = true
        collectionError = nil
        sanitizeSettings()
        defer {
            if collectionError == nil && !refreshAfterPolicyChange {
                lastUpdated = Date()
                widgetUpdatedAt = lastUpdated
            }
            isRefreshing = false
            publishWidgetSnapshot()
            if refreshAfterPolicyChange {
                refreshAfterPolicyChange = false
                if automaticallyPublishSnapshots { Task { await self.refresh() } }
            }
        }

        let error = await RefreshSequence.run(local: {
            applyLocalSnapshot(try await runLocalCollectorScript())
        }, remote: {
            await refreshConfiguredAPIs()
        })
        if let error, !(error is CancellationError) {
            collectionError = "利用状況を更新できませんでした。設定とログの場所を確認して再試行してください"
        }
    }

    /// Both the floating window and WidgetKit use these exact, resolved metrics.
    func widgetSnapshot(showUsageAmounts amountOverride: Bool? = nil) -> AIMeterWidgetSnapshot {
        var services: [WidgetServiceItem] = []
        if showOpenAISection, let item = WidgetServiceItem.fromMetrics(
            id: "openai", name: "OpenAI Codex", shortName: "OAI", iconName: "brain.head.profile",
            unit: "tokens", metrics: openaiMetrics
        ) { services.append(item) }
        if showGeminiSection, let item = WidgetServiceItem.fromMetrics(
            id: "gemini", name: "Gemini", shortName: "Gem", iconName: "sparkle",
            unit: "tokens", metrics: geminiMetrics
        ) { services.append(item) }
        if showAntigravitySection, let item = WidgetServiceItem.fromMetrics(
            id: "antigravity", name: "Antigravity", shortName: "AG", iconName: "sparkles",
            unit: "", metrics: antigravityMetrics
        ) { services.append(item) }
        for sub in customSubscriptions where sub.isEnabled {
            if let item = WidgetServiceItem.fromMetrics(
                id: sub.id, name: sub.name, shortName: sub.shortName, iconName: sub.iconName,
                unit: providerUnit(for: sub.id), metrics: metrics(for: sub)
            ) { services.append(item) }
        }
        return .make(services: services, totalCostUSD: totalCostUSD,
                     updatedAt: widgetUpdatedAt, hasData: hasUsageSnapshot,
                     updateFailed: collectionError != nil, showUsageAmounts: amountOverride ?? showUsageAmounts)
    }

    func characterHighlight(at date: Date = Date()) -> UsageHighlight {
        var services: [HighlightService] = []
        if showOpenAISection {
            services.append(.init(id: "openai", name: "Codex", metrics: openaiMetrics))
        }
        if showGeminiSection {
            services.append(.init(id: "gemini", name: "Gemini", metrics: geminiMetrics))
        }
        if showAntigravitySection {
            services.append(.init(id: "antigravity", name: "Antigravity", metrics: antigravityMetrics))
        }
        for sub in customSubscriptions where sub.isEnabled {
            services.append(.init(id: sub.id, name: sub.name, metrics: metrics(for: sub)))
        }
        return .resolve(services: services, hasData: hasUsageSnapshot, updatedAt: widgetUpdatedAt,
                        isRefreshing: isRefreshing, updateFailed: collectionError != nil, now: date)
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
        // Preview/test monitors can publish only to an explicitly supplied
        // synthetic destination, including refresh and policy-retry paths.
        guard !requiresCollectionIntroduction, automaticallyPublishSnapshots || customURL != nil else { return }
        do {
            try SharedStore.saveWidgetSnapshot(widgetSnapshot(showUsageAmounts: requestedUsageAmounts), to: customURL)
            if let requested = requestedUsageAmounts {
                storedShowUsageAmounts = requested
                requestedUsageAmounts = nil
            }
            widgetAmountChangePending = false
            widgetSharingError = nil
            if customURL == nil { SharedStore.reloadWidgetTimelines() }
        } catch {
            widgetSharingError = widgetAmountChangePending
                ? "表示設定は未適用です。Widgetの保存情報を更新できませんでした。更新を再試行してください"
                : "Widgetの表示情報を保存できませんでした。更新を再試行してください"
        }
    }

    @discardableResult
    func setUsageAmountVisibility(_ enabled: Bool, to customURL: URL? = nil) -> Bool {
        objectWillChange.send()
        requestedUsageAmounts = enabled
        widgetAmountChangePending = true
        // Non-monitoring test/preview instances never touch a real snapshot.
        if !automaticallyPublishSnapshots && customURL == nil {
            storedShowUsageAmounts = enabled
            requestedUsageAmounts = nil
            widgetAmountChangePending = false
            return true
        }
        publishWidgetSnapshot(to: customURL)
        return !widgetAmountChangePending
    }

    func cleanupTemporarySnapshots() {
        Task {
            let worker = Task.detached(priority: .utility) { try PrivateSnapshotManager.cleanup() }
            do {
                _ = try await worker.value
                temporaryDataCleanupError = nil
            } catch {
                temporaryDataCleanupError = "以前の一時作業データを安全に回収できませんでした。元のAIログは変更していません。"
            }
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

            customProviderLiveUsage = Dictionary(uniqueKeysWithValues: (localData.providers ?? [:]).map { id, usage in
                var safe = usage
                if safe.status != nil {
                    safe.status = LocalUsageCollector.safePlan(safe.status, provider: LocalUsageCollector.baseProviderID(id))
                }
                return (id, safe)
            })
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
                // Service discovery is an explicit setup action. Upgrading a
                // cache must not enable additional sources without that action.
                didAutoSeedLocalProvidersV2 = true
                didMigrateHonestCostsV3 = true
                hasCompletedSetupWizard = true
            }

            if let plan = localData.openaiPlanType, !plan.isEmpty {
                openaiStatus = LocalUsageCollector.safePlan(plan, provider: "openai")
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

    func loadOpenAICredentialIfEnabled() {
        guard !requiresCollectionIntroduction, openAIIntegrationEnabled, !openAICredential.isLoaded else { return }
        if openAICredential.load(legacyValue: legacyOpenaiAdminKey) { _ = removeLegacyCredentialPreference() }
    }

    func retryOpenAICredentialLoad() {
        guard !requiresCollectionIntroduction, openAIIntegrationEnabled else { return }
        stopOpenAIRequests()
        if openAICredential.load(legacyValue: legacyOpenaiAdminKey) { _ = removeLegacyCredentialPreference() }
    }

    @discardableResult
    func saveOpenAICredential() -> Bool {
        guard openAIIntegrationEnabled else { return false }
        stopOpenAIRequests()
        guard openAICredential.save() else { return false }
        return removeLegacyCredentialPreference()
    }

    func migrateLegacyOpenAICredential() {
        stopOpenAIRequests()
        let result = openAICredential.migrateLegacy(legacyValue: legacyOpenaiAdminKey)
        finishCredentialMaintenance(result)
    }

    func deleteStoredOpenAICredential() {
        stopOpenAIRequests()
        finishCredentialMaintenance(openAICredential.deleteStored())
    }

    private func finishCredentialMaintenance(_ result: CredentialMaintenance.Result) {
        guard result.canClearLegacy else {
            openaiCredentialMaintenanceStatus = result.status
            return
        }
        openaiCredentialMaintenanceStatus = result.confirmingLegacyRemoval(
            removeLegacyCredentialPreference()).status
    }

    private func removeLegacyCredentialPreference() -> Bool {
        credentialDefaults.removeObject(forKey: "openaiAdminKey")
        let removed = credentialDefaults.object(forKey: "openaiAdminKey") == nil
        openaiCredentialMaintenanceStatus = removed ? .legacyRemovalConfirmed : .legacyRemovalPending
        return removed
    }

    private func stopOpenAIRequests() {
        openAIPermitSlot.revoke()
        openAIPermit?.revoke(); openAITask?.cancel()
        openAIPermit = nil; openAITask = nil
    }

    private func stopOpenAIIntegration() {
        stopOpenAIRequests()
        openAICredential.forget()
    }

    private func stopGeminiIntegration() {
        geminiPermitSlot.revoke()
        geminiPermit?.revoke(); geminiTask?.cancel()
        geminiPermit = nil; geminiTask = nil
    }

    private func integrationSettingChanged(_ key: String, enabled: Bool?) {
        objectWillChange.send()
        if key != "gcpProjectId" { invalidateLocalCollection() }
        if key == "showOpenAISection" {
            stopOpenAIRequests()
            // Use the authoritative typed value for the permission transition.
            // A delayed background notification must not erase a newer draft
            // after a subsequent enable transition.
            if enabled == false,
               !IntegrationSettingsObservation.isEnabled(in: credentialDefaults, key: key) { openAICredential.forget() }
        } else { stopGeminiIntegration() }
    }

    private func checkOpenAI(_ permit: IntegrationPermit) throws {
        guard openAIIntegrationEnabled, openAIPermit === permit else { throw CancellationError() }
        try permit.check()
    }

    private func checkGemini(_ permit: IntegrationPermit) throws {
        guard geminiIntegrationEnabled, geminiPermit === permit else { throw CancellationError() }
        try permit.check()
    }

    // Initial, timer, wake and manual refresh all enter this same policy.
    func refreshConfiguredAPIs() async {
        guard !requiresCollectionIntroduction else { return }
        await refreshAntigravityQuota()
        guard !Task.isCancelled else { return }
        let budget = APIReadBudget()
        if openAIIntegrationEnabled {
            loadOpenAICredentialIfEnabled()
            let key = openaiAdminKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                stopOpenAIRequests()
                let permit = IntegrationPermit()
                openAIPermit = permit
                openAIPermitSlot.install(permit)
                let task = Task { await self.fetchOpenAIUsage(apiKey: key, budget: budget, permit: permit) }
                openAITask = task
                await withTaskCancellationHandler { await task.value }
                    onCancel: { permit.revoke(); task.cancel() }
                if openAIPermit === permit { stopOpenAIRequests() }
            }
        } else { stopOpenAIIntegration() }
        guard !Task.isCancelled else { return }
        if geminiIntegrationEnabled {
            let project = (credentialDefaults.object(forKey: "gcpProjectId") as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if UsageParser.isValidGCPProjectReference(project) {
                stopGeminiIntegration()
                let permit = IntegrationPermit()
                geminiPermit = permit
                geminiPermitSlot.install(permit)
                let task = Task { await self.fetchGeminiUsage(projectId: project, budget: budget, permit: permit) }
                geminiTask = task
                await withTaskCancellationHandler { await task.value }
                    onCancel: { permit.revoke(); task.cancel() }
                if geminiPermit === permit { stopGeminiIntegration() }
            }
        } else { stopGeminiIntegration() }
    }

    static func localIDs(in subscriptions: [CustomSubscriptionConfig]) -> Set<String> {
        Set(subscriptions.filter(\.isEnabled).map { LocalUsageCollector.baseProviderID($0.id) })
    }

    var enabledLocalProviderIDs: Set<String> {
        var ids = Self.localIDs(in: customSubscriptions)
        if showOpenAISection { ids.insert("openai") }
        if showGeminiSection { ids.insert("gemini") }
        return ids
    }

    private func invalidateLocalCollection() {
        localCollectionPermitSlot.revoke()
        localCollectionPermit?.revoke()
        localCollectionTask?.cancel()
        localCollectionGeneration = UUID()
        if isRefreshing { refreshAfterPolicyChange = true }
    }

    private func runLocalCollectorScript() async throws -> LocalUsageData {
        let generation = UUID()
        localCollectionGeneration = generation
        let ids = enabledLocalProviderIDs
        let permit = IntegrationPermit()
        localCollectionPermit = permit
        localCollectionPermitSlot.install(permit)
        let paths = customProviderPaths
        let injected = localCollector
        let task = Task {
            if let injected { return try await injected(ids, permit) }
            return try await LocalUsageCollector.collectAndSave(customPaths: paths,
                enabledProviderIDs: ids, commitPermit: permit)
        }
        localCollectionTask = task
        defer {
            if localCollectionGeneration == generation {
                localCollectionTask = nil
                localCollectionPermit = nil
            }
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { permit.revoke(); task.cancel() }
        guard generation == localCollectionGeneration, ids == enabledLocalProviderIDs else {
            throw CancellationError()
        }
        try permit.check()
        return result
    }

    func loadLocalJSON(from customURL: URL? = nil) -> LocalUsageData? {
        let url = customURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
        return SharedStore.loadLocalUsageData(from: url)
    }

    private func fetchOpenAIUsage(apiKey: String, budget: APIReadBudget, permit: IntegrationPermit) async {
        let now = Date()
        let monthStart = UsageParser.startTimestamp(for: .monthly, now: now)
        let weekStart = UsageParser.startTimestamp(for: .weekly, now: now)
        let dayStart = UsageParser.startTimestamp(for: .daily, now: now)
        let fiveHoursStart = UsageParser.startTimestamp(for: .fiveHours, now: now)
        let twoHoursStart = UsageParser.startTimestamp(for: .twoHours, now: now)

        let queryStart = min(monthStart, weekStart)

        do {
            try checkOpenAI(permit)
            let dailyBuckets = try await fetchPaginatedOpenAIBuckets(
                apiKey: apiKey,
                startTime: queryStart,
                bucketWidth: "1d",
                limit: 31,
                budget: budget,
                permit: permit
            )

            try checkOpenAI(permit)
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
                limit: 6,
                budget: budget,
                permit: permit
            ) {
                try checkOpenAI(permit)
                let fiveHourTotal = try UsageParser.totalTokens(in: hourlyBuckets)
                let twoHourTotal = try UsageParser.totalTokens(in: hourlyBuckets, since: twoHoursStart)
                self.openaiUsed5h = fiveHourTotal
                self.openaiUsed2h = twoHourTotal
            }

            if let totalCost = try? await fetchPaginatedOpenAICosts(apiKey: apiKey, startTime: monthStart, budget: budget, permit: permit) {
                try checkOpenAI(permit)
                self.openaiCostUSD = totalCost
            }
            try checkOpenAI(permit)
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
        limit: Int,
        budget: APIReadBudget,
        permit: IntegrationPermit
    ) async throws -> [UsageParser.BucketTokenRecord] {
        var allBuckets: [UsageParser.BucketTokenRecord] = []
        var nextPage: String? = nil
        var pageCount = 0
        var seenPages = Set<String>()

        repeat {
            try checkOpenAI(permit)
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

            let data = try await apiClient.data(for: req, budget: budget, permit: permit)

            try checkOpenAI(permit)
            let parsed = try UsageParser.parseOpenAIUsagePageWithBuckets(data: data)
            allBuckets.append(contentsOf: parsed.buckets)
            nextPage = parsed.nextPage
            if let nextPage, nextPage.utf8.count > 4096 || !seenPages.insert(nextPage).inserted {
                throw BoundedAPIClient.Failure.limit
            }
        } while nextPage != nil && pageCount < 10
        guard nextPage == nil else { throw BoundedAPIClient.Failure.limit }
        return allBuckets
    }

    private func fetchPaginatedOpenAICosts(apiKey: String, startTime: Int, budget: APIReadBudget, permit: IntegrationPermit) async throws -> Double {
        var totalCost = 0.0
        var nextPage: String? = nil
        var pageCount = 0
        var seenPages = Set<String>()

        repeat {
            try checkOpenAI(permit)
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

            let data = try await apiClient.data(for: req, budget: budget, permit: permit)

            try checkOpenAI(permit)
            let parsed = try UsageParser.parseOpenAICostsPage(data: data)
            totalCost = try UsageNumber.add(totalCost, parsed.costUSD)
            nextPage = parsed.nextPage
            if let nextPage, nextPage.utf8.count > 4096 || !seenPages.insert(nextPage).inserted {
                throw BoundedAPIClient.Failure.limit
            }
        } while nextPage != nil && pageCount < 10
        guard nextPage == nil else { throw BoundedAPIClient.Failure.limit }
        return totalCost
    }

    private func fetchGeminiUsage(projectId: String, budget: APIReadBudget, permit: IntegrationPermit) async {
        guard (try? checkGemini(permit)) != nil,
              let token = await configuredGcloudToken(budget: budget, permit: permit) else {
            return
        }

        guard (try? checkGemini(permit)) != nil else { return }
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
                endStr: endStr,
                budget: budget,
                permit: permit
            ), monthTokens > 0 {
                try checkGemini(permit)
                self.geminiUsedTokens = monthTokens

                let weekStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .weekly, now: now))))
                let dayStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .daily, now: now))))
                let fiveHStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .fiveHours, now: now))))
                let twoHStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .twoHours, now: now))))

                if let w = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: weekStartStr, endStr: endStr, budget: budget, permit: permit) {
                    try checkGemini(permit)
                    self.geminiUsedWeekly = w
                }
                if let d = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: dayStartStr, endStr: endStr, budget: budget, permit: permit) {
                    try checkGemini(permit)
                    self.geminiUsedDaily = d
                }
                if let h = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: fiveHStartStr, endStr: endStr, budget: budget, permit: permit) {
                    try checkGemini(permit)
                    self.geminiUsed5h = h
                }
                if let h2 = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: twoHStartStr, endStr: endStr, budget: budget, permit: permit) {
                    try checkGemini(permit)
                    self.geminiUsed2h = h2
                }

                try checkGemini(permit)
                recordUsageUpdate()
                geminiStatus = "GCP"
                return
            }

            let reqCount = try await queryCloudMonitoring(
                projectId: projectId,
                token: token,
                filter: requestCountFilter,
                startStr: monthStartStr,
                endStr: endStr,
                budget: budget,
                permit: permit
            )
            try checkGemini(permit)
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
        endStr: String,
        budget: APIReadBudget,
        permit: IntegrationPermit
    ) async throws -> Int {
        guard UsageParser.isValidGCPProjectReference(projectId),
              var components = URLComponents(string: "https://monitoring.googleapis.com") else {
            throw URLError(.badURL)
        }
        components.path = "/v3/projects/\(projectId)/timeSeries"
        let queryItems = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "interval.startTime", value: startStr),
            URLQueryItem(name: "interval.endTime", value: endStr)
        ]
        var total = 0
        var nextPage: String?
        var seenPages = Set<String>()
        for _ in 0..<10 {
            try checkGemini(permit)
            components.queryItems = queryItems + (nextPage.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data = try await apiClient.data(for: request, budget: budget, permit: permit)
            try checkGemini(permit)
            total = try UsageNumber.add(total, UsageParser.parseGeminiMonitoringSeries(data: data))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            nextPage = (root?["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let nextPage else { return total }
            guard nextPage.utf8.count <= 4096, seenPages.insert(nextPage).inserted else {
                throw BoundedAPIClient.Failure.limit
            }
        }
        throw BoundedAPIClient.Failure.limit
    }

    private func configuredGcloudToken(budget: APIReadBudget, permit: IntegrationPermit) async -> String? {
        guard (try? checkGemini(permit)) != nil else { return nil }
        if let gcloudTokenProvider { return await gcloudTokenProvider(budget, permit) }
        return await fetchGcloudAccessToken(budget: budget, permit: permit)
    }

    private func fetchGcloudAccessToken(budget: APIReadBudget, permit: IntegrationPermit) async -> String? {
        guard (try? checkGemini(permit)) != nil,
              (try? budget.remainingSeconds()) != nil else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud",
                          "\(home)/google-cloud-sdk/bin/gcloud", "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"]
        let worker = Task.detached(priority: .utility) { () async throws -> String? in
            guard let executable = candidates.compactMap({ ExecutableTrust.executable(at: $0) }).first else { return nil }
            let environment = try GcloudEnvironment.make(home: home, inherited: ProcessInfo.processInfo.environment)
            // Revalidate the exact resolved path immediately before spawning.
            guard ExecutableTrust.executable(at: executable) == executable else { return nil }
            var limits = BoundedProcess.Limits()
            let remaining = try budget.remainingSeconds()
            let cleanupAllowance = limits.terminationGrace + limits.killGrace
            guard remaining > cleanupAllowance else { return nil }
            limits.seconds = min(limits.seconds, remaining - cleanupAllowance)
            let output = try await BoundedProcess.run(executable: executable,
                arguments: ["auth", "print-access-token", "--quiet"], environment: environment, limits: limits, permit: permit)
            guard let token = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  BoundedAPIClient.isSafeBearer(token) else { return nil }
            return token
        }
        return await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: { worker.cancel() }
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
            return showUsageAmounts && !metric.isQuotaOnly
                ? "\(status)、推定使用量 \(formatCompactUsage(metric.usedTokens, unit: unit)) \(unit)"
                : status
        }
        let prefix = metric.remainingSource == .configuredLimit ? "設定上限からの目安、" : ""
        let percentage = "\(prefix)残り \(metric.remainingPercent)パーセント"
        guard showUsageAmounts && !metric.isQuotaOnly else { return percentage }
        return "\(percentage)、残量の目安 \(formatCompactUsage(metric.remainingTokens, unit: unit)) \(unit)"
    }

    var body: some View {
        let ratio = metric.remainingRatio
        let pct = metric.remainingPercent
        let usageText = metric.isValid ? formatCompactUsage(metric.remainingTokens, unit: unit) : "数値エラー"

        HStack(spacing: 8) {
            // 1. Period Label
            Text(metric.displayLabel)
                .font(.caption.weight(isHighlighted ? .semibold : .regular))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .frame(width: metric.isQuotaOnly ? 128 : 38, alignment: .leading)
                .lineLimit(2)
                .help(metric.displayLabel)

            // 2. Native remaining-capacity gauge
            if metric.isRemainingAvailable {
                RemainingQuotaGauge(ratio: ratio)

                // Optional amount; percentages remain the default presentation.
                if showUsageAmounts && !metric.isQuotaOnly {
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
                if showUsageAmounts && !metric.isQuotaOnly {
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
        .accessibilityLabel("\(metric.displayLabel)制限")
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

    @State private var isShowingDetails: Bool = false

    var displayedMetrics: [PeriodUsageMetric] {
        if let filter = selectedFilter {
            return metrics.filter { $0.period == filter }
        }
        if isDetailed || metrics.contains(where: \.isQuotaOnly) {
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
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    providerHeader
                    if metrics.allSatisfy(\.isQuotaOnly), !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var providerHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(spacing: 5) {
                ServiceIcon(serviceID: serviceID, fallbackSystemName: resolvedIconName)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)

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
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
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
    }

    private var usageDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title)の利用詳細")
                .font(.headline)

            if metrics.allSatisfy(\.isQuotaOnly) {
                Text("Antigravityが返す利用枠の残り割合です。トークン数や設定上限からの推計ではありません。取得できない枠は未取得とし、リセット予定を過ぎた値は再取得まで表示しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if metrics.contains(where: \.requiresOfficialQuota) {
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
                        LabeledContent("\(metric.displayLabel)枠のリセット", value: reset)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(metric.displayLabel)枠のリセット")
                            .accessibilityValue(reset)
                    }
                }
            }

            ForEach(metrics.filter { $0.resetDescription != nil }) { metric in
                if let description = metric.resetDescription {
                    Text("\(metric.displayLabel)：\(description)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

func isDesktopWidgetWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.contains("desktop-widget") == true
        || window.title == "AIMeter"
        || window.title == "AI Meter Widget"
}

func closeDesktopWidgetWindow(monitor: UsageMonitor? = nil) {
    DispatchQueue.main.async {
        for window in NSApp.windows where isDesktopWidgetWindow(window) {
            window.close()
        }
        monitor?.isDesktopWidgetOpen = false
    }
}

func miniaturizeDesktopWidgetWindow(monitor: UsageMonitor? = nil) {
    DispatchQueue.main.async {
        for window in NSApp.windows where isDesktopWidgetWindow(window) {
            window.miniaturize(nil)
        }
        monitor?.isDesktopWidgetOpen = false
    }
}

func openOrRestoreDesktopWidgetWindow(monitor: UsageMonitor? = nil, openWindow: @escaping (String) -> Void) {
    DispatchQueue.main.async {
        var found = false
        for window in NSApp.windows where isDesktopWidgetWindow(window) {
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
        window.level = isPinned ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = allowBackgroundDrag
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

// MARK: - Native desktop shell and shared meter content
struct DesktopMeterView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        AIMeterCardView(monitor: monitor)
            .navigationTitle("AIMeter")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    MeterRefreshButton(monitor: monitor)
                    Toggle(isOn: $monitor.isWidgetPinned) {
                        Label("最前面に固定", systemImage: monitor.isWidgetPinned ? "pin.fill" : "pin")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help(monitor.isWidgetPinned ? "最前面固定中 (クリックで解除)" : "通常ウィンドウ (クリックで最前面固定)")
                    .accessibilityIdentifier("pin-widget")
                    .accessibilityValue(monitor.isWidgetPinned ? "固定中" : "解除中")
                    MeterSettingsButton()
                        .disabled(monitor.requiresCollectionIntroduction)
                }
            }
    }
}

private struct MeterRefreshButton: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        Button {
            Task { await monitor.refresh() }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .opacity(monitor.isRefreshing ? 0 : 1)
                if monitor.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 16, height: 16)
        }
        .disabled(monitor.requiresCollectionIntroduction || monitor.isRefreshing)
        .help("今すぐ更新")
        .accessibilityLabel("今すぐ更新")
        .accessibilityValue(monitor.isRefreshing ? "更新中" : "")
        .accessibilityIdentifier("refresh-usage")
    }
}

private struct MeterSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openSettingsWindow(openWindow: openWindow)
        } label: {
            Label("設定を開く", systemImage: "gearshape")
        }
        .labelStyle(.iconOnly)
        .help("設定を開く (⌘,)")
        .accessibilityIdentifier("open-settings")
    }
}

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

    var totalVisibleProvidersCount: Int {
        (monitor.showOpenAISection ? 1 : 0) + (monitor.showGeminiSection ? 1 : 0)
            + (monitor.showAntigravitySection ? 1 : 0) + visibleCustomSubscriptions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isMenuBar {
                HStack {
                    Text("AIMeter")
                        .font(.headline)
                    Spacer()
                    MeterRefreshButton(monitor: monitor)
                    MeterSettingsButton()
                        .disabled(monitor.requiresCollectionIntroduction)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Divider()
            }

            if monitor.requiresCollectionIntroduction {
                ScrollView {
                    CollectionIntroductionView(monitor: monitor)
                        .padding(.trailing, 2)
                }
                .frame(height: 560)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    // A monitor refresh may be newer than the last timeline tick.
                    CharacterSummaryView(highlight: monitor.characterHighlight())
                }

                UsageDisplayModePicker(isDetailedView: $monitor.isDetailedView)

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
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ViewThatFits(in: .vertical) {
                        providerSectionsStack
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            providerSectionsStack
                                .padding(.trailing, 2)
                        }
                    }
                    .frame(maxHeight: isMenuBar ? 300 : 420)
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
            }

            if isMenuBar {
                Divider()
                menuBarFooterButtons
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 348)
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
            if let win = note.object as? NSWindow, isDesktopWidgetWindow(win) {
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

    private var menuBarFooterButtons: some View {
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
            .accessibilityValue(monitor.isDesktopWidgetOpen ? "表示中" : "非表示")

            Spacer()

            Button("設定...") {
                openSettingsWindow(openWindow: openWindow)
            }
            .disabled(monitor.requiresCollectionIntroduction)

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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

            if monitor.showAntigravitySection {
                ProviderUsageSection(
                    title: "Antigravity", subtitle: monitor.antigravityStatus,
                    usedCostUSD: 0, budgetUSD: 0, metrics: monitor.antigravityMetrics,
                    highlightedPeriod: nil, unit: "", isDetailed: monitor.isDetailedView,
                    showUsageAmounts: false, iconName: "sparkles", serviceID: "antigravity"
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
        Window("AIMeter", id: "desktop-widget") {
            DesktopMeterView(monitor: monitor)
        }
        .windowToolbarStyle(.unifiedCompact)
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
            settingsContent
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            settingsContent
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
    }

    @ViewBuilder
    private var settingsContent: some View {
        if monitor.requiresCollectionIntroduction {
            CollectionIntroductionView(monitor: monitor)
                .padding(20)
                .frame(width: 388)
        } else {
            SettingsView(monitor: monitor)
        }
    }
}
