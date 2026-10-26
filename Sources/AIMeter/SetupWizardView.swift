import SwiftUI
import AppKit
import AIMeterCore

// MARK: - Setup Wizard View
struct SetupWizardView: View {
    @ObservedObject var monitor: UsageMonitor
    var onOpenHelp: (() -> Void)? = nil
    var onComplete: () -> Void

    @StateObject private var pathValidator = PathValidation()
    @State private var isScanning: Bool = false
    @State private var activePathPickerProviderId: String? = nil
    @State private var customPathInput: String = ""
    @State private var validationResult: LocalUsageCollector.ProviderPathScanResult? = nil

    // New custom service form states
    @State private var showNewServiceForm: Bool = false
    @State private var newServiceName: String = ""
    @State private var newServiceShortName: String = ""
    @State private var newServicePath: String = ""
    @State private var newServiceIcon: String = "cpu.fill"
    @State private var newServiceValidationResult: LocalUsageCollector.ProviderPathScanResult? = nil

    struct ServiceSetupItem: Identifiable {
        let id: String
        let name: String
        let shortName: String
        let iconName: String
        let defaultLogHint: String
        var isBuiltIn: Bool // true for OpenAI/Gemini
    }

    private let standardServices: [ServiceSetupItem] = [
        ServiceSetupItem(
            id: "openai",
            name: "OpenAI / Codex",
            shortName: "GPT",
            iconName: "brain.head.profile",
            defaultLogHint: "~/.codex/sessions/**/*.jsonl",
            isBuiltIn: true
        ),
        ServiceSetupItem(
            id: "gemini",
            name: "Google Gemini",
            shortName: "Gem",
            iconName: "sparkle",
            defaultLogHint: "~/.gemini/antigravity/brain",
            isBuiltIn: true
        ),
        ServiceSetupItem(
            id: "claude",
            name: "Anthropic Claude",
            shortName: "Cld",
            iconName: "bubble.left.and.bubble.right.fill",
            defaultLogHint: "~/.claude/projects / sessions",
            isBuiltIn: false
        ),
        ServiceSetupItem(
            id: "windsurf",
            name: "Windsurf",
            shortName: "Wind",
            iconName: "wind",
            defaultLogHint: "~/Library/.../state.vscdb",
            isBuiltIn: false
        ),
        ServiceSetupItem(
            id: "cursor",
            name: "Cursor",
            shortName: "Cur",
            iconName: "terminal.fill",
            defaultLogHint: "~/Library/.../Cursor/AgentStores",
            isBuiltIn: false
        ),
        ServiceSetupItem(
            id: "copilot",
            name: "GitHub Copilot",
            shortName: "Cop",
            iconName: "chevron.left.forwardslash.chevron.right",
            defaultLogHint: "~/.copilot/session-state",
            isBuiltIn: false
        ),
        ServiceSetupItem(
            id: "grokbot",
            name: "Grok / GrokBot",
            shortName: "Grok",
            iconName: "sparkles",
            defaultLogHint: "~/Library/.../Grok Bot",
            isBuiltIn: false
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                LiquidGlassIconOrb(
                    systemName: "slider.horizontal.2.square",
                    accent: .accentColor,
                    size: 38,
                    iconSize: 19
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("AIサービスの確認・初期セットアップ")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("表示したいサービスの選択や、新規サービスの追加・パス指定を行えます。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onOpenHelp {
                    Button {
                        onOpenHelp()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .help("ヘルプ・Q&Aを見る")
                }

                Button {
                    Task {
                        isScanning = true
                        await monitor.refresh()
                        isScanning = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("再検出")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                .disabled(isScanning)
            }

            Divider()
                .opacity(0.35)

            // Service List & Add Service Section
            ScrollView {
                VStack(spacing: 12) {
                    // Standard Detected / Configured Services
                    VStack(spacing: 10) {
                        ForEach(standardServices) { service in
                            serviceRowView(service: service)
                        }

                        // Extra custom user subscriptions that aren't in standardServices
                        ForEach(extraCustomSubscriptions) { sub in
                            extraSubscriptionRowView(sub: sub)
                        }
                    }

                    // Add New Service Section
                    addServiceSectionView
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 360)

            Divider()
                .opacity(0.35)

            // Footer Actions
            HStack {
                Text("\(enabledServicesCount) 個のサービスを表示中")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("完了して使い始める") {
                    monitor.hasCompletedSetupWizard = true
                    onComplete()
                }
                .buttonStyle(GlassCapsuleButtonStyle(isProminent: true))
                .font(.system(size: 14, weight: .semibold))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 530)
        .background(LiquidGlassBackground(cornerRadius: 20))
        .onAppear {
            if monitor.customSubscriptions.isEmpty {
                monitor.autoAddDetectedSubscriptions()
            }
        }
        .onDisappear { pathValidator.cancel() }
    }

    // MARK: - Row View for Standard Services
    @ViewBuilder
    private func serviceRowView(service: ServiceSetupItem) -> some View {
        let isEnabled = isServiceEnabled(service)
        let isDetected = isServiceDetected(service)
        let preview = serviceUsagePreview(service)
        let customPath = monitor.customProviderPaths[service.id]
        let accent = providerAccentColor(for: service.id)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Toggle Checkbox
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { setServiceEnabled(service, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.regular)

                // Icon + Name
                LiquidGlassIconOrb(
                    systemName: service.iconName,
                    accent: isEnabled ? accent : .secondary,
                    size: 26,
                    iconSize: 13,
                    serviceID: service.id
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(service.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isEnabled ? .primary : .secondary)

                        // Status Badge
                        if customPath != nil {
                            LiquidGlassBadge(text: "手動指定", tint: .blue)
                        } else if isDetected {
                            LiquidGlassBadge(text: "検出済み", tint: .green)
                        } else {
                            LiquidGlassBadge(text: "未検出")
                        }
                    }

                    Text(preview)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(isDetected || customPath != nil ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.6))
                }

                Spacer()

                // Manual Path Button
                Button {
                    pathValidator.cancel()
                    if activePathPickerProviderId == service.id {
                        activePathPickerProviderId = nil
                        validationResult = nil
                    } else {
                        activePathPickerProviderId = service.id
                        customPathInput = monitor.customProviderPaths[service.id] ?? ""
                        validationResult = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: customPath != nil ? "folder.fill" : "folder.badge.gearshape")
                        Text(customPath != nil ? "パス変更" : "パス指定")
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(GlassCapsuleButtonStyle(isSelected: customPath != nil))
            }

            // Inline Path Picker Expansion
            if activePathPickerProviderId == service.id {
                pathEditorView(serviceId: service.id, defaultHint: service.defaultLogHint)
            }
        }
        .padding(11)
        .background(
            FrostedGlassCardBackground(
                cornerRadius: 12,
                accentTint: isEnabled ? accent : nil
            )
        )
    }

    // MARK: - Row View for Extra Custom Subscriptions
    @ViewBuilder
    private func extraSubscriptionRowView(sub: CustomSubscriptionConfig) -> some View {
        let customPath = monitor.customProviderPaths[sub.id]
        let isExpanded = activePathPickerProviderId == sub.id
        let accent = providerAccentColor(for: sub.id)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { sub.isEnabled },
                    set: { val in
                        if let idx = monitor.customSubscriptions.firstIndex(where: { $0.id == sub.id }) {
                            monitor.customSubscriptions[idx].isEnabled = val
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.regular)

                LiquidGlassIconOrb(
                    systemName: sub.iconName,
                    accent: sub.isEnabled ? accent : .secondary,
                    size: 26,
                    iconSize: 13,
                    serviceID: sub.id
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(sub.name)
                            .font(.system(size: 14, weight: .bold))

                        if customPath != nil {
                            LiquidGlassBadge(text: "手動指定", tint: .blue)
                        } else {
                            LiquidGlassBadge(text: "カスタム", tint: .purple)
                        }
                    }

                    if let usage = monitor.customProviderLiveUsage[sub.id], let monthly = usage.usedByPeriod?.monthly, monthly > 0 {
                        Text("実ログ: \(formatTokenCount(monthly)) (\(usage.status ?? sub.statusNote))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color.primary.opacity(0.85))
                    } else if !sub.statusNote.isEmpty {
                        Text(sub.statusNote)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    pathValidator.cancel()
                    if isExpanded {
                        activePathPickerProviderId = nil
                        validationResult = nil
                    } else {
                        activePathPickerProviderId = sub.id
                        customPathInput = monitor.customProviderPaths[sub.id] ?? ""
                        validationResult = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: customPath != nil ? "folder.fill" : "folder.badge.gearshape")
                        Text(customPath != nil ? "パス変更" : "パス指定")
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(GlassCapsuleButtonStyle(isSelected: customPath != nil))

                Button {
                    monitor.removeSubscription(id: sub.id)
                    monitor.setCustomPath(for: sub.id, path: "")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                pathEditorView(serviceId: sub.id, defaultHint: "~/path/to/logs")
            }
        }
        .padding(11)
        .background(
            FrostedGlassCardBackground(
                cornerRadius: 12,
                accentTint: sub.isEnabled ? accent : nil
            )
        )
    }

    // MARK: - Add New Service Section
    @ViewBuilder
    private var addServiceSectionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("+ サービスを追加")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            // Preset Quick-add Buttons
            HStack(spacing: 6) {
                Button("+ Devin") { addOrEnablePreset(.devinPreset()) }
                Button("+ Perplexity") { addOrEnablePreset(.perplexityPreset()) }
                Button("+ DeepSeek") { addOrEnablePreset(.deepseekPreset()) }
                Button("+ Poe") { addOrEnablePreset(.poePreset()) }
                Button("+ Trae") { addOrEnablePreset(.traePreset()) }
            }
            .controlSize(.small)
            .font(.system(size: 12))

            // Custom New Service Toggle
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showNewServiceForm.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showNewServiceForm ? "chevron.up.circle.fill" : "plus.circle.fill")
                        .foregroundStyle(.tint)
                    Text(showNewServiceForm ? "カスタム作成を閉じる" : "新規カスタムAIを手動作成...")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            if showNewServiceForm {
                newCustomServiceFormView
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                )
        )
    }

    // MARK: - New Custom Service Form
    @ViewBuilder
    private var newCustomServiceFormView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(spacing: 8) {
                TextField("サービス名 (例: Local Ollama)", text: $newServiceName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))

                TextField("略称 (例: Oll)", text: $newServiceShortName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                    .frame(width: 90)
            }

            // Log Path with Browse Button
            HStack(spacing: 6) {
                TextField("ログファイル / 保存先ディレクトリ (任意)", text: $newServicePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button("参照...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "選択"
                    panel.message = "ログファイルまたはディレクトリを選択してください"

                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK, let url = panel.url {
                        newServicePath = url.path
                    }
                }
                .controlSize(.small)
            }

            HStack {
                Spacer()

                Button("キャンセル") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showNewServiceForm = false
                        newServiceName = ""
                        newServiceShortName = ""
                        newServicePath = ""
                    }
                }
                .controlSize(.regular)

                Button("サービスを追加") {
                    let name = newServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }

                    let shortId = String(UUID().uuidString.prefix(6)).lowercased()
                    let customId = "custom_\(shortId)"
                    let shortName = newServiceShortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(name.prefix(4))
                        : newServiceShortName.trimmingCharacters(in: .whitespacesAndNewlines)

                    let newConfig = CustomSubscriptionConfig(
                        id: customId,
                        name: name,
                        shortName: shortName,
                        iconName: "cpu.fill",
                        isEnabled: true,
                        showInMenuBar: true,
                        enabledPeriodRawValues: ["5h", "1d", "7d", "30d"],
                        limit2h: 200_000,
                        limit5h: 500_000,
                        limitDaily: 2_000_000,
                        limitWeekly: 10_000_000,
                        limitMonthly: 30_000_000,
                        manualUsed2h: 0,
                        manualUsed5h: 0,
                        manualUsedDaily: 0,
                        manualUsedWeekly: 0,
                        manualUsedMonthly: 0,
                        usedCostUSD: 0.0,
                        budgetUSD: 20.0,
                        statusNote: "カスタム"
                    )

                    monitor.addSubscription(newConfig)

                    let trimmedPath = newServicePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedPath.isEmpty {
                        monitor.setCustomPath(for: customId, path: trimmedPath)
                    }

                    // Reset and hide form
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showNewServiceForm = false
                        newServiceName = ""
                        newServiceShortName = ""
                        newServicePath = ""
                    }

                    Task {
                        await monitor.refresh()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(newServiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Path Editor View
    @ViewBuilder
    private func pathEditorView(serviceId: String, defaultHint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ログファイルまたはディレクトリを手動指定:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField(defaultHint, text: Binding(get: { customPathInput }, set: { pathValidator.cancel(); customPathInput = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button("参照...") {
                    selectFileOrFolder(for: serviceId)
                }
                .controlSize(.small)

                Button("検証 & 適用") {
                    validateAndApply(for: serviceId, path: customPathInput)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                if monitor.customProviderPaths[serviceId] != nil {
                    Button("リセット") {
                        pathValidator.cancel()
                        monitor.setCustomPath(for: serviceId, path: "")
                        customPathInput = ""
                        validationResult = nil
                        Task { await monitor.refresh() }
                    }
                    .controlSize(.small)
                }
            }

            if pathValidator.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("ログを検証中…")
                    Button("中止") { pathValidator.cancel() }
                }
            }
            if let result = validationResult {
                HStack(spacing: 5) {
                    Image(systemName: result.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.isValid ? .green : .orange)
                    Text(result.message)
                        .font(.system(size: 12))
                        .foregroundStyle(result.isValid ? .green : .orange)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Helpers
    private func badgeView(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    private func isServiceEnabled(_ service: ServiceSetupItem) -> Bool {
        if service.id == "openai" { return monitor.showOpenAISection }
        if service.id == "gemini" { return monitor.showGeminiSection }
        return monitor.customSubscriptions.first(where: { $0.id == service.id })?.isEnabled ?? false
    }

    private func setServiceEnabled(_ service: ServiceSetupItem, enabled: Bool) {
        if service.id == "openai" {
            monitor.showOpenAISection = enabled
        } else if service.id == "gemini" {
            monitor.showGeminiSection = enabled
        } else {
            if let idx = monitor.customSubscriptions.firstIndex(where: { $0.id == service.id }) {
                monitor.customSubscriptions[idx].isEnabled = enabled
            } else if enabled {
                if let preset = CustomSubscriptionConfig.preset(forId: service.id) {
                    var newSub = preset
                    newSub.isEnabled = true
                    monitor.addSubscription(newSub)
                }
            }
        }
    }

    private func addOrEnablePreset(_ preset: CustomSubscriptionConfig) {
        if let idx = monitor.customSubscriptions.firstIndex(where: { $0.id == preset.id }) {
            monitor.customSubscriptions[idx].isEnabled = true
        } else {
            monitor.addSubscription(preset)
        }
    }

    private func isServiceDetected(_ service: ServiceSetupItem) -> Bool {
        if service.id == "openai" {
            return monitor.openaiUsedTokens > 0 || monitor.openaiServerPct != nil
        } else if service.id == "gemini" {
            return monitor.geminiUsedTokens > 0
        } else {
            return monitor.detectedProviderIds.contains(service.id) ||
                (monitor.customProviderLiveUsage[service.id]?.usedByPeriod?.monthly ?? 0) > 0
        }
    }

    private func serviceUsagePreview(_ service: ServiceSetupItem) -> String {
        if service.id == "openai" {
            if monitor.openaiUsedTokens > 0 {
                let formatted = formatTokenCount(monitor.openaiUsedTokens)
                let plan = monitor.openaiStatus
                return "実ログ: 月間 \(formatted) tokens (\(plan))"
            }
            return "ログ未検出"
        } else if service.id == "gemini" {
            if monitor.geminiUsedTokens > 0 {
                let formatted = formatTokenCount(monitor.geminiUsedTokens)
                return "実ログ: 月間 \(formatted) tokens"
            }
            return "ログ未検出"
        } else {
            if let usage = monitor.customProviderLiveUsage[service.id] {
                let monthly = usage.usedByPeriod?.monthly ?? 0
                let status = usage.status ?? ""
                if service.id == "windsurf" {
                    return "実ログ: \(monthly.formatted()) メッセージ (\(status))"
                } else if service.id == "cursor" || service.id == "copilot" {
                    return "実ログ: \(monthly) リクエスト (\(status))"
                } else {
                    return "実ログ: 月間 \(formatTokenCount(monthly)) tokens (\(status))"
                }
            }
            return "ログ未検出"
        }
    }

    private var extraCustomSubscriptions: [CustomSubscriptionConfig] {
        let standardIds = Set(standardServices.map(\.id))
        return monitor.customSubscriptions.filter { !standardIds.contains($0.id) }
    }

    private var enabledServicesCount: Int {
        var count = 0
        if monitor.showOpenAISection { count += 1 }
        if monitor.showGeminiSection { count += 1 }
        count += monitor.customSubscriptions.filter(\.isEnabled).count
        return count
    }

    private func selectFileOrFolder(for serviceId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "\(serviceId) のログファイルまたは設定ディレクトリを選択してください"

        NSApplication.shared.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            customPathInput = url.path
            validateAndApply(for: serviceId, path: url.path)
        }
    }

    private func validateAndApply(for serviceId: String, path: String) {
        pathValidator.cancel()
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationResult = LocalUsageCollector.ProviderPathScanResult(
                isValid: false, message: "パスを入力してください", previewCount: 0, statusNote: nil
            )
            return
        }

        validationResult = nil
        pathValidator.start(provider: serviceId, path: trimmed) { res in
            validationResult = res
            if res.isValid {
                monitor.setCustomPath(for: serviceId, path: trimmed)
                // Ensure service is enabled
                if serviceId == "openai" {
                    monitor.showOpenAISection = true
                } else if serviceId == "gemini" {
                    monitor.showGeminiSection = true
                } else {
                    if let idx = monitor.customSubscriptions.firstIndex(where: { $0.id == serviceId }) {
                        monitor.customSubscriptions[idx].isEnabled = true
                    } else if let preset = CustomSubscriptionConfig.preset(forId: serviceId) {
                        var s = preset
                        s.isEnabled = true
                        monitor.addSubscription(s)
                    }
                }
                Task {
                    await monitor.refresh()
                }
            }
        }
    }
}
