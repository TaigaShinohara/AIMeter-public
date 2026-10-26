import Foundation
import Darwin

#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Widget Presentation Data Model
public struct WidgetServiceItem: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let shortName: String
    public let iconName: String
    public let remainingPercent: Int
    public let remainingRatio: Double
    public let usedTokens: Int
    public let limitTokens: Int
    public let usedDisplay: String
    public let limitDisplay: String
    public let unit: String
    public let bottleneckPeriod: LimitPeriod
    public let resetText: String?
    public let resetTimestamp: Int?
    public let remainingSource: RemainingQuotaSource

    public var isRemainingAvailable: Bool { remainingSource != .unavailable }

    private enum CodingKeys: String, CodingKey {
        case id, name, shortName, iconName, remainingPercent, remainingRatio
        case usedTokens, limitTokens, usedDisplay, limitDisplay, unit, bottleneckPeriod
        case resetText, resetTimestamp, remainingSource
    }

    public init(
        id: String,
        name: String,
        shortName: String,
        iconName: String,
        remainingPercent: Int,
        remainingRatio: Double,
        usedTokens: Int,
        limitTokens: Int,
        usedDisplay: String,
        limitDisplay: String,
        unit: String,
        bottleneckPeriod: LimitPeriod,
        resetText: String? = nil,
        resetTimestamp: Int? = nil,
        remainingSource: RemainingQuotaSource = .configuredLimit
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.iconName = iconName
        self.remainingPercent = remainingPercent
        self.remainingRatio = remainingRatio
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.usedDisplay = usedDisplay
        self.limitDisplay = limitDisplay
        self.unit = unit
        self.bottleneckPeriod = bottleneckPeriod
        self.resetText = resetText
        self.resetTimestamp = resetTimestamp
        self.remainingSource = remainingSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        shortName = try container.decode(String.self, forKey: .shortName)
        iconName = try container.decode(String.self, forKey: .iconName)
        remainingPercent = try container.decode(Int.self, forKey: .remainingPercent)
        remainingRatio = try container.decode(Double.self, forKey: .remainingRatio)
        usedTokens = try container.decode(Int.self, forKey: .usedTokens)
        limitTokens = try container.decode(Int.self, forKey: .limitTokens)
        usedDisplay = try container.decode(String.self, forKey: .usedDisplay)
        limitDisplay = try container.decode(String.self, forKey: .limitDisplay)
        unit = try container.decode(String.self, forKey: .unit)
        bottleneckPeriod = try container.decode(LimitPeriod.self, forKey: .bottleneckPeriod)
        resetText = try container.decodeIfPresent(String.self, forKey: .resetText)
        resetTimestamp = try container.decodeIfPresent(Int.self, forKey: .resetTimestamp)
        remainingSource = try container.decodeIfPresent(RemainingQuotaSource.self, forKey: .remainingSource)
            ?? (id.lowercased() == "gemini" ? .unavailable : .configuredLimit)
    }

    fileprivate var migratingLegacyQuotaSource: WidgetServiceItem {
        WidgetServiceItem(
            id: id, name: name, shortName: shortName, iconName: iconName,
            remainingPercent: remainingPercent, remainingRatio: remainingRatio,
            usedTokens: usedTokens, limitTokens: limitTokens,
            usedDisplay: usedDisplay, limitDisplay: limitDisplay, unit: unit,
            bottleneckPeriod: bottleneckPeriod, resetText: resetText, resetTimestamp: resetTimestamp,
            remainingSource: id.lowercased() == "gemini" ? .unavailable : .configuredLimit
        )
    }

    public func remainingResetText(at date: Date = Date()) -> String? {
        resetTimestamp != nil ? formatRemainingTime(from: resetTimestamp, now: date) : resetText
    }

    /// Uses the same enabled-period metrics that the host app displays.
    public static func fromMetrics(
        id: String, name: String, shortName: String, iconName: String,
        unit: String, metrics: [PeriodUsageMetric]
    ) -> WidgetServiceItem? {
        let validMetrics = metrics.filter(\.isValid)
        let available = validMetrics.filter(\.isRemainingAvailable)
        guard let metric = available.min(by: { $0.remainingRatio < $1.remainingRatio })
            ?? validMetrics.first(where: { $0.period == .monthly }) ?? validMetrics.first else {
            return nil
        }
        let availableRemaining = metric.isRemainingAvailable
        return WidgetServiceItem(
            id: id, name: name, shortName: shortName, iconName: iconName,
            remainingPercent: availableRemaining ? metric.remainingPercent : 0,
            remainingRatio: availableRemaining ? metric.remainingRatio : 0,
            usedTokens: metric.usedTokens, limitTokens: availableRemaining ? metric.effectiveLimitTokens : 0,
            usedDisplay: formatCompactUsage(metric.usedTokens, unit: unit),
            limitDisplay: availableRemaining ? formatCompactUsage(metric.effectiveLimitTokens, unit: unit) : "",
            unit: unit, bottleneckPeriod: metric.period,
            resetTimestamp: availableRemaining ? metric.resetTimestamp : nil,
            remainingSource: metric.remainingSource
        )
    }
}

public struct AIMeterWidgetSnapshot: Equatable, Codable {
    public let mostCriticalService: WidgetServiceItem?
    public let topServices: [WidgetServiceItem]
    public let allServices: [WidgetServiceItem]
    public let totalCostUSD: Double
    public let updatedAt: Date?
    public let hasData: Bool
    public let updateFailed: Bool
    public let schemaVersion: Int
    public let showUsageAmounts: Bool

    private enum CodingKeys: String, CodingKey {
        case mostCriticalService, topServices, allServices, totalCostUSD, updatedAt
        case hasData, updateFailed, schemaVersion, showUsageAmounts
    }

    public init(
        mostCriticalService: WidgetServiceItem?,
        topServices: [WidgetServiceItem],
        allServices: [WidgetServiceItem],
        totalCostUSD: Double,
        updatedAt: Date?,
        hasData: Bool,
        updateFailed: Bool = false,
        showUsageAmounts: Bool = false
    ) {
        self.mostCriticalService = mostCriticalService
        self.topServices = topServices
        self.allServices = allServices
        self.totalCostUSD = totalCostUSD
        self.updatedAt = updatedAt
        self.hasData = hasData
        self.updateFailed = updateFailed
        self.schemaVersion = 2
        self.showUsageAmounts = showUsageAmounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let critical = try container.decodeIfPresent(WidgetServiceItem.self, forKey: .mostCriticalService)
        let top = try container.decode([WidgetServiceItem].self, forKey: .topServices)
        let all = try container.decode([WidgetServiceItem].self, forKey: .allServices)
        totalCostUSD = try container.decode(Double.self, forKey: .totalCostUSD)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        hasData = try container.decode(Bool.self, forKey: .hasData)
        updateFailed = try container.decode(Bool.self, forKey: .updateFailed)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        showUsageAmounts = try container.decodeIfPresent(Bool.self, forKey: .showUsageAmounts) ?? false
        if version == 1 {
            // Check the old redundant lists before rebuilding their order. Gemini's
            // former configured-limit percentage is never migrated as official quota.
            guard top == Array(all.prefix(3)), critical == all.first,
                  zip(all, all.dropFirst()).allSatisfy({ $0.0.remainingRatio <= $0.1.remainingRatio }) else {
                throw DecodingError.dataCorruptedError(forKey: .allServices, in: container,
                                                       debugDescription: "Inconsistent legacy widget services")
            }
            let migrated = Self.sortedServices(all.map(\.migratingLegacyQuotaSource))
            mostCriticalService = migrated.first(where: \.isRemainingAvailable)
            topServices = Array(migrated.prefix(3))
            allServices = migrated
            schemaVersion = 2
        } else {
            mostCriticalService = critical
            topServices = top
            allServices = all
            schemaVersion = version
        }
    }

    public static func empty(updateFailed: Bool = false, showUsageAmounts: Bool = false) -> AIMeterWidgetSnapshot {
        AIMeterWidgetSnapshot(
            mostCriticalService: nil, topServices: [], allServices: [],
            totalCostUSD: 0, updatedAt: nil, hasData: false, updateFailed: updateFailed,
            showUsageAmounts: showUsageAmounts
        )
    }

    public static func make(
        services: [WidgetServiceItem], totalCostUSD: Double, updatedAt: Date?,
        hasData: Bool, updateFailed: Bool = false, showUsageAmounts: Bool = false
    ) -> AIMeterWidgetSnapshot {
        guard hasData else { return .empty(updateFailed: updateFailed, showUsageAmounts: showUsageAmounts) }
        let sorted = sortedServices(services)
        return AIMeterWidgetSnapshot(
            mostCriticalService: sorted.first(where: \.isRemainingAvailable), topServices: Array(sorted.prefix(3)),
            allServices: sorted, totalCostUSD: totalCostUSD, updatedAt: updatedAt,
            hasData: true, updateFailed: updateFailed, showUsageAmounts: showUsageAmounts
        )
    }

    fileprivate static func sortedServices(_ services: [WidgetServiceItem]) -> [WidgetServiceItem] {
        services.sorted {
            if $0.isRemainingAvailable != $1.isRemainingAvailable { return $0.isRemainingAvailable }
            if !$0.isRemainingAvailable { return $0.id < $1.id }
            return $0.remainingRatio == $1.remainingRatio
                ? $0.id < $1.id : $0.remainingRatio < $1.remainingRatio
        }
    }

    /// Sample values are reserved for WidgetKit's placeholder and gallery preview.
    public static func placeholder() -> AIMeterWidgetSnapshot {
        let claude = WidgetServiceItem(
            id: "claude",
            name: "Anthropic Claude",
            shortName: "Cld",
            iconName: "brain.head.profile",
            remainingPercent: 32,
            remainingRatio: 0.32,
            usedTokens: 1_020_000,
            limitTokens: 1_500_000,
            usedDisplay: "1.0M",
            limitDisplay: "1.5M",
            unit: "tokens",
            bottleneckPeriod: .fiveHours,
            resetText: "あと1時間20分"
        )
        let cursor = WidgetServiceItem(
            id: "cursor",
            name: "Cursor",
            shortName: "Cur",
            iconName: "terminal.fill",
            remainingPercent: 68,
            remainingRatio: 0.68,
            usedTokens: 16,
            limitTokens: 50,
            usedDisplay: "16",
            limitDisplay: "50",
            unit: "req",
            bottleneckPeriod: .daily,
            resetText: nil
        )
        let codex = WidgetServiceItem(
            id: "openai",
            name: "OpenAI Codex",
            shortName: "OAI",
            iconName: "cpu",
            remainingPercent: 85,
            remainingRatio: 0.85,
            usedTokens: 6_000_000,
            limitTokens: 40_000_000,
            usedDisplay: "6.0M",
            limitDisplay: "40M",
            unit: "tokens",
            bottleneckPeriod: .fiveHours,
            resetText: nil
        )

        return AIMeterWidgetSnapshot(
            mostCriticalService: claude,
            topServices: [claude, cursor, codex],
            allServices: [claude, cursor, codex],
            totalCostUSD: 14.50,
            updatedAt: Date(),
            hasData: true
        )
    }
}

// MARK: - Shared Store
public enum SharedStore {
    public static let localUsageFileURL: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = FileManager.default.string(withFileSystemRepresentation: home, length: strlen(home))
            return URL(fileURLWithPath: homePath).appendingPathComponent(".ai_meter_usage.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
    }()

    public static func loadLocalUsageData(from customURL: URL? = nil) -> LocalUsageData? {
        let url = customURL ?? localUsageFileURL
        guard let data = try? BoundedInput().data(at: url),
              let snapshot = try? JSONDecoder().decode(LocalUsageData.self, from: data),
              (try? snapshot.validateNumbers()) != nil else { return nil }
        return snapshot
    }

    public static func loadCustomSubscriptionsFromUserDefaults() -> [CustomSubscriptionConfig] {
        let raw = UserDefaults.standard.string(forKey: "customSubscriptionsJSON") ?? "[]"
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([CustomSubscriptionConfig].self, from: data) else {
            return []
        }
        return list
    }

    public static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Presentation cache contains only the host app's final display values.
    /// The extension does not independently interpret preferences or local logs.
    public static let widgetSnapshotFileURL = localUsageFileURL.deletingLastPathComponent()
        .appendingPathComponent(".ai_meter_widget.json")

    public static func loadWidgetSnapshot(from customURL: URL? = nil) -> AIMeterWidgetSnapshot {
        var limits = BoundedInput.Limits()
        limits.jsonBytes = 1024 * 1024
        guard let data = try? BoundedInput(limits: limits).data(at: customURL ?? widgetSnapshotFileURL),
              let snapshot = try? JSONDecoder().decode(AIMeterWidgetSnapshot.self, from: data),
              (try? validateWidgetSnapshot(snapshot)) != nil else { return .empty() }
        return snapshot
    }

    /// The exclusive 0600 temporary file is never readable with broader default
    /// permissions. Atomic rename replaces the destination itself, not symlink targets.
    public static func saveWidgetSnapshot(_ snapshot: AIMeterWidgetSnapshot, to customURL: URL? = nil) throws {
        try validateWidgetSnapshot(snapshot)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1024 * 1024 else { throw BoundedInput.Failure.limit }
        let destination = customURL ?? widgetSnapshotFileURL
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".ai_meter_widget.\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BoundedInput.Failure.file }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw BoundedInput.Failure.file }
    }

    private static func validateWidgetSnapshot(_ snapshot: AIMeterWidgetSnapshot) throws {
        guard snapshot.schemaVersion == 2,
              snapshot.allServices.count <= 256,
              Set(snapshot.allServices.map(\.id)).count == snapshot.allServices.count,
              snapshot.topServices == Array(snapshot.allServices.prefix(3)),
              snapshot.mostCriticalService == snapshot.allServices.first(where: \.isRemainingAvailable),
              snapshot.allServices == AIMeterWidgetSnapshot.sortedServices(snapshot.allServices) else {
            throw BoundedInput.Failure.file
        }
        _ = try UsageNumber.finite(snapshot.totalCostUSD)
        if snapshot.hasData {
            guard let date = snapshot.updatedAt,
                  date.timeIntervalSince1970.isFinite,
                  (0...253_402_300_799).contains(date.timeIntervalSince1970) else {
                throw BoundedInput.Failure.file
            }
        } else {
            guard snapshot.updatedAt == nil, snapshot.allServices.isEmpty, snapshot.totalCostUSD == 0 else {
                throw BoundedInput.Failure.file
            }
        }
        for item in snapshot.allServices {
            if let reset = item.resetTimestamp {
                guard (0...253_402_300_799).contains(reset) else { throw BoundedInput.Failure.file }
            }
            _ = try UsageNumber.checked(item.usedTokens)
            _ = try UsageNumber.checked(item.limitTokens)
            guard item.remainingRatio.isFinite, (0...1).contains(item.remainingRatio),
                  item.remainingPercent == Int((item.remainingRatio * 100).rounded()),
                  !item.id.isEmpty,
                  [item.id, item.name, item.shortName, item.iconName, item.usedDisplay,
                   item.limitDisplay, item.unit, item.resetText ?? ""].allSatisfy({ $0.utf8.count <= 512 }) else {
                throw BoundedInput.Failure.file
            }
        }
    }
}
