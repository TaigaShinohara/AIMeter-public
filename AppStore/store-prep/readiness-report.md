# ストア審査準備レポート：AIMeter（Mac App Store）

- 実施スキル：`store_review_readiness`（3点セット 1/3）
- 対象アプリ：AIMeter（表示名：`AI Meter`、version `1.2.0` / build `1`、macOS 14以降）
- 対象ストア：Apple App Store（Mac App Store、無料・日本語・日本向け予定）
- 確認日：2026-11-16

---

## 1. 総合判定と根拠

- **Mac App Store 判定：直せば提出可能**（一部項目は **未確認**）
- **根拠（実物確認・公式要件照合）：**
  1. `AppStore/Configuration/StoreBuildGuard.swift` に `#error("AIMeter Store target is an incomplete scaffold; do not build or run it yet.")` が意図的に配置されており、現時点でコンパイル・署名・実行ができない（実物確認）。
  2. `AppStore/Configuration/Store.xcconfig` の `AIMETER_STORE_APP_BUNDLE_ID`、`AIMETER_STORE_WIDGET_BUNDLE_ID`、`AIMETER_STORE_DEVELOPMENT_TEAM`、`AIMETER_STORE_APP_GROUP`、`AIMETER_STORE_KEYCHAIN_SERVICE`、`AIMETER_STORE_WIDGET_KIND`、`AIMETER_STORE_URL_SCHEME` がすべて空欄で未確定（実物確認）。
  3. `docs/APP_STORE_SOURCE_AUDIT.md` にて、FDベースのStore用収集試作と実画面・許可管理・Widget間の接続および実Sandbox検証・実WidgetKit検証が未完了であることが記録されている（実物確認）。
  4. Required Reason API（`UserDefaults`、`ProcessInfo.processInfo.systemUptime` 等）を `Sources/` 内で使用しているが、`PrivacyInfo.xcprivacy` がリポジトリ内に未同梱（実物確認・Apple公式要件照合）。
  5. `AppStore/Configuration/App-Info.plist` に Mac App Store 必須キー **`LSApplicationCategoryType`** が未設定、かつ `project.pbxproj` が参照する **`AppStore/Resources/AppIcon.icns`** の実体が存在しない（実物確認・Apple公式要件照合）。
  6. Mac App Store 用の 16:10・RGB・透過なしスクリーンショット（1280×800 / 1440×900 / 2560×1600 / 2880×1800）が未撮影（既存の `docs/images/first-launch.png` は 696×732 RGBA PNG で規格外）。

---

## 2. アプリ実態の確定結果

| 項目 | 確定内容（リポジトリ実物より） |
| --- | --- |
| 対象プラットフォーム・ストア | macOS 14以降 / Mac App Store（GitHub Releases 直接配布版とは分離） |
| 主要機能 | メニューバー・浮遊ウィンドウ・macOS Widget（小・中・大）で AI ツール（Codex / Gemini / Claude Code / Grok Bot / GitHub Copilot / Windsurf / Cursor）の利用量・残量目安を表示 |
| ログイン・サーバー通信 | アプリ独自のログイン不要。ローカルログ集計が基本。任意の OpenAI 連携（`api.openai.com`）のみ外部 HTTPS 通信あり（Store版では gcloud / Antigravity ローカル通信は未検証のため非対応表示方針） |
| 収集・送信データ | 会話本文は端末内で一時推定に使うのみで保存・送信しない。集計結果・設定・OpenAI Admin Key（Keychain）は端末内保存。第三者解析・広告SDK・クラッシュ送信SDKなし（外部Swiftパッケージ依存なし） |
| 権限（Entitlements 候補） | `app-sandbox`, `application-groups`, `files.user-selected.read-only`, `files.bookmarks.app-scope`, `network.client` |
| 課金・広告 | 無料、アプリ内課金なし、広告なし、アフィリエイトなし |
| 対象年齢・UGC・外部リンク | 全年齢対象（4+想定）、UGC・チャットなし、サポート/GitHubリンクあり |
| 審査の再現性条件 | 実ログやAPIキーがない審査環境でも、初回説明画面および未選択・設定画面・空状態等を確認可能にする必要あり（審査用メモでローカルフォルダ選択方法を案内） |

---

## 3. Mac App Store 公式要件（2026-11-16 確認）

| 観点 | 公式要件（確認結果） | 出典（確認日：2026-11-16） |
| --- | --- | --- |
| ツールチェーン / SDK | 2026-04-28 以降、App Store Connect 提出には **Xcode 26 以降および対応 SDK** が必須（現環境の Xcode は `27.2 (27B52)` で要件充足）。2027年4月から Xcode 27 SDK 系へ移行予定。 | Apple Developer News & Updates (`developer.apple.com` 検索確認、2026-11-16) |
| App Sandbox | Guideline 2.4.5(i) により Mac App Store アプリは App Sandbox 必須。最小権限の entitlements のみ要求すること。 | Apple App Store Review Guidelines 2.4.5 (`developer.apple.com` 検索確認、2026-11-16) |
| Privacy Manifest | `PrivacyInfo.xcprivacy` をアプリ本体に同梱必須。Required Reason API（`UserDefaults`: `CA92.1`、`systemUptime`: `35F9.1` 等）の理由コードとデータ収集有無を宣言する。欠落時は `ITMS-91053` 等の警告・差し戻し対象。 | Apple Privacy manifest files (`developer.apple.com` 検索確認、2026-11-16) |
| Quarantine 属性禁止 | TestFlight / Mac App Store 提出バイナリ内の全ファイルに `com.apple.quarantine` 拡張属性が残っているとアップロードがブロックされる。 | Apple Developer Documentation (`developer.apple.com` 検索確認、2026-11-16) |
| スクリーンショット | 1〜10枚、16:10（`1280x800`, `1440x900`, `2560x1600`, `2880x1800`）、PNG または JPEG、RGB、**透過（アルファチャンネル）なし**、72dpi推奨。 | App Store Connect Screenshot Specifications (`developer.apple.com` 検索確認、2026-11-16) |
| テキスト上限 | 名前 30文字、サブタイトル 30文字、プロモーション文 170文字、説明 4,000文字、キーワード 100文字（カンマ区切り合計）、新機能 4,000文字。 | `store_listing_pack/references/copy-specs.md`（2026-11-16照合） |

---

## 4. リジェクト頻出パターン照合

| 重要度 | 該当パターン | 本案件の実態と対策 |
| --- | --- | --- |
| **提出前に必須で直す** | **2.1 未完成・ビルド不可** | `StoreBuildGuard.swift` の `#error` 除去前に、未接続のStore用FD収集・部分結果表示・App Group共有・非対応連携表示を接続・検証する（`docs/APP_STORE_SOURCE_AUDIT.md` 参照）。 |
| **提出前に必須で直す** | **5.1.1 / PrivacyInfo.xcprivacy 欠落** | `UserDefaults`・`systemUptime` 等を使用しているため、`PrivacyInfo.xcprivacy` を追加し、App Store Connect の App Privacy（「データを収集しない」想定）と一致させる。 |
| **提出前に必須で直す** | **2.4.5 Sandbox / 権限・識別子未設定** | `Store.local.xcconfig` に確定済みの Bundle ID / Widget ID / Team ID / App Group / Keychain Service / URL Scheme を設定し、`AIMETER_APP_STORE` が `AIMeterCore` にも伝播するか確認する。 |
| **提出前に必須で直す** | **2.3 スクリーンショット・URL不備** | Mac App Store 規格（16:10、透過なしRGB）の実画面スクショを撮影する。プライバシーポリシー公開URLとサポートURLが実際にブラウザで開ける状態にする。 |
| **提出はできるが落ちる確率が高い** | **4.2 最小機能・審査環境での動作** | 審査員のMacには Codex/Gemini 等の実ログが存在しない可能性が高い。未許可・未取得時でもアプリが正常に起動し、設定画面・空状態が破綻なく動作することを実機で確認し、`review-notes.md` に操作手順を明記する。 |
| **審査員の質問で止まる恐れがある** | **2.3 他社商標・非公式ツール表記** | アプリ説明文・キーワードに他社商標を誤認させる形で使わず、「非公式ツール」である旨と機能範囲を正確に記述する。 |
| 該当なし（確認済み） | 3.1 課金 / アカウント削除 / 広告 | 無料・課金なし・アカウント作成なし・広告なしのため該当しない。 |

---

## 5. 未確認の範囲

- Apple Developer Program の有効性、本人確認、Team ID、App Store Connect 上でのアプリ登録枠（Bundle ID / App Group）の確保状況。
- `AIMeterCore`（ローカル Swift Package）への `AIMETER_APP_STORE` ビルド条件の伝播挙動。
- 実署名済み Mac App Store ビルドでの App Sandbox 下の security-scoped bookmark、FD走査、Keychain分離、WidgetKit App Group 共有の実機動作。
- 公開URL（プライバシーポリシー・サポートページ）の本番公開状態。

---

## 6. 後続スキルへの入力リスト

### 6-1. `store_listing_pack`（素材パック作成）への入力
- アプリ名：`AI Meter`（スラッグ：`aimeter`、version：`1.2.0`、build：`1`）
- カテゴリ：ユーティリティ / 仕事効率化（最終選択は App Store Connect 登録時に確定）
- 価格モデル：`free`（無料、IAP・広告なし）
- サポート連絡先：`support-aimeter@dobulab.com`
- プライバシーポリシー正本：`docs/PRIVACY.md` をベースに公開URL用原稿を作成（公開URLはユーザー確認）
- アイコン正本：`scripts/AppIcon.iconset/icon_512x512@2x.png`（2048×2048 PNG、1024×1024 RGB 透過なし版を書き出し）
- スクリーンショット：16:10（2560×1600 または 1440×900 / 1280×800、RGB透過なし）の撮影計画を作成（実撮影はStore版ビルド完成後）
- 申告材料：データ棚卸し（収集なし / 端末内のみ）、App Privacy（「データを収集しない」）、権限理由文（`files.user-selected.read-only` / `files.bookmarks.app-scope` / `network.client` / `application-groups`）、年齢レーティング（4+相当）、輸出コンプライアンス（標準HTTPS暗号化のみか確認）

### 6-2. `store_submission_ops`（提出実行・手順書切り分け）への入力
- 開発者作業（手順書化）：
  1. 識別子・署名設定（Apple Developer Portal での App ID / Widget ID / App Group 登録、`Store.local.xcconfig` 作成、証明書/プロビジョニング確認）
  2. アプリ本体の Store 対応完成（`PrivacyInfo.xcprivacy` 追加、`AIMETER_APP_STORE` 伝播確認、Store用FD収集・Widget接続、`StoreBuildGuard.swift` 解除、Sandbox/WidgetKit 実機検証）
  3. Mac App Store 用スクリーンショット撮影（実ビルド画面から 16:10・RGB透過なしで取得）
  4. Xcode Archive & App Store Connect へのビルドアップロード（`com.apple.quarantine` なし確認）
- ユーザー本人確認・承認ゲート：
  - App Store Connect アカウントログイン・2要素認証・規約同意
  - 公開プライバシーポリシーURL・サポートURLの確定
  - 最終提出ボタンの確定（審査へ送信）
