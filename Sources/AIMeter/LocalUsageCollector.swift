import Foundation
import SQLite3
import CryptoKit
import AIMeterCore

// MARK: - Native Local Usage Collector
/// Scans local AI tool sessions and storage directly on macOS with zero external Python dependency.
enum LocalUsageCollector {

    static let targetURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
    }()

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISODate(_ str: String) -> Date? {
        if let d = isoFormatterFractional.date(from: str) { return d }
        if let d = isoFormatterStandard.date(from: str) { return d }
        // Fallback for timestamps missing Z or non-standard
        let cleaned = str.replacingOccurrences(of: "Z", with: "+00:00")
        if let d = isoFormatterFractional.date(from: cleaned) { return d }
        if let d = isoFormatterStandard.date(from: cleaned) { return d }
        return nil
    }

    static func calculateCutoffs(now: Date = Date()) -> [String: Date] {
        return [
            "2h": now.addingTimeInterval(-2 * 3600),
            "5h": now.addingTimeInterval(-5 * 3600),
            "1d": now.addingTimeInterval(-24 * 3600),
            "7d": now.addingTimeInterval(-7 * 86400),
            "30d": now.addingTimeInterval(-30 * 86400)
        ]
    }

    private static func fileInfoIfPresent(at url: URL) throws -> stat? {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw BoundedInput.Failure.file
    }

    // MARK: - Validation Result Struct
    struct ProviderPathScanResult: Equatable {
        var isValid: Bool
        var message: String
        var previewCount: Int
        var statusNote: String?
    }

    // MARK: - Main Entrypoint
    @discardableResult
    static func collectAndSave(targetFileURL: URL? = nil, customPaths: [String: String] = [:],
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               limits: BoundedInput.Limits = .init()) async throws -> LocalUsageData {
        let now = Date()
        let cutoffs = calculateCutoffs(now: now)
        let destination = targetFileURL ?? targetURL

        // Run collector on utility queue
        let worker = Task.detached(priority: .utility) {
            let input = BoundedInput(limits: limits)
            var existingProviders: [String: CustomProviderUsageJSON] = [:]
            if let existingData = try input.dataIfPresent(at: destination),
               let existingRoot = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
               let provs = existingRoot["providers"] as? [String: Any] {
                let decoder = JSONDecoder()
                for (k, v) in provs {
                    // Foundation raises an Objective-C exception for scalars;
                    // Swift's try? cannot catch it. Preserve valid providers
                    // independently when another saved provider is malformed.
                    if let object = v as? [String: Any],
                       let d = try? JSONSerialization.data(withJSONObject: object),
                       let parsed = try? decoder.decode(CustomProviderUsageJSON.self, from: d) {
                        existingProviders[k] = parsed
                    }
                }
            }

            let codex = try collectCodex(now: now, cutoffs: cutoffs, customPath: customPaths["openai"] ?? customPaths["codex"], home: home, input: input)
            let gemini = try collectGemini(now: now, cutoffs: cutoffs, customPath: customPaths["gemini"], home: home, input: input)
            let claude = try collectClaude(now: now, cutoffs: cutoffs, customPath: customPaths["claude"], home: home, input: input)
            let grok = try collectGrokBot(now: now, cutoffs: cutoffs, customPath: customPaths["grokbot"], home: home, input: input)
            let copilot = try collectCopilot(now: now, cutoffs: cutoffs, customPath: customPaths["copilot"], home: home, input: input)
            let windsurf = try collectWindsurf(customPath: customPaths["windsurf"], home: home, input: input)
            let cursor = try collectCursor(now: now, cutoffs: cutoffs, customPath: customPaths["cursor"], home: home, input: input)

            existingProviders["claude"] = claude
            if let grok { existingProviders["grokbot"] = grok }
            if let copilot { existingProviders["copilot"] = copilot }
            if let windsurf { existingProviders["windsurf"] = windsurf }
            if let cursor { existingProviders["cursor"] = cursor }

            var detected = detectInstalledProviders(home: home)
            for (pid, cp) in customPaths where !cp.isEmpty {
                if !detected.contains(pid) {
                    detected.append(pid)
                }
            }

            let isoNow = isoFormatterStandard.string(from: now)
            let payload = LocalUsageData(
                openaiUsedTokens: codex.used.monthly ?? 0,
                openaiCostUSD: codex.cost,
                geminiUsedTokens: gemini.used.monthly ?? 0,
                geminiCostUSD: gemini.cost,
                openaiUsedByPeriod: codex.used,
                geminiUsedByPeriod: gemini.used,
                openaiServerUsedPercentByPeriod: codex.serverPct,
                openaiResetAtByPeriod: codex.resetAt,
                openaiPlanType: codex.planType,
                openaiCreditBalance: codex.creditBalance,
                providers: existingProviders,
                detectedProviders: detected,
                source: "local_logs_native",
                updatedAt: isoNow
            )

            try input.check()
            try payload.validateNumbers()
            try saveAtomically(payload: payload, to: destination)
            return payload
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    static func validateAndScanAsync(providerId: String, path: String) async -> ProviderPathScanResult {
        let worker = Task.detached(priority: .utility) { validateAndScan(providerId: providerId, path: path) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    // MARK: - Path Validation Helper
    static func validateAndScan(providerId: String, path: String,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                limits: BoundedInput.Limits = .init()) -> ProviderPathScanResult {
        do {
            return try scanPath(providerId: providerId, path: path, home: home, input: BoundedInput(limits: limits))
        } catch {
            return ProviderPathScanResult(isValid: false, message: error is CancellationError ? "検証を中止しました" : error.localizedDescription,
                                          previewCount: 0, statusNote: nil)
        }
    }

    private static func scanPath(providerId: String, path: String, home: URL, input: BoundedInput) throws -> ProviderPathScanResult {
        let expanded = (path as NSString).expandingTildeInPath
        var scanRootInfo = stat()
        guard Darwin.lstat(expanded, &scanRootInfo) == 0 else {
            return ProviderPathScanResult(isValid: false, message: "指定されたファイルまたはディレクトリが存在しません", previewCount: 0, statusNote: nil)
        }

        let now = Date()
        let cutoffs = calculateCutoffs(now: now)

        switch providerId.lowercased() {
        case "windsurf":
            if let ws = try collectWindsurf(customPath: expanded, home: home, input: input) {
                let msgs = ws.usedByPeriod?.monthly ?? 0
                return ProviderPathScanResult(
                    isValid: true,
                    message: "正常に読み込みました (\(msgs.formatted()) メッセージ)",
                    previewCount: msgs,
                    statusNote: ws.status
                )
            } else {
                return ProviderPathScanResult(isValid: false, message: "Windsurfの有効な state.vscdb が見つかりませんでした", previewCount: 0, statusNote: nil)
            }
        case "claude":
            let c = try collectClaude(now: now, cutoffs: cutoffs, customPath: expanded, home: home, input: input)
            let tokens = c.usedByPeriod?.monthly ?? 0
            if tokens > 0 {
                return ProviderPathScanResult(
                    isValid: true,
                    message: "正常に読み込みました (\(tokens.formatted()) tokens)",
                    previewCount: tokens,
                    statusNote: c.status
                )
            } else {
                return ProviderPathScanResult(isValid: true, message: "ディレクトリを確認しました（直近30日のログ: 0 tokens）", previewCount: 0, statusNote: c.status)
            }
        case "cursor":
            if let cur = try collectCursor(now: now, cutoffs: cutoffs, customPath: expanded, home: home, input: input) {
                let reqs = cur.usedByPeriod?.monthly ?? 0
                return ProviderPathScanResult(isValid: true, message: "正常に読み込みました (\(reqs) リクエスト)", previewCount: reqs, statusNote: cur.status)
            } else {
                return ProviderPathScanResult(isValid: false, message: "Cursorの有効なログが見つかりませんでした", previewCount: 0, statusNote: nil)
            }
        case "copilot":
            if let cop = try collectCopilot(now: now, cutoffs: cutoffs, customPath: expanded, home: home, input: input) {
                let reqs = cop.usedByPeriod?.monthly ?? 0
                return ProviderPathScanResult(isValid: true, message: "正常に読み込みました (\(reqs) リクエスト)", previewCount: reqs, statusNote: cop.status)
            } else {
                return ProviderPathScanResult(isValid: false, message: "Copilotの有効な events.jsonl が見つかりませんでした", previewCount: 0, statusNote: nil)
            }
        case "openai", "codex":
            let cod = try collectCodex(now: now, cutoffs: cutoffs, customPath: expanded, home: home, input: input)
            let tokens = cod.used.monthly ?? 0
            return ProviderPathScanResult(
                isValid: true,
                message: "正常に読み込みました (\(tokens.formatted()) tokens)",
                previewCount: tokens,
                statusNote: cod.planType ?? "実ログ"
            )
        case "gemini":
            let gem = try collectGemini(now: now, cutoffs: cutoffs, customPath: expanded, home: home, input: input)
            let tokens = gem.used.monthly ?? 0
            return ProviderPathScanResult(
                isValid: true,
                message: "正常に読み込みました (\(tokens.formatted()) tokens)",
                previewCount: tokens,
                statusNote: "実ログ"
            )
        case "grokbot":
            let grok = try collectGrokBot(now: now, cutoffs: cutoffs, customPath: expanded, home: home, input: input)
            return ProviderPathScanResult(isValid: grok != nil, message: grok == nil ? "Grokのログが見つかりませんでした" : "正常に読み込みました",
                                          previewCount: grok?.usedByPeriod?.monthly ?? 0, statusNote: grok?.status)
        default:
            return ProviderPathScanResult(isValid: true, message: "パスを確認しました（使用量の自動解析には未対応）", previewCount: 0, statusNote: nil)
        }
    }

    // MARK: - Save Atomically with 0600 Permissions
    static func saveAtomically(payload: LocalUsageData, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try BoundedInput.writeRegularFileAtomically(data, to: fileURL)
    }

    // MARK: - 1. Codex / OpenAI
    private static func collectCodex(now: Date, cutoffs: [String: Date], customPath: String? = nil, home: URL, input: BoundedInput) throws -> (
        used: ProviderPeriodUsageJSON,
        raw: ProviderPeriodUsageJSON,
        cost: Double,
        serverPct: ProviderPeriodPercentJSON?,
        resetAt: ProviderPeriodUsageJSON?,
        planType: String?,
        creditBalance: Double?
    ) {
        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var rawCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var cost30d: Double = 0.0

        var latestRL: [String: Any]?
        var latestRLTimestamp = ""

        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)
        let codexBase: URL
        if let cp = customPath, !cp.isEmpty {
            codexBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            codexBase = home.appendingPathComponent(".codex/sessions")
        }

        for fileURL in try input.files(at: codexBase) {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mdate = attrs.contentModificationDate,
                  mdate >= cutoff30d else { continue }

            var prevTuple: (inp: Int, cached: Int, out: Int)?

            try input.lines(at: fileURL, containing: "\"token_count\"") { line in
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count" else { return }

                let tsStr = obj["timestamp"] as? String ?? ""
                if let rl = payload["rate_limits"] as? [String: Any], tsStr > latestRLTimestamp {
                    latestRLTimestamp = tsStr
                    latestRL = rl
                }

                guard let info = payload["info"] as? [String: Any],
                      let tot = info["total_token_usage"] as? [String: Any],
                      !tsStr.isEmpty,
                      let dt = parseISODate(tsStr) else { return }

                let curIn = try UsageNumber.count(tot["input_tokens"])
                let curCached = try UsageNumber.count(tot["cached_input_tokens"])
                let curOut = try UsageNumber.count(tot["output_tokens"])
                let curTuple = (inp: curIn, cached: curCached, out: curOut)

                let dIn: Int
                let dCached: Int
                let dOut: Int

                if let prev = prevTuple {
                    if prev == curTuple { return }
                    dIn = try UsageNumber.difference(curIn, prev.inp)
                    dCached = try UsageNumber.difference(curCached, prev.cached)
                    dOut = try UsageNumber.difference(curOut, prev.out)
                } else {
                    dIn = curIn
                    dCached = curCached
                    dOut = curOut
                }
                prevTuple = curTuple

                let uncachedIn = try UsageNumber.difference(dIn, dCached)
                let effective = try UsageNumber.sum([uncachedIn, dOut, dCached / 10])
                let rawTot = try UsageNumber.add(dIn, dOut)

                for (k, cutoffDate) in cutoffs {
                    if dt >= cutoffDate {
                        usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], effective)
                        rawCounts[k] = try UsageNumber.add(rawCounts[k, default: 0], rawTot)
                    }
                }

                if dt >= cutoff30d {
                    cost30d = try UsageNumber.add(cost30d, (Double(uncachedIn) * 2.50 + Double(dCached) * 0.25 + Double(dOut) * 10.0) / 1_000_000.0)
                }
            }
        }

        var planType: String?
        var creditBalance: Double?
        var serverPctDict: [String: Double] = [:]
        var resetAtDict: [String: Int] = [:]

        if let rl = latestRL {
            planType = rl["plan_type"] as? String
            if let creds = rl["credits"] as? [String: Any], let rawBalance = creds["balance"] {
                creditBalance = try UsageNumber.nonnegative(rawBalance)
            }

            for slotKey in ["primary", "secondary"] {
                guard let slot = rl[slotKey] as? [String: Any] else { continue }
                let winMin = try UsageNumber.count(slot["window_minutes"])
                let usedPct = try slot["used_percent"].map { try UsageNumber.nonnegative($0) }
                let resetsAt = try slot["resets_at"].map { try UsageNumber.count($0) }

                let periodKey: String?
                switch winMin {
                case 90...150: periodKey = "2h"
                case 240...360: periodKey = "5h"
                case 1380...1500: periodKey = "1d"
                case 9500...10500: periodKey = "7d"
                case 40000...: periodKey = "30d"
                default: periodKey = nil
                }

                if let pk = periodKey {
                    if let pct = usedPct { serverPctDict[pk] = pct }
                    if let r = resetsAt { resetAtDict[pk] = r }
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )
        let rawJSON = ProviderPeriodUsageJSON(
            twoHours: rawCounts["2h"],
            fiveHours: rawCounts["5h"],
            daily: rawCounts["1d"],
            weekly: rawCounts["7d"],
            monthly: rawCounts["30d"]
        )
        let serverPctJSON = serverPctDict.isEmpty ? nil : ProviderPeriodPercentJSON(
            twoHours: serverPctDict["2h"],
            fiveHours: serverPctDict["5h"],
            daily: serverPctDict["1d"],
            weekly: serverPctDict["7d"],
            monthly: serverPctDict["30d"]
        )
        let resetAtJSON = resetAtDict.isEmpty ? nil : ProviderPeriodUsageJSON(
            twoHours: resetAtDict["2h"],
            fiveHours: resetAtDict["5h"],
            daily: resetAtDict["1d"],
            weekly: resetAtDict["7d"],
            monthly: resetAtDict["30d"]
        )

        return (
            used: usedJSON,
            raw: rawJSON,
            cost: round(cost30d * 100) / 100.0,
            serverPct: serverPctJSON,
            resetAt: resetAtJSON,
            planType: planType,
            creditBalance: creditBalance
        )
    }

    // MARK: - 2. Gemini
    private static func collectGemini(now: Date, cutoffs: [String: Date], customPath: String? = nil, home: URL, input: BoundedInput) throws -> (
        used: ProviderPeriodUsageJSON,
        raw: ProviderPeriodUsageJSON,
        cost: Double
    ) {
        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var rawCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var cost30d: Double = 0.0

        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)
        let agBrainBase: URL
        if let cp = customPath, !cp.isEmpty {
            agBrainBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            agBrainBase = home.appendingPathComponent(".gemini/antigravity/brain")
        }

        let transcriptFiles = try input.files(at: agBrainBase, allowedHiddenNames: [".system_generated"]).filter {
            $0.lastPathComponent == "transcript.jsonl" || $0.lastPathComponent == "transcript_full.jsonl"
        }
        let transcriptsBySession = Dictionary(grouping: transcriptFiles) {
            $0.deletingLastPathComponent().standardizedFileURL.path
        }
        for session in transcriptsBySession.keys.sorted() {
            try input.check()
            let files = (transcriptsBySession[session] ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Keep the larger multiplicity across the two files, rather than
            // collapsing genuine repetitions within a file or another session.
            // Different canonical payloads are intentionally not treated as copies.
            var unmatchedOccurrences: [Data: Int] = [:]
            for (index, fileURL) in files.enumerated() {
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate,
                      mdate >= cutoff30d else { continue }

                try input.lines(at: fileURL) { line in
                    guard line.contains("\"created_at\"") else { return }
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let tsStr = obj["created_at"] as? String,
                          let dt = parseISODate(tsStr) else { return }

                    let inp = try UsageNumber.count(obj["input_tokens"])
                    let cached = try UsageNumber.count(obj["cache_read_tokens"])
                    let out = try UsageNumber.count(obj["output_tokens"])

                    let effective: Int
                    let rawTot: Int
                    let stepCost: Double

                    if try UsageNumber.sum([inp, cached, out]) > 0 {
                        effective = try UsageNumber.sum([inp, out, cached / 10])
                        rawTot = try UsageNumber.sum([inp, cached, out])
                        stepCost = (Double(inp) * 1.25 + Double(cached) * 0.3125 + Double(out) * 5.0) / 1_000_000.0
                    } else {
                        let content = (obj["content"] as? String ?? "") + (obj["thinking"] as? String ?? "")
                        let est = max(1, content.count / 4)
                        effective = est
                        rawTot = est
                        stepCost = (Double(est) * 2.0) / 1_000_000.0
                    }

                    // Validate every row before copy selection, including duplicate
                    // candidates. Old rows cannot affect these rolling periods.
                    guard dt >= cutoff30d else { return }
                    if files.count > 1 {
                        let canonical = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
                        let fingerprint = Data(SHA256.hash(data: canonical))
                        try input.check()
                        if index == 0 {
                            if unmatchedOccurrences[fingerprint] == nil {
                                guard unmatchedOccurrences.count < input.limits.entries else { throw BoundedInput.Failure.limit }
                            }
                            unmatchedOccurrences[fingerprint] = try UsageNumber.add(unmatchedOccurrences[fingerprint, default: 0], 1)
                        } else if let remaining = unmatchedOccurrences[fingerprint], remaining > 0 {
                            unmatchedOccurrences[fingerprint] = remaining - 1
                            return
                        }
                    }

                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], effective)
                            rawCounts[k] = try UsageNumber.add(rawCounts[k, default: 0], rawTot)
                        }
                    }

                    if dt >= cutoff30d {
                        cost30d = try UsageNumber.add(cost30d, stepCost)
                    }
                }
            }
        }

        // Gemini tmp chats
        let chatsBase = home.appendingPathComponent(".gemini/tmp")
        for fileURL in try input.files(at: chatsBase) {
            guard fileURL.pathExtension == "json", fileURL.path.contains("/chats/") else { continue }
            guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mdate = attrs.contentModificationDate,
                  mdate >= cutoff30d else { continue }

            let fileData = try input.data(at: fileURL)
            guard
                  let root = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
                  let messages = root["messages"] as? [[String: Any]] else { continue }

            for msg in messages {
                try input.check()
                guard let tsStr = msg["timestamp"] as? String,
                      let dt = parseISODate(tsStr),
                      let tokens = msg["tokens"] as? [String: Any] else { continue }

                let tot = try UsageNumber.count(tokens["total"])
                let cached = try UsageNumber.count(tokens["cached"])
                let out = try UsageNumber.count(tokens["output"])
                let inp = try UsageNumber.count(tokens["input"])
                let uncachedIn = try UsageNumber.difference(inp, cached)
                let effective = try UsageNumber.sum([uncachedIn, out, cached / 10])

                for (k, cutoffDate) in cutoffs {
                    if dt >= cutoffDate {
                        usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], effective)
                        rawCounts[k] = try UsageNumber.add(rawCounts[k, default: 0], tot)
                    }
                }

                if dt >= cutoff30d {
                    cost30d = try UsageNumber.add(cost30d, (Double(uncachedIn) * 1.25 + Double(cached) * 0.3125 + Double(out) * 5.0) / 1_000_000.0)
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )
        let rawJSON = ProviderPeriodUsageJSON(
            twoHours: rawCounts["2h"],
            fiveHours: rawCounts["5h"],
            daily: rawCounts["1d"],
            weekly: rawCounts["7d"],
            monthly: rawCounts["30d"]
        )

        return (
            used: usedJSON,
            raw: rawJSON,
            cost: round(cost30d * 100) / 100.0
        )
    }

    // MARK: - 3. Claude
    private static func collectClaude(now: Date, cutoffs: [String: Date], customPath: String? = nil, home: URL, input: BoundedInput) throws -> CustomProviderUsageJSON {
        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var cost30d: Double = 0.0

        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)
        let claudeBase: URL
        if let cp = customPath, !cp.isEmpty {
            claudeBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            claudeBase = home.appendingPathComponent(".claude")
        }

        for dirName in [""] {
            let subDir = dirName.isEmpty ? claudeBase : claudeBase.appendingPathComponent(dirName)

            for fileURL in try input.files(at: subDir) {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate,
                      mdate >= cutoff30d else { continue }

                try input.lines(at: fileURL) { line in
                    guard line.contains("usage") else { return }
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }

                    let tsStr = (obj["timestamp"] as? String) ?? (obj["createdAt"] as? String) ?? ""
                    guard let dt = parseISODate(tsStr) else { return }

                    let msg = obj["message"] as? [String: Any]
                    let usage = (msg?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any]) ?? [:]

                    let inp = try UsageNumber.count(usage["input_tokens"])
                    let cached = try UsageNumber.count(usage["cache_read_input_tokens"])
                    let out = try UsageNumber.count(usage["output_tokens"])
                    let effective = try UsageNumber.sum([inp, out, cached / 10])
                    guard effective > 0 else { return }

                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], effective)
                        }
                    }

                    if dt >= cutoff30d {
                        cost30d = try UsageNumber.add(cost30d, (Double(inp) * 3.0 + Double(cached) * 0.30 + Double(out) * 15.0) / 1_000_000.0)
                    }
                }
            }
        }

        var statusLabel = "Pro"
        let claudeJSONPath = claudeBase.appendingPathComponent(".claude.json")
        let defaultClaudeJSON = home.appendingPathComponent(".claude.json")
        let cData = try input.dataIfPresent(at: claudeJSONPath)
            ?? (claudeJSONPath == defaultClaudeJSON ? nil : try input.dataIfPresent(at: defaultClaudeJSON))

        if let cData,
           let cObj = try? JSONSerialization.jsonObject(with: cData) as? [String: Any] {
            if let tier = cObj["claudeMaxTier"] as? String, tier != "not_max" {
                statusLabel = "Max (\(tier))"
            }
            if usedCounts["30d"] == 0, let projDict = cObj["projects"] as? [String: Any] {
                var totEff = 0
                var totCost: Double = 0.0
                for (_, pv) in projDict {
                    try input.check()
                    guard let pObj = pv as? [String: Any] else { continue }
                    let inp = try UsageNumber.count(pObj["lastTotalInputTokens"])
                    let out = try UsageNumber.count(pObj["lastTotalOutputTokens"])
                    let cw = try UsageNumber.count(pObj["lastTotalCacheCreationInputTokens"])
                    let cr = try UsageNumber.count(pObj["lastTotalCacheReadInputTokens"])
                    totEff = try UsageNumber.sum([totEff, inp, out, cw, cr / 10])
                    totCost = try UsageNumber.add(totCost, UsageNumber.nonnegative(pObj["lastCost"]))
                }
                if totEff > 0 {
                    usedCounts["30d"] = totEff
                    usedCounts["7d"] = totEff
                }
                if totCost > 0 {
                    cost30d = max(cost30d, totCost)
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: nil,
            resetAtByPeriod: nil,
            costUSD: cost30d > 0 ? round(cost30d * 100) / 100.0 : 0.0,
            status: statusLabel
        )
    }

    // MARK: - 4. GrokBot
    private static func collectGrokBot(now: Date, cutoffs: [String: Date], customPath: String? = nil, home: URL, input: BoundedInput) throws -> CustomProviderUsageJSON? {
        let appSupport: URL
        if let cp = customPath, !cp.isEmpty {
            appSupport = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            appSupport = home
                .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
        }
        let dotGrok = home.appendingPathComponent(".grokbot")

        let hasAppSupport = try fileInfoIfPresent(at: appSupport) != nil
        let hasDotGrok = try fileInfoIfPresent(at: dotGrok) != nil

        if !hasAppSupport && !hasDotGrok {
            return nil
        }

        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var serverPctDict: [String: Double] = [:]
        var resetAtDict: [String: Int] = [:]
        var costUSD: Double = 0.0
        var planLabel = "Grok Bot"

        if hasAppSupport {
            for fp in try input.files(at: appSupport) where fp.pathExtension == "blob" {
                let fn = fp.lastPathComponent
                let data = try input.data(at: fp)
                guard
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let val = root["value"] as? [String: Any] else { continue }

                // Base32 key decode to detect cache type
                let b32 = fn.replacingOccurrences(of: ".blob", with: "").uppercased()
                let decKey = decodeBase32(b32)

                if decKey.contains("weekly-usage.cache") {
                    if let reading = val["reading"] as? [String: Any],
                       let usage = reading["usage"] as? [String: Any] {
                        if let rawPercent = usage["percentUsed"] {
                            let pct = try UsageNumber.nonnegative(rawPercent)
                            serverPctDict["7d"] = round(pct * 100) / 100.0
                        }
                        if let rawReset = usage["nextResetMs"] {
                            resetAtDict["7d"] = try UsageNumber.count(rawReset) / 1000
                        }
                        if let onDemand = usage["onDemand"] as? [String: Any],
                           let rawCents = onDemand["usedCents"] {
                            let cents = try UsageNumber.nonnegative(rawCents)
                            costUSD = max(costUSD, round((cents / 100.0) * 100) / 100.0)
                        }
                        if let lbl = usage["grokPlanLabel"] as? String, !lbl.isEmpty {
                            planLabel = lbl
                        }
                    }
                } else if decKey.contains("transcript.replicas.") {
                    if let entries = val["entries"] as? [[String: Any]] {
                        for entry in entries {
                            try input.check()
                            guard let rawTimestamp = entry["timestampMs"] else { continue }
                            let tsMs = try UsageNumber.nonnegative(rawTimestamp)
                            let dt = Date(timeIntervalSince1970: tsMs / 1000.0)
                            let content = (entry["content"] as? String) ?? (entry["message"] as? String) ?? ""
                            let est = max(1, content.count / 3)
                            for (k, cutoffDate) in cutoffs {
                                if dt >= cutoffDate {
                                    usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], est)
                                }
                            }
                        }
                    }
                }
            }
        }

        if let pct = serverPctDict["7d"], usedCounts["7d"] == 0 {
            usedCounts["7d"] = try UsageNumber.roundedCount(10_000_000.0 * (pct / 100.0), rule: .towardZero)
            usedCounts["30d"] = max(usedCounts["30d"] ?? 0, usedCounts["7d"] ?? 0)
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )
        let serverPctJSON = serverPctDict.isEmpty ? nil : ProviderPeriodPercentJSON(
            twoHours: serverPctDict["2h"],
            fiveHours: serverPctDict["5h"],
            daily: serverPctDict["1d"],
            weekly: serverPctDict["7d"],
            monthly: serverPctDict["30d"]
        )
        let resetAtJSON = resetAtDict.isEmpty ? nil : ProviderPeriodUsageJSON(
            twoHours: resetAtDict["2h"],
            fiveHours: resetAtDict["5h"],
            daily: resetAtDict["1d"],
            weekly: resetAtDict["7d"],
            monthly: resetAtDict["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: serverPctJSON,
            resetAtByPeriod: resetAtJSON,
            costUSD: costUSD,
            status: planLabel
        )
    }

    // MARK: - 5. Windsurf (SQLite3)
    private static func collectWindsurf(customPath: String? = nil, home: URL, input: BoundedInput) throws -> CustomProviderUsageJSON? {
        let dbPath: URL
        if let cp = customPath, !cp.isEmpty {
            let u = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
            var uInfo = stat()
            if Darwin.lstat(u.path, &uInfo) != 0 {
                if errno == ENOENT || errno == ENOTDIR { return nil }
                throw BoundedInput.Failure.file
            }
            let uMode = uInfo.st_mode & S_IFMT
            if uMode == S_IFREG {
                dbPath = u
            } else if uMode == S_IFDIR {
                dbPath = u.appendingPathComponent("state.vscdb")
            } else {
                throw BoundedInput.Failure.file
            }
        } else {
            dbPath = home
                .appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        }

        var dbInfo = stat()
        if Darwin.lstat(dbPath.path, &dbInfo) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw BoundedInput.Failure.file
        }

        guard let data = try WindsurfDatabase.readPlan(at: dbPath, input: input) else { return nil }
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BoundedInput.Failure.database
        }

        let planName = (info["planName"] as? String) ?? "Pro"
        let usage = (info["usage"] as? [String: Any]) ?? [:]
        let usedMsgs = try UsageNumber.count(usage["usedMessages"])
        let totalMsgs = try UsageNumber.count(usage["messages"], default: 50000)

        let pct30d = totalMsgs > 0 ? round((Double(usedMsgs) / Double(totalMsgs)) * 10000.0) / 100.0 : 0.0

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: 0,
            fiveHours: 0,
            daily: 0,
            weekly: 0,
            monthly: usedMsgs
        )
        let serverPctJSON = pct30d > 0 ? ProviderPeriodPercentJSON(
            twoHours: nil, fiveHours: nil, daily: nil, weekly: nil, monthly: pct30d
        ) : nil

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: serverPctJSON,
            resetAtByPeriod: nil,
            costUSD: 0.0,
            status: "Windsurf \(planName)"
        )
    }

    // MARK: - 6. GitHub Copilot
    private static func collectCopilot(now: Date, cutoffs: [String: Date], customPath: String? = nil, home: URL, input: BoundedInput) throws -> CustomProviderUsageJSON? {
        let copilotBase: URL
        if let cp = customPath, !cp.isEmpty {
            copilotBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            copilotBase = home.appendingPathComponent(".copilot/session-state")
        }
        var copilotInfo = stat()
        if Darwin.lstat(copilotBase.path, &copilotInfo) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw BoundedInput.Failure.file
        }

        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)

        for fileURL in try input.files(at: copilotBase) {
            guard fileURL.lastPathComponent == "events.jsonl" else { continue }
            guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mdate = attrs.contentModificationDate,
                  mdate >= cutoff30d else { continue }

            var sessionReqByPeriod = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
            var snapCost: Double = 0.0
            var snapDate: Date?

            try input.lines(at: fileURL) { line in
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let evType = obj["type"] as? String else { return }

                let tsStr = obj["timestamp"] as? String ?? ""
                let dt = parseISODate(tsStr)

                if evType == "user.message", let dt {
                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            sessionReqByPeriod[k] = try UsageNumber.add(sessionReqByPeriod[k, default: 0], 1)
                        }
                    }
                } else if evType == "session.usage_checkpoint" {
                    if let data = obj["data"] as? [String: Any],
                       let snap = data["accountingSnapshot"] as? [String: Any],
                       let rawCost = snap["totalPremiumRequestCost"] {
                        snapCost = max(snapCost, try UsageNumber.nonnegative(rawCost))
                        if let dt { snapDate = dt }
                    }
                }
            }

            for (k, cutoffDate) in cutoffs {
                if snapCost > 0, let sd = snapDate, sd >= cutoffDate {
                    usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], max(try UsageNumber.roundedCount(snapCost), sessionReqByPeriod[k] ?? 0))
                } else {
                    usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], sessionReqByPeriod[k] ?? 0)
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: nil,
            resetAtByPeriod: nil,
            costUSD: 0.0,
            status: "Premium Reqs"
        )
    }

    // MARK: - 7. Cursor
    private static func collectCursor(now: Date, cutoffs: [String: Date], customPath: String? = nil, home: URL, input: BoundedInput) throws -> CustomProviderUsageJSON? {
        let cursorAppSupport: URL
        if let cp = customPath, !cp.isEmpty {
            cursorAppSupport = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            cursorAppSupport = home
                .appendingPathComponent("Library/Application Support/Cursor")
        }
        let dotCursor = home.appendingPathComponent(".cursor")

        let appSupportInfo = try fileInfoIfPresent(at: cursorAppSupport)
        let hasAppSupport = appSupportInfo != nil
        let hasDotCursor = try fileInfoIfPresent(at: dotCursor) != nil

        if !hasAppSupport && !hasDotCursor {
            return nil
        }

        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        if let appSupportInfo {
            let appMode = appSupportInfo.st_mode & S_IFMT
            guard appMode == S_IFDIR || appMode == S_IFREG else {
                throw BoundedInput.Failure.file
            }
            let controlDir = cursorAppSupport.appendingPathComponent("AgentStores/cursor_agent_stores/.control")
            let hasControl = appMode == S_IFDIR ? try fileInfoIfPresent(at: controlDir) != nil : false
            let pinsDir = hasControl ? controlDir : cursorAppSupport

            for fileURL in try input.files(at: pinsDir, includeHidden: true) {
                guard fileURL.pathExtension == "json" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate else { continue }

                for (k, cutoffDate) in cutoffs {
                    if mdate >= cutoffDate {
                        usedCounts[k] = try UsageNumber.add(usedCounts[k, default: 0], 1)
                    }
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: nil,
            resetAtByPeriod: nil,
            costUSD: 0.0,
            status: "Pro / Agent"
        )
    }

    // MARK: - Installed Providers Detection
    static func detectInstalledProviders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var detected: [String] = []
        let appSupport = home.appendingPathComponent("Library/Application Support")

        let checks: [(String, [URL])] = [
            ("grokbot", [home.appendingPathComponent(".grokbot"), appSupport.appendingPathComponent("Grok Bot")]),
            ("claude", [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude.json"), appSupport.appendingPathComponent("Claude")]),
            ("windsurf", [home.appendingPathComponent(".windsurf"), home.appendingPathComponent(".codeium"), appSupport.appendingPathComponent("Windsurf")]),
            ("copilot", [home.appendingPathComponent(".copilot")]),
            ("cursor", [home.appendingPathComponent(".cursor"), appSupport.appendingPathComponent("Cursor")]),
            ("trae", [home.appendingPathComponent(".trae-aicc"), appSupport.appendingPathComponent("Trae")])
        ]

        for (pid, paths) in checks {
            if paths.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                detected.append(pid)
            }
        }
        return detected
    }

    // MARK: - Simple Base32 Decoder
    private static func decodeBase32(_ input: String) -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0
        var value = 0
        var outputData = Data()

        for char in input {
            guard let idx = alphabet.firstIndex(of: char) else { continue }
            let val = alphabet.distance(from: alphabet.startIndex, to: idx)
            value = (value << 5) | val
            bits += 5
            if bits >= 8 {
                bits -= 8
                outputData.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
