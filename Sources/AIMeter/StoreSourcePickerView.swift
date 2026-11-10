import AppKit
import SwiftUI

/// Standalone selection UI. It does not scan, validate, or start collection.
/// The host must implement `performChange` as a synchronization boundary.
/// It must invalidate/cancel existing work before executing the operation and
/// serialize the operation with result persistence, then return after it ends.
@MainActor
struct StoreSourcePickerView: View {
    let service: StoreSourceCatalog.Service
    let bookmarks: StoreBookmarkStore
    /// The host decides how to advance or return to service settings.
    let onDefer: (String) -> Void
    /// The host executes the supplied operation once within its shared gate.
    /// Throwing before the operation leaves the saved selection unchanged.
    let performChange: (_ sourceID: String, _ operation: @escaping () throws -> Void) async throws -> Void

    @State private var notices: [String: String] = [:]
    @State private var statuses: [String: StoreBookmarkStore.SelectionStatus] = [:]
    @State private var isChanging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(service.displayName)の読み取り先")
                .font(.headline)
            Text("利用状況を集計するため、読み取る場所を選びます。後で設定することもできます。")
                .fixedSize(horizontal: false, vertical: true)
            Text("保存した選択を表示します。場所を読み取れるか、利用データを取得できるかは確認していません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("隠しフォルダは、選択画面で Command + Shift + . を押すと表示できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("ログには会話内容が含まれる場合があります。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(service.sources) { source in
                sourceSection(source)
            }
        }
        .onAppear { refreshStatuses() }
    }

    private func sourceSection(_ source: StoreSourceCatalog.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.displayName).font(.subheadline.weight(.semibold))
            Text(purpose(for: source))
                .fixedSize(horizontal: false, vertical: true)
            Text("選ばない場合：\(source.missingDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(statusText(statuses[source.id]))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = notices[source.id] {
                Text(notice)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(source.selectionKind == .directory ? "フォルダを選択…" : "ファイルを選択…") {
                    choose(source)
                }
                Button("後で設定") { onDefer(source.id) }
                Button("選択を解除") {
                    change(source.id) { bookmarks.remove(sourceID: source.id) }
                }
            }
            .disabled(isChanging)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func choose(_ source: StoreSourceCatalog.Source) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = source.selectionKind == .directory
        panel.canChooseFiles = source.selectionKind == .file
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "選択"
        panel.message = "\(source.displayName)を選択してください。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change(source.id) { try bookmarks.save(url, sourceID: source.id) }
    }

    private func change(_ id: String, operation: @escaping () throws -> Void) {
        isChanging = true
        Task { @MainActor in
            do {
                try await performChange(id, operation)
                notices[id] = "選択を更新しました。読み取りは未確認です。"
            } catch {
                notices[id] = "選択の変更を完了できませんでした。保存状態を確認してください。"
            }
            refreshStatuses()
            isChanging = false
        }
    }

    private func refreshStatuses() {
        for source in service.sources {
            statuses[source.id] = bookmarks.selectionStatus(sourceID: source.id)
        }
    }

    private func statusText(_ status: StoreBookmarkStore.SelectionStatus?) -> String {
        switch status {
        case .none: return "保存した選択を確認中です。"
        case .some(.unselected): return "保存した選択はありません。"
        case .some(.saved(let url)): return "保存した選択：\(url.path)（読み取りは未確認）"
        case .some(.needsReselection): return "保存した選択を確認できません。再選択してください。"
        }
    }

    private func purpose(for source: StoreSourceCatalog.Source) -> String {
        switch source.id {
        case "openai.sessions": return "Codexのセッションログから使用量を集計します。通常は .codex/sessions フォルダを選びます。"
        case "gemini.brain": return "Antigravityのログから使用量を集計します。通常は .gemini/antigravity/brain フォルダを選びます。"
        case "gemini.chats": return "Geminiのチャットログから使用量を集計します。通常は .gemini/tmp フォルダを選びます。"
        case "claude.logs": return "Claudeのログから使用量を集計します。通常は .claude フォルダを選びます。"
        case "claude.settings": return "ログ内の設定を使えない場合に、プラン表示や使用量の補完に使います。必要ならホーム直下の .claude.json を選びます。"
        case "grokbot.persistence": return "Grok Botの保存データから使用量などを集計します。通常は ~/Library/Application Support/Grok Bot/sand-client-persistence フォルダを選びます。"
        case "copilot.sessions": return "Copilotのセッションログから使用量を集計します。通常は .copilot/session-state フォルダを選びます。"
        case "windsurf.databaseDirectory": return "データベースと隣接する更新データを読みます。通常は ~/Library/Application Support/Windsurf/User/globalStorage フォルダを選びます。"
        case "cursor.agentStores": return "CursorのAgentStoresのデータから使用状況を集計します。通常は ~/Library/Application Support/Cursor フォルダを選びます。"
        default: return "この入力元から利用状況を集計します。"
        }
    }
}
