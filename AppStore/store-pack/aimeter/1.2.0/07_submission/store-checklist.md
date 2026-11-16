# ストア別提出チェック：Mac App Store（AI Meter 1.2.0 / build 1）

- 実施スキル：`store_submission_ops`（3点セット 3/3）
- 実行経路：A/B（App Store Connect API / ブラウザ）＋ C（Xcode署名・ビルド・鍵管理・2要素認証は手順書へ切り分け）
- 現在状態：**開発者・本人作業待ち（コード未完成・識別子未確定・スクショ未撮影のため App Store Connect への入力・アップロード未実施）**

## 作業票（Mac App Store）

| 順序 | 工程 | 状態 | 担当 | 参照・手順書 |
| --- | --- | --- | --- | --- |
| 1 | アカウント照合（Apple Developer Program / App Store Connect ロール・規約・2FA確認） | 未完了 | ユーザー本人 | 手順書 `handoff/01-developer-ids-and-signing.md` |
| 2 | 識別子確保・署名準備（App ID / Widget ID / App Group 登録、`Store.local.xcconfig` 作成、証明書確認） | 未完了 | 開発者・本人 | 手順書 `handoff/01-developer-ids-and-signing.md` |
| 3 | アプリ本体の Store 対応完成（`PrivacyInfo.xcprivacy` 追加・`AIMETER_APP_STORE` 伝播・FD収集接続・`StoreBuildGuard.swift` 解除・Sandbox/WidgetKit 実機検証） | 未完了 | 開発者 | 手順書 `handoff/02-app-store-code-completion.md` |
| 4 | 公開URL確定・スクリーンショット撮影（16:10 RGB透過なし、`validate_pack.py --expect apple=macos:2560x1600` 合格） | 未完了 | 開発者・本人 | 手順書 `handoff/03-screenshots-and-legal-urls.md` |
| 5 | App Store Connect アプリレコード作成・メタデータ・申告入力（`01_copy/by-store/apple.md`、`04_declarations/`、`06_review/` より転記） | 未完了（4完了後） | 本人 / AI補助 | 手順書 `handoff/04-xcode-archive-and-upload.md` |
| 6 | Xcode Archive・`com.apple.quarantine` 不在確認・ビルドアップロード・ビルド紐付け | 未完了（3完了後） | 開発者 | 手順書 `handoff/04-xcode-archive-and-upload.md` |
| 7 | プレビュー最終確認（アプリ名・バージョン・価格無料・配信地域・スクショ並び・App Privacy・審査用メモ） | 未完了 | ユーザー本人 | — |
| 8 | **承認ゲート：提出ボタン確定（審査へ送信）** | **停止中（明示承認待ち）** | **ユーザー本人** | 承認後に実施 |
| 9 | 審査状態・受付ID記録 | 未着手 | — | 提出後に記録 |

## 審査結果・受付記録欄（提出後に記入）
- 提出日時：
- 提出バージョン / ビルド番号：
- 受付ID / 状態：
- 確認方法：App Store Connect → マイ App → AI Meter → Mac App 1.2.0
