import Foundation

/// Help texts. Every command answers `--help` with usage, required
/// arguments, and an example on one screen. Help is always plain text,
/// regardless of the output format flags.
public enum CLIHelp {
    public static let commonFlags = """
    共通フラグ:
      --json            JSON で出力する（既定）
      --human           人間向けの整形で出力する（--json と併用不可）
      --timeout <秒>    処理の上限秒数を受け付ける（読み取りはローカルで即時に終わるため、検証のみ）
      --data-dir <パス>  データファイルの基準ディレクトリ（既定: ホーム直下。環境変数 AIMETER_CLI_DATA_DIR でも指定可）
      --help            このヘルプを表示する
    未対応フラグ:
      --dry-run / --yes / --idempotency-key は書き込み系コマンド用です。
      この CLI のコマンドはすべて読み取り専用のため、指定すると unsupported_flag エラー（終了コード 1）になります。
    終了コード: 0 成功 / 1 入力誤り / 2 アプリ側失敗 / 3 権限不足 / 4 対象なし
    """

    public static var topLevel: String {
        """
        AIMeterCLI — AIMeter の読み取り専用 CLI（GitHub 配布版が対象）

        使い方: AIMeterCLI <コマンド> [引数] [フラグ]

        コマンド:
          status     アプリ情報とデータの前提状態を表示する
          list       サービス一覧（残量・状態つき）を表示する
          get <ID>   1 サービスの詳細を表示する
          history    最終更新の状態を表示する（実行履歴は永続化されていない）
          doctor     前提条件（ファイル・設定・資格情報の有無）を一覧で点検する

        \(commonFlags)

        例:
          AIMeterCLI status
          AIMeterCLI list --json
          AIMeterCLI get openai
          AIMeterCLI doctor --human
        """
    }

    public static func text(for command: CLICommand) -> String {
        switch command {
        case .status:
            return """
            AIMeterCLI status — アプリ情報と前提状態

            使い方: AIMeterCLI status [フラグ]
            引数: なし

            アプリ名・配布形態・識別子、収集スナップショットとウィジェット共有
            ファイルの有無と最終更新、サービス数、セットアップ完了状態を返す。
            Mac App Store 版のデータは Sandbox 内にあるため対象外で、その旨を
            notes に明記する。

            \(commonFlags)

            例: AIMeterCLI status
            """
        case .list:
            return """
            AIMeterCLI list — サービス一覧

            使い方: AIMeterCLI list [フラグ]
            引数: なし

            既知の全サービス（組み込みとカスタム）を、期間ごとの枠（使用量・
            上限・残量・残量の出所つき）で返す。ID は安定 ID で、get の引数に
            そのまま使える。

            \(commonFlags)

            例: AIMeterCLI list --json
            """
        case .get:
            return """
            AIMeterCLI get <サービスID> — 1 サービスの詳細

            使い方: AIMeterCLI get <サービスID> [フラグ]
            必須引数: <サービスID>  list で得られる安定 ID（例: openai, gemini）

            存在しない ID は not_found（終了コード 4）になる。

            \(commonFlags)

            例: AIMeterCLI get openai
            """
        case .history:
            return """
            AIMeterCLI history — 最終更新の状態

            使い方: AIMeterCLI history [フラグ]
            引数: なし

            AIMeter は実行履歴を永続化していないため、履歴そのものは返らない。
            その事実を persistent_history_available: false として正直に返し、
            保存データから分かる最終更新時刻と更新失敗の有無だけを返す。

            \(commonFlags)

            例: AIMeterCLI history
            """
        case .doctor:
            return """
            AIMeterCLI doctor — 前提条件の点検

            使い方: AIMeterCLI doctor [フラグ]
            引数: なし

            データファイルの存在と読み取り可否、ウィジェット共有ファイルの
            スキーマ版数、設定の妥当性、OpenAI API キーの確認可否などを一覧で
            返す。Keychain は OS の許可ダイアログを誘発せずに確認できないため
            「未確認（unknown）」として理由つきで返す（値には一切触れない）。
            終了コードは最も重い結果を表す（エラーあり: 2、権限不足: 3）。

            \(commonFlags)

            例: AIMeterCLI doctor --human
            """
        }
    }
}
