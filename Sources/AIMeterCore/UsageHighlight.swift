import Foundation

/// Inputs retain every enabled period, including unavailable and invalid values.
public struct HighlightService {
    public let id: String
    public let name: String
    public let metrics: [PeriodUsageMetric]

    public init(id: String, name: String, metrics: [PeriodUsageMetric]) {
        self.id = id
        self.name = name
        self.metrics = metrics
    }
}

/// A deterministic, local-only message for the character at the top of the host card.
public struct UsageHighlight: Equatable {
    public enum Tone: Equatable {
        case calm, attention, urgent, checking
    }

    public let tone: Tone
    public let title: String
    public let message: String
    public let detail: String?
    public let serviceID: String?

    public init(tone: Tone, title: String, message: String, detail: String? = nil, serviceID: String? = nil) {
        self.tone = tone
        self.title = title
        self.message = message
        self.detail = detail
        self.serviceID = serviceID
    }

    public static func resolve(
        services: [HighlightService], hasData: Bool, updatedAt: Date?,
        isRefreshing: Bool, updateFailed: Bool, now: Date = Date()
    ) -> UsageHighlight {
        guard !services.isEmpty else {
            return .init(tone: .calm, title: "はじめよう", message: "設定で、表示するサービスを選ぼう。")
        }
        guard hasData else {
            if isRefreshing {
                return .init(tone: .checking, title: "確認中", message: "最初のデータを確認しているよ。")
            }
            return .init(tone: updateFailed ? .attention : .calm, title: updateFailed ? "取得できなかったよ" : "こんにちは",
                         message: "右上の更新ボタンで、残量を確認してみよう。")
        }

        let entries = services.flatMap { service in service.metrics.map { (service: service, metric: $0) } }
        let hasInvalid = entries.contains { !$0.metric.isValid } || services.contains { $0.metrics.isEmpty }
        let hasUnavailable = entries.contains { $0.metric.isValid && !$0.metric.isRemainingAvailable }
        let candidates = entries.filter { $0.metric.isRemainingAvailable }.sorted {
            if $0.metric.remainingRatio != $1.metric.remainingRatio {
                return $0.metric.remainingRatio < $1.metric.remainingRatio
            }
            if $0.service.id != $1.service.id { return $0.service.id < $1.service.id }
            return periodOrder($0.metric.period) < periodOrder($1.metric.period)
        }
        // This is the host's last acquisition time, not a per-provider freshness guarantee.
        let isOld = updatedAt.map { now.timeIntervalSince($0) >= 300 || $0 > now } ?? true
        let hasPassedReset = candidates.contains { entry in
            entry.metric.resetTimestamp.map { Double($0) <= now.timeIntervalSince1970 } ?? false
        }
        var notes: [String] = []
        if isRefreshing {
            notes.append("表示中の値を更新しているよ。")
        } else if updateFailed {
            notes.append("更新できなかったので、右上の更新で確認してね。")
        } else if isOld {
            notes.append("しばらく確認できていないので、右上から更新してね。")
        }
        if hasPassedReset { notes.append("リセット予定を過ぎた枠は、再確認が必要だよ。") }
        if hasInvalid { notes.append("数値を確認できない枠もあるよ。") }
        if hasUnavailable { notes.append("残量が未取得の枠もあるよ。") }

        if let lowest = candidates.first, lowest.metric.remainingRatio < 0.35 {
            let metric = lowest.metric
            let previous = updateFailed || isOld || isRefreshing || hasPassedReset
            let amount = metric.remainingRatio > 0 && metric.remainingPercent == 0
                ? "1%未満" : "\(metric.remainingPercent)%"
            let subject = "\(lowest.service.name)の\(metric.displayLabel)枠"
            let qualifier = metric.remainingSource == .configuredLimit ? "設定上限の目安は" : ""
            let sentence = "\(previous ? "前回は" : "")\(subject)、\(qualifier)残り\(amount)\(previous ? "だったよ。" : "だよ。")"
            return .init(tone: metric.remainingRatio < 0.15 ? .urgent : .attention,
                         title: metric.remainingRatio < 0.15 ? "残りわずか" : "少なくなってきたよ",
                         message: sentence, detail: notes.isEmpty ? nil : notes.joined(separator: " "),
                         serviceID: lowest.service.id)
        }
        if updateFailed || isOld || hasPassedReset {
            return .init(tone: .attention, title: isRefreshing ? "確認中" : "もう一度確認しよう",
                         message: "今の残量は、更新してから確認しよう。",
                         detail: notes.isEmpty ? nil : notes.joined(separator: " "))
        }
        if hasInvalid || hasUnavailable || candidates.isEmpty {
            return .init(tone: .checking, title: "まだ分からない枠があるよ",
                         message: "残量を確認できない枠があるよ。全枠表示で見てね。",
                         detail: isRefreshing ? "表示中の値を更新しているよ。" : nil)
        }
        let hasEstimates = candidates.contains { $0.metric.remainingSource == .configuredLimit }
        return .init(tone: .calm, title: "ひとこと",
                     message: hasEstimates ? "確認できた枠の目安は、どれも残り35%以上だよ。" : "確認できた枠は、どれも残り35%以上だよ。",
                     detail: [hasEstimates ? "設定上限からの目安を含むよ。" : nil,
                              isRefreshing ? "表示中の値を更新しているよ。" : nil].compactMap { $0 }.joinedOrNil())
    }

    private static func periodOrder(_ period: LimitPeriod?) -> Int {
        guard let period else { return LimitPeriod.allCases.count }
        return LimitPeriod.allCases.firstIndex(of: period) ?? 0
    }
}

private extension Array where Element == String {
    func joinedOrNil() -> String? { isEmpty ? nil : joined(separator: " ") }
}
