import SwiftUI
import AppKit
import CoreFoundation
import AIMeterCore

// MARK: - Onboarding Persistence & Version Management

enum CollectionIntroduction {
    static let acknowledgmentPreference = "hasAcknowledgedCollectionV1"
    static let onboardingVersionPreference = "onboardingCompletedVersion"
    static let currentOnboardingVersion = 1

    /// Earlier versions started collection at launch. Preserve those users'
    /// chosen services without presenting a new-install screen after an update.
    static func hasAcknowledged(in defaults: UserDefaults) -> Bool {
        if let value = defaults.object(forKey: acknowledgmentPreference) {
            return isTrueBoolean(value)
        }
        return ["didCalibrateRealLimitsV1", "didAutoSeedLocalProvidersV2", "didMigrateHonestCostsV3"]
            .contains { key in
                defaults.object(forKey: key).map(isTrueBoolean) ?? false
            }
    }

    /// Checks whether onboarding should be shown, factoring in both first-launch
    /// acknowledgment and onboarding version upgrades when an explicit version is stored.
    static func shouldShowOnboarding(
        in defaults: UserDefaults,
        requiredVersion: Int = currentOnboardingVersion
    ) -> Bool {
        guard hasAcknowledged(in: defaults) else { return true }
        if let storedVersion = defaults.object(forKey: onboardingVersionPreference) as? Int {
            return storedVersion < requiredVersion
        }
        return false
    }

    static func markOnboardingCompleted(
        in defaults: UserDefaults,
        version: Int = currentOnboardingVersion
    ) {
        defaults.set(true, forKey: acknowledgmentPreference)
        defaults.set(version, forKey: onboardingVersionPreference)
    }

    private static func isTrueBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}

// MARK: - First-use navigation

@MainActor
final class OnboardingController: ObservableObject {
    enum Page: Int, CaseIterable {
        case overview, display, services

        var title: String {
            switch self {
            case .overview: return "AIの利用状況を、ひと目で"
            case .display: return "最初の表示を選ぶ"
            case .services: return "集計するAIを選ぶ"
            }
        }
    }

    @Published private(set) var currentPage: Page

    init(initialPageIndex: Int = 0) {
        currentPage = Page(rawValue: min(max(0, initialPageIndex), Page.allCases.count - 1)) ?? .overview
    }

    var canGoBack: Bool { currentPage != .overview }
    var canSkip: Bool { currentPage != .services }

    func goNext() {
        if let next = Page(rawValue: currentPage.rawValue + 1) { currentPage = next }
    }

    func goBack() {
        if let previous = Page(rawValue: currentPage.rawValue - 1) { currentPage = previous }
    }

    func skipToConnection() { currentPage = .services }

    func selectDisplayMode(_ detailed: Bool, applyTo monitor: UsageMonitor) {
        monitor.isDetailedView = detailed
    }

    func completeOnboarding(monitor: UsageMonitor) {
        guard currentPage == .services else { return }
        monitor.beginCollection()
    }
}

struct CollectionIntroductionView: View {
    @ObservedObject var monitor: UsageMonitor
    @StateObject private var controller: OnboardingController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    init(monitor: UsageMonitor, initialPageIndex: Int = 0) {
        self.monitor = monitor
        _controller = StateObject(wrappedValue: OnboardingController(initialPageIndex: initialPageIndex))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("戻る", systemImage: "chevron.left") { controller.goBack() }
                    .disabled(!controller.canGoBack)
                Spacer()
                Text("\(controller.currentPage.rawValue + 1) / \(OnboardingController.Page.allCases.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("全3ステップ中、\(controller.currentPage.rawValue + 1)ステップ目")
                Spacer()
                Button("設定へ") { controller.skipToConnection() }
                    .disabled(!controller.canSkip)
                    .help("集計するAIの選択へ進みます。まだ集計は開始しません")
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Text(controller.currentPage.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            pageContent

            Button {
                if controller.currentPage == .services {
                    controller.completeOnboarding(monitor: monitor)
                } else {
                    controller.goNext()
                }
            } label: {
                Text(actionTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(controller.currentPage == .services ? "begin-collection" : "onboarding-next")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionTitle: String {
        switch controller.currentPage {
        case .overview: return "表示を選ぶ"
        case .display: return "集計するAIを選ぶ"
        case .services: return "使い始める"
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch controller.currentPage {
        case .overview:
            HStack(alignment: .center, spacing: 16) {
                LiquidBallArtwork(contrast: contrast, colorScheme: colorScheme,
                                  reduceTransparency: reduceTransparency, motion: .rest)
                    .frame(width: 56, height: 64)
                    .accessibilityHidden(true)
                Text("メニューバーとウィジェットで、複数のAIをまとめて確認できます。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("公式値・設定上限からの目安・未取得を区別して表示します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .display:
            UsageDisplayModePicker(isDetailedView: Binding(
                get: { monitor.isDetailedView },
                set: { controller.selectDisplayMode($0, applyTo: monitor) }
            ))
            ProviderUsageSection(
                title: "Codex", subtitle: "表示サンプル", usedCostUSD: 0, budgetUSD: 0,
                metrics: [
                    PeriodUsageMetric(period: .fiveHours, usedTokens: 30, limitTokens: 100),
                    PeriodUsageMetric(period: .daily, usedTokens: 20, limitTokens: 100),
                    PeriodUsageMetric(period: .weekly, usedTokens: 40, limitTokens: 100),
                    PeriodUsageMetric(period: .monthly, usedTokens: 10, limitTokens: 100)
                ],
                highlightedPeriod: nil, isDetailed: monitor.isDetailedView, serviceID: "openai"
            )
            Text("表示サンプルです。開始後も上部の切替で変更できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .services:
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Codexのローカルログ", isOn: $monitor.showOpenAISection)
                        .accessibilityIdentifier("step-toggle-openai")
                    Toggle("Geminiのローカルログ", isOn: $monitor.showGeminiSection)
                        .accessibilityIdentifier("step-toggle-gemini")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("開始するまでログは読み取りません。ログはこのMac内で集計し、会話本文は保存・送信しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if AIMETER_APP_STORE
            Text("読み取り先の選択と他のAIの追加は、開始後に「設定 → サービス連携」から行えます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("他のAIは、開始後に「設定 → サービス連携」から追加できます。すべてオフでも開始できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }
}
