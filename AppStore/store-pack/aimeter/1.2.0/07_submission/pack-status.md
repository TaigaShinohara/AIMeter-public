# パック状態（2026-11-16 検証時点）

**総合状態：未完成（テキスト・申告材料・アイコン正本は揃ったが、実ビルド依存のスクリーンショット・識別子・公開URLが不足）**

## 揃ったもの
- `00_manifest.yaml`（確定済み基本情報・連絡先。未確定IDは `TBD` として記録）
- `01_copy/master-copy.md` および `01_copy/by-store/apple.md`（Mac App Store 文字数制限内の文案）
- `02_images/icon/app-icon-2048.png`（2048×2048 RGBA PNG正本）、`app-icon-1024-rgb.png`（1024×1024 RGB PNG）
- `02_images/screenshots/SCREENSHOT_PLAN.md`（5枚構成・16:10 RGB透過なし撮影計画）
- `03_legal/privacy-policy.md`（Mac App Store版正本下書き）、`support.md`、`licenses.md`
- `04_declarations/` 一式（`data-map.yaml`, `privacy-answers.md`, `permission-justifications.md`, `age-rating-answers.md`, `pricing-and-iap.md`）
- `05_build/build-pointer.md`（未ビルド状態の記録）
- `06_review/review-notes.md`、`demo-account.ref.md`

## 不足（提出前に必須）
- `02_images/screenshots/apple/macos/*.png`：Mac App Store 規格（16:10：`2560x1600` 等、RGB、透過なし）の実画面スクリーンショット 1〜10枚
- `00_manifest.yaml` の確定値：Bundle ID、Widget Bundle ID、App Group ID、Developer Team ID
- 公開プライバシーポリシーURLの本番公開とブラウザ疎通確認（`privacy_policy_url`）
- 実ビルド参照情報（`StoreBuildGuard.swift` 解除・`PrivacyInfo.xcprivacy` 追加・Xcode Archive 後）

## 未確認
- App Store Connect 上のアプリレコード作成・カテゴリ最終選択・輸出コンプライアンス回答の画面照合
- 公開サポートURL / プライバシーポリシーURLの本番アクセス確認

## 提出に使ってはいけない素材
- `docs/images/first-launch.png`（696×732 RGBA PNG のため、Mac App Store の 16:10 寸法・透過なし要件に不適合）
- GitHub直接配布版の `README.md` / `DISTRIBUTION_GUIDE.md` にある「App Sandbox 制限なし」「自動アップデート」前提の説明文
