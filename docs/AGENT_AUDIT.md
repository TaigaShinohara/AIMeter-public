# AIMeter エージェント対応 監査記録

agent_friendly_app_design スキルのチェックリスト様式による現状監査（2026-11-24、コード確認に基づく）。
各項目は 済 / 未 / 対象外 で記録し、理由を 1 行添える。操作の棚卸しは [AGENT_OPERATIONS.md](AGENT_OPERATIONS.md) が正本。

## 1. 監査（現状把握）

- [x] データの保存場所と形式が特定できている — 済。下記「保存場所の内訳」のとおり特定した。
- [x] 業務ロジックが UI から分離されているか、混在箇所が特定できている — 済。下記「ロジックの分離状況」のとおり特定した。
- [x] 外部から触れる経路の有無 — 済。URL スキームは登録のみで内容を解釈しない。CLI / HTTP API / XPC / AppleScript は無い。ファイル経由の入力として `~/.ai_meter_usage.json` が存在する。
- [x] ID の安定性 — 済（基盤として）。組み込みサービス ID と期間 ID は固定文字列、カスタムサービス ID は追加時に採番され永続化される。再起動・並び替えで変わらない。
- [ ] 実行履歴と失敗理由が残っているか — 未。永続化されるのは最終更新時刻と更新失敗フラグのみ。失敗理由はメモリ上の状態で、アプリ終了時に消える。
- [x] テスト基盤とスクリーンショット取得経路の有無 — 済（テスト基盤）。`swift test -j 2`（AIMeterTests / AIMeterWidgetUITests、合成フィクスチャと一時ディレクトリ、Keychain 操作は注入式）と StoreSandboxQA ハーネスがある。スクリーンショットはウィジェット描画テストのプレビュー書き出しのみで、本体 GUI の取得経路は無い。
- [x] 現在の到達レベルの判定と根拠 — 済。**L0**（根拠は「到達レベルの判定」参照）。

### 保存場所の内訳

| 対象 | GitHub 配布版（direct） | Mac App Store 版（appStore） |
|---|---|---|
| 収集スナップショット（入力） | `~/.ai_meter_usage.json`（`LocalUsageData` の JSON。アプリ内収集が書き、旧 `scripts/update_usage.py` も同じ形式を書く） | Sandbox コンテナ内（Store 専用パイプラインが選択フォルダから収集。ホーム直下ファイルは使わない） |
| ウィジェット共有データ | `~/.ai_meter_widget.json`（`AIMeterWidgetSnapshot` の JSON、schemaVersion 4） | App Group コンテナ内の `.ai_meter_widget.json`（`containerURL(forSecurityApplicationGroupIdentifier:)` で解決） |
| 設定 | UserDefaults（Bundle ID `com.local.AIMeter` の Preferences）。有効化・期間・上限・予算・カスタムサービス（`customSubscriptionsJSON`）・パス（`customProviderPathsJSON`）・表示モード等を `@AppStorage` キーで保持 | Sandbox コンテナ内の UserDefaults（キーは同じ。読み取り元 bookmark は `storeSourceBookmarks` / `storeSourceIdentities` キーに追加保存） |
| 資格情報 | Keychain（service `com.local.AIMeter`、account `openaiAdminKey` に OpenAI Admin Key のみ） | Keychain（service は Info.plist の `AIMeterKeychainService`。direct と重ならないことが `DistributionConfiguration` で検証される） |
| 読み取り権限 | Sandbox なし（entitlements で app-sandbox は false）。ホーム直下ファイルを直接読む | App Sandbox 有効。利用者が選んだフォルダへの app-scope security-scoped bookmark（読み取り専用）＋選択時の同一性記録で検証する |
| 配布の識別 | Info.plist に配布メタデータが無い場合は direct として解決（Keychain `com.local.AIMeter` / Widget 種別 `com.local.AIMeter.widget` / URL スキーム `aimeter`） | Info.plist の `AIMeterDistribution = app-store` と各識別子が必須。欠落・重複は direct に倒さずエラーで閉じる（fail closed） |

補足: OpenAI Admin Key は旧版で UserDefaults の `openaiAdminKey` キーに保持されていた時期があり、Keychain への移行と旧設定の除去を行う保守操作（`CredentialMaintenance`）が設定画面にある。キーの値はログ・出力・テストに残さない設計で、カナリアテスト（`PrivacyCanaryTests` 等）が担保する。

### ロジックの分離状況

- AIMeterCore（アプリ・ウィジェット・QA が共有）: データモデル（`Models`）、利用量パース（`UsageParser`）、共有ファイルの読み書き（`SharedStore`）、配布設定の解決（`DistributionConfiguration`）、サービス識別（`ServiceIdentity`）、整形（`Formatters`）、入力境界（`BoundedInput`）。
- アプリターゲット側に残る芯: 収集（`LocalUsageCollector`、Store 版の `Store*Pipeline` / `Store*Collector`）、状態管理（`UsageMonitor`）、Keychain（`KeychainHelper`）、資格情報の保守（`CredentialMaintenance`）、アプリ更新（`AppUpdater`）、bookmark の保存（`StoreBookmarkStore`）。
- テストターゲットはアプリターゲットにも依存している（`AIMeterTests` が `AIMeter` ターゲットをリンク）。CLI が芯を共有するには、対象ロジックの AIMeterCore への切り出し、または CLI からの共有方法の設計判断が次段で必要。

## 2. 操作カタログ

- [x] 主要操作が全件リスト化されている — 済。本監査と同時に [AGENT_OPERATIONS.md](AGENT_OPERATIONS.md) を追加した。
- [x] 各操作に機械経路か人間専用の宣言がある — 済。カタログの各行に記載した。
- [x] 破壊的操作に印が付いている — 済。カタログの「破壊的」列で明示した。
- [x] 副作用（通知、外部送信、課金、ファイル変更）が書かれている — 済。カタログの「副作用」列に記載した。

## 3. CLI / API 契約

- [ ] 主要操作にサブコマンドがある — 未。CLI 製品が存在しない。
- [ ] 全コマンドに `--help` があり例が載っている — 未。同上。
- [ ] 共通フラグ `--json` `--dry-run` `--yes` `--idempotency-key` `--timeout` の対応状況が明示されている — 未。同上。
- [ ] 終了コードが統一されている（0 成功、1 入力誤り、2 アプリ側失敗、3 権限不足、4 対象なし） — 未。同上。
- [ ] 破壊的操作は `--yes` なしで実行されない — 未。機械経路自体が無い。
- [ ] 冪等キーで再実行しても二重に作られない — 未。同上。
- [ ] 長い処理はジョブ ID か進捗を返し `status` で追える — 未。収集は GUI 内の非同期処理で、外部から追跡できない。

## 4. 入出力

- [ ] 成功と失敗の JSON の包みが統一されている — 未。機械向け入出力の契約が存在しない。
- [ ] エラーコードが文字列定数で安定している — 未。失敗は画面表示用の文字列が中心。
- [x] ID が安定し再利用されない — 済。サービス ID・期間 ID は固定文字列。カスタムサービス ID は追加時に「プリセット ID＋必要なら UUID 先頭 4 文字のサフィックス」で採番され、設定 JSON に永続化される。
- [ ] 日時が ISO 8601 とタイムゾーン付きである — 未（部分的）。`LocalUsageData.updatedAt` は文字列の ISO 8601 だが、機械向け出力としての契約は無い。
- [ ] スキーマにバージョンがある — 未（部分的）。ウィジェット共有 JSON には schemaVersion（現行 4）があるが、これは内部表現であり CLI の入出力スキーマではない。
- [x] 秘密情報の値が出力に含まれない — 済。キーの値は保存状態の有無だけを扱い、値そのものを表示・記録しない設計とカナリアテストがある。

## 5. 読み取りと検証

- [ ] `status` でアプリ情報、版数、前提条件が分かる — 未。
- [ ] `list --json` と `get <id> --json` がある — 未。
- [ ] `history --json` で成功と失敗理由が見られる — 未。履歴データ自体が存在しない（第 1 節参照）。
- [ ] `doctor` で権限不足と未設定が一覧になる — 未。前提条件の不足は画面上の状態表示に留まる。
- [ ] 書き込み系に `--dry-run` がある — 未。
- [ ] `verify` が合格か不合格かと理由を返す — 未。
- [ ] テスト用の `seed` と `reset --test-data` に本番ガードがある — 未。テストは合成フィクスチャと一時ディレクトリで分離されており、製品機能としての seed / reset は無い。
- [ ] 決定的モード（時刻、シード、応答の固定）がある — 未（テスト基盤のみ）。テストではフィクスチャと操作注入で決定的に検証できるが、製品の決定的モードは無い。
- [ ] 画面検証の経路がある — 未（部分的）。ウィジェット描画のプレビュー書き出し（`AIMETER_WIDGET_PREVIEW_DIR` 指定時）はあるが、本体 GUI のスクリーンショット取得経路は無い。

## 6. ドキュメント

- [ ] `docs/AGENT_GUIDE.md` がある — 未。CLI 実装と同時に作成する（本監査はその前段）。
- [ ] `docs/agent-manifest.json` がある — 未。同上。
- [ ] ガイドと実装のコマンド一覧が一致している — 未。実装が無いため未判定。
- [x] 人間専用操作の一覧と理由がガイドにある — 済（カタログ側）。一覧と理由は [AGENT_OPERATIONS.md](AGENT_OPERATIONS.md) に記録した。ガイド作成時に転記する。

## 7. MCP / SDK 層

- [x] MCP 対応の要否が決まっている — 済。**今は入れない**。L2 の操作と L3 の検証が動いてから最後に検討する（スキルの後付け手順どおり）。
- [ ] コマンドとツールの対応表がある — 未。MCP 未対応のため存在しない。
- [ ] ツール定義が CLI のスキーマ正本から生成か変換されている — 未。同上。
- [ ] 読み取りがリソース、書き込みと実行がツールに分かれている — 未。同上。
- [ ] 破壊的ツールにドライラン相当の引数がある — 未。同上。
- [ ] MCP サーバーの認証と公開範囲が決まっている — 未。同上。
- [ ] 許可ツールが列挙されている — 未。同上。
- [ ] MCP があっても CLI が残っている — 未。CLI 自体が無い。
- [x] SDK の要否が判断されている — 済。**作らない**（既定どおり。他アプリからの再利用需要も外部公開方針も無い）。

## 到達レベルの判定

**現在レベル: L0（GUI のみ）**

根拠:

- 状態・結果はすべて GUI でしか確認できない。外部から呼べる読み取り・操作の契約（CLI、API、解釈されるディープリンク）が存在しない。URL スキームは登録されているが、ハンドラは URL の内容を無視してウィジェットウィンドウを開くのみで、操作の経路になっていない。
- ホーム直下の JSON 2 点（収集スナップショットとウィジェット共有データ）は機械可読だが、どちらも内部表現（収集の入力と表示用キャッシュ）であり、読み取り契約として公開・安定化されたものではない。設定の読み取り経路と実行履歴は存在しないため、L1 の定義（状態・一覧・履歴・設定を JSON で取得できる）には届かない。
- ただし GitHub 配布版については、JSON ファイルと Preferences が同一ユーザー権限で読める場所にあるため、L1 化の素材は揃っている。

## 目標レベルの提案

| 配布形態 | 目標 | 理由 |
|---|---|---|
| GitHub 配布版（direct） | **L2（操作可能）** | 既定どおり。データと設定が同一ユーザー権限で到達可能な場所にあり、CLI を同パッケージの実行可能ターゲットとして AIMeterCore を共有できる。注意点として、設定の書き込みはアプリ実行中だとアプリ側のメモリ状態や cfprefsd と競合しうるため、書き込み系の扱い（アプリ未起動時に限るか、アプリ経由にするか）は次段の設計判断とする。 |
| Mac App Store 版（appStore） | **L1（読み取り可能）を上限とし、初回は対象外** | データは App Sandbox コンテナと App Group コンテナの中にあり、独立した CLI プロセスは entitlement の都合で到達できない。到達にはアプリ同梱ヘルパー（同一 App Group の entitlement を持つ署名済みプロセス）が必要で、書き込みまで含む L2 は Sandbox の制約と提出審査への影響が大きい。まず GitHub 配布版で L2 を作り、Store 版の読み取りは同梱方式の提出影響を見て別途判断する。 |

MCP は今回入れない（L2 の操作と L3 の検証が動いてから検討）。SDK は作らない。

## 次段（CLI 読み取り系の実装）への申し送り

- 読み取りから始める: `status` → `list` / `get` → `history` / `doctor` の順。`history` は既存データが最終結果しかないため、初版は「最終更新の状態」を返す範囲に限定し、履歴の永続化は別途設計する。
- CLI は AIMeterCore を共有する。収集・設定・資格情報のロジックはアプリターゲット側にあるため、読み取りに必要な範囲から Core への切り出し範囲を決めること。
- 資格情報は有無だけを返す。キーの値の保存・削除・移行はカタログどおり人間専用のままにする。
- Store 版のデータには独立 CLI から触れない。direct 版の保存場所だけを対象として実装し、配布形態の取り違えが起きないよう CLI 側でも `DistributionConfiguration` 相当の判定を行うこと。
