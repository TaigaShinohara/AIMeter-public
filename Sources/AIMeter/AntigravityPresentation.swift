import Foundation
import AIMeterCore

extension UsageMonitor {
    var antigravityMetrics: [PeriodUsageMetric] { antigravityMetrics(at: Date()) }

    func antigravityMetrics(at now: Date) -> [PeriodUsageMetric] {
        guard let snapshot = antigravityQuota,
              (-5...120).contains(now.timeIntervalSince(snapshot.fetchedAt)),
              !snapshot.windows.isEmpty else {
            return [.init(period: nil, usedTokens: 0, limitTokens: 0, requiresOfficialQuota: true,
                          quotaWindowID: "antigravity-unavailable", quotaWindowLabel: "利用枠", isQuotaOnly: true)]
        }
        return snapshot.windows.map { window in
            let reset = window.resetAt.flatMap { date -> Int? in
                let value = date.timeIntervalSince1970
                return value.isFinite && (0...253_402_300_799).contains(value) ? Int(value) : nil
            }
            let resetPassed = reset.map { Double($0) <= now.timeIntervalSince1970 } ?? false
            let fraction = window.remainingFraction.flatMap { value -> Double? in
                value.isFinite && (0...1).contains(value) && !window.isDisabled && !resetPassed ? value : nil
            }
            return .init(period: window.period, usedTokens: 0, limitTokens: 0,
                         serverUsedPercent: fraction.map { (1 - $0) * 100 },
                         resetTimestamp: reset,
                         requiresOfficialQuota: true, quotaWindowID: window.id,
                         quotaWindowLabel: window.title, isQuotaOnly: true,
                         resetDescription: window.isDisabled ? "この枠は利用できません" : window.resetDescription,
                         quotaExpiresAt: min(Int(snapshot.fetchedAt.timeIntervalSince1970 + 120), reset ?? Int.max))
        }
    }

    /// No credential files, OAuth flow or application launch is needed here.
    /// A failed refresh clears the previous quota, so it cannot look current.
    func refreshAntigravityQuota(
        fetch: () async throws -> AntigravityQuotaSnapshot = { try await AntigravityQuotaClient.fetch() }
    ) async {
        guard showAntigravitySection else {
            antigravityQuota = nil
            return
        }
        do {
            let snapshot = try await fetch()
            try Task.checkCancellation()
            antigravityQuota = snapshot
            antigravityStatus = "Antigravityから取得・ログイン中のアカウント"
            if !antigravityMetrics.contains(where: \.isRemainingAvailable) {
                antigravityStatus = "最新の残量を確認できません。もう一度更新してください"
            }
            recordUsageUpdate(at: snapshot.fetchedAt)
        } catch {
            antigravityQuota = nil
            antigravityStatus = error is CancellationError ? "更新を中断しました" :
                (error as? LocalizedError)?.errorDescription ?? "残量を取得できません。Antigravityの起動・ログインを確認して更新してください"
        }
    }
}
