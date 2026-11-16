import SwiftUI
import AppKit
import CoreFoundation
import AIMeterCore

// MARK: - Onboarding Persistence & Version Management

enum CollectionIntroduction {
    static let acknowledgmentPreference = "hasAcknowledgedCollectionV1"
    static let onboardingVersionPreference = "onboardingCompletedVersion"
    static let selectedWorryPreference = "onboardingSelectedWorryV1"
    static let selectedTrialModePreference = "onboardingSelectedTrialModeV1"
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

// MARK: - Page Roles & Page Map Specification

enum OnboardingPageRole: String, CaseIterable, Equatable {
    case hook = "フック"
    case selection = "選択"
    case match = "マッチ"
    case identity = "アイデンティティ"
    case value = "価値"
    case step = "ステップ"
    case interaction = "インタラクション"
    case expectation = "期待"
    case connection = "接続"
}

enum OnboardingReactionLevel: String, Equatable {
    case neutral
    case small
    case medium
    case large
}

enum OnboardingValueTopic: String, CaseIterable, Equatable, Identifiable {
    case proactiveAlert
    case unifiedView
    case localPrivacy

    var id: String { rawValue }
}

enum OnboardingWorryChoice: String, CaseIterable, Equatable, Identifiable {
    case limitSurprise = "limit_surprise"
    case multiToolCheck = "multi_tool_check"
    case privacyConcern = "privacy_concern"
    case notSureYet = "not_sure_yet"

    var id: String { rawValue }

    var optionText: String {
        switch self {
        case .limitSurprise:
            return "気づかないうちに上限に達して、作業が止まる"
        case .multiToolCheck:
            return "AIごとに別々の画面で残りを調べるのが手間"
        case .privacyConcern:
            return "ローカルのログをどう読むのか、安全面が気になる"
        case .notSureYet:
            return "まだわからない・まずは見てみたい"
        }
    }

    var iconName: String {
        switch self {
        case .limitSurprise: return "exclamationmark.triangle.fill"
        case .multiToolCheck: return "square.stack.3d.up.fill"
        case .privacyConcern: return "lock.shield.fill"
        case .notSureYet: return "sparkles"
        }
    }

    var matchHeading: String {
        switch self {
        case .limitSurprise:
            return "「上限で止まる」あなたに、AIMeterはぴったり"
        case .multiToolCheck:
            return "「調べるのが手間」なあなたに、ぴったりです"
        case .privacyConcern:
            return "「安全面が気になる」あなたに、ぴったりです"
        case .notSureYet:
            return "まだ決まっていなくて大丈夫。1つ試しましょう"
        }
    }

    var matchSupplement: String {
        switch self {
        case .limitSurprise:
            return "一番減っている枠をリボが見つけて、メニューバーで先回りして知らせます"
        case .multiToolCheck:
            return "CodexもGeminiも1つのメーターに並べて、ひと目で比べられます"
        case .privacyConcern:
            return "会話の本文は保存も送信もせず、このMacの中だけで集計します"
        case .notSureYet:
            return "開始を押すまでログは読み取らないので、安心して試せます"
        }
    }

    var orderedValueTopics: [OnboardingValueTopic] {
        switch self {
        case .limitSurprise, .notSureYet:
            return [.proactiveAlert, .unifiedView, .localPrivacy]
        case .multiToolCheck:
            return [.unifiedView, .proactiveAlert, .localPrivacy]
        case .privacyConcern:
            return [.localPrivacy, .proactiveAlert, .unifiedView]
        }
    }
}

enum OnboardingDisplayTrialChoice: String, CaseIterable, Equatable, Identifiable {
    case summary = "summary"
    case detailed = "detailed"

    var id: String { rawValue }

    var optionTitle: String {
        switch self {
        case .summary: return "要点だけスッキリ見る"
        case .detailed: return "全期間をじっくり見る"
        }
    }

    var optionSubtitle: String {
        switch self {
        case .summary: return "一番減っている枠と月間枠だけに絞ります"
        case .detailed: return "5時間・日・週・月のすべての枠を並べます"
        }
    }

    var iconName: String {
        switch self {
        case .summary: return "rectangle.compress.vertical"
        case .detailed: return "list.bullet.below.rectangle"
        }
    }

    var resultHeading: String {
        switch self {
        case .summary: return "「要点だけスッキリ見る」をセットしました！"
        case .detailed: return "「全期間をじっくり見る」をセットしました！"
        }
    }

    var resultSupplement: String {
        switch self {
        case .summary: return "始めた瞬間から要点モードで開きます。あとでいつでも切り替えられます"
        case .detailed: return "始めた瞬間から全期間モードで開きます。あとでいつでも切り替えられます"
        }
    }
}

enum OnboardingPageID: Equatable, Hashable {
    case hook
    case worrySelection
    case worryMatch
    case identity
    case value(OnboardingValueTopic)
    case step1ChooseAI
    case step2CheckMenuBar
    case step3SwitchMode
    case trialInteraction
    case trialResult
    case expectation
    case connection
}

struct OnboardingPageSpec: Equatable, Identifiable {
    let index: Int
    let pageID: OnboardingPageID
    let role: OnboardingPageRole
    let chapterLabel: String
    let heading: String
    let supplement: String
    let visualCenterpiece: String
    let heroAnimationMeaning: String
    let ambientElementCount: Int
    let showsNextButton: Bool
    let reactionLevel: OnboardingReactionLevel

    var id: OnboardingPageID { pageID }
}

// MARK: - Window Dots Progress Calculation

struct OnboardingWindowDotsModel: Equatable {
    enum DotScale: Equatable {
        case current
        case adjacent
        case outer
        case edgeMore
    }

    struct DotItem: Equatable, Identifiable {
        let pageIndex: Int
        let scale: DotScale
        let isCompletedFinal: Bool

        var id: Int { pageIndex }
    }

    let currentPage: Int
    let totalPages: Int
    let windowSize: Int
    let windowStart: Int
    let dots: [DotItem]

    static let maxVisibleDots = 5

    init(currentPage: Int, totalPages: Int) {
        let clampedTotal = max(1, totalPages)
        let clampedCurrent = min(max(0, currentPage), clampedTotal - 1)
        let size = min(Self.maxVisibleDots, clampedTotal)
        let maxStart = max(0, clampedTotal - size)
        let start = min(max(0, clampedCurrent - 2), maxStart)
        let end = start + size
        let isFinalPage = (clampedCurrent == clampedTotal - 1)

        var items: [DotItem] = []
        items.reserveCapacity(size)
        for idx in start..<end {
            let scale: DotScale
            if idx == clampedCurrent {
                scale = .current
            } else if idx == start && start > 0 {
                scale = .edgeMore
            } else if idx == end - 1 && end < clampedTotal {
                scale = .edgeMore
            } else if abs(idx - clampedCurrent) == 1 {
                scale = .adjacent
            } else {
                scale = .outer
            }
            items.append(DotItem(pageIndex: idx, scale: scale, isCompletedFinal: isFinalPage))
        }

        self.currentPage = clampedCurrent
        self.totalPages = clampedTotal
        self.windowSize = size
        self.windowStart = start
        self.dots = items
    }
}

// MARK: - Haptics, Non-Repeating Praise & Privacy-Safe Events

protocol OnboardingHapticPerforming {
    func perform(level: OnboardingReactionLevel)
}

struct SystemOnboardingHapticPerformer: OnboardingHapticPerforming {
    func perform(level: OnboardingReactionLevel) {
        switch level {
        case .neutral:
            break
        case .small:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .medium:
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        case .large:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
}

enum OnboardingEvent: Equatable {
    case pageViewed(pageID: OnboardingPageID, role: OnboardingPageRole)
    case interactionAnswered(questionID: String)
    case skipped(fromPageIndex: Int)
    case completed
}

@MainActor
final class OnboardingController: ObservableObject {
    @Published private(set) var currentPageIndex: Int
    @Published private(set) var selectedWorry: OnboardingWorryChoice
    @Published private(set) var selectedTrialChoice: OnboardingDisplayTrialChoice
    @Published private(set) var latestPraise: String?
    @Published private(set) var latestReactionLevel: OnboardingReactionLevel = .neutral
    @Published private(set) var reactionPulseID = UUID()
    @Published private(set) var isAutoAdvancing: Bool = false
    @Published private(set) var navigationDirection: Int = 1
    @Published private(set) var recordedEvents: [OnboardingEvent] = []

    private var lastPraiseIndexByLevel: [OnboardingReactionLevel: Int] = [:]
    private var autoAdvanceTask: Task<Void, Never>?
    private let hapticPerformer: OnboardingHapticPerforming
    let autoAdvanceDelayNanoseconds: UInt64

    static let smallPraisePool = [
        "確認しました。次へ進みましょう",
        "了解です。そのまま続けましょう",
        "受け取りました。次のステップです"
    ]

    static let mediumPraisePool = [
        "教えてくれてありがとうございます。ぴったりの順番に整えました",
        "その選び方でばっちりです。最初の画面に反映します",
        "あなたに合う表示が見つかりました。このまま進みましょう"
    ]

    static let largePraisePool = [
        "準備が整いました。あなた専用のメーターを始められます",
        "いい設定ができました。さっそく最初の残量を見てみましょう",
        "ここまでで準備は完了です。あとは使い始めるだけです"
    ]

    init(
        initialPageIndex: Int = 0,
        selectedWorry: OnboardingWorryChoice = .limitSurprise,
        selectedTrialChoice: OnboardingDisplayTrialChoice = .summary,
        autoAdvanceDelayNanoseconds: UInt64 = 300_000_000,
        hapticPerformer: OnboardingHapticPerforming = SystemOnboardingHapticPerformer()
    ) {
        self.currentPageIndex = initialPageIndex
        self.selectedWorry = selectedWorry
        self.selectedTrialChoice = selectedTrialChoice
        self.autoAdvanceDelayNanoseconds = autoAdvanceDelayNanoseconds
        self.hapticPerformer = hapticPerformer
        let initialPages = Self.buildPages(worry: selectedWorry, trial: selectedTrialChoice)
        let safeIndex = min(max(0, initialPageIndex), initialPages.count - 1)
        self.currentPageIndex = safeIndex
        recordPageView(for: initialPages[safeIndex])
    }

    var pages: [OnboardingPageSpec] {
        Self.buildPages(worry: selectedWorry, trial: selectedTrialChoice)
    }

    var currentPage: OnboardingPageSpec {
        let all = pages
        return all[min(max(0, currentPageIndex), all.count - 1)]
    }

    var windowDots: OnboardingWindowDotsModel {
        OnboardingWindowDotsModel(currentPage: currentPageIndex, totalPages: pages.count)
    }

    var canGoBack: Bool {
        currentPageIndex > 0
    }

    var canSkip: Bool {
        currentPageIndex < pages.count - 1
    }

    static func buildPages(
        worry: OnboardingWorryChoice,
        trial: OnboardingDisplayTrialChoice
    ) -> [OnboardingPageSpec] {
        var specs: [OnboardingPageSpec] = []

        func add(
            pageID: OnboardingPageID,
            role: OnboardingPageRole,
            chapterLabel: String,
            heading: String,
            supplement: String,
            visualCenterpiece: String,
            heroAnimationMeaning: String,
            ambientElementCount: Int,
            showsNextButton: Bool,
            reactionLevel: OnboardingReactionLevel
        ) {
            specs.append(OnboardingPageSpec(
                index: specs.count,
                pageID: pageID,
                role: role,
                chapterLabel: chapterLabel,
                heading: heading,
                supplement: supplement,
                visualCenterpiece: visualCenterpiece,
                heroAnimationMeaning: heroAnimationMeaning,
                ambientElementCount: ambientElementCount,
                showsNextButton: showsNextButton,
                reactionLevel: reactionLevel
            ))
        }

        // #1 フック
        add(
            pageID: .hook,
            role: .hook,
            chapterLabel: "はじめに",
            heading: "AIの残り枠、別々に開いて調べていませんか？",
            supplement: "メニューバーをひと目見るだけで、今の残りがわかります",
            visualCenterpiece: "リボと複数AIのミニメーター図",
            heroAnimationMeaning: "散らばったAIアイコンがメーターへ集まり、1箇所で把握できることを伝える",
            ambientElementCount: 1,
            showsNextButton: true,
            reactionLevel: .small
        )

        // #2 選択（悩み・希望）
        add(
            pageID: .worrySelection,
            role: .selection,
            chapterLabel: "お困りごとの選択",
            heading: "AIを使っていて、いちばん困るのはどれですか？",
            supplement: "あなたの答えに合わせて、続く説明と初期表示を整えます",
            visualCenterpiece: "具体的な場面の選択肢3つと逃げ道1つ",
            heroAnimationMeaning: "選択肢カードが順番に浮かび上がり、タップして選べることを伝える",
            ambientElementCount: 0,
            showsNextButton: false,
            reactionLevel: .medium
        )

        // #3 マッチ（結果のページ）
        add(
            pageID: .worryMatch,
            role: .match,
            chapterLabel: "ぴったりの理由",
            heading: worry.matchHeading,
            supplement: worry.matchSupplement,
            visualCenterpiece: "選んだ悩みのアイコンとリボが重なる図",
            heroAnimationMeaning: "悩みのアイコンとリボが寄って重なり、目的にぴったり合うことを伝える",
            ambientElementCount: 1,
            showsNextButton: true,
            reactionLevel: .medium
        )

        // #4 アイデンティティ
        add(
            pageID: .identity,
            role: .identity,
            chapterLabel: "AIMeterの役割",
            heading: "複数のAIの残り枠を、ひと目で見守る計器です",
            supplement: "CodexやGeminiなどの利用状況を、メニューバーとウィジェットに集めます",
            visualCenterpiece: "メニューバーとデスクトップウィジェットのモック",
            heroAnimationMeaning: "メニューバーからウィジェットへ注目が移り、常駐して見守る仕組みを伝える",
            ambientElementCount: 1,
            showsNextButton: true,
            reactionLevel: .small
        )

        // #5〜#7 価値（選んだ悩みに対応する価値から先に並べる）
        for (offset, topic) in worry.orderedValueTopics.enumerated() {
            let chapter = "できることの\(offset + 1)つめ"
            switch topic {
            case .proactiveAlert:
                add(
                    pageID: .value(.proactiveAlert),
                    role: .value,
                    chapterLabel: chapter,
                    heading: "残り少ない枠を、リボが先回りして知らせます",
                    supplement: "5時間枠や月間枠から、いま一番減っているところをひとことで案内します",
                    visualCenterpiece: "リボと吹き出しの案内カード",
                    heroAnimationMeaning: "吹き出しが開いて最小残量のゲージが光り、先回り案内を伝える",
                    ambientElementCount: 1,
                    showsNextButton: true,
                    reactionLevel: .small
                )
            case .unifiedView:
                add(
                    pageID: .value(.unifiedView),
                    role: .value,
                    chapterLabel: chapter,
                    heading: "よく使うAIの残りを、1つの画面にまとめます",
                    supplement: "公式の残量と、設定上限からの『約』の目安を区別して並べます",
                    visualCenterpiece: "CodexとGeminiの比較ゲージカード",
                    heroAnimationMeaning: "複数のサービスゲージが順番に伸びて揃い、一覧で比べられることを伝える",
                    ambientElementCount: 1,
                    showsNextButton: true,
                    reactionLevel: .small
                )
            case .localPrivacy:
                #if AIMETER_APP_STORE
                let privacySupplement = "集計はこのMacに保存し、開始するまでログは読み取りません。更新はMac App Storeから行います"
                #else
                let privacySupplement = "会話の本文は集計へ保存せず外部へ送りません。開始までログは読み取りません"
                #endif
                add(
                    pageID: .value(.localPrivacy),
                    role: .value,
                    chapterLabel: "安全とプライバシー",
                    heading: "このMacの中だけで集計し、いつでも停止できます",
                    supplement: privacySupplement,
                    visualCenterpiece: "Macと保護シールドの図形",
                    heroAnimationMeaning: "保護シールドが短いフェードで静かに現れ、端末内保護の安心感を伝える",
                    ambientElementCount: 0, // 真剣なページでは常時アニメーションを止める
                    showsNextButton: true,
                    reactionLevel: .small
                )
            }
        }

        // #8 ステップ1
        add(
            pageID: .step1ChooseAI,
            role: .step,
            chapterLabel: "使い方の1つめ",
            heading: "1. 使うAIを選ぶ",
            supplement: "最初に集計するサービスをオンにします。他のAIも設定から追加できます",
            visualCenterpiece: "ステップ番号1とCodex・Geminiの選択カード",
            heroAnimationMeaning: "番号1とサービスのスイッチが強調され、最初の手順を伝える",
            ambientElementCount: 0,
            showsNextButton: true,
            reactionLevel: .small
        )

        // #9 ステップ2
        add(
            pageID: .step2CheckMenuBar,
            role: .step,
            chapterLabel: "使い方の2つめ",
            heading: "2. メニューバーを見る",
            supplement: "作業中でも画面を切り替えずに、残り％とリボの案内がわかります",
            visualCenterpiece: "ステップ番号2とメニューバー残量表示モック",
            heroAnimationMeaning: "番号2へ切り替わり、メニューバーの残り％が描かれて確認手順を伝える",
            ambientElementCount: 1,
            showsNextButton: true,
            reactionLevel: .small
        )

        // #10 ステップ3
        add(
            pageID: .step3SwitchMode,
            role: .step,
            chapterLabel: "使い方の3つめ",
            heading: "3. 要点と全期間を切り替える",
            supplement: "普段は要点だけ、気になる時は全期間のゲージを広げて確かめられます",
            visualCenterpiece: "ステップ番号3と要点・全期間切替モック",
            heroAnimationMeaning: "番号3へ切り替わり、ゲージが要点から全期間へ広がって得られる状態を伝える",
            ambientElementCount: 0,
            showsNextButton: true,
            reactionLevel: .small
        )

        // #11 インタラクション（試し操作）
        add(
            pageID: .trialInteraction,
            role: .interaction,
            chapterLabel: "表示の試し操作",
            heading: "試しに、最初の表示モードを選んでみてください",
            supplement: "本物のメーターのミニ版です。選んだ方がそのまま初期設定になります",
            visualCenterpiece: "ミニメーターと要点・全期間の2択カード",
            heroAnimationMeaning: "表示切替カードが軽く脈打ち、タップして試せることを伝える",
            ambientElementCount: 0,
            showsNextButton: false,
            reactionLevel: .medium
        )

        // #12 マッチ（試し操作の結果）
        add(
            pageID: .trialResult,
            role: .match,
            chapterLabel: "試し操作の結果",
            heading: trial.resultHeading,
            supplement: trial.resultSupplement,
            visualCenterpiece: "セットされた表示モードのメーターと達成チェック",
            heroAnimationMeaning: "メーターとチェック印が一度だけ広がって収まり、設定完了の達成を伝える",
            ambientElementCount: 1,
            showsNextButton: true,
            reactionLevel: .large
        )

        // #13 期待
        add(
            pageID: .expectation,
            role: .expectation,
            chapterLabel: "これからの体験",
            heading: "AIが増えても、残りのペース配分に迷いません",
            supplement: "ClaudeやCursorなどを追加しても、いちばん減っている枠をリボが見守ります",
            visualCenterpiece: "複数のAIアイコンとリボが並ぶメーター図",
            heroAnimationMeaning: "AIアイコンが順番に加わり、使い続けると広がる安心感を伝える",
            ambientElementCount: 2,
            showsNextButton: true,
            reactionLevel: .small
        )

        // #14 接続
        add(
            pageID: .connection,
            role: .connection,
            chapterLabel: "使い始める",
            heading: "選んだAIの残量を、さっそく表示する",
            supplement: "開始ボタンを押すまで、ログは一切読み取りません",
            visualCenterpiece: "選択中サービスの確認カードと使い始めるボタン",
            heroAnimationMeaning: "使い始めるボタンが静かに脈打ち、最初の残量表示へ直結することを伝える",
            ambientElementCount: 1,
            showsNextButton: true,
            reactionLevel: .large
        )

        return specs
    }

    func goNext() {
        autoAdvanceTask?.cancel()
        isAutoAdvancing = false
        guard currentPageIndex < pages.count - 1 else { return }
        navigationDirection = 1
        triggerReaction(.small)
        currentPageIndex += 1
        recordPageView(for: currentPage)
    }

    func goBack() {
        autoAdvanceTask?.cancel()
        isAutoAdvancing = false
        guard canGoBack else { return }
        navigationDirection = -1
        // スキップと戻るには称賛も成功の触覚も付けない
        latestPraise = nil
        latestReactionLevel = .neutral
        currentPageIndex -= 1
        recordPageView(for: currentPage)
    }

    func skipToConnection() {
        autoAdvanceTask?.cancel()
        isAutoAdvancing = false
        guard canSkip else { return }
        let origin = currentPageIndex
        navigationDirection = 1
        // スキップと戻るには称賛も成功の触覚も付けない
        latestPraise = nil
        latestReactionLevel = .neutral
        recordedEvents.append(.skipped(fromPageIndex: origin))
        currentPageIndex = pages.count - 1
        recordPageView(for: currentPage)
    }

    func selectWorry(_ choice: OnboardingWorryChoice, applyTo monitor: UsageMonitor) {
        guard !isAutoAdvancing else { return }
        selectedWorry = choice
        applyWorryChoice(choice, to: monitor)
        recordedEvents.append(.interactionAnswered(questionID: "worry_selection"))
        triggerReaction(.medium)
        scheduleAutoAdvance()
    }

    func selectTrialChoice(_ choice: OnboardingDisplayTrialChoice, applyTo monitor: UsageMonitor) {
        guard !isAutoAdvancing else { return }
        selectedTrialChoice = choice
        monitor.isDetailedView = (choice == .detailed)
        recordedEvents.append(.interactionAnswered(questionID: "display_mode_trial"))
        triggerReaction(.medium)
        scheduleAutoAdvance()
    }

    func completeOnboarding(monitor: UsageMonitor) {
        autoAdvanceTask?.cancel()
        isAutoAdvancing = false
        triggerReaction(.large)
        recordedEvents.append(.completed)
        monitor.beginCollection()
    }

    func applyWorryChoice(_ choice: OnboardingWorryChoice, to monitor: UsageMonitor) {
        switch choice {
        case .limitSurprise:
            monitor.menuBarPeriodMode = "min"
            monitor.menuBarDisplayMode = "smart"
        case .multiToolCheck:
            monitor.menuBarPeriodMode = "min"
            monitor.menuBarDisplayMode = "compact"
        case .privacyConcern:
            monitor.menuBarPeriodMode = "min"
            _ = monitor.setUsageAmountVisibility(false)
        case .notSureYet:
            monitor.menuBarPeriodMode = "min"
            monitor.menuBarDisplayMode = "smart"
        }
    }

    @discardableResult
    func triggerReaction(_ level: OnboardingReactionLevel) -> String? {
        latestReactionLevel = level
        reactionPulseID = UUID()
        hapticPerformer.perform(level: level)

        let pool: [String]
        switch level {
        case .neutral:
            latestPraise = nil
            return nil
        case .small:
            pool = Self.smallPraisePool
        case .medium:
            pool = Self.mediumPraisePool
        case .large:
            pool = Self.largePraisePool
        }

        let previousIndex = lastPraiseIndexByLevel[level]
        var nextIndex = 0
        if let previousIndex {
            nextIndex = (previousIndex + 1) % pool.count
        }
        lastPraiseIndexByLevel[level] = nextIndex
        let phrase = pool[nextIndex]
        latestPraise = phrase
        return phrase
    }

    private func scheduleAutoAdvance() {
        isAutoAdvancing = true
        let delay = autoAdvanceDelayNanoseconds
        if delay == 0 {
            advanceAfterInteraction()
            return
        }
        autoAdvanceTask?.cancel()
        autoAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.advanceAfterInteraction()
        }
    }

    private func advanceAfterInteraction() {
        isAutoAdvancing = false
        guard currentPageIndex < pages.count - 1 else { return }
        navigationDirection = 1
        currentPageIndex += 1
        let dest = currentPage
        if dest.pageID == .trialResult {
            triggerReaction(.large)
        }
        recordPageView(for: dest)
    }

    private func recordPageView(for spec: OnboardingPageSpec) {
        recordedEvents.append(.pageViewed(pageID: spec.pageID, role: spec.role))
    }
}

// MARK: - Onboarding View (1 Page = 1 Claim, Window Dots, Praise & 2-Layer Motion)

struct CollectionIntroductionView: View {
    @ObservedObject var monitor: UsageMonitor
    @StateObject private var controller: OnboardingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date()
    @State private var heroEntered = false

    init(monitor: UsageMonitor, initialPageIndex: Int = 0) {
        self.monitor = monitor
        _controller = StateObject(wrappedValue: OnboardingController(initialPageIndex: initialPageIndex))
    }

    var body: some View {
        let page = controller.currentPage

        VStack(alignment: .leading, spacing: 12) {
            // 1. Top Bar: 戻る + 窓ドット + スキップ (always in the same fixed slots)
            topNavigationBar(for: page)
                .accessibilitySortPriority(1)

            // 2. Middle: Visual Centerpiece (>= 30% of area, never text-only)
            visualStage(for: page)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 190)
                .accessibilitySortPriority(3)

            // 3. Lower: Heading (1 line claim) + Supplement (max 2 lines)
            textSection(for: page)
                .accessibilitySortPriority(4)

            // 4. Praise Feedback Pill (when active)
            praiseBannerView
                .accessibilitySortPriority(2)

            // 5. Bottom: Action Area (Choice options, or Next / Start button)
            bottomActionArea(for: page)
                .accessibilitySortPriority(1)
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .onChange(of: controller.currentPageIndex) { _, _ in
            heroEntered = false
            if reduceMotion {
                heroEntered = true
            } else {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    heroEntered = true
                }
            }
        }
        .onAppear {
            startedAt = Date()
            heroEntered = true
        }
    }

    // MARK: - 1. Top Navigation Bar & Window Dots

    private func topNavigationBar(for page: OnboardingPageSpec) -> some View {
        HStack(spacing: 8) {
            Button {
                if reduceMotion {
                    controller.goBack()
                } else {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        controller.goBack()
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text("戻る")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .opacity(controller.canGoBack ? 1 : 0)
            .disabled(!controller.canGoBack)
            .accessibilityHidden(!controller.canGoBack)
            .accessibilityIdentifier("onboarding-back")

            Spacer(minLength: 4)

            OnboardingWindowDotsView(model: controller.windowDots, reduceMotion: reduceMotion)
                .accessibilityHidden(true)

            Spacer(minLength: 4)

            Button {
                if reduceMotion {
                    controller.skipToConnection()
                } else {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        controller.skipToConnection()
                    }
                }
            } label: {
                Text("スキップ")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .opacity(controller.canSkip ? 1 : 0)
            .disabled(!controller.canSkip)
            .accessibilityHidden(!controller.canSkip)
            .accessibilityIdentifier("onboarding-skip")
        }
    }

    // MARK: - 2. Visual Centerpiece with 2-Layer Animation

    @ViewBuilder
    private func visualStage(for page: OnboardingPageSpec) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || page.ambientElementCount == 0)) { context in
            let elapsed = reduceMotion ? 0 : context.date.timeIntervalSince(startedAt)
            let ambientOffset1 = (reduceMotion || page.ambientElementCount < 1)
                ? 0.0
                : 2.2 * sin(elapsed / 3.6 * 2 * .pi)
            let ambientScale2 = (reduceMotion || page.ambientElementCount < 2)
                ? 1.0
                : 1.0 + 0.025 * cos((elapsed + 1.1) / 4.2 * 2 * .pi)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if page.ambientElementCount >= 2 {
                    Circle()
                        .fill(Color.accentColor.opacity(0.07))
                        .frame(width: 110, height: 110)
                        .scaleEffect(ambientScale2)
                        .offset(x: 68, y: -24)
                        .accessibilityHidden(true)
                }

                centerpieceContent(for: page, elapsed: elapsed, ambientOffset: ambientOffset1)
                    .padding(14)
                    .scaleEffect(reduceMotion ? 1.0 : (heroEntered ? 1.0 : 0.94))
                    .opacity(heroEntered ? 1.0 : 0.0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.10), lineWidth: 1)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page.visualCenterpiece)
    }

    @ViewBuilder
    private func centerpieceContent(
        for page: OnboardingPageSpec,
        elapsed: TimeInterval,
        ambientOffset: Double
    ) -> some View {
        let motion = (reduceMotion || page.ambientElementCount == 0)
            ? CharacterMotionFrame.rest
            : CharacterMotionFrame.at(elapsed)

        switch page.pageID {
        case .hook:
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    onboardingLiquidBall(motion: motion)
                        .frame(width: 48, height: 54)

                    VStack(alignment: .leading, spacing: 8) {
                        miniServiceRow(
                            id: "openai",
                            name: "Codex",
                            icon: "brain.head.profile",
                            isEnabled: monitor.showOpenAISection,
                            ratio: 0.72,
                            percentText: "約72%"
                        )
                        miniServiceRow(
                            id: "gemini",
                            name: "Gemini",
                            icon: "sparkle",
                            isEnabled: monitor.showGeminiSection,
                            ratio: 0.34,
                            percentText: "約34%"
                        )
                    }
                }
                Text(monitor.showOpenAISection || monitor.showGeminiSection
                     ? "選択中のサービスをひと目で比較"
                     : "すべてオフで開始・あとから追加もOK")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .worrySelection:
            VStack(spacing: 6) {
                ForEach(OnboardingWorryChoice.allCases) { choice in
                    let isSelected = controller.selectedWorry == choice
                    Button {
                        controller.selectWorry(choice, applyTo: monitor)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: choice.iconName)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .frame(width: 18)
                            Text(choice.optionText)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.88)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right.circle")
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("worry-choice-\(choice.rawValue)")
                    .accessibilityHint("押すと選択して次のページへ自動で進みます")
                }
            }

        case .worryMatch:
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    onboardingIconBadge(
                        systemName: controller.selectedWorry.iconName,
                        tint: .accentColor,
                        size: 44,
                        iconSize: 20
                    )
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                    onboardingLiquidBall(motion: motion)
                        .frame(width: 48, height: 54)
                }
                onboardingPillBadge(
                    text: "あなた向けに説明順と初期表示を最適化しました",
                    icon: "checkmark.seal.fill",
                    tint: .accentColor
                )
            }

        case .identity:
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.needle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("GPT 残約72% · Gem 残約34%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .offset(y: ambientOffset * 0.5)

                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    onboardingLiquidBall(motion: motion)
                        .frame(width: 44, height: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("メニューバー ＋ ウィジェット")
                            .font(.caption.weight(.semibold))
                        Text("作業画面を邪魔せず、いつでも残量を確認")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .value(let topic):
            switch topic {
            case .proactiveAlert:
                HStack(spacing: 12) {
                    onboardingLiquidBall(motion: motion)
                        .frame(width: 48, height: 54)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("少なくなってきたよ", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("Geminiの5時間枠が残り約28%だよ")
                            .font(.caption.weight(.medium))
                        OnboardingQuotaBar(ratio: 0.28)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }

            case .unifiedView:
                VStack(spacing: 10) {
                    miniServiceRow(
                        id: "openai",
                        name: "OpenAI Codex (公式値)",
                        icon: "brain.head.profile",
                        isEnabled: true,
                        ratio: 0.80,
                        percentText: "80%"
                    )
                    miniServiceRow(
                        id: "gemini",
                        name: "Gemini (設定上限の目安)",
                        icon: "sparkle",
                        isEnabled: true,
                        ratio: 0.45,
                        percentText: "約45%"
                    )
                    miniServiceRow(
                        id: "claude",
                        name: "Claude Code (目安)",
                        icon: "bubble.left.and.bubble.right.fill",
                        isEnabled: true,
                        ratio: 0.62,
                        percentText: "約62%"
                    )
                }
                .offset(y: ambientOffset * 0.5)

            case .localPrivacy:
                VStack(spacing: 10) {
                    onboardingIconBadge(
                        systemName: "lock.laptopcomputer",
                        tint: .teal,
                        size: 46,
                        iconSize: 22
                    )
                    HStack(spacing: 8) {
                        onboardingPillBadge(text: "会話本文は保存しない", icon: "checkmark.shield.fill", tint: .teal)
                        onboardingPillBadge(text: "いつでも停止可能", icon: "pause.circle.fill", tint: .secondary)
                    }
                    Text("非公式ツールとして、公式値・目安・未取得を正直に区別します")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

        case .step1ChooseAI:
            VStack(alignment: .leading, spacing: 10) {
                stepBadge(number: 1, title: "最初に集計するサービスを選ぶ")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Codexのローカルログ", isOn: $monitor.showOpenAISection)
                        .accessibilityIdentifier("step-toggle-openai")
                    Toggle("Geminiのローカルログ", isOn: $monitor.showGeminiSection)
                        .accessibilityIdentifier("step-toggle-gemini")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                Text("他のサービスは開始後に「設定 → サービス連携」から選べます")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .step2CheckMenuBar:
            VStack(alignment: .leading, spacing: 10) {
                stepBadge(number: 2, title: "メニューバーをちらっと見る")
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.needle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Gem 残約34%")
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 4)
                    onboardingPillBadge(text: "最小残量を自動表示", icon: "sparkles", tint: .accentColor)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .offset(y: ambientOffset * 0.5)
                Text("作業画面を切り替えずに、いま一番減っている枠がわかります")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .step3SwitchMode:
            VStack(alignment: .leading, spacing: 10) {
                stepBadge(number: 3, title: "要点と全期間を切り替える")
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("要点")
                            .font(.caption.weight(.bold))
                        Text("最小残量＋月間のみ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        OnboardingQuotaBar(ratio: 0.34)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("全期間")
                            .font(.caption.weight(.bold))
                        Text("5h / 1d / 7d / 30d")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        OnboardingQuotaBar(ratio: 0.34)
                        OnboardingQuotaBar(ratio: 0.72)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .trialInteraction:
            VStack(spacing: 8) {
                ForEach(OnboardingDisplayTrialChoice.allCases) { choice in
                    let isSelected = controller.selectedTrialChoice == choice
                    Button {
                        controller.selectTrialChoice(choice, applyTo: monitor)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: choice.iconName)
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.optionTitle)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(choice.optionSubtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "hand.tap.fill")
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trial-choice-\(choice.rawValue)")
                    .accessibilityHint("押すと表示モードをセットして結果のページへ自動で進みます")
                }
            }

        case .trialResult:
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    onboardingIconBadge(
                        systemName: "checkmark.circle.fill",
                        tint: .green,
                        size: 44,
                        iconSize: 22
                    )
                    onboardingLiquidBall(motion: motion)
                        .frame(width: 48, height: 54)
                }
                onboardingPillBadge(
                    text: monitor.isDetailedView ? "初期表示：全期間モード" : "初期表示：要点モード",
                    icon: "slider.horizontal.3",
                    tint: .accentColor
                )
            }

        case .expectation:
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(["openai", "gemini", "claude", "cursor"], id: \.self) { serviceID in
                        ServiceIcon(
                            serviceID: serviceID,
                            fallbackSystemName: providerIconName(for: serviceID),
                            size: 28,
                            tint: providerAccentColor(for: serviceID)
                        )
                    }
                    onboardingLiquidBall(motion: motion)
                        .frame(width: 46, height: 52)
                }
                .offset(y: ambientOffset * 0.6)

                Text("どのAIが先に上限へ近づいても、リボがひとことで案内します")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .connection:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    onboardingLiquidBall(motion: motion)
                        .frame(width: 44, height: 50)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("最初に集計するサービス")
                            .font(.caption.weight(.semibold))
                        Toggle("Codexのローカルログ", isOn: $monitor.showOpenAISection)
                            .controlSize(.small)
                        Toggle("Geminiのローカルログ", isOn: $monitor.showGeminiSection)
                            .controlSize(.small)
                    }
                }
                Text("数値がないログでは文字数を端末内で一時的に使い、本文は保存・送信しません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 3. Heading & Supplement Section (Reading Order: Heading -> Supplement)

    private func textSection(for page: OnboardingPageSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.chapterLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("現在地、\(page.chapterLabel)")

            Text(page.heading)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if !page.supplement.isEmpty {
                Text(page.supplement)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 4. Praise Feedback Pill

    @ViewBuilder
    private var praiseBannerView: some View {
        if let praise = controller.latestPraise {
            HStack(spacing: 6) {
                Image(systemName: controller.latestReactionLevel == .large ? "sparkles" : "hand.thumbsup.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(praise)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .accessibilityIdentifier("onboarding-praise-banner")
        }
    }

    // MARK: - 5. Bottom Action Area

    @ViewBuilder
    private func bottomActionArea(for page: OnboardingPageSpec) -> some View {
        if page.pageID == .connection {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    controller.completeOnboarding(monitor: monitor)
                } label: {
                    Text("選んだサービスで使い始める")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("begin-collection")

                Text("すべてオフのまま開始し、あとで設定することもできます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if page.showsNextButton {
            HStack {
                Button {
                    if reduceMotion {
                        controller.goNext()
                    } else {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            controller.goNext()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("次へ")
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-next")
            }
        } else {
            // 選択・試し操作のページには「次へ」ボタンを置かない（選択肢を押すと反応の後に自動で進む）
            Text("上の選択肢を1つ押すと、自動で次のページへ進みます")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("onboarding-auto-advance-hint")
        }
    }

    // MARK: - Subviews

    private func onboardingLiquidBall(motion: CharacterMotionFrame) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.teal.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            Color.cyan.opacity(colorScheme == .dark ? 0.10 : 0.06)
                        ],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 36
                    )
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.teal.opacity(colorScheme == .dark ? 0.45 : 0.32),
                            lineWidth: 1.0
                        )
                )
                .frame(width: 44, height: 44)
                .offset(y: motion.offsetY)

            LiquidBallArtwork(
                contrast: contrast,
                colorScheme: colorScheme,
                reduceTransparency: reduceTransparency,
                motion: motion
            )
        }
    }

    private func onboardingIconBadge(
        systemName: String,
        tint: Color,
        size: CGFloat,
        iconSize: CGFloat
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.20 : 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                )
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }

    private func onboardingPillBadge(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(tint.opacity(0.28), lineWidth: 0.75)
                )
        )
    }

    private func miniServiceRow(
        id: String,
        name: String,
        icon: String,
        isEnabled: Bool,
        ratio: Double,
        percentText: String
    ) -> some View {
        HStack(spacing: 6) {
            ServiceIcon(serviceID: id, fallbackSystemName: icon, size: 16)
            Text(name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isEnabled {
                OnboardingQuotaBar(ratio: ratio)
                    .frame(width: 64)
                Text(percentText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .frame(width: 38, alignment: .trailing)
            } else {
                Text("オフ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepBadge(number: Int, title: String) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Onboarding Quota Bar (Renders deterministically in both windows & ImageRenderer)

private struct OnboardingQuotaBar: View {
    let ratio: Double
    @Environment(\.colorScheme) private var colorScheme

    private var clamped: Double { min(max(ratio, 0.0), 1.0) }

    private var fillColor: Color {
        if clamped < 0.15 { return .red }
        if clamped < 0.35 { return .orange }
        return Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.62)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(fillColor)
                    .frame(width: width)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Window Dots View (Max 5 visible dots, display-only, sliding window)

struct OnboardingWindowDotsView: View {
    let model: OnboardingWindowDotsModel
    var reduceMotion: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.dots) { dot in
                Capsule(style: .continuous)
                    .fill(dotColor(for: dot))
                    .frame(width: dotWidth(for: dot.scale), height: dotHeight(for: dot.scale))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.82), value: model.currentPage)
        .allowsHitTesting(false)
    }

    private func dotWidth(for scale: OnboardingWindowDotsModel.DotScale) -> CGFloat {
        switch scale {
        case .current: return 18
        case .adjacent: return 7
        case .outer: return 5.5
        case .edgeMore: return 4
        }
    }

    private func dotHeight(for scale: OnboardingWindowDotsModel.DotScale) -> CGFloat {
        switch scale {
        case .current: return 6
        case .adjacent: return 6
        case .outer: return 5.5
        case .edgeMore: return 4
        }
    }

    private func dotColor(for dot: OnboardingWindowDotsModel.DotItem) -> Color {
        if dot.isCompletedFinal || dot.scale == .current {
            return .accentColor
        }
        switch dot.scale {
        case .current:
            return .accentColor
        case .adjacent:
            return Color.primary.opacity(0.38)
        case .outer:
            return Color.primary.opacity(0.24)
        case .edgeMore:
            return Color.primary.opacity(0.16)
        }
    }
}
