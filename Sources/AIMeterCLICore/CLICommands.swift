import Foundation
import AIMeterCore

public struct CLICommandResult {
    public var data: JSONValue
    public var human: String
    public var exitCode: Int32

    public init(data: JSONValue, human: String, exitCode: Int32 = 0) {
        self.data = data
        self.human = human
        self.exitCode = exitCode
    }
}

/// Access to the direct (GitHub) distribution's persisted state, shared by
/// the read commands in this file and the write / verify commands in
/// CLIWriteCommands.swift. The read commands here are side-effect free;
/// nothing in the CLI ever touches the Keychain or starts the app.
public struct CLIContext {
    public let environment: CLIEnvironment

    public init(environment: CLIEnvironment) {
        self.environment = environment
    }

    public var usageFileURL: URL {
        environment.dataDirectory.appendingPathComponent(".ai_meter_usage.json")
    }

    public var widgetFileURL: URL {
        environment.dataDirectory.appendingPathComponent(".ai_meter_widget.json")
    }

    // MARK: Shared inputs

    public func preferences() -> UsagePreferences {
        UsagePreferences.load(from: environment.defaults)
    }

    public func customSubscriptions() -> [CustomSubscriptionConfig] {
        SharedStore.loadCustomSubscriptions(from: environment.defaults)
    }

    public func usageData() -> LocalUsageData? {
        SharedStore.loadLocalUsageData(from: usageFileURL)
    }

    public func widgetSnapshotIfPresent() -> AIMeterWidgetSnapshot? {
        guard FileManager.default.fileExists(atPath: widgetFileURL.path) else { return nil }
        return SharedStore.loadWidgetSnapshot(from: widgetFileURL)
    }

    public func serviceList(data: LocalUsageData? = nil) -> [ServiceUsage] {
        ServiceUsageBuilder.services(
            data: data ?? usageData(),
            preferences: preferences(),
            customSubscriptions: customSubscriptions()
        )
    }

    // MARK: Date handling (ISO 8601 with time zone)

    public func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = environment.timeZone
        return formatter.string(from: date)
    }

    public func isoDate(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    public func usageUpdatedAt(_ usage: LocalUsageData?) -> Date? {
        usage?.updatedAt.flatMap { isoDate(from: $0) }
    }

    // MARK: JSON conversion

    public static func sourceCode(_ source: RemainingQuotaSource) -> String {
        switch source {
        case .official: return "official"
        case .configuredLimit: return "configured_limit"
        case .unavailable: return "unavailable"
        }
    }

    public static func sourceLabel(_ source: RemainingQuotaSource) -> String {
        switch source {
        case .official: return "公式値"
        case .configuredLimit: return "目安"
        case .unavailable: return "未取得"
        }
    }

    public func frameJSON(_ metric: PeriodUsageMetric) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("id", .string(metric.id)),
            ("period", metric.period.map { .string($0.rawValue) } ?? .null),
            ("period_label", .string(metric.displayLabel)),
            ("used_tokens", .int(metric.usedTokens)),
            ("limit_tokens", .int(metric.limitTokens)),
            ("is_quota_only", .bool(metric.isQuotaOnly)),
            ("valid", .bool(metric.isValid))
        ]
        if metric.isValid && metric.isRemainingAvailable {
            pairs.append(("remaining_tokens", .int(metric.remainingTokens)))
            pairs.append(("remaining_percent", .int(metric.remainingPercent)))
            pairs.append(("remaining_ratio", .double(metric.remainingRatio)))
            pairs.append(("remaining_source", .string(Self.sourceCode(metric.remainingSource))))
        } else {
            pairs.append(("remaining_tokens", .null))
            pairs.append(("remaining_percent", .null))
            pairs.append(("remaining_ratio", .null))
            pairs.append(("remaining_source", .string(metric.isValid ? Self.sourceCode(metric.remainingSource) : "unavailable")))
        }
        pairs.append(("reset_at", metric.resetTimestamp.map { .string(isoString(from: Date(timeIntervalSince1970: Double($0)))) } ?? .null))
        if let description = metric.resetDescription {
            pairs.append(("reset_description", .string(description)))
        }
        return .object(pairs)
    }

    public func serviceJSON(_ service: ServiceUsage) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("id", .string(service.id)),
            ("name", .string(service.name)),
            ("short_name", .string(service.shortName)),
            ("kind", .string(service.kind.rawValue)),
            ("unit", .string(service.unit)),
            ("enabled", .bool(service.isEnabled)),
            ("has_data", .bool(service.hasData)),
            ("frames", .array(service.metrics.map { frameJSON($0) }))
        ]
        if let bottleneck = service.bottleneckMetric {
            pairs.append(("bottleneck", .object([
                ("frame_id", .string(bottleneck.id)),
                ("period", bottleneck.period.map { .string($0.rawValue) } ?? .null),
                ("remaining_percent", bottleneck.isRemainingAvailable ? .int(bottleneck.remainingPercent) : .null),
                ("remaining_source", .string(Self.sourceCode(bottleneck.remainingSource)))
            ])))
        } else {
            pairs.append(("bottleneck", .null))
        }
        pairs.append(("cost_usd", .double(service.costUSD)))
        pairs.append(("budget_usd", .double(service.budgetUSD)))
        pairs.append(("status_note", .string(service.statusNote)))
        pairs.append(("plan_type", service.planType.map { .string($0) } ?? .null))
        return .object(pairs)
    }

    // MARK: Human rendering helpers

    public func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public func bottleneckLine(_ service: ServiceUsage) -> String {
        guard let bottleneck = service.bottleneckMetric, bottleneck.isRemainingAvailable else {
            return "\(service.name) (\(service.id)): 未取得"
        }
        let percent = bottleneck.remainingSource.percentText(bottleneck.remainingPercent)
        return "\(service.name) (\(service.id)): 残り \(percent)（\(bottleneck.displayLabel)・\(Self.sourceLabel(bottleneck.remainingSource))）"
    }

    // MARK: status

    public func runStatus() throws -> CLICommandResult {
        let configuration: DistributionConfiguration
        do {
            configuration = try DistributionConfiguration.current()
        } catch {
            throw CLIError.appFailure("配布設定を解決できませんでした。", code: "configuration_error")
        }
        let fileManager = FileManager.default
        let usageExists = fileManager.fileExists(atPath: usageFileURL.path)
        let usage = usageExists ? usageData() : nil
        let widgetExists = fileManager.fileExists(atPath: widgetFileURL.path)
        let widget = widgetSnapshotIfPresent()
        let services = serviceList(data: usage)
        let preferences = preferences()

        let usageUpdated = usageUpdatedAt(usage)
        let data: JSONValue = .object([
            ("app", .object([
                ("name", .string("AIMeter")),
                ("distribution", .string(configuration.mode == .direct ? "direct" : "app_store")),
                ("keychain_service", .string(configuration.keychainService)),
                ("widget_kind", .string(configuration.widgetKind)),
                ("url_scheme", .string(configuration.urlScheme))
            ])),
            ("cli", .object([
                ("name", .string("AIMeterCLI")),
                ("version", .string(aimeterCLIVersion)),
                ("schema_version", .int(aimeterCLISchemaVersion))
            ])),
            ("data", .object([
                ("usage_snapshot", .object([
                    ("path", .string(usageFileURL.path)),
                    ("exists", .bool(usageExists)),
                    ("decodable", .bool(usage != nil)),
                    ("updated_at", usageUpdated.map { .string(isoString(from: $0)) } ?? .null),
                    ("source", usage?.source.map { .string($0) } ?? .null)
                ])),
                ("widget_snapshot", .object([
                    ("path", .string(widgetFileURL.path)),
                    ("exists", .bool(widgetExists)),
                    ("schema_version", rawWidgetSchemaVersion().map { .int($0) } ?? .null),
                    ("has_data", widget.map { .bool($0.hasData) } ?? .null),
                    ("update_failed", widget.map { .bool($0.updateFailed) } ?? .null),
                    ("updated_at", widget?.updatedAt.map { .string(isoString(from: $0)) } ?? .null)
                ])),
                ("services", .object([
                    ("known", .int(services.count)),
                    ("enabled", .int(services.filter(\.isEnabled).count))
                ])),
                ("setup_completed", .bool(preferences.hasCompletedSetupWizard))
            ])),
            ("notes", .array([.string(Self.storeScopeNote)]))
        ])

        let usageLine: String
        if usageExists, let usageUpdated {
            usageLine = "収集スナップショット: あり（最終更新 \(isoString(from: usageUpdated))）"
        } else {
            usageLine = "収集スナップショット: \(usageExists ? "あり" : "なし")"
        }
        let widgetLine: String
        if widgetExists, let widget {
            widgetLine = "ウィジェット共有: あり（データ\(widget.hasData ? "あり" : "なし")\(widget.updateFailed ? "・前回更新失敗" : "")）"
        } else {
            widgetLine = "ウィジェット共有: \(widgetExists ? "あり" : "なし")"
        }
        let lines = [
            "AIMeter（GitHub 配布版 / direct）",
            "CLI: AIMeterCLI \(aimeterCLIVersion) / スキーマ \(aimeterCLISchemaVersion)",
            usageLine,
            widgetLine,
            "サービス: \(services.count) 件（有効 \(services.filter(\.isEnabled).count) 件）",
            "セットアップ: \(preferences.hasCompletedSetupWizard ? "完了" : "未完了")",
            "注記: \(Self.storeScopeNote)"
        ]
        return CLICommandResult(data: data, human: lines.joined(separator: "\n"))
    }

    public static let storeScopeNote = "対象は GitHub 配布版（direct）のみです。Mac App Store 版のデータは Sandbox コンテナと App Group 内にあり、独立した CLI からは到達できないため、この CLI では参照しません。"

    /// The widget file's declared schema version, probed without applying
    /// the model's migration/normalization, for status and doctor reporting.
    public func rawWidgetSchemaVersion() -> Int? {
        guard let data = try? BoundedInput().data(at: widgetFileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let version = dictionary["schemaVersion"] as? NSNumber else {
            return nil
        }
        return version.intValue
    }

    // MARK: list

    public func runList() -> CLICommandResult {
        let usage = usageData()
        let services = serviceList(data: usage)
        let updated = usageUpdatedAt(usage)
        let data: JSONValue = .object([
            ("services", .array(services.map { serviceJSON($0) })),
            ("count", .int(services.count)),
            ("has_data", .bool(usage != nil)),
            ("updated_at", updated.map { .string(isoString(from: $0)) } ?? .null)
        ])
        let human = services.map { bottleneckLine($0) }.joined(separator: "\n")
        return CLICommandResult(data: data, human: human)
    }

    // MARK: get

    public func runGet(serviceID: String) throws -> CLICommandResult {
        let services = serviceList()
        guard let service = services.first(where: { $0.id == serviceID }) else {
            throw CLIError.notFound(
                "サービスが見つかりません: \(serviceID)",
                details: .object([("known_ids", .array(services.map { .string($0.id) }))])
            )
        }
        var lines = ["\(service.name) (\(service.id))\(service.unit.isEmpty ? "" : " / \(service.unit)")"]
        for metric in service.metrics {
            if metric.isRemainingAvailable {
                lines.append("  \(metric.id) \(metric.displayLabel): 使用 \(grouped(metric.usedTokens)) / 上限 \(grouped(metric.limitTokens))、残り \(metric.remainingSource.percentText(metric.remainingPercent))（\(Self.sourceLabel(metric.remainingSource))）")
            } else {
                lines.append("  \(metric.id) \(metric.displayLabel): 使用 \(grouped(metric.usedTokens)) / 上限 \(grouped(metric.limitTokens))、残り 未取得")
            }
        }
        return CLICommandResult(data: serviceJSON(service), human: lines.joined(separator: "\n"))
    }

    // MARK: history

    public func runHistory() -> CLICommandResult {
        let usage = usageData()
        let widget = widgetSnapshotIfPresent()
        let updated = usageUpdatedAt(usage) ?? widget?.updatedAt
        let data: JSONValue = .object([
            ("persistent_history_available", .bool(false)),
            ("reason", .string("AIMeter は実行履歴を永続化していません。保存されているのは最終更新の状態のみで、失敗理由はアプリのメモリ上にのみ残り、終了時に消えます。")),
            ("last_update", .object([
                ("updated_at", updated.map { .string(isoString(from: $0)) } ?? .null),
                ("update_failed", widget.map { .bool($0.updateFailed) } ?? .null),
                ("source", usage?.source.map { .string($0) } ?? .null),
                ("has_data", .bool(widget?.hasData ?? (usage != nil)))
            ]))
        ])
        let human = """
        実行履歴は永続化されていません（保存されるのは最終更新の状態のみです）。
        最終更新: \(updated.map { isoString(from: $0) } ?? "記録なし")\(widget.map { $0.updateFailed ? "（前回更新は失敗）" : "" } ?? "")
        """
        return CLICommandResult(data: data, human: human)
    }

    // MARK: doctor

    public struct DoctorCheck {
        public var id: String
        public var status: Status
        public var message: String
        public var isPermissionFailure: Bool
        public var details: JSONValue?

        public enum Status: String {
            case ok, warning, error, unknown
        }

        public init(id: String, status: Status, message: String, isPermissionFailure: Bool = false, details: JSONValue? = nil) {
            self.id = id
            self.status = status
            self.message = message
            self.isPermissionFailure = isPermissionFailure
            self.details = details
        }

        public var json: JSONValue {
            var pairs: [(String, JSONValue)] = [
                ("id", .string(id)),
                ("status", .string(status.rawValue)),
                ("message", .string(message))
            ]
            if let details {
                pairs.append(("details", details))
            }
            return .object(pairs)
        }
    }

    public func runDoctor() -> CLICommandResult {
        let fileManager = FileManager.default
        let preferences = preferences()
        var checks: [DoctorCheck] = []

        let configuration = try? DistributionConfiguration.current()
        if let configuration {
            checks.append(DoctorCheck(
                id: "distribution",
                status: .ok,
                message: "配布形態は direct（GitHub 配布版）として解決されました。\(Self.storeScopeNote)",
                details: .object([("keychain_service", .string(configuration.keychainService)), ("widget_kind", .string(configuration.widgetKind))])
            ))
        } else {
            checks.append(DoctorCheck(
                id: "distribution",
                status: .error,
                message: "配布設定を解決できませんでした。"
            ))
        }

        // Usage snapshot file.
        if !fileManager.fileExists(atPath: usageFileURL.path) {
            checks.append(DoctorCheck(
                id: "usage_file", status: .warning,
                message: "収集スナップショットがありません。アプリが未起動か、まだ収集されていません。",
                details: .object([("path", .string(usageFileURL.path))])
            ))
        } else if !fileManager.isReadableFile(atPath: usageFileURL.path) {
            checks.append(DoctorCheck(
                id: "usage_file", status: .error,
                message: "収集スナップショットはありますが、読み取り権限がありません。",
                isPermissionFailure: true,
                details: .object([("path", .string(usageFileURL.path))])
            ))
        } else if usageData() == nil {
            checks.append(DoctorCheck(
                id: "usage_file", status: .error,
                message: "収集スナップショットはありますが、形式の検証に失敗しました（破損の可能性があります）。",
                details: .object([("path", .string(usageFileURL.path))])
            ))
        } else {
            let updated = usageUpdatedAt(usageData())
            checks.append(DoctorCheck(
                id: "usage_file", status: .ok,
                message: "収集スナップショットは読み取り可能です\(updated.map { "（最終更新 \(isoString(from: $0))）" } ?? "")。",
                details: .object([("path", .string(usageFileURL.path))])
            ))
        }

        // Widget snapshot file. SharedStore.loadWidgetSnapshot collapses
        // every failure into an empty snapshot, so doctor probes the file
        // directly to tell a corrupt file apart from an empty one.
        if !fileManager.fileExists(atPath: widgetFileURL.path) {
            checks.append(DoctorCheck(
                id: "widget_file", status: .warning,
                message: "ウィジェット共有ファイルがありません。アプリがまだ共有データを書いていません。",
                details: .object([("path", .string(widgetFileURL.path))])
            ))
        } else if !fileManager.isReadableFile(atPath: widgetFileURL.path) {
            checks.append(DoctorCheck(
                id: "widget_file", status: .error,
                message: "ウィジェット共有ファイルはありますが、読み取り権限がありません。",
                isPermissionFailure: true,
                details: .object([("path", .string(widgetFileURL.path))])
            ))
        } else if let data = try? BoundedInput().data(at: widgetFileURL),
                  (try? JSONSerialization.jsonObject(with: data)) != nil {
            if (try? JSONDecoder().decode(AIMeterWidgetSnapshot.self, from: data)) == nil {
                checks.append(DoctorCheck(
                    id: "widget_file", status: .error,
                    message: "ウィジェット共有ファイルはありますが、形式の検証に失敗しました（破損の可能性があります）。",
                    details: .object([("path", .string(widgetFileURL.path))])
                ))
            } else if let version = rawWidgetSchemaVersion(), version != 4 {
                checks.append(DoctorCheck(
                    id: "widget_file", status: .warning,
                    message: "ウィジェット共有ファイルのスキーマ版数は \(version) です（現行は 4）。",
                    details: .object([("path", .string(widgetFileURL.path)), ("schema_version", .int(version))])
                ))
            } else {
                checks.append(DoctorCheck(
                    id: "widget_file", status: .ok,
                    message: "ウィジェット共有ファイルは読み取り可能です（スキーマ版数 4）。",
                    details: .object([("path", .string(widgetFileURL.path)), ("schema_version", .int(4))])
                ))
            }
        } else {
            checks.append(DoctorCheck(
                id: "widget_file", status: .error,
                message: "ウィジェット共有ファイルはありますが、JSON として読み取れません。",
                details: .object([("path", .string(widgetFileURL.path))])
            ))
        }

        // Preferences domain.
        checks.append(DoctorCheck(
            id: "preferences", status: .ok,
            message: "設定ドメイン（\(environment.preferenceDomain)）を読み取りできます。",
            details: .object([("domain", .string(environment.preferenceDomain))])
        ))

        // Custom subscriptions JSON.
        if let raw = environment.defaults.string(forKey: "customSubscriptionsJSON") {
            if let data = raw.data(using: .utf8),
               let list = try? JSONDecoder().decode([CustomSubscriptionConfig].self, from: data) {
                checks.append(DoctorCheck(
                    id: "custom_subscriptions", status: .ok,
                    message: "カスタムサービス設定は妥当です（\(list.count) 件）。",
                    details: .object([("count", .int(list.count))])
                ))
            } else {
                checks.append(DoctorCheck(
                    id: "custom_subscriptions", status: .error,
                    message: "カスタムサービス設定（customSubscriptionsJSON）の形式が不正です。"
                ))
            }
        } else {
            checks.append(DoctorCheck(
                id: "custom_subscriptions", status: .ok,
                message: "カスタムサービスは未設定です。"
            ))
        }

        // OpenAI API key: presence cannot be probed from another process
        // without risking a Keychain access prompt, so report it honestly
        // as unverified. The key's value is never read.
        checks.append(DoctorCheck(
            id: "openai_api_key", status: .unknown,
            message: "OpenAI API キーの保存有無は、OS の許可ダイアログを誘発せずに CLI から確認できないため未確認です。アプリの設定画面（OpenAI 詳細）で確認してください。値には触れていません。",
            details: .object([
                ("keychain_service", .string(configuration?.keychainService ?? "com.local.AIMeter")),
                ("account", .string("openaiAdminKey")),
                ("checked", .bool(false))
            ])
        ))

        // Legacy plaintext preference (presence only, never the value).
        let legacyPresent = (environment.defaults.string(forKey: "openaiAdminKey")?.isEmpty == false)
        checks.append(DoctorCheck(
            id: "legacy_openai_key",
            status: legacyPresent ? .warning : .ok,
            message: legacyPresent
                ? "旧設定にキーが残っています（値は表示しません）。アプリ設定の「キーの管理」から Keychain へ移行してください。"
                : "旧設定にキーは残っていません。"
        ))

        // GCP project (presence only).
        if preferences.gcpProjectId.isEmpty {
            checks.append(DoctorCheck(
                id: "gcp_project", status: .warning,
                message: "GCP プロジェクト ID が未設定のため、Gemini のクラウド同期は使えません（ローカル収集は可能です）。"
            ))
        } else {
            checks.append(DoctorCheck(
                id: "gcp_project", status: .ok,
                message: "GCP プロジェクト ID は設定済みです（値は表示しません）。"
            ))
        }

        var summary: [DoctorCheck.Status: Int] = [:]
        for check in checks { summary[check.status, default: 0] += 1 }
        let exitCode: Int32
        if checks.contains(where: { $0.isPermissionFailure }) {
            exitCode = 3
        } else if checks.contains(where: { $0.status == .error }) {
            exitCode = 2
        } else {
            exitCode = 0
        }

        let data: JSONValue = .object([
            ("checks", .array(checks.map(\.json))),
            ("summary", .object([
                ("ok", .int(summary[.ok] ?? 0)),
                ("warning", .int(summary[.warning] ?? 0)),
                ("error", .int(summary[.error] ?? 0)),
                ("unknown", .int(summary[.unknown] ?? 0))
            ]))
        ])
        let labels: [DoctorCheck.Status: String] = [.ok: "OK", .warning: "警告", .error: "エラー", .unknown: "未確認"]
        let human = checks.map { "[\(labels[$0.status] ?? "")] \($0.id): \($0.message)" }.joined(separator: "\n")
        return CLICommandResult(data: data, human: human, exitCode: exitCode)
    }
}
