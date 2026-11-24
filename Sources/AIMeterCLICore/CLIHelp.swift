import Foundation

/// Help texts. Every command answers `--help` with usage, required
/// arguments, and an example on one screen. Help is always plain text,
/// regardless of the output format flags.
public enum CLIHelp {
    public static let commonFlags = """
    共通フラグ:
      --json            JSON で出力する（既定）
      --human           人間向けの整形で出力する（--json と併用不可）
      --timeout <秒>    処理の上限秒数を受け付ける（処理はローカルで即時に終わるため、検証のみ）
      --data-dir <パス>  データファイルの基準ディレクトリ（既定: ホーム直下。環境変数 AIMETER_CLI_DATA_DIR でも指定可）
      --help            このヘルプを表示する
    書き込み系フラグ（update コマンドのみ対応）:
      --dry-run               実際には変えず、何がどう変わるかだけを返す
      --idempotency-key <キー> 同じキーの再実行では二重に処理せず、最初の結果を返す
      --yes                   受け付ける（update は破壊的操作ではないため必須ではない）
      読み取りコマンド（status / list / get / history / doctor / verify）で指定すると
      unsupported_flag エラー（終了コード 1）になります。
    終了コード: 0 成功 / 1 入力誤り / 2 アプリ側失敗 / 3 権限不足 / 4 対象なし
    """

    public static var topLevel: String {
        """
        AIMeterCLI — AIMeter のエージェント向け CLI（GitHub 配布版が対象）

        使い方: AIMeterCLI <コマンド> [引数] [フラグ]

        コマンド:
          status     アプリ情報とデータの前提状態を表示する
          list       サービス一覧（残量・状態つき）を表示する
          get <ID>   1 サービスの詳細を表示する
          history    最終更新の状態を表示する（実行履歴は永続化されていない）
          doctor     前提条件（ファイル・設定・資格情報の有無）を一覧で点検する
          update service <ID> --enabled|--disabled
                     連携サービスの有効 / 無効を切り替える（設定への書き込み）
          verify     データ整合性と前提条件を自己点検し、合格 / 不合格で返す

        \(commonFlags)

        例:
          AIMeterCLI status
          AIMeterCLI list --json
          AIMeterCLI get openai
          AIMeterCLI update service gemini --disabled --dry-run
          AIMeterCLI verify
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
        case .update:
            return """
            AIMeterCLI update service <サービスID> --enabled|--disabled — 連携サービスの有効 / 無効

            使い方: AIMeterCLI update service <サービスID> (--enabled | --disabled) [フラグ]
            必須引数: service <サービスID>  list で得られる安定 ID（例: openai, gemini, claude）

            アプリと同じ保存先（GitHub 配布版の設定ドメインとカスタムサービス
            設定 JSON）に書き込む。既にその状態のサービスへの実行は成功として
            現状を返す（冪等）。アプリ実行中の場合は、アプリ側の設定読み取り・
            再起動のタイミングで反映される。
            存在しない ID は not_found（終了コード 4）になる。

            対応フラグ:
              --dry-run               実際には変えず、変更前後の状態だけを返す
              --idempotency-key <キー> 同じキーの再実行は最初の結果を返し、二重に処理しない。
                                      別の変更に使ったキーを再利用すると idempotency_conflict（終了コード 1）
              --yes                   受け付ける（この操作は破壊的ではないため必須ではない）

            \(commonFlags)

            例:
              AIMeterCLI update service gemini --disabled --dry-run
              AIMeterCLI update service openai --enabled --idempotency-key setting-2026-001
            """
        case .verify:
            return """
            AIMeterCLI verify — データ整合性と前提条件の自己点検

            使い方: AIMeterCLI verify [フラグ]
            引数: なし

            収集スナップショットのデコード可否、ウィジェット共有ファイルの
            スキーマ版数、カスタムサービス設定の整合（デコード・ID の重複と
            衝突）、設定値の形式、サービス ID の一意性を点検し、項目ごとに
            pass / fail / skipped で返す。読み取り専用で、状態は変えない。
            合格は終了コード 0、不合格は verification_failed（終了コード 2）で、
            理由と直し方は error.details の checks に項目ごとに返る。

            \(commonFlags)

            例: AIMeterCLI verify
            """
        }
    }
}
