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
            }
            .listStyle(.sidebar)
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
        .frame(minWidth: 860, minHeight: 560)
    }
}

// MARK: - General Settings Tab
private struct GeneralSettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginManager

    var body: some View {
        SettingsForm {
            #if AIMETER_APP_STORE
            SettingsSection("アプリのアップデート") {
                Text("アップデートはMac App Storeから行ってください。")
                    .foregroundStyle(.secondary)
            }
            #else
            AppUpdateSettingsSection()
            #endif

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
                Text("通常は残り％のみ表示します。オフではmacOSウィジェットの共有ファイルにも使用量・上限の数値を保存しません。本体の集計は保持します。『約』の残り％は設定上限からの目安です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if monitor.widgetAmountChangePending, let error = monitor.widgetSharingError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if let error = monitor.temporaryDataCleanupError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("一時作業データの回収を再試行") { monitor.cleanupTemporarySnapshots() }
                }
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
                    .buttonStyle(.bordered)
                    .disabled(monitor.isRefreshing)
                }
            }
        }
        .navigationTitle("一般")
    }
}

// MARK: - Application Updates
private struct AppUpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    @State private var confirmDevelopmentUpdate = false

    var body: some View {
        SettingsSection("アプリのアップデート") {
            SettingsLabeledContent("現在のバージョン") {
                Text(updater.currentVersion)
                    .foregroundStyle(.secondary)
            }
            SettingsLabeledContent("現在の種類") {
                Text(updater.currentChannelLabel)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("公開済みの最新安定版をインストールします。更新後にAIMeterが再起動します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("最新版に更新", systemImage: "arrow.down.circle") {
                    Task { await updater.update(to: .stable) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(updater.isBusy)
            }

            if updater.isBusy {
                if let progress = updater.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("アプリのアップデート")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if !updater.status.isEmpty {
                Text(updater.status)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("アップデート状況: \(updater.status)")
            }

            DisclosureGroup("開発用") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("公開済みの開発版に切り替えます。開発中の変更が含まれるため、動作が不安定な場合があります。安定版へは「最新版に更新」で戻せます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("開発版に更新") { confirmDevelopmentUpdate = true }
                        .disabled(updater.isBusy)
                }
                .padding(.vertical, 6)
            }
            .confirmationDialog("開発版に更新しますか？", isPresented: $confirmDevelopmentUpdate) {
                Button("開発版に更新") {
                    Task { await updater.update(to: .development) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("公開済みの最新開発版をインストールして再起動します。設定と利用データは引き継ぎます。")
            }
        }
    }
}

// MARK: - Services Settings Tab
private struct ServicesSettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @Binding var selectedServiceId: String

    @StateObject private var pathValidator = PathValidation()
    @State private var pathInputs: [String: String] = [:]
    @State private var pathValidationResults: [String: LocalUsageCollector.ProviderPathScanResult] = [:]
    @State private var confirmStoredKeyDeletion: Bool = false

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

                        serviceRow(id: "antigravity", name: "Antigravity", icon: "sparkles",
                                   isEnabled: monitor.showAntigravitySection, hasCustomPath: false,
                                   isDetected: monitor.antigravityQuota != nil)
                            .tag("antigravity")
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
                    .buttonStyle(.bordered)

                    Button {
                        if selectedServiceId != "openai" && selectedServiceId != "gemini" && selectedServiceId != "antigravity" {
                            let idToRemove = selectedServiceId
                            selectedServiceId = "openai"
                            monitor.removeSubscription(id: idToRemove)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("選択したサービスを削除")
                    .disabled(["openai", "gemini", "antigravity"].contains(selectedServiceId))

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
                    .buttonStyle(.bordered)
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
    }

    @ViewBuilder
    private var detailForm: some View {
        if selectedServiceId == "openai" {
            openAIDetailForm
        } else if selectedServiceId == "gemini" {
            geminiDetailForm
        } else if selectedServiceId == "antigravity" {
            antigravityDetailForm
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
                SettingsToggle("サービスを有効にする（収集・表示・クラウド同期）", isOn: $monitor.showOpenAISection)
                SettingsToggle("メニューバーに表示する", isOn: $monitor.showOpenAIInMenuBar)
                    .disabled(!monitor.showOpenAISection)
            }

            SettingsSection("ローカルログパス") {
                logPathEditor(for: "openai")
            }

            SettingsSection("クラウド組織連携 (任意)") {
                LabeledContent("OpenAI Admin Key") {
                    SecureField("OpenAI Admin Key", text: $monitor.openaiAdminKeyDraft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("OpenAI Admin Key")
                }
                .disabled(!monitor.showOpenAISection)
                HStack {
                    Button("キーを保存") {
                        monitor.saveOpenAICredential()
                    }
                    .disabled(monitor.openaiAdminKeyDraft.isEmpty)
                    Button("保存済みキーを読み直す") { monitor.retryOpenAICredentialLoad() }
                }
                .buttonStyle(.bordered)
                .disabled(!monitor.showOpenAISection)
                if let error = monitor.openaiCredentialError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("入力後に保存してください。保存を確認できたキーだけを同期に使用します。キーの値は画面に表示しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("クラウド組織全体のAPI利用量を同期する場合のみ設定してください。ローカルセッションの集計には不要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("保存済みキーの保守") {
                #if AIMETER_APP_STORE
                Text("連携をオフにしたまま、このアプリに保存したキーを削除できます。旧版のキーは引き継ぎません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("連携をオフにしたまま操作できます。旧設定を安全に移行するか、この端末の保存済みキーを削除します。これらの操作でAPI照会は開始しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                HStack {
                    #if !AIMETER_APP_STORE
                    Button("旧設定を移行") { monitor.migrateLegacyOpenAICredential() }
                    #endif
                    Button("この端末の保存済みキーを削除", role: .destructive) {
                        confirmStoredKeyDeletion = true
                    }
                }
                .buttonStyle(.bordered)
                .confirmationDialog("この端末の保存済みキーを削除しますか？",
                                    isPresented: $confirmStoredKeyDeletion,
                                    titleVisibility: .visible) {
                    Button("保存済みキーを削除", role: .destructive) {
                        monitor.deleteStoredOpenAICredential()
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("Keychainと旧設定に保存されたOpenAIキーを削除します。再び利用するにはキーの入力と保存が必要です。")
                }
                Text(monitor.openaiCredentialMaintenanceStatus.message)
                    .font(.caption)
                    .foregroundStyle(monitor.openaiCredentialMaintenanceStatus.isFailure ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("openai-credential-maintenance-status")
            }
        }
        .onAppear { monitor.loadOpenAICredentialIfEnabled() }
        .onChange(of: monitor.showOpenAISection) { _, enabled in
            if enabled { monitor.loadOpenAICredentialIfEnabled() }
        }
    }

    // Gemini Details
    @ViewBuilder
    private var geminiDetailForm: some View {
        SettingsForm {
            SettingsSection("表示設定") {
                SettingsToggle("サービスを有効にする（収集・表示・クラウド同期）", isOn: $monitor.showGeminiSection)
                SettingsToggle("メニューバーに表示する", isOn: $monitor.showGeminiInMenuBar)
                    .disabled(!monitor.showGeminiSection)
            }

            SettingsSection("ローカルログパス") {
                logPathEditor(for: "gemini")
            }

            #if AIMETER_APP_STORE
            SettingsSection("GCPプロジェクト連携") {
                Text("Mac App Store版ではCloud Monitoringとの連携に対応していません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            SettingsSection("GCPプロジェクト連携 (任意)") {
                SettingsLabeledContent("GCP Project ID") {
                    TextField("GCP Project ID", text: $monitor.gcpProjectId)
                        .labelsHidden()
                }
                Text("Cloud Monitoring から Gemini 利用量を同期する場合のみ入力してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
    }

    private var antigravityDetailForm: some View {
        SettingsForm {
            SettingsSection("表示設定") {
                SettingsToggle("このサービスを有効にする", isOn: $monitor.showAntigravitySection)
                SettingsToggle("メニューバーに表示する", isOn: $monitor.showAntigravityInMenuBar)
                    .disabled(!monitor.showAntigravitySection)
            }
            SettingsSection("Antigravityの残量") {
                #if AIMETER_APP_STORE
                Text("Mac App Store版ではAntigravityの残量取得に対応していません。")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("Antigravityを起動してログインした状態で更新してください。AIMeterへの追加ログインは不要です。取得できたモデル群ごとの残り％とリセット予定を表示します。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Geminiのローカル推定使用量とは別の情報です。Antigravityの残りトークン数は推計しません。アプリの終了や更新失敗時は未取得になります。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(monitor.antigravityStatus).font(.caption)
                Button("今すぐ更新") { Task { await monitor.refresh() } }
                    .disabled(monitor.isRefreshing || !monitor.showAntigravitySection)
                #endif
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
            .buttonStyle(.bordered)

            if pathValidator.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("ログを検証中…")
                    Button("中止") { pathValidator.cancel() }
                        .buttonStyle(.bordered)
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
                    Text("OpenAI / Codex").tag("openai")
                    Text("Google Gemini").tag("gemini")
                    ForEach(monitor.customSubscriptions) { sub in
                        Text(sub.name).tag(sub.id)
                    }
                }
            }
            .listStyle(.plain)
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
            Section {
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
            }

            SettingsSection("データと通信の扱い") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title3)
                        .foregroundStyle(.green)

                    #if AIMETER_APP_STORE
                    Text("ローカルログの読み取りは準備中です。任意のOpenAI連携を有効にすると、利用量と費用を照会します。GCPとAntigravityの残量連携には対応していません。アップデートはMac App Storeから行います。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    #else
                    Text("ローカルログはMac内で集計します。任意のOpenAI・GCP連携を有効にすると公式サービスへ利用量・費用を照会します。Antigravity連携は同じMac内の正規アプリと通信します。アプリのアップデートはボタンを押したときにGitHubへ確認・ダウンロードします。コードやプロンプト本文をこれらの要求へ含めません。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    #endif
                    Spacer()
                }
            }

            SettingsSection("お問い合わせ") {
                Link(SupportContact.email, destination: SupportContact.mailURL)
                Text("利用ログ・集計ファイル・APIキーは添付しないでください。脆弱性はGitHubの非公開報告窓口も利用できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsSection("よくある質問 (Q&A)") {
                TextField("Q&Aを検索...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                qaList
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
