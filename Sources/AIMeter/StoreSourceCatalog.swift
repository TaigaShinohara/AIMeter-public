import Foundation

/// Describes possible inputs only; it does not grant access, scan, or establish
/// whether an input can be used by a sandboxed App Store build.
enum StoreSourceCatalog {
    enum Requirement: Equatable {
        /// At least one primary input must be available to produce a result.
        /// A service can have several primary inputs and a partial result.
        case primary
        /// The primary source can provide a result without this supplement.
        case optional
    }

    enum SelectionKind: Equatable {
        case directory
        case file
    }

    struct Source: Equatable, Identifiable {
        /// Stable identity for one independently selectable access grant.
        let id: String
        let displayName: String
        let requirement: Requirement
        let selectionKind: SelectionKind
        /// Describes the missing information; it is not an access status.
        let missingDescription: String
    }

    struct Service: Equatable, Identifiable {
        /// Matches the existing provider ID; sources have independent IDs.
        let id: String
        let displayName: String
        let sources: [Source]
    }

    static let services: [Service] = [
        Service(id: "openai", displayName: "OpenAI / Codex", sources: [
            Source(id: "openai.sessions", displayName: "Codexのセッションログ",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "Codexのローカル使用量を取得できません。")
        ]),
        Service(id: "gemini", displayName: "Google Gemini", sources: [
            Source(id: "gemini.brain", displayName: "Antigravityのログ",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "Antigravityのログに含まれる使用量が集計に含まれません。"),
            Source(id: "gemini.chats", displayName: "Geminiのチャットログ",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "Geminiのチャットログに含まれる使用量が集計に含まれません。")
        ]),
        Service(id: "claude", displayName: "Claude Code", sources: [
            Source(id: "claude.logs", displayName: "Claudeのログ",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "Claudeのログから使用量を取得できません。"),
            Source(id: "claude.settings", displayName: "Claudeの補助設定JSON",
                   requirement: .optional, selectionKind: .file,
                   missingDescription: "ログ内の設定JSONが使えない場合、別の設定JSONによるプラン表示と使用量の補完ができません。")
        ]),
        Service(id: "grokbot", displayName: "Grok Bot", sources: [
            Source(id: "grokbot.persistence", displayName: "Grok Botの保存データ",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "Grok Botのローカル使用量と残量を取得できません。")
        ]),
        Service(id: "copilot", displayName: "GitHub Copilot", sources: [
            Source(id: "copilot.sessions", displayName: "Copilotのセッションログ",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "Copilotのローカル使用量を取得できません。")
        ]),
        Service(id: "windsurf", displayName: "Windsurf", sources: [
            Source(id: "windsurf.databaseDirectory", displayName: "Windsurfのデータベースフォルダ",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "データベースと隣接する更新データを読み取れず、Windsurfの使用量を取得できません。")
        ]),
        Service(id: "cursor", displayName: "Cursor", sources: [
            Source(id: "cursor.agentStores", displayName: "CursorのAgentStores保存先",
                   requirement: .primary, selectionKind: .directory,
                   missingDescription: "Cursorのローカル使用量を取得できません。")
        ])
    ]

    static func service(id: String) -> Service? {
        services.first { $0.id == id }
    }

    static func source(id: String) -> Source? {
        services.lazy.flatMap(\.sources).first { $0.id == id }
    }
}
