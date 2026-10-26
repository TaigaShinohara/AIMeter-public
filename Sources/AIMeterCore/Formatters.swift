import Foundation

// MARK: - Unit & Path Hint Helpers
public func providerUnit(for providerId: String) -> String {
    let lower = providerId.lowercased()
    if lower.contains("windsurf") {
        return "msgs"
    } else if lower.contains("poe") {
        return "pts"
    } else if lower.contains("devin") {
        return "ACU"
    } else if lower.contains("cursor") || lower.contains("copilot") || lower.contains("perplexity") || lower.contains("trae") {
        return "req"
    }
    return "tokens"
}

public func defaultLogPathHint(for providerId: String) -> String {
    let lower = providerId.lowercased()
    if lower.contains("openai") || lower.contains("codex") {
        return "~/.codex/sessions"
    } else if lower.contains("gemini") {
        return "~/.gemini/antigravity/brain"
    } else if lower.contains("claude") {
        return "~/.claude"
    } else if lower.contains("windsurf") {
        return "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
    } else if lower.contains("cursor") {
        return "~/Library/Application Support/Cursor"
    } else if lower.contains("copilot") {
        return "~/.copilot/session-state"
    } else if lower.contains("grok") {
        return "~/Library/Application Support/Grok Bot/sand-client-persistence"
    }
    return "~/path/to/logs"
}

public func formatCompactUsage(_ count: Int, unit: String) -> String {
    return formatCompactTokenCount(count)
}

public func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.2fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000_000.0 * 1_000.0)
    } else {
        return "\(max(0, count))"
    }
}

public func formatCompactTokenCount(_ count: Int) -> String {
    if count >= 100_000_000 {
        return String(format: "%.0fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    } else if count >= 10_000 {
        return String(format: "%.0fK", Double(count) / 1_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000.0)
    } else {
        return "\(max(0, count))"
    }
}

public func formatResetTimestamp(_ epoch: Int?) -> String? {
    guard let epoch, epoch > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(epoch))
    let formatter = DateFormatter()
    if Calendar.current.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else {
        formatter.dateFormat = "MM/dd HH:mm"
    }
    return formatter.string(from: date)
}

public func formatRemainingTime(from epoch: Int?, now: Date = Date()) -> String? {
    guard let epoch, epoch > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(epoch))
    let diff = date.timeIntervalSince(now)

    if diff <= 0 {
        return "即時リセット"
    } else if diff < 3600 {
        let mins = max(1, Int((diff / 60.0).rounded()))
        return "あと\(mins)分"
    } else if diff < 86400 {
        let hrs = Int(diff / 3600.0)
        let mins = Int((diff.truncatingRemainder(dividingBy: 3600.0) / 60.0).rounded())
        return mins > 0 ? "あと\(hrs)時間\(mins)分" : "あと\(hrs)時間"
    } else {
        let days = Int(diff / 86400.0)
        let hrs = Int((diff.truncatingRemainder(dividingBy: 86400.0) / 3600.0).rounded())
        return hrs > 0 ? "あと\(days)日\(hrs)時間" : "あと\(days)日"
    }
}
