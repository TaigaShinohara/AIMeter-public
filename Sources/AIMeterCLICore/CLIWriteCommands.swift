import Foundation
import CoreFoundation
import AIMeterCore

/// Write-side commands (`update`) and the self-check (`verify`).
///
/// `update service` writes to exactly the stores the GUI writes to: the
/// same UserDefaults keys for built-in services (`showOpenAISection`,
/// `showGeminiSection`, `showAntigravitySection`, mirroring the app's
/// `@AppStorage` declarations) and the same `customSubscriptionsJSON`
/// document for custom services. No CLI-only store is introduced for the
/// settings themselves. The only CLI-owned file is the idempotency ledger
/// (`.ai_meter_cli_idempotency.json` next to the data files), which records
/// the *result* of an `update` per `--idempotency-key` so a retried run
/// returns the first result instead of applying the change twice.
extension CLIContext {

    // MARK: Idempotency ledger

    public var idempotencyLedgerURL: URL {
        environment.dataDirectory.appendingPathComponent(".ai_meter_cli_idempotency.json")
    }

    public struct IdempotencyRecord: Codable, Equatable {
        public var serviceID: String
        public var enabled: Bool
        public var changed: Bool
        public var appliedAt: String

        public init(serviceID: String, enabled: Bool, changed: Bool, appliedAt: String) {
            self.serviceID = serviceID
            self.enabled = enabled
            self.changed = changed
            self.appliedAt = appliedAt
        }

        enum CodingKeys: String, CodingKey {
            case serviceID = "service_id"
            case enabled
            case changed
            case appliedAt = "applied_at"
        }
    }

    public struct IdempotencyLedger: Codable, Equatable {
        public var records: [String: IdempotencyRecord] = [:]
    }

    /// A missing or unreadable ledger is treated as empty: the worst case
    /// is that a retried update applies again, and applying an enable /
    /// disable is itself idempotent (it converges to the target state).
    public func loadIdempotencyLedger() -> IdempotencyLedger {
        guard let data = try? Data(contentsOf: idempotencyLedgerURL),
              let ledger = try? JSONDecoder().decode(IdempotencyLedger.self, from: data) else {
            return IdempotencyLedger()
        }
        return ledger
    }

    @discardableResult
    public func saveIdempotencyLedger(_ ledger: IdempotencyLedger) -> Bool {
        guard let data = try? JSONEncoder().encode(ledger) else { return false }
        return (try? data.write(to: idempotencyLedgerURL, options: [.atomic])) != nil
    }

    // MARK: update service

    /// The UserDefaults key the GUI binds each built-in service's enable
    /// toggle to. Custom services have no key: their flag lives inside
    /// `customSubscriptionsJSON`.
    public static func preferenceKey(forBuiltinServiceID id: String) -> String? {
        switch id {
        case "openai": return "showOpenAISection"
        case "gemini": return "showGeminiSection"
        case "antigravity": return "showAntigravitySection"
        default: return nil
        }
    }

    public func runUpdateService(
        serviceID: String,
        enabled: Bool,
        dryRun: Bool,
        idempotencyKey: String?
    ) throws -> CLICommandResult {
        let services = serviceList()
        guard let service = services.first(where: { $0.id == serviceID }) else {
            throw CLIError.notFound(
                "サービスが見つかりません: \(serviceID)",
                details: .object([("known_ids", .array(services.map { .string($0.id) }))])
            )
        }
        let previous = service.isEnabled
        let changed = previous != enabled

        // Idempotency: a recorded key replays its first result without
        // touching the stores again; the same key with different
        // parameters is a caller error.
        if let key = idempotencyKey, let record = loadIdempotencyLedger().records[key] {
            guard record.serviceID == serviceID, record.enabled == enabled else {
                throw CLIError.idempotencyConflict(
                    key: key, recordedServiceID: record.serviceID, recordedEnabled: record.enabled
                )
            }
            let data = updateResultJSON(
                service: service, previousEnabled: previous, enabled: enabled,
                changed: record.changed, dryRun: dryRun, idempotentReplay: true,
                idempotencyKey: key, idempotencyRecorded: true
            )
            return CLICommandResult(data: data, human: updateHumanLine(
                service: service, previousEnabled: previous, enabled: enabled,
                changed: record.changed, dryRun: dryRun, idempotentReplay: true
            ))
        }

        if dryRun {
            let data = updateResultJSON(
                service: service, previousEnabled: previous, enabled: enabled,
                changed: changed, dryRun: true, idempotentReplay: false,
                idempotencyKey: idempotencyKey, idempotencyRecorded: false
            )
            return CLICommandResult(data: data, human: updateHumanLine(
                service: service, previousEnabled: previous, enabled: enabled,
                changed: changed, dryRun: true, idempotentReplay: false
            ))
        }

        if changed {
            try applyEnabled(enabled, to: service)
            _ = environment.defaults.synchronize()
        }

        var recorded = false
        if let key = idempotencyKey {
            var ledger = loadIdempotencyLedger()
            ledger.records[key] = IdempotencyRecord(
                serviceID: serviceID, enabled: enabled, changed: changed,
                appliedAt: isoString(from: Date())
            )
            recorded = saveIdempotencyLedger(ledger)
        }

        let updated = serviceList().first(where: { $0.id == serviceID }) ?? service
        let data = updateResultJSON(
            service: updated, previousEnabled: previous, enabled: enabled,
            changed: changed, dryRun: false, idempotentReplay: false,
            idempotencyKey: idempotencyKey, idempotencyRecorded: recorded
        )
        return CLICommandResult(data: data, human: updateHumanLine(
            service: updated, previousEnabled: previous, enabled: enabled,
            changed: changed, dryRun: false, idempotentReplay: false
        ))
    }

    private func applyEnabled(_ enabled: Bool, to service: ServiceUsage) throws {
        if let key = Self.preferenceKey(forBuiltinServiceID: service.id) {
            environment.defaults.set(enabled, forKey: key)
            return
        }
        // Custom service: rewrite the same JSON document the GUI saves.
        // A document that exists but does not decode is never overwritten:
        // replacing it would silently drop every custom service.
        let raw = environment.defaults.string(forKey: "customSubscriptionsJSON")
        var list = customSubscriptions()
        if raw != nil, list.isEmpty {
            // loadCustomSubscriptions collapses decode failure to []; a
            // non-empty raw value that yields no entries here can also be
            // a legitimately empty "[]", so re-check by decoding directly.
            let decodes = raw.flatMap { $0.data(using: .utf8) }
                .map { (try? JSONDecoder().decode([CustomSubscriptionConfig].self, from: $0)) != nil } ?? false
            guard decodes else {
                throw CLIError.appFailure(
                    "カスタムサービス設定（customSubscriptionsJSON）の形式が不正なため、書き込めませんでした。設定を失わないよう、アプリの設定画面で確認してください。",
                    code: "custom_subscriptions_invalid"
                )
            }
        }
        guard let index = list.firstIndex(where: { $0.id == service.id }) else {
            throw CLIError.appFailure(
                "カスタムサービス \(service.id) の設定が見つかりませんでした。",
                code: "custom_subscriptions_invalid"
            )
        }
        list[index].isEnabled = enabled
        guard let data = try? JSONEncoder().encode(list),
              let string = String(data: data, encoding: .utf8) else {
            throw CLIError.appFailure("カスタムサービス設定の保存に失敗しました。", code: "custom_subscriptions_invalid")
        }
        environment.defaults.set(string, forKey: "customSubscriptionsJSON")
    }

    private func updateResultJSON(
        service: ServiceUsage,
        previousEnabled: Bool,
        enabled: Bool,
        changed: Bool,
        dryRun: Bool,
        idempotentReplay: Bool,
        idempotencyKey: String?,
        idempotencyRecorded: Bool
    ) -> JSONValue {
        .object([
            ("service", serviceJSON(service)),
            ("service_id", .string(service.id)),
            ("previous_enabled", .bool(previousEnabled)),
            ("enabled", .bool(enabled)),
            ("changed", .bool(changed)),
            ("dry_run", .bool(dryRun)),
            ("idempotent_replay", .bool(idempotentReplay)),
            ("idempotency_key", idempotencyKey.map { .string($0) } ?? .null),
            ("idempotency_recorded", .bool(idempotencyRecorded)),
            ("note", .string("設定はアプリと同じ保存先（GitHub 配布版の設定ドメイン）に書き込まれます。アプリ実行中の場合は、アプリ側の設定読み取り・再起動のタイミングで反映されます。"))
        ])
    }

    private func updateHumanLine(
        service: ServiceUsage,
        previousEnabled: Bool,
        enabled: Bool,
        changed: Bool,
        dryRun: Bool,
        idempotentReplay: Bool
    ) -> String {
        let state: (Bool) -> String = { $0 ? "有効" : "無効" }
        if idempotentReplay {
            return "\(service.name) (\(service.id)): 冪等キーにより前回の結果を返しました（現在 \(state(enabled))、前回の変更 \(changed ? "あり" : "なし")）"
        }
        if dryRun {
            return "ドライラン: \(service.name) (\(service.id)): \(state(previousEnabled)) → \(state(enabled))（\(changed ? "変更されます" : "変更なし")）"
        }
        return "\(service.name) (\(service.id)): \(state(previousEnabled)) → \(state(enabled))（\(changed ? "変更しました" : "変更なし・既にその状態です")）"
    }

    // MARK: verify

    public struct VerifyCheck {
        public var id: String
        public var status: Status
        public var message: String
        public var remedy: String?

        public enum Status: String {
            case pass, fail, skipped
        }

        public init(id: String, status: Status, message: String, remedy: String? = nil) {
            self.id = id
            self.status = status
            self.message = message
            self.remedy = remedy
        }

        public var json: JSONValue {
            var pairs: [(String, JSONValue)] = [
                ("id", .string(id)),
                ("status", .string(status.rawValue)),
                ("message", .string(message))
            ]
            if let remedy {
                pairs.append(("remedy", .string(remedy)))
            }
            return .object(pairs)
        }
    }

    /// Data-integrity and precondition self-check over everything the CLI
    /// itself can judge from the shared stores. Read-only. Passes with
    /// exit 0; any failure throws `verification_failed` (exit 2) with the
    /// per-check reasons and remedies in the error details.
    public func runVerify() throws -> CLICommandResult {
        let fileManager = FileManager.default
        var checks: [VerifyCheck] = []

        // Distribution configuration resolves.
        if (try? DistributionConfiguration.current()) != nil {
            checks.append(VerifyCheck(id: "distribution", status: .pass, message: "配布設定は direct（GitHub 配布版）として解決できます。"))
        } else {
            checks.append(VerifyCheck(
                id: "distribution", status: .fail,
                message: "配布設定を解決できませんでした。",
                remedy: "アプリの配布形態と Info.plist の AIMeterDistribution を確認してください。"
            ))
        }

        // Usage snapshot decodes when present.
        if !fileManager.fileExists(atPath: usageFileURL.path) {
            checks.append(VerifyCheck(id: "usage_file", status: .skipped, message: "収集スナップショットはまだありません（アプリ未起動では正常です）。"))
        } else if usageData() != nil {
            checks.append(VerifyCheck(id: "usage_file", status: .pass, message: "収集スナップショットはデコードできます。"))
        } else {
            checks.append(VerifyCheck(
                id: "usage_file", status: .fail,
                message: "収集スナップショットはありますが、デコードできません（破損の可能性があります）。",
                remedy: "\(usageFileURL.path) を削除してアプリを起動し直すと再収集されます。残したい場合はファイルを退避してから削除してください。"
            ))
        }

        // Widget snapshot: decodable and on the current schema version.
        if !fileManager.fileExists(atPath: widgetFileURL.path) {
            checks.append(VerifyCheck(id: "widget_file", status: .skipped, message: "ウィジェット共有ファイルはまだありません（アプリが未書き込みの状態です）。"))
        } else if let data = try? BoundedInput().data(at: widgetFileURL),
                  (try? JSONSerialization.jsonObject(with: data)) != nil,
                  (try? JSONDecoder().decode(AIMeterWidgetSnapshot.self, from: data)) != nil {
            if let version = rawWidgetSchemaVersion(), version != 4 {
                checks.append(VerifyCheck(
                    id: "widget_file", status: .fail,
                    message: "ウィジェット共有ファイルのスキーマ版数は \(version) です（現行は 4）。",
                    remedy: "アプリを現行版で起動し直すと、共有ファイルが現行スキーマで書き直されます。"
                ))
            } else {
                checks.append(VerifyCheck(id: "widget_file", status: .pass, message: "ウィジェット共有ファイルはデコードでき、スキーマ版数は現行（4）です。"))
            }
        } else {
            checks.append(VerifyCheck(
                id: "widget_file", status: .fail,
                message: "ウィジェット共有ファイルはありますが、デコードできません（破損の可能性があります）。",
                remedy: "\(widgetFileURL.path) を削除してアプリを起動し直すと再生成されます。"
            ))
        }

        // Custom subscriptions: decodable, no duplicate ids, no collision
        // with built-in ids.
        let builtinIDs: Set<String> = ["openai", "gemini", "antigravity"]
        if let raw = environment.defaults.string(forKey: "customSubscriptionsJSON") {
            if let data = raw.data(using: .utf8),
               let list = try? JSONDecoder().decode([CustomSubscriptionConfig].self, from: data) {
                let ids = list.map(\.id)
                let duplicates = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
                let collisions = Set(ids).intersection(builtinIDs)
                if !duplicates.isEmpty || !collisions.isEmpty {
                    var problems: [String] = []
                    if !duplicates.isEmpty { problems.append("重複 ID: \(duplicates.sorted().joined(separator: ", "))") }
                    if !collisions.isEmpty { problems.append("組み込み ID との衝突: \(collisions.sorted().joined(separator: ", "))") }
                    checks.append(VerifyCheck(
                        id: "custom_subscriptions", status: .fail,
                        message: "カスタムサービス設定に ID の問題があります（\(problems.joined(separator: " / "))）。",
                        remedy: "アプリの設定画面で対象サービスの削除と追加をやり直すか、customSubscriptionsJSON を直接修正してください。"
                    ))
                } else {
                    checks.append(VerifyCheck(id: "custom_subscriptions", status: .pass, message: "カスタムサービス設定はデコードでき、ID の重複・衝突はありません（\(list.count) 件）。"))
                }
            } else {
                checks.append(VerifyCheck(
                    id: "custom_subscriptions", status: .fail,
                    message: "カスタムサービス設定（customSubscriptionsJSON）がデコードできません。",
                    remedy: "アプリの設定画面でカスタムサービスを確認してください。修復できない場合は customSubscriptionsJSON を削除すると初期状態に戻ります（カスタム設定は失われます）。"
                ))
            }
        } else {
            checks.append(VerifyCheck(id: "custom_subscriptions", status: .pass, message: "カスタムサービスは未設定です。"))
        }

        // Preference value shapes the GUI relies on: the integration
        // toggles must be real booleans when present (a malformed value is
        // treated as "not permitted" by the app's own reader).
        var preferenceProblems: [String] = []
        for key in ["showOpenAISection", "showGeminiSection"] {
            if let value = environment.defaults.object(forKey: key) {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    preferenceProblems.append("\(key) が真偽値ではありません")
                    continue
                }
            }
        }
        let validPeriods = Set(LimitPeriod.allCases.map(\.rawValue))
        for key in ["openaiEnabledPeriodsCSV", "geminiEnabledPeriodsCSV"] {
            if let csv = environment.defaults.string(forKey: key) {
                let tokens = csv.split(separator: ",").map(String.init)
                if tokens.isEmpty || !tokens.allSatisfy({ validPeriods.contains($0) }) {
                    preferenceProblems.append("\(key) に未知の期間が含まれます")
                }
            }
        }
        if preferenceProblems.isEmpty {
            checks.append(VerifyCheck(id: "preferences", status: .pass, message: "設定値の形式（連携トグルと期間の指定）は妥当です。"))
        } else {
            checks.append(VerifyCheck(
                id: "preferences", status: .fail,
                message: "設定値に形式の問題があります（\(preferenceProblems.joined(separator: " / "))）。",
                remedy: "アプリの設定画面で対象サービスのトグルと期間を切り替え直すと、正しい形式で保存し直されます。"
            ))
        }

        // Service ids unique across the derived list.
        let services = serviceList()
        let serviceIDs = services.map(\.id)
        if Set(serviceIDs).count == serviceIDs.count {
            checks.append(VerifyCheck(id: "service_ids", status: .pass, message: "サービス ID は一意です（\(serviceIDs.count) 件）。"))
        } else {
            let duplicates = Set(serviceIDs.filter { id in serviceIDs.filter { $0 == id }.count > 1 })
            checks.append(VerifyCheck(
                id: "service_ids", status: .fail,
                message: "サービス ID に重複があります（\(duplicates.sorted().joined(separator: ", "))）。",
                remedy: "カスタムサービス設定の重複を解消してください。"
            ))
        }

        let failures = checks.filter { $0.status == .fail }
        let summary: JSONValue = .object([
            ("pass", .int(checks.filter { $0.status == .pass }.count)),
            ("fail", .int(failures.count)),
            ("skipped", .int(checks.filter { $0.status == .skipped }.count))
        ])
        if !failures.isEmpty {
            throw CLIError(
                code: "verification_failed",
                message: "verify: \(failures.count) 件の不整合が見つかりました（\(failures.map(\.id).joined(separator: ", "))）。",
                exitCode: 2,
                details: .object([
                    ("passed", .bool(false)),
                    ("checks", .array(checks.map(\.json))),
                    ("summary", summary)
                ])
            )
        }
        let data: JSONValue = .object([
            ("passed", .bool(true)),
            ("checks", .array(checks.map(\.json))),
            ("summary", summary)
        ])
        let human = checks.map { check -> String in
            let label: String
            switch check.status {
            case .pass: label = "合格"
            case .fail: label = "不合格"
            case .skipped: label = "対象外"
            }
            return "[\(label)] \(check.id): \(check.message)"
        }.joined(separator: "\n")
        return CLICommandResult(data: data, human: "verify: 合格\n" + human)
    }
}
