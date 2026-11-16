# スクリーンショット撮影計画（Mac App Store）

## 規格要件（2026-11-16 公式仕様確認済み）
- 保存先フォルダ：`02_images/screenshots/apple/macos/`
- ファイル名規則：`apple-macos-<連番2桁>-<画面名>.png`
- 枚数：1〜10枚（推奨 4〜5枚）
- 解像度（16:10 必須）：`2560x1600` 推奨（または `1280x800` / `1440x900` / `2880x1800`）
- 形式：PNG または JPEG、RGB、**透過（アルファチャンネル）なし**
- 禁止事項：
  - 既存の `docs/images/first-launch.png`（696×732 RGBA）をそのまま使わないこと（サイズ・アスペクト比・透過違反）
  - 個人ログ、実際のメールアドレス、APIキー、私的フォルダパスを写り込ませないこと（必ず合成デモデータを使用）

## 撮影構成案（5枚）
1. `apple-macos-01-menubar-popover.png` — メニューバー＋メインポップオーバー（核の機能：各サービスの残量・使用量一覧とLiquidBall案内）
2. `apple-macos-02-floating-widget.png` — 浮遊ウィンドウ（詳細展開状態、期間枠 2h/5h/1d/7d/30d の表示）
3. `apple-macos-03-macos-widgets.png` — macOS デスクトップ上の Widget（小・中・大の3サイズ表示）
4. `apple-macos-04-first-launch-permission.png` — 初回説明画面とサービスごとのフォルダ選択UI（プライバシー配慮のアピール）
5. `apple-macos-05-settings-integrations.png` — 設定画面（サービス連携・許可状態・メニューバー表示形式の選択）
