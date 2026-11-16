# 手順書：スクリーンショット撮影と公開URL確定（AI Meter / Mac App Store）

## 目的と完了条件
- Mac App Store 提出規格に適合した実画面スクリーンショットを撮影し、プライバシーポリシー・サポートURLを実際にブラウザで開ける状態に確定する。
- 完了条件：
  1. `AppStore/store-pack/aimeter/1.2.0/02_images/screenshots/apple/macos/` に 1〜10枚（推奨5枚）の PNG が配置されていること。
  2. `validate_pack.py <pack_dir> --expect apple=macos:2560x1600`（または採用した 16:10 寸法）が `RESULT: OK` で通ること（透過なしRGB確認含む）。
  3. `00_manifest.yaml` の `privacy_policy_url` と `support_url` が本番公開され、ブラウザで HTTP 200 で閲覧できること。

## 前提
- `handoff/02-app-store-code-completion.md` により、Store版アプリが起動して実画面を確認できる状態であること。
- 撮影計画：`02_images/screenshots/SCREENSHOT_PLAN.md`

## 手順
1. テスト用の合成データ（個人情報・実メールアドレス・APIキーを含まない）を用意し、Store版アプリを起動する。
2. `02_images/screenshots/SCREENSHOT_PLAN.md` の5画面を macOS 上で撮影する。
3. 撮影した画像を **16:10（`2560x1600` 推奨、または `1280x800` / `1440x900` / `2880x1800`）**、**RGB・透過（アルファチャンネル）なし** の PNG/JPEG に整え、`02_images/screenshots/apple/macos/apple-macos-01-...png` として保存する。
4. `03_legal/privacy-policy.md` の内容を公開場所（例：GitHubリポジトリの `docs/PRIVACY.md` 更新版、または専用公開ページ）へ反映し、その公開URLを `00_manifest.yaml` の `privacy_policy_url` に記入する。
5. 以下の検証コマンドを実行する（サイズ例が 2560x1600 の場合）：
   ```sh
   PYTHONDONTWRITEBYTECODE=1 python3 <store_listing_pack スキル>/scripts/validate_pack.py \
     <リポジトリ>/AppStore/store-pack/aimeter/1.2.0 \
     --expect apple=macos:2560x1600
   ```

## 注意
- 既存の `docs/images/first-launch.png`（696×732 RGBA）は規格外のため使用しない。
- スクリーンショットに個人のユーザー名・ホームパス・APIキーが写り込んでいないか1枚ずつ目視確認する。
