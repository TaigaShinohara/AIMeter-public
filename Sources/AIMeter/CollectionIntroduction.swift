import AppKit
import SwiftUI
import CoreFoundation

enum CollectionIntroduction {
    static let acknowledgmentPreference = "hasAcknowledgedCollectionV1"

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

    private static func isTrueBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}

/// What a new user says they worry about most, chosen on the second onboarding
/// page. Stored on-device only (`onboardingConcernV1`); never sent anywhere.
enum OnboardingConcern: String, CaseIterable {
    case hittingLimits
    case checkingEveryService
    case unsureAboutEstimates
    case notSureYet

    var optionTitle: String {
        switch self {
        case .hittingLimits: return "気づいたら上限に当たっていた"
        case .checkingEveryService: return "残量を確かめるのに、いちいち開いている"
        case .unsureAboutEstimates: return "推定の数字を、どこまで信じていいか不安"
        case .notSureYet: return "まだわからない"
        }
    }

    var optionSymbol: String {
        switch self {
        case .hittingLimits: return "exclamationmark.triangle"
        case .checkingEveryService: return "arrow.triangle.2.circlepath"
        case .unsureAboutEstimates: return "questionmark.circle"
        case .notSureYet: return "hand.raised"
        }
    }

    /// The declaration on the match page. The escape choice never asserts.
    var matchHeadline: String {
        switch self {
        case .hittingLimits: return "「気づいたら上限」なあなたに、ぴったりです"
        case .checkingEveryService: return "「いちいち開いて確かめる」あなたに、ぴったりです"
        case .unsureAboutEstimates: return "「推定を信じていいか不安」なあなたに、ぴったりです"
        case .notSureYet: return "まだわからなくて、大丈夫です"
        }
    }

    /// The single strength that answers this concern directly.
    var matchReason: String {
        switch self {
        case .hittingLimits: return "残りわずかになると、リボが先に知らせます。"
        case .checkingEveryService: return "残量はメニューバーに集まるので、開き直しは要りません。"
        case .unsureAboutEstimates: return "公式の値・目安・未取得を、はっきり分けて表示します。"
        case .notSureYet: return "まずは1つのサービスから、様子を見ながら始められます。"
        }
    }
}

private enum OnboardingValue: CaseIterable {
    case glance
    case honestLabels
    case riboNotice

    var headline: String {
        switch self {
        case .glance: return "全サービスを、メニューバーで一目で"
        case .honestLabels: return "公式・目安・未取得を、分けて見せる"
        case .riboNotice: return "残りわずかは、リボが先に知らせる"
        }
    }

    var detail: String {
        switch self {
        case .glance: return "本体を開かなくても、残りの割合が分かります。"
        case .honestLabels: return "推定の数字を、公式の残量のように見せません。"
        case .riboNotice: return "一番少ない残量を、上部のひとことで案内します。"
        }
    }

    var symbol: String {
        switch self {
        case .glance: return "menubar.rectangle"
        case .honestLabels: return "tag"
        case .riboNotice: return "bell.badge"
        }
    }
}

private enum OnboardingFirstServices: CaseIterable {
    case codexOnly
    case geminiOnly
    case both
    case later

    var optionTitle: String {
        switch self {
        case .codexOnly: return "Codexだけ"
        case .geminiOnly: return "Geminiだけ"
        case .both: return "両方"
        case .later: return "あとで決める"
        }
    }
}

/// Paged first-run onboarding. Design and page map: docs/ONBOARDING_PAGE_MAP.md.
/// The privacy contract is unchanged: nothing is read until the final page's
/// start button calls `monitor.beginCollection()`.
struct CollectionIntroductionView: View {
    @ObservedObject var monitor: UsageMonitor

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("onboardingConcernV1") private var storedConcernRaw = ""

    @State private var page = 0
    @State private var concern: OnboardingConcern?
    @State private var tappedConcern: OnboardingConcern?
    @State private var tappedServices: OnboardingFirstServices?
    @State private var isAdvancing = false
    @State private var praise = ""
    @State private var praiseStageCounts: [String: Int] = [:]

    private let pageCount = 12
    private let lastPage = 11

    var body: some View {
        VStack(spacing: 12) {
            header
            pageContent
                .id(page)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: .infinity)
                .frame(height: 396)
            praiseLine
            footer
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .onAppear {
            if concern == nil, let saved = OnboardingConcern(rawValue: storedConcernRaw) {
                concern = saved
            }
        }
    }

    // MARK: - Chrome (dots, skip, praise, back/next stay in fixed places)

    private var header: some View {
        ZStack {
            OnboardingWindowDots(current: page, total: pageCount)
            HStack {
                Spacer()
                if page < lastPage {
                    Button("スキップ") { goTo(lastPage) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("最後のページへ進みます")
                }
            }
        }
        .frame(height: 20)
    }

    private var praiseLine: some View {
        Text(praise)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .opacity(praise.isEmpty ? 0 : 1)
            .accessibilityHidden(praise.isEmpty)
    }

    private var footer: some View {
        HStack {
            if page > 0 {
                Button("戻る") { goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if page < lastPage, page != 1, page != 9 {
                Button("次へ") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(height: 28)
    }

    // MARK: - Navigation and reactions

    private func goTo(_ target: Int) {
        praise = ""
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.28)) {
            page = target
        }
    }

    private func goBack() {
        guard page > 0 else { return }
        goTo(page - 1)
    }

    private func advance() {
        guard page < lastPage else { return }
        haptic(.levelChange)
        goTo(page + 1)
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Praise lines rotate per stage so the same sentence never repeats back
    /// to back. One sentence at a time, about the specific action taken.
    private func nextPraise(stage: String, variants: [String]) -> String {
        let count = praiseStageCounts[stage, default: 0]
        praiseStageCounts[stage] = count + 1
        return variants[count % variants.count]
    }

    private func showPraise(_ text: String) {
        withAnimation(.easeInOut(duration: 0.2)) { praise = text }
    }

    private func chooseConcern(_ choice: OnboardingConcern) {
        guard !isAdvancing else { return }
        isAdvancing = true
        concern = choice
        storedConcernRaw = choice.rawValue
        tappedConcern = choice
        haptic(.alignment)
        showPraise(nextPraise(stage: "concern", variants: [
            "教えてくれてありがとう。その困りごとに効く順で案内します。",
            "その気持ち、よく分かります。ぴったりの見せ方をします。",
            "いい選択です。その不安に答える作りになっています。"
        ]))
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.15 : 0.38)) {
            tappedConcern = nil
            isAdvancing = false
            goTo(2)
        }
    }

    private func chooseFirstServices(_ choice: OnboardingFirstServices) {
        guard !isAdvancing else { return }
        isAdvancing = true
        tappedServices = choice
        monitor.showOpenAISection = (choice == .codexOnly || choice == .both)
        monitor.showGeminiSection = (choice == .geminiOnly || choice == .both)
        haptic(.alignment)
        showPraise(nextPraise(stage: "services", variants: [
            "決めてくれてありがとう。最後のページに反映しました。",
            "その組み合わせで用意しました。最後に確認できます。",
            "受け取りました。あとから設定でいつでも変えられます。"
        ]))
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.15 : 0.38)) {
            tappedServices = nil
            isAdvancing = false
            goTo(10)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0: hookPage
        case 1: concernPage
        case 2: matchPage
        case 3: identityPage
        case 4: valuePage(at: 0)
        case 5: valuePage(at: 1)
        case 6: stepPage(number: 1)
        case 7: stepPage(number: 2)
        case 8: stepPage(number: 3)
        case 9: firstServicesPage
        case 10: expectationPage
        default: connectionPage
        }
    }

    private func pageShell<Visual: View>(headline: String, detail: String? = nil,
                                         @ViewBuilder visual: () -> Visual) -> some View {
        VStack(spacing: 16) {
            visual()
                .frame(height: 196)
            Text(headline)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var hookPage: some View {
        pageShell(headline: "AIの残量、もう探し回らない",
                  detail: "使うたびに各サービスを開く、その手間をなくします") {
            ZStack {
                HStack(spacing: 8) {
                    ForEach(["Codex", "Gemini", "Claude"], id: \.self) { name in
                        Text(name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                }
                .offset(y: -64)
                .modifier(GentleFloat(enabled: !reduceMotion, distance: 3, duration: 3.4))
                OnboardingRibo(contrast: contrast, colorScheme: colorScheme,
                               reduceTransparency: reduceTransparency,
                               motionEnabled: !reduceMotion)
                    .scaleEffect(1.7)
            }
        }
    }

    private var concernPage: some View {
        VStack(spacing: 16) {
            Text("いちばん気になるのは、どれ？")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 10) {
                ForEach(OnboardingConcern.allCases, id: \.self) { option in
                    choiceButton(title: option.optionTitle, symbol: option.optionSymbol,
                                 isTapped: tappedConcern == option) {
                        chooseConcern(option)
                    }
                    .accessibilityHint("選ぶと、次のページへ進みます")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var matchPage: some View {
        let current = concern ?? .notSureYet
        return pageShell(headline: current.matchHeadline, detail: current.matchReason) {
            HStack(spacing: 18) {
                Image(systemName: current.optionSymbol)
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "equal")
                    .foregroundStyle(.secondary)
                OnboardingRibo(contrast: contrast, colorScheme: colorScheme,
                               reduceTransparency: reduceTransparency,
                               motionEnabled: !reduceMotion)
                    .scaleEffect(1.4)
            }
        }
    }

    private var identityPage: some View {
        pageShell(headline: "AIMeterは、残量の見守り役です",
                  detail: "メニューバーとウィジェットに、AIツールの残量を表示します") {
            OnboardingBarsMock(rows: [("Codex", 0.72), ("Gemini", 0.45)],
                               animated: !reduceMotion)
        }
    }

    private func valuePage(at index: Int) -> some View {
        let value = orderedValues[min(index, orderedValues.count - 1)]
        return pageShell(headline: value.headline, detail: value.detail) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 150, height: 150)
                    .modifier(GentleFloat(enabled: !reduceMotion, distance: 2, duration: 3.8))
                Image(systemName: value.symbol)
                    .font(.system(size: 52))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// The strength used on the match page is not repeated as a value page;
    /// the remaining two are ordered for the chosen concern.
    private var orderedValues: [OnboardingValue] {
        switch concern ?? .notSureYet {
        case .hittingLimits: return [.glance, .honestLabels]
        case .checkingEveryService: return [.honestLabels, .riboNotice]
        case .unsureAboutEstimates: return [.glance, .riboNotice]
        case .notSureYet: return [.glance, .honestLabels]
        }
    }

    private func stepPage(number: Int) -> some View {
        let headlines = ["1. 集めるサービスを選ぶ", "2. 「使い始める」を押す", "3. メニューバーで残量を見る"]
        let details = ["最初は Codex と Gemini だけでも大丈夫です。",
                       "押すまでは、ログをいっさい読みません。",
                       "作業の合間に、チラ見で確認できます。"]
        let symbols = ["checklist", "play.circle.fill", "menubar.rectangle"]
        return pageShell(headline: headlines[number - 1], detail: details[number - 1]) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 132, height: 132)
                VStack(spacing: 6) {
                    Text("\(number)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: symbols[number - 1])
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var firstServicesPage: some View {
        VStack(spacing: 16) {
            Text("どのサービスから始めますか？")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 10) {
                ForEach(OnboardingFirstServices.allCases, id: \.self) { option in
                    choiceButton(title: option.optionTitle, symbol: nil,
                                 isTapped: tappedServices == option) {
                        chooseFirstServices(option)
                    }
                    .accessibilityHint("選ぶと、次のページへ進みます")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var expectationPage: some View {
        pageShell(headline: "チラ見で済む毎日が、始まります",
                  detail: "Widgetにも残量が出るので、デスクトップからも確認できます") {
            OnboardingBarsMock(rows: [("Codex", 0.72), ("Gemini", 0.45), ("Claude", 0.81)],
                               animated: !reduceMotion)
                .modifier(GentleFloat(enabled: !reduceMotion, distance: 2, duration: 4.2))
        }
    }

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("最初のサービスで、使い始めよう", systemImage: "gauge.with.needle")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Codexのローカルログ", isOn: $monitor.showOpenAISection)
                    Toggle("Geminiのローカルログ", isOn: $monitor.showGeminiSection)
                    Text("他のサービスやログの場所は、開始後に「設定 → サービス連携」から選べます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    introductionDetail("読み取る内容", text: "利用量の情報を読み、数値がないログでは会話本文の文字数を端末内で一時的に使うことがあります。")
                    #if AIMETER_APP_STORE
                    introductionDetail("保存と通信", text: "集計はこのMacに保存します。任意のAPI連携を設定すると、キーなどをその連携先の認証に使い、利用量を照会します。アプリの更新はMac App Storeから行います。")
                    introductionDetail("ストア版の設定", text: "GitHub版とは別のアプリです。設定やAPIキーは引き継がれないため、このアプリで設定してください。")
                    #else
                    introductionDetail("保存と通信", text: "集計はこのMacに保存し、会話本文は集計へ保存せず外部へ送りません。任意のAPI連携を設定すると、キーなどをその連携先の認証に使い、利用量を照会します。更新の確認・取得ではGitHubへ接続します。")
                    #endif
                    introductionDetail("表示の意味", text: "各AIサービスとは独立した非公式ツールです。設定上限からの目安や推定使用量は、公式の残量・請求額とは異なることがあります。")
                    introductionDetail("いつでも停止", text: "「設定 → サービス連携」でサービスを無効にすると、そのサービスの収集と任意API取得を停止します。アプリの終了でも収集を停止できます。")
                }

                Button("選んだサービスで使い始める") {
                    haptic(.generic)
                    monitor.beginCollection()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("begin-collection")

                Text("すべてオフのまま開始し、あとで設定することもできます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func introductionDetail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choiceButton(title: String, symbol: String?, isTapped: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                }
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(isTapped ? 0.9 : 0.25),
                                  lineWidth: isTapped ? 2 : 1)
            )
            .scaleEffect(reduceMotion ? 1 : (isTapped ? 1.04 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isTapped)
        }
        .buttonStyle(.plain)
        .disabled(isAdvancing)
    }
}

/// Window dots: at most five dots are visible, the window slides with the
/// current page, and edge dots shrink when more pages exist beyond them.
/// Totals are never shown as numbers. See docs/ONBOARDING_PAGE_MAP.md.
struct OnboardingWindowDots: View {
    let current: Int
    let total: Int

    var windowSize: Int { min(5, total) }
    var windowStart: Int { max(0, min(current - 2, total - windowSize)) }
    var windowEnd: Int { windowStart + windowSize - 1 }

    private var start: Int { windowStart }
    private var end: Int { windowEnd }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(start...end, id: \.self) { index in
                if index == current {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 22, height: 8)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: dotSize(for: index), height: dotSize(for: index))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityHidden(true)
    }

    private func dotSize(for index: Int) -> CGFloat {
        if index == start, start > 0 { return 4 }
        if index == end, end < total - 1 { return 4 }
        if abs(index - current) == 1 { return 7 }
        return 5.5
    }
}

/// A very small, slow float for ambient elements: a few points over several
/// seconds, always disabled when reduced motion is requested.
private struct GentleFloat: ViewModifier {
    let enabled: Bool
    let distance: CGFloat
    let duration: Double
    @State private var floating = false

    func body(content: Content) -> some View {
        content
            .offset(y: enabled && floating ? -distance : 0)
            .onAppear {
                guard enabled else { return }
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    floating = true
                }
            }
    }
}

/// リボ with the app's own float/blink motion, reused from the main UI so the
/// onboarding guide is the same character the user meets afterwards.
private struct OnboardingRibo: View {
    let contrast: ColorSchemeContrast
    let colorScheme: ColorScheme
    let reduceTransparency: Bool
    let motionEnabled: Bool
    @State private var isWindowVisible = false
    @State private var startedAt = Date()

    var body: some View {
        ZStack {
            if motionEnabled && isWindowVisible {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    LiquidBallArtwork(contrast: contrast, colorScheme: colorScheme,
                                      reduceTransparency: reduceTransparency,
                                      isInteractive: true,
                                      motion: .at(context.date.timeIntervalSince(startedAt)))
                }
            } else {
                LiquidBallArtwork(contrast: contrast, colorScheme: colorScheme,
                                  reduceTransparency: reduceTransparency, motion: .rest)
            }
        }
        .frame(width: 56, height: 56)
        .background {
            if motionEnabled {
                CharacterVisibilityReader { visible in
                    if visible && !isWindowVisible { startedAt = Date() }
                    isWindowVisible = visible
                }
            }
        }
        .onChange(of: motionEnabled) { _, enabled in
            if enabled { startedAt = Date() }
        }
        .onDisappear { isWindowVisible = false }
        .accessibilityHidden(true)
    }
}

/// Synthetic menu-bar / widget style mock with bars that draw themselves in.
/// Uses made-up numbers only; it never reads real usage.
private struct OnboardingBarsMock: View {
    let rows: [(String, Double)]
    let animated: Bool
    @State private var progress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { name, fraction in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .frame(width: 52, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * fraction * progress)
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            if animated {
                withAnimation(.easeOut(duration: 0.9)) { progress = 1 }
            } else {
                progress = 1
            }
        }
        .accessibilityHidden(true)
    }
}
