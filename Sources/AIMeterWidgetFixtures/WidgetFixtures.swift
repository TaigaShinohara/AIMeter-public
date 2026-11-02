import Foundation
import AIMeterCore

/// Synthetic scenarios shared by layout tests and the separate QA extension.
/// This module never loads preferences, caches, credentials, or service data.
public enum WidgetFixtureScenario: String, CaseIterable, Identifiable {
    case normal
    case longMixed
    case empty
    case updateFailed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: return "通常・6サービス"
        case .longMixed: return "長い名前・未取得"
        case .empty: return "データ未取得"
        case .updateFailed: return "更新失敗・前回値"
        }
    }
}

public enum WidgetFixtures {
    public static let referenceDate = Date(timeIntervalSince1970: 1_793_491_200)
    public static var scenarios: [WidgetFixtureScenario] { WidgetFixtureScenario.allCases }

    public static var normal: AIMeterWidgetSnapshot { snapshot(for: .normal) }
    public static var longMixed: AIMeterWidgetSnapshot { snapshot(for: .longMixed) }
    public static var empty: AIMeterWidgetSnapshot { snapshot(for: .empty) }
    public static var updateFailed: AIMeterWidgetSnapshot { snapshot(for: .updateFailed) }

    /// Numeric values and reset descriptions are fixed. QA can anchor the update
    /// label to its timeline date without introducing any production input.
    public static func snapshot(
        for scenario: WidgetFixtureScenario,
        at date: Date = referenceDate,
        showUsageAmounts: Bool = true
    ) -> AIMeterWidgetSnapshot {
        guard scenario != .empty else {
            return .empty(showUsageAmounts: showUsageAmounts)
        }
        return .make(
            services: scenario == .longMixed ? longMixedServices : normalServices,
            totalCostUSD: 0,
            updatedAt: date.addingTimeInterval(-120),
            hasData: true,
            updateFailed: scenario == .updateFailed,
            showUsageAmounts: showUsageAmounts
        )
    }

    private static var normalServices: [WidgetServiceItem] {
        [
            item("openai", name: "OpenAI Codex", shortName: "Codex", percent: 12,
                 used: 8_800_000, limit: 10_000_000, usedDisplay: "8.8M", limitDisplay: "10M",
                 period: .fiveHours, source: .official, reset: "1時間20分"),
            item("claude", name: "Anthropic Claude", shortName: "Claude", percent: 34,
                 used: 660_000, limit: 1_000_000, usedDisplay: "660K", limitDisplay: "1.0M",
                 period: .weekly, reset: "2日3時間"),
            item("cursor", name: "Cursor", shortName: "Cursor", percent: 56,
                 used: 44, limit: 100, usedDisplay: "44", limitDisplay: "100", unit: "req",
                 period: .daily, reset: "6時間"),
            item("windsurf", name: "Windsurf", shortName: "Windsurf", percent: 70,
                 used: 150, limit: 500, usedDisplay: "150", limitDisplay: "500", unit: "credits",
                 period: .monthly, reset: "12日"),
            item("copilot", name: "GitHub Copilot", shortName: "Copilot", percent: 90,
                 used: 30, limit: 300, usedDisplay: "30", limitDisplay: "300", unit: "req",
                 period: .monthly, reset: "12日"),
            item("grokbot", name: "Grok Bot", shortName: "Grok", percent: 100,
                 used: 0, limit: 200, usedDisplay: "0", limitDisplay: "200", unit: "req",
                 period: .twoHours, source: .official, reset: "2時間")
        ]
    }

    private static var longMixedServices: [WidgetServiceItem] {
        [
            item("custom-long-name", name: "個人用の長い名前を付けたカスタムAIサービス",
                 shortName: "長い名前のカスタムAIサービス", percent: 0,
                 used: 12_345_678, limit: 12_345_678, usedDisplay: "12.3M", limitDisplay: "12.3M",
                 period: .monthly, reset: "12日3時間"),
            WidgetServiceItem(
                id: "antigravity", name: "Antigravity", shortName: "Antigravity",
                iconName: "sparkles", remainingPercent: 15, remainingRatio: 0.15,
                usedTokens: 0, limitTokens: 0, usedDisplay: "", limitDisplay: "", unit: "",
                bottleneckPeriod: nil, resetText: "1時間20分", remainingSource: .official,
                quotaWindowLabel: "Claude Sonnet・Gemini Pro 共有モデルグループの利用枠",
                isQuotaOnly: true
            ),
            item("openai", name: "OpenAI Codex", shortName: "Codex", percent: 35,
                 used: 6_500_000, limit: 10_000_000, usedDisplay: "6.5M", limitDisplay: "10M",
                 period: .fiveHours, source: .official, reset: "1時間20分"),
            item("cursor", name: "Cursor", shortName: "Cursor", percent: 100,
                 used: 0, limit: 100, usedDisplay: "0", limitDisplay: "100", unit: "req",
                 period: .daily, reset: "6時間"),
            item("gemini", name: "Gemini", shortName: "Gemini", percent: 0,
                 used: 5_300_000, limit: 0, usedDisplay: "5.3M", limitDisplay: "",
                 period: .monthly, source: .unavailable),
            item("custom-unavailable", name: "追加したカスタムサービス（残量を確認できない状態）",
                 shortName: "残量未取得のカスタムサービス", percent: 0,
                 used: 120, limit: 0, usedDisplay: "120", limitDisplay: "", unit: "req",
                 period: .weekly, source: .unavailable)
        ]
    }

    private static func item(
        _ id: String,
        name: String,
        shortName: String,
        percent: Int,
        used: Int,
        limit: Int,
        usedDisplay: String,
        limitDisplay: String,
        unit: String = "tokens",
        period: LimitPeriod,
        source: RemainingQuotaSource = .configuredLimit,
        reset: String? = nil
    ) -> WidgetServiceItem {
        WidgetServiceItem(
            id: id, name: name, shortName: shortName, iconName: "cpu",
            remainingPercent: percent, remainingRatio: Double(percent) / 100,
            usedTokens: used, limitTokens: limit, usedDisplay: usedDisplay, limitDisplay: limitDisplay,
            unit: unit, bottleneckPeriod: period, resetText: reset, remainingSource: source
        )
    }
}
