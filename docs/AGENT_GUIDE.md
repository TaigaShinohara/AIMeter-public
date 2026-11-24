# AGENT_GUIDE — AIMeter

AI エージェント向けの使い方メモ。このファイルが、AIMeter を機械から使うときの正本である。
操作の棚卸しは [AGENT_OPERATIONS.md](AGENT_OPERATIONS.md)、現状監査は [AGENT_AUDIT.md](AGENT_AUDIT.md) を参照。

## アプリの目的（1行）

複数の AI ツールの使用量・残量を Mac のメニューバーとウィジェットで一目で確認できるアプリ。

## 到達レベル

- レベル: **L1（読み取り可能）** — GitHub 配布版（direct）のみ。目標は L2。
- 読み取り: 可（`status` / `list` / `get` / `history` / `doctor`）
- 操作: 不可（書き込み系コマンドは未実装。変更は GUI で行う）
- 検証: 部分的（`doctor` が前提条件を一覧で返す。`verify` は未実装）

Mac App Store 版は対象外。データが App Sandbox コンテナと App Group 内にあり、独立した CLI プロセスからは entitlement の都合で到達できない。CLI は Store 版の保存場所を読みに行かず、`status` と `doctor` の出力でもその旨を明示する。

## 最初に読むもの

- 機械可読な目録: `docs/agent-manifest.json`
- スキーマ版数: 1
- 実行ファイル: Swift Package の製品 `AIMeterCLI`（`swift build --product AIMeterCLI -j 2` でビルド）

## コマンド一覧

| コマンド | 種別 | 説明 | 例 |
|---|---|---|---|
| `status` | 読み取り | アプリ情報・配布形態・データファイルの有無と最終更新・サービス数 | `AIMeterCLI status` |
| `list` | 読み取り | 全サービスの一覧（期間ごとの枠・残量・残量の出所つき） | `AIMeterCLI list --json` |
| `get <サービスID>` | 読み取り | 1 サービスの詳細。存在しない ID は終了コード 4 | `AIMeterCLI get openai` |
| `history` | 読み取り | 最終更新の状態のみ（実行履歴は永続化されていないことを正直に返す） | `AIMeterCLI history` |
| `doctor` | 読み取り | 前提条件の一覧点検（ファイル・設定・資格情報の確認可否） | `AIMeterCLI doctor` |
| 書き込み系（`run` / `create` / `update` / `delete` / `verify`） | — | **未実装**。カタログに登録済みの操作も、CLI ではまだ実行できない | — |

サービスの安定 ID: 組み込みは `openai` / `gemini` / `antigravity`、カスタムサービスは設定に永続化された ID（例: `claude`、プリセット複製は `cursor_ab12` のような接尾辞つき）。再起動・並び替えで変わらない。

読み取りの土台は GUI と同じ芯（AIMeterCore のモデル・共有ストア・配布設定）で、CLI 用の独自パースはしていない。残量計算はアプリと同じ規則で、保存済みスナップショット（`~/.ai_meter_usage.json`）と設定（Preferences ドメイン `com.local.AIMeter`）から導く。

### データの所在と差し替え

- 既定ではホーム直下の `.ai_meter_usage.json` / `.ai_meter_widget.json` と、Preferences ドメイン `com.local.AIMeter` を読む。
- テストや検証では `--data-dir <パス>` フラグか環境変数 `AIMETER_CLI_DATA_DIR` で基準ディレクトリを差し替えられる。
- Antigravity の残量はアプリのメモリ上にのみ保持され永続化されないため、CLI では常に「未取得」の枠として返る。
- Gemini の残量は公式クォータが無い限り「未取得（unavailable）」として返る（アプリの表示と同じ）。

## MCP

MCP 未対応。CLI を使うこと（L2 の操作と L3 の検証が動いてから検討する）。

## SDK

SDK 未対応。JSON スキーマと CLI を使うこと（作らない方針は監査文書に記録済み）。

## 典型フロー

### 1. 状態を確認してから使う

```
AIMeterCLI status          # 前提状態と最終更新を確認
AIMeterCLI list            # サービスと残量の一覧
AIMeterCLI get openai      # 気になるサービスの詳細
```

### 2. 変更する

書き込み系は未実装のため、変更は GUI で行うこと。将来の書き込み系は「ドライラン → 結果確認 → 本実行 → verify」の順を契約とする（現時点ではどの変更も CLI からは実行できない）。

### 3. 失敗したときに調べる

```
AIMeterCLI history         # 最終更新が失敗していないか
AIMeterCLI doctor          # ファイル・設定・未設定の一覧点検
```

## 入出力スキーマ

- 成功: `{"ok": true, "data": ..., "meta": {"schema_version": 1, "request_id": "...", "cli_version": "...", "command": "..."}}`
- 失敗: `{"ok": false, "error": {"code": "...", "message": "...", "retryable": false, "details": {...}}, "meta": {...}}`
- 既定の出力は JSON。人間向け整形は `--human`（併用不可、混ぜない）。
- 日時は ISO 8601（タイムゾーン付き）。金額は USD の数値フィールド（`cost_usd` / `budget_usd`）。
- 残量の出所は `remaining_source`: `official`（公式値）/ `configured_limit`（設定上限からの目安）/ `unavailable`（未取得）。未取得のとき残量フィールドは `null`。
- 秘密情報は値ではなく有無だけを返す。OpenAI API キーについては有無の確認自体が Keychain の許可ダイアログを誘発しうるため、`doctor` は「未確認（unknown）」と理由を返す。
- 終了コード: 0 成功 / 1 入力誤り / 2 アプリ側失敗 / 3 権限不足 / 4 対象なし。`doctor` は点検結果を `data` に返し、終了コードは最も重い結果を表す（エラーあり 2、権限不足 3、警告のみ 0）。

### 共通フラグの対応

| フラグ | 対応 |
|---|---|
| `--json` | 対応（既定の出力形式の明示） |
| `--human` | 対応（人間向け整形。`--json` と併用不可） |
| `--timeout <秒>` | 受け付ける（正の数の検証のみ。読み取りはローカルで即時に終わる） |
| `--data-dir <パス>` | 対応（基準ディレクトリの差し替え） |
| `--help` | 対応（全コマンド） |
| `--dry-run` / `--yes` / `--idempotency-key` | **未対応**。読み取り専用コマンドでは意味を持たないため、黙って無視せず `unsupported_flag` エラー（終了コード 1）で明示する |

## エラーコード表

| コード | 意味 | 終了コード | 再試行 | 対処 |
|---|---|---|---|---|
| `invalid_argument` | 引数・フラグの誤り | 1 | 不可 | `--help` で使い方を確認する |
| `unknown_command` | 存在しないコマンド | 1 | 不可 | コマンド一覧を確認する |
| `unsupported_flag` | そのコマンドで未対応のフラグ | 1 | 不可 | フラグを外す（書き込み系フラグは読み取りでは使えない） |
| `not_found` | 対象のサービスが無い | 4 | 不可 | `details.known_ids` と `list` で ID を確認する |
| `permission_denied` | ファイルの読み取り権限不足 | 3 | 不可 | 人間に権限の確認を依頼する（`doctor` の結果として返る場合もある） |
| `configuration_error` | 配布設定を解決できない | 2 | 不可 | アプリの配布形態と Info.plist を確認する |
| `internal_error` | その他のアプリ側失敗 | 2 | 不可 | `doctor` で前提条件を確認する |

## 人間専用操作

| 操作 | 理由 | 人間が行う手順 |
|---|---|---|
| OpenAI API キーを保存する | 秘密情報の値をコマンドライン引数や平文で扱わせないため | 設定画面の OpenAI 詳細でセキュアフィールドに入力し「キーを保存」 |
| OpenAI API キーを削除する | 資格情報の破壊的操作で、Keychain のアクセス確認ダイアログが出る場合があるため | 設定画面の「キーの管理」で削除し、確認ダイアログで確定 |
| 旧設定のキーを Keychain へ移行する | 資格情報の移動を伴う保守操作のため | 設定画面の「キーの管理」で「旧設定を移行」 |
| 読み取り元フォルダを選ぶ（Store 版） | OS のフォルダ選択ダイアログ自体が人間の操作で、同一性記録も選択の瞬間に行われるため | 設定の「読み取り先」でフォルダを選択 |
| アプリを更新する（GitHub 配布版） | 配布物の置き換えと再起動を伴う配布操作のため | 設定の「アプリのアップデート」で更新し確認 |
| 初回セットアップを完了する | フォルダ選択ダイアログと初回の同意確認を含むため | 初回案内とセットアップウィザードを進める |
| macOS ウィジェットを追加/削除する | OS のウィジェットギャラリー操作であり、アプリの操作ではないため | 通知センターのウィジェットギャラリーで操作 |
| アプリを終了する | プロセスの起動・終了は OS の領分であるため | メニューバーから終了 |

このほか、Mac App Store への提出・規約同意・支払い確定・署名と公証はアプリ外の人間専用手続き（カタログ参照）。

## やってはいけない操作

- Mac App Store 版の保存場所（Sandbox コンテナ、App Group、Store 版の Keychain service）を CLI で読みに行くこと。対象は GitHub 配布版の保存場所だけ。
- API キーなどの秘密情報を CLI の出力・引数・ログに含めること。`doctor` が返すのは有無と確認可否だけ。
- 実在の利用量 JSON や API キーをテストのフィクスチャに使うこと。テストは一時ディレクトリの合成データと専用 UserDefaults スイートで分離されている。
- 読み取りコマンドに副作用を期待すること。全コマンドは読み取り専用で、読むだけで状態は変わらない。
