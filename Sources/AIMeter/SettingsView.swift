import SwiftUI
import AppKit
import AIMeterCore

// MARK: - Settings Tab Enum
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "general"
    case services = "services"
    case limits = "limits"
    case help = "help"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .services: return "サービス連携"
        case .limits: return "制限と予算"
        case .help: return "ヘルプ & 情報"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .services: return "cpu"
        case .limits: return "gauge.with.needle"
        case .help: return "questionmark.circle"
        }
    }
}

// MARK: - Native macOS Tahoe Settings View
struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

    @State private var selectedTab: SettingsTab? = .general
    @State private var selectedServiceId: String = "openai"

    init(monitor: UsageMonitor, initialTab: SettingsTab = .general, initialServiceId: String = "openai") {
        self.monitor = monitor
        _selectedTab = State(initialValue: initialTab)
        _selectedServiceId = State(initialValue: initialServiceId)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 210)
        } detail: {
            switch selectedTab ?? .general {
            case .general:
                GeneralSettingsView(monitor: monitor, launchAtLogin: launchAtLogin)
            case .services:
                ServicesSettingsView(monitor: monitor, selectedServiceId: $selectedServiceId)
            case .limits:
                LimitsSettingsView(monitor: monitor, selectedServiceId: $selectedServiceId)
            case .help:
                HelpSettingsView()
            }
        }
        .font(.system(size: 13))
        .frame(minWidth: 860, minHeight: 560)
        .background {
            LiquidGlassBackground(cornerRadius: 18)
                .ignoresSafeArea()
        }
        .background(SettingsWindowAccessor())
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}

// MARK: - General Settings Tab
private struct GeneralSettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginManager

    var body: some View {
        SettingsForm {
            SettingsSection("起動とウィンドウ") {
                SettingsToggle("Mac ログイン時に自動起動", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .help("Macの起動・ログイン時にAIMeterを自動的に起動します")

                SettingsToggle("アプリ起動時にデスクトップウィジェットを表示", isOn: $monitor.autoShowWidgetOnLaunch)
                    .help("アプリ起動時にデスクトップウィジェットを自動で表示します")

                SettingsToggle("ウィジェットを常に最前面に固定", isOn: $monitor.isWidgetPinned)
                    .help("デスクトップウィジェットを他のウィンドウの上に浮遊表示します")
            }

            SettingsSection("利用状況の表示") {
                SettingsToggle("トークン量・利用回数を表示", isOn: $monitor.showUsageAmounts)
                Text("通常は残り％のみ表示します。オンにすると、カードとmacOSウィジェットに利用量も表示します。公式残量が未取得のサービスは推定使用量を表示します。『約』の残り％は設定上限からの目安です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("メニューバー") {
                SettingsLabeledContent("表示モード") {
                    Picker("表示モード", selection: $monitor.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .help("メニューバーアイコンの右側に表示する文字列のルール")

                SettingsLabeledContent("表示優先期間") {
                    Picker("表示優先期間", selection: $monitor.menuBarPeriodMode) {
                        Text("最も逼迫している枠（自動）").tag("min")
                        Divider()
                        ForEach(LimitPeriod.allCases) { period in
                            Text(period.label).tag(period.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .help("パーセント計算の基準となる制限期間")
            }

            SettingsSection("データ更新") {
                SettingsLabeledContent("前回の更新") {
                    Group {
                        if let date = monitor.lastUpdated {
                            Text(date, style: .time)
                        } else {
                            Text("未取得")
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button {
                        Task {
                            await monitor.refresh()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if monitor.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("今すぐ更新")
                        }
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .disabled(monitor.isRefreshing)
                }
            }
        }
        .navigationTitle("一般")
    }
}

// MARK: - Services Settings Tab
private struct ServicesSettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @Binding var selectedServiceId: String

    @StateObject private var pathValidator = PathValidation()
    @State private var pathInputs: [String: String] = [:]
    @State private var pathValidationResults: [String: LocalUsageCollector.ProviderPathScanResult] = [:]
    @State private var revealAdminKey: Bool = false

    private struct PresetOption: Identifiable {
        let id: String
        let label: String
        let config: CustomSubscriptionConfig
    }

    private var presetOptions: [PresetOption] {
        [
            PresetOption(id: "claude", label: "Anthropic Claude", config: .claudePreset()),
            PresetOption(id: "cursor", label: "Cursor", config: .cursorPreset()),
            PresetOption(id: "windsurf", label: "Windsurf", config: .windsurfPreset()),
            PresetOption(id: "copilot", label: "GitHub Copilot", config: .copilotPreset()),
            PresetOption(id: "grokbot", label: "Grok / GrokBot", config: .grokbotPreset()),
            PresetOption(id: "devin", label: "Devin", config: .devinPreset()),
            PresetOption(id: "perplexity", label: "Perplexity Pro", config: .perplexityPreset()),
            PresetOption(id: "deepseek", label: "DeepSeek", config: .deepseekPreset()),
            PresetOption(id: "poe", label: "Poe", config: .poePreset()),
            PresetOption(id: "trae", label: "Trae AI", config: .traePreset())
        ]
    }

    private func isPresetAdded(_ id: String) -> Bool {
        monitor.customSubscriptions.contains { $0.id == id || $0.id.hasPrefix("\(id)_") }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Service List
            VStack(spacing: 0) {
                List(selection: $selectedServiceId) {
                    Section("組み込みサービス") {
                        serviceRow(
                            id: "openai",
                            name: "OpenAI / Codex",
                            icon: "brain.head.profile",
                            isEnabled: monitor.showOpenAISection,
                            hasCustomPath: monitor.customProviderPaths["openai"] != nil,
                            isDetected: monitor.openaiUsedTokens > 0 || monitor.openaiServerPct != nil
                        )
                        .tag("openai")

                        serviceRow(
                            id: "gemini",
                            name: "Google Gemini",
                            icon: "sparkle",
                            isEnabled: monitor.showGeminiSection,
                            hasCustomPath: monitor.customProviderPaths["gemini"] != nil,
                            isDetected: monitor.geminiUsedTokens > 0
                        )
                        .tag("gemini")
                    }

                    if !monitor.customSubscriptions.isEmpty {
                        Section("追加されたサービス") {
                            ForEach(monitor.customSubscriptions) { sub in
                                let baseKey = sub.id.split(separator: "_").first.map(String.init) ?? sub.id
                                let live = monitor.customProviderLiveUsage[sub.id] ?? monitor.customProviderLiveUsage[baseKey]
                                let hasCustomPath = monitor.customProviderPaths[sub.id] != nil
                                let monthly = live?.usedByPeriod?.monthly ?? sub.manualUsedMonthly
                                let isDetected = monitor.detectedProviderIds.contains(baseKey) || monthly > 0

                                serviceRow(
                                    id: sub.id,
                                    name: sub.name,
                                    icon: sub.iconName,
                                    isEnabled: sub.isEnabled,
                                    hasCustomPath: hasCustomPath,
                                    isDetected: isDetected
                                )
                                .tag(sub.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                Divider()

                // Bottom Action Bar
                HStack(spacing: 8) {
                    Menu {
                        ForEach(presetOptions) { item in
                            let added = isPresetAdded(item.id)
                            Button(added ? "✓ \(item.label) (追加済)" : "+ \(item.label)") {
                                monitor.addSubscription(item.config)
                                selectedServiceId = item.config.id
                            }
                            .disabled(added)
                        }
                        Divider()
                        Button("＋ 新規カスタムサービス...") {
                            let newCustom = CustomSubscriptionConfig.blankCustom()
                            monitor.addSubscription(newCustom)
                            selectedServiceId = newCustom.id
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("サービスを追加")
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)

                    Button {
                        if selectedServiceId != "openai" && selectedServiceId != "gemini" {
                            let idToRemove = selectedServiceId
                            selectedServiceId = "openai"
                            monitor.removeSubscription(id: idToRemove)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .accessibilityLabel("選択したサービスを削除")
                    .disabled(selectedServiceId == "openai" || selectedServiceId == "gemini")
                    .frame(width: 24)

                    Spacer()

                    Button {
                        monitor.autoAddDetectedSubscriptions()
                        Task { await monitor.refresh() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("自動検出")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .help("Mac内のAIツールログを再スキャンして未登録サービスを追加")
                }
                .padding(8)
            }
            .frame(minWidth: 190, idealWidth: 200, maxWidth: 240)

            Divider()

            // Service Details Detail Form
            detailForm
                .frame(minWidth: 408, maxWidth: .infinity)
        }
        .navigationTitle("サービス連携")
        .onDisappear { pathValidator.cancel() }
        .onChange(of: selectedServiceId) { _, _ in pathValidator.cancel() }
    }

    @ViewBuilder
    private func serviceRow(id: String, name: String, icon: String, isEnabled: Bool, hasCustomPath: Bool, isDetected: Bool) -> some View {
        HStack(spacing: 8) {
            ServiceIcon(serviceID: id, fallbackSystemName: icon,
                        tint: isEnabled ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                HStack(spacing: 4) {
                    if hasCustomPath {
                        Text("手動パス")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    } else if isDetected {
                        Text("実ログ検出")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Text("未検出")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if !isEnabled {
                Text("オフ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var detailForm: some View {
        if selectedServiceId == "openai" {
            openAIDetailForm
        } else if selectedServiceId == "gemini" {
            geminiDetailForm
        } else if let subIndex = monitor.customSubscriptions.firstIndex(where: { $0.id == selectedServiceId }) {
            customSubDetailForm(subIndex: subIndex)
        } else {
            ContentUnavailableView("サービスが選択されていません", systemImage: "cpu")
        }
    }

    // OpenAI Details
    @ViewBuilder
    private var openAIDetailForm: some View {
        SettingsForm {
            SettingsSection("表示設定") {
                SettingsToggle("このサービスを有効にする", isOn: $monitor.showOpenAISection)
                SettingsToggle("メニューバーに表示する", isOn: $monitor.showOpenAIInMenuBar)
                    .disabled(!monitor.showOpenAISection)
            }

            SettingsSection("ローカルログパス") {
                logPathEditor(for: "openai")
            }

            SettingsSection("クラウド組織連携 (任意)") {
                Text("OpenAI Admin Key")
                    .font(.subheadline)
                HStack {
                    if revealAdminKey {
                        TextField("OpenAI Admin Key", text: $monitor.openaiAdminKey)
                    } else {
                        SecureField("OpenAI Admin Key", text: $monitor.openaiAdminKey)
                    }
                    Button {
                        revealAdminKey.toggle()
                    } label: {
                        Image(systemName: revealAdminKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .accessibilityLabel(revealAdminKey ? "キーを隠す" : "キーを表示")
                }
                Text("クラウド組織全体のAPI利用量を同期する場合のみ設定してください。ローカルセッションの集計には不要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Gemini Details
    @ViewBuilder
    private var geminiDetailForm: some View {
        SettingsForm {
            SettingsSection("表示設定") {
                SettingsToggle("このサービスを有効にする", isOn: $monitor.showGeminiSection)
                SettingsToggle("メニューバーに表示する", isOn: $monitor.showGeminiInMenuBar)
                    .disabled(!monitor.showGeminiSection)
            }

            SettingsSection("ローカルログパス") {
                logPathEditor(for: "gemini")
            }

            SettingsSection("GCPプロジェクト連携 (任意)") {
                SettingsLabeledContent("GCP Project ID") {
                    TextField("GCP Project ID", text: $monitor.gcpProjectId)
                        .labelsHidden()
                }
                Text("Cloud Monitoring から Gemini 利用量を同期する場合のみ入力してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Custom Sub Details
    @ViewBuilder
    private func customSubDetailForm(subIndex: Int) -> some View {
        let sub = $monitor.customSubscriptions[subIndex]
        let currentSub = sub.wrappedValue

        SettingsForm {
            SettingsSection("基本情報") {
                SettingsLabeledContent("サービス名") {
                    TextField("サービス名", text: sub.name)
                        .labelsHidden()
                        .frame(minWidth: 0)
                }
                SettingsLabeledContent("略称 (メニューバー用)") {
                    TextField("略称 (メニューバー用)", text: sub.shortName)
                        .labelsHidden()
                        .frame(minWidth: 0)
                }

                SettingsToggle("このサービスを有効にする", isOn: sub.isEnabled)
                SettingsToggle("メニューバーに表示する", isOn: sub.showInMenuBar)
                    .disabled(!currentSub.isEnabled)
            }

            SettingsSection("ローカルログパス") {
                logPathEditor(for: currentSub.id)
            }
        }
    }

    // Log Path Editor Subcomponent
    @ViewBuilder
    private func logPathEditor(for serviceId: String) -> some View {
        let hint = defaultLogPathHint(for: serviceId)
        let currentSaved = monitor.customProviderPaths[serviceId]
        let inputBinding = Binding<String>(
            get: { pathInputs[serviceId] ?? currentSaved ?? "" },
            set: { pathValidator.cancel(); pathInputs[serviceId] = $0 }
        )

        VStack(alignment: .leading, spacing: 8) {
            TextField(hint, text: inputBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 0)
                .accessibilityLabel("ローカルログパス")
            HStack {
                Spacer()
                Button("選択...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "選択"
                    panel.message = "\(serviceId) のログファイルまたはフォルダを選択してください"
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK, let url = panel.url {
                        pathInputs[serviceId] = url.path
                        applyCustomPath(for: serviceId, path: url.path)
                    }
                }
                .controlSize(.small)

                Button("適用") {
                    applyCustomPath(for: serviceId, path: inputBinding.wrappedValue)
                }
                .controlSize(.small)

                if currentSaved != nil {
                    Button("リセット") {
                        pathValidator.cancel()
                        monitor.setCustomPath(for: serviceId, path: "")
                        pathInputs[serviceId] = ""
                        pathValidationResults.removeValue(forKey: serviceId)
                        Task { await monitor.refresh() }
                    }
                    .controlSize(.small)
                }
            }
            .buttonStyle(GlassCapsuleButtonStyle())

            if pathValidator.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("ログを検証中…")
                    Button("中止") { pathValidator.cancel() }
                        .buttonStyle(GlassCapsuleButtonStyle())
                }
            }
            if let result = pathValidationResults[serviceId] {
                HStack(spacing: 4) {
                    Image(systemName: result.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(result.message)
                }
                .font(.caption)
                .foregroundStyle(result.isValid ? .green : .orange)
            }
        }
    }

    private func applyCustomPath(for serviceId: String, path: String) {
        pathValidator.cancel()
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            monitor.setCustomPath(for: serviceId, path: "")
            pathValidationResults.removeValue(forKey: serviceId)
            Task { await monitor.refresh() }
            return
        }
        pathValidationResults.removeValue(forKey: serviceId)
        pathValidator.start(provider: serviceId, path: trimmed) { res in
            pathValidationResults[serviceId] = res
            if res.isValid {
                monitor.setCustomPath(for: serviceId, path: trimmed)
                Task { await monitor.refresh() }
            }
        }
    }
}

// MARK: - Limits & Budgets Tab
private struct LimitsSettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @Binding var selectedServiceId: String

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedServiceId) {
                Section("サービス選択") {
                    Text("OpenAI / Codex").tag("openai").listRowBackground(Color.clear)
                    Text("Google Gemini").tag("gemini").listRowBackground(Color.clear)
                    ForEach(monitor.customSubscriptions) { sub in
                        Text(sub.name).tag(sub.id).listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 190, idealWidth: 200, maxWidth: 240)

            Divider()

            detailLimitsForm
                .frame(minWidth: 408, maxWidth: .infinity)
        }
        .navigationTitle("制限と予算")
    }

    @ViewBuilder
    private var detailLimitsForm: some View {
        if selectedServiceId == "openai" {
            openAILimitsForm
        } else if selectedServiceId == "gemini" {
            geminiLimitsForm
        } else if let subIndex = monitor.customSubscriptions.firstIndex(where: { $0.id == selectedServiceId }) {
            customSubLimitsForm(subIndex: subIndex)
        } else {
            ContentUnavailableView("サービスを選択してください", systemImage: "gauge.with.needle")
        }
    }

    // OpenAI Limits
    @ViewBuilder
    private var openAILimitsForm: some View {
        SettingsForm {
            SettingsSection("有効にする制限期間") {
                periodToggles(isOpenAI: true, csv: monitor.openaiEnabledPeriodsCSV)
            }

            SettingsSection("トークン上限値") {
                if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .twoHours) {
                    limitRow(label: "2時間上限", value: $monitor.openaiTokenLimit2h, unit: "tokens")
                }
                if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .fiveHours) {
                    limitRow(label: "5時間上限", value: $monitor.openaiTokenLimit5h, unit: "tokens")
                }
                if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .daily) {
                    limitRow(label: "1日上限", value: $monitor.openaiTokenLimitDaily, unit: "tokens")
                }
                if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .weekly) {
                    limitRow(label: "週次上限", value: $monitor.openaiTokenLimitWeekly, unit: "tokens")
                }
                if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .monthly) {
                    limitRow(label: "月次上限", value: $monitor.openaiTokenLimit, unit: "tokens")
                }
            }

            SettingsSection("予算目標") {
                SettingsLabeledContent("月間予算目標 ($)") {
                    TextField("USD", value: $monitor.openaiBudgetUSD, format: .number)
                        .accessibilityLabel("月間予算目標 ($)")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
        }
    }

    // Gemini Limits
    @ViewBuilder
    private var geminiLimitsForm: some View {
        SettingsForm {
            SettingsSection("公式残量") {
                Text("Geminiの公式残量は未取得です。ローカルログやGCPの使用量から公式の残り％は計算しません。推定使用量は一般設定から表示できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("有効にする集計期間") {
                periodToggles(isOpenAI: false, csv: monitor.geminiEnabledPeriodsCSV)
            }

            SettingsSection("予算目標") {
                SettingsLabeledContent("月間予算目標 ($)") {
                    TextField("USD", value: $monitor.geminiBudgetUSD, format: .number)
                        .accessibilityLabel("月間予算目標 ($)")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
        }
    }

    // Custom Sub Limits
    @ViewBuilder
    private func customSubLimitsForm(subIndex: Int) -> some View {
        let currentSub = monitor.customSubscriptions[subIndex]
        let unit = providerUnit(for: currentSub.id)

        SettingsForm {
            SettingsSection("有効にする制限期間") {
                HStack(spacing: 8) {
                    ForEach(LimitPeriod.allCases, id: \.self) { (period: LimitPeriod) in
                        let isOn = currentSub.isPeriodEnabled(period)
                        Toggle(period.label, isOn: Binding(
                            get: { isOn },
                            set: { monitor.customSubscriptions[subIndex].setPeriod(period, enabled: $0) }
                        ))
                    }
                }
                .toggleStyle(.checkbox)
            }

            SettingsSection("上限値 (\(unit))") {
                if currentSub.isPeriodEnabled(.twoHours) {
                    limitRow(label: "2時間上限", value: $monitor.customSubscriptions[subIndex].limit2h, unit: unit)
                }
                if currentSub.isPeriodEnabled(.fiveHours) {
                    limitRow(label: "5時間上限", value: $monitor.customSubscriptions[subIndex].limit5h, unit: unit)
                }
                if currentSub.isPeriodEnabled(.daily) {
                    limitRow(label: "1日上限", value: $monitor.customSubscriptions[subIndex].limitDaily, unit: unit)
                }
                if currentSub.isPeriodEnabled(.weekly) {
                    limitRow(label: "週次上限", value: $monitor.customSubscriptions[subIndex].limitWeekly, unit: unit)
                }
                if currentSub.isPeriodEnabled(.monthly) {
                    limitRow(label: "月次上限", value: $monitor.customSubscriptions[subIndex].limitMonthly, unit: unit)
                }
            }

            SettingsSection("予算目標") {
                SettingsLabeledContent("月間予算目標 ($)") {
                    TextField("USD", value: $monitor.customSubscriptions[subIndex].budgetUSD, format: .number)
                        .accessibilityLabel("月間予算目標 ($)")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
        }
    }

    @ViewBuilder
    private func periodToggles(isOpenAI: Bool, csv: String) -> some View {
        HStack(spacing: 8) {
            ForEach(LimitPeriod.allCases, id: \.self) { (period: LimitPeriod) in
                let isOn = monitor.isBuiltInPeriodEnabled(csv: csv, period: period)
                Toggle(period.label, isOn: Binding(
                    get: { isOn },
                    set: { monitor.setBuiltInPeriod(isOpenAI: isOpenAI, period: period, enabled: $0) }
                ))
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private func limitRow(label: String, value: Binding<Int>, unit: String) -> some View {
        SettingsLabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .accessibilityLabel(label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Help & About Tab
private struct HelpSettingsView: View {
    @State private var searchText: String = ""

    var body: some View {
        SettingsForm {
            VStack(alignment: .leading, spacing: 14) {
                // About Header
                HStack(spacing: 14) {
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("AIMeter")
                            .font(.title2.weight(.bold))
                        Text("ローカル完結型 AI 利用量・残量メーター")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(FrostedGlassCardBackground(cornerRadius: 12))

                // Privacy Box
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title3)
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("完全ローカル・プライバシー設計")
                            .font(.headline)
                        Text("AIMeterはMac内に各AIツールが保存しているローカルログのみを読み取り合算します。プロンプト内容やコードを外部サーバーへ送信することはありません。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(FrostedGlassCardBackground(cornerRadius: 12))

                // QA Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("よくある質問 (Q&A)")
                        .font(.headline)

                    TextField("Q&Aを検索...", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    qaList
                }
                .padding(14)
                .background(FrostedGlassCardBackground(cornerRadius: 12))
            }
        }
        .navigationTitle("ヘルプ & 情報")
    }

    @ViewBuilder
    private var qaList: some View {
        let items = [
            ("使用量はどのように集計されていますか？", "お使いの Mac 内に各 AI ツール（Cursor, Windsurf, Claude Code, Copilot, Codex, Gemini など）が保存しているローカルセッションログやキャッシュデータベースを安全に直接読み取り、タイムスタンプに基づいて 2時間 / 5時間 / 1日 / 7日 / 30日 ごとに自動合算しています。"),
            ("ブラウザ版やスマホでの会話は反映されますか？", "反映されません。Mac ローカル内のログのみを集計対象としているため、その Mac 上のエディタやターミナルで作業した分のみが反映されます。組織全体の集計を行いたい場合は設定から OpenAI Admin Key や GCP Project ID を登録してください。"),
            ("使っているツールが「未検出」と表示される場合は？", "ポータブル版エディタや非標準のディレクトリにインストールしている場合、「サービス連携」タブからログファイルまたはフォルダを直接指定して「適用」を押してください。"),
            ("メニューバーのパーセントは何を表していますか？", "各サービスの「現在もっとも逼迫している（残量が少ない）制限枠の残りパーセント」を表しています。残量が 15% 未満になると ⚠️ マークで警告します。")
        ]

        let filtered = items.filter {
            searchText.isEmpty || $0.0.localizedCaseInsensitiveContains(searchText) || $0.1.localizedCaseInsensitiveContains(searchText)
        }

        ForEach(filtered, id: \.0) { item in
            DisclosureGroup(item.0) {
                Text(item.1)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        }
    }
}
