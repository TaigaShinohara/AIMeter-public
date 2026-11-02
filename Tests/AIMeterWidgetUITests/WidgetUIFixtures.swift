import AIMeterCore
import Foundation
import WidgetKit

/// Entirely synthetic display data. These fixtures never read the host cache,
/// preferences, credentials, collectors, or a service API.
enum WidgetUIFixtures {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(
        index: Int = 0,
        percent: Int = 60,
        source: RemainingQuotaSource = .official,
        quotaOnly: Bool = false,
        longText: Bool = false,
        includeReset: Bool = true
    ) -> WidgetServiceItem {
        let available = source != .unavailable
        let ratio = available ? Double(percent) / 100 : 0
        let limit = available && !quotaOnly ? 10_000_000 : 0
        let used = quotaOnly ? 0 : available ? Int((1 - ratio) * Double(limit)) : 1_234_567
        return WidgetServiceItem(
            id: String(format: "synthetic-%02d", index),
            name: longText
                ? "合成サービスの長い正式名称・同じ接頭辞を持つ別サービス \(index)"
                : "Synthetic Service \(index)",
            shortName: longText ? "長い短縮サービス名\(index)" : "AI\(index)",
            iconName: "cpu",
            remainingPercent: available ? percent : 0,
            remainingRatio: ratio,
            usedTokens: used,
            limitTokens: limit,
            usedDisplay: quotaOnly ? "" : "1.2M",
            limitDisplay: available && !quotaOnly ? "10M" : "",
            unit: quotaOnly ? "" : longText ? "tokens（長い独自利用単位の表示）" : "tokens",
            bottleneckPeriod: quotaOnly ? nil : .fiveHours,
            resetText: includeReset
                ? (longText ? "あと1日23時間59分・長い補足付きリセット時刻" : "あと1時間20分") : nil,
            remainingSource: source,
            quotaWindowLabel: longText
                ? "Claude Opus / Claude Sonnet / Gemini Pro / Gemini Flash の共有利用枠と長い期間名"
                : quotaOnly ? "Claude / Gemini 共有枠" : nil,
            isQuotaOnly: quotaOnly,
            quotaExpiresAt: quotaOnly ? Int(date.timeIntervalSince1970) + 3_600 : nil
        )
    }

    static func snapshot(
        count: Int,
        showUsage: Bool,
        percent: Int = 60,
        source: RemainingQuotaSource = .official,
        quotaOnly: Bool = false,
        longText: Bool = false,
        updateFailed: Bool = false,
        hasData: Bool = true
    ) -> AIMeterWidgetSnapshot {
        .make(
            services: (0..<count).map {
                item(index: $0, percent: percent, source: source, quotaOnly: quotaOnly, longText: longText)
            },
            totalCostUSD: 0,
            updatedAt: hasData ? date : nil,
            hasData: hasData,
            updateFailed: updateFailed,
            showUsageAmounts: showUsage
        )
    }

    static func mixedSnapshot(showUsage: Bool) -> AIMeterWidgetSnapshot {
        .make(
            services: [
                item(index: 0, percent: 0),
                item(index: 1, percent: 35, source: .configuredLimit, longText: true),
                item(index: 2, percent: 60, quotaOnly: true, longText: true),
                item(index: 3, percent: 99),
                item(index: 4, source: .unavailable, longText: true),
                item(index: 5, source: .unavailable, quotaOnly: true),
                item(index: 6, percent: 100)
            ],
            totalCostUSD: 0, updatedAt: date, hasData: true,
            showUsageAmounts: showUsage
        )
    }

    /// Content bounds measured in the macOS WidgetKit gallery and placement on
    /// 2026-11-01: an 18 pt content margin on every side of each widget.
    struct Canvas {
        let family: WidgetFamily
        let label: String
        let width: CGFloat
        let height: CGFloat

        var size: CGSize { CGSize(width: width, height: height) }
        var visibleServiceLimit: Int {
            switch family {
            case .systemSmall: return 1
            case .systemMedium: return 3
            default: return 6
            }
        }
    }

    static let canvases: [Canvas] = [
        Canvas(family: .systemSmall, label: "small", width: 128, height: 128),
        Canvas(family: .systemMedium, label: "medium", width: 308, height: 128),
        Canvas(family: .systemLarge, label: "large", width: 308, height: 308)
    ]
}
