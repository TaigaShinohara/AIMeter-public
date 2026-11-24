# Mac App Store用プロジェクト

このプロジェクトは AIMeter の Mac App Store 版の構成です。コンパイルを停止していたビルドガード（`StoreBuildGuard.swift`）は、実署名・Sandbox での実証が完了したため解除済みです（PR #26）。Store ターゲットは Release 構成でビルドできることを確認済みです。配布と審査提出は、手順書04の承認ゲートに従って別途進めます。GitHub 配布用のビルド手順とは独立しています。

本体と Widget は既存の Swift ソースとローカル Swift Package の共通モジュールを参照します。識別子は確定し、Apple Developer へ登録済みです：本体 `com.taigashinohara.aimeter`、Widget `com.taigashinohara.aimeter.widget`、App Group `group.com.taigashinohara.aimeter`、Keychain Service `com.taigashinohara.aimeter`、URL Scheme `aimeter-store`。値は `Configuration/Store.xcconfig` で管理し、Team ID を含むローカル値は Git 管理外の `Store.local.xcconfig` に置きます。既存ファイルや秘密情報を Git へ含めないでください。

権限ファイルには sandbox、ユーザー選択の読取、ブックマーク、通信、App Group を記載しています。従来版との Keychain、Widget、共有ファイル、更新処理の分離は成立しており、実署名（TeamIdentifier 付き）・Sandbox・App Group 共有領域への Widget スナップショット保存は 2026-11-17 に実証済みです。読み取り元フォルダの選択は、同一性記録と対で保存する security-scoped bookmark で行い、アクセス時は二段照合でフォルダのすり替えを検知します。収集の接続は Codex / Claude / Copilot / Gemini の縦切りまで完了しています（設計は docs/STORE_CONNECTION_DESIGN.md）。

本体と Widget のビルド条件には `AIMETER_APP_STORE` を指定しています。ローカル Swift Package の `AIMeterCore` へは Xcode のビルド設定が伝播しないため、`Package.swift` がマニフェスト評価時の環境変数 `AIMETER_APP_STORE=1` を検出した場合に限り、同じ define を `AIMeterCore` へ追加します（直接配布ビルドでは未設定のため挙動は変わりません）。この経路は実際の Xcode ビルドで意図どおり働くことを確認済みです。本体と Widget はそれぞれ起動時に Store の配布設定を必須として検証します。

未検証・残件は次のとおりです：Xcode Archive と App Store Connect への提出（手順書04、提出確定は本人の承認ゲート）、実環境での Widget 表示、OpenAI Keychain のダミー保存確認、Tests/StoreSandboxQA ハーネスによる範囲外アクセスの検証。登録・審査提出・公開は承認ゲートなしに進めません。
