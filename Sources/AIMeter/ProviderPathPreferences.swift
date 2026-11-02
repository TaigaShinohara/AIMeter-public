import Foundation

enum ProviderPathPreferences {
    /// Preserve path semantics while avoiding an unnecessary copy of the
    /// account name. The separator prevents /Users/name-other matching name.
    static func stored(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        guard !base.isEmpty else { return value }
        if value == base { return "~" }
        if value.hasPrefix(base + "/") { return "~" + value.dropFirst(base.count) }
        return value
    }
}
