# 手順書：アプリ本体の Mac App Store 対応完成・ビルドガード解除（AI Meter / Mac App Store）

## 目的と完了条件
- `AppStore/README.md` および `docs/APP_STORE_SOURCE_AUDIT.md` に記載された未接続・未検証項目を解消し、`PrivacyInfo.xcprivacy` を同梱したうえで `StoreBuildGuard.swift` のガードを解除し、Sandbox/WidgetKit でクラッシュなく動作するビルドを完成させる。
- 完了条件：
  1. `AppStore/AIMeterStore.xcodeproj` が Release 構成でエラーなくビルドできること。
  2. アプリバンドル内に `PrivacyInfo.xcprivacy` が含まれ、Xcode の Privacy Report で未申告の Required Reason API 警告が出ないこと。
  3. 実署名済み Sandbox 環境で、初回未許可起動・フォルダ選択・部分許可・キャンセル・再起動復元・Widget表示・OpenAI Keychain保守がクラッシュなく通ること。

## 前提
- `handoff/01-developer-ids-and-signing.md` が完了していること。
- 参照設計書：`docs/APP_STORE_DESIGN.md`、`docs/APP_STORE_SOURCE_AUDIT.md`、`AppStore/README.md`

## 手順
1. **必須メタデータ・アイコン実体・`PrivacyInfo.xcprivacy`（エージェント実施済み / Archive時確認のみ）**：
   - `AppStore/Configuration/App-Info.plist` に `LSApplicationCategoryType` (`public.app-category.utilities`) と `ITSAppUsesNonExemptEncryption` (`false`) を追加済み。
   - `AppStore/Resources/AppIcon.icns` を生成・配置済み。
   - `AppStore/Resources/PrivacyInfo.xcprivacy`（`UserDefaults`: `CA92.1`、`SystemBootTime`: `35F9.1`）を作成し、本体・Widget ターゲットに登録済み。
   - `project.pbxproj` の Debug `SWIFT_ACTIVE_COMPILATION_CONDITIONS` を `$(inherited) DEBUG` に修正済み。
   - Archive 時に Xcode の Privacy Report で未申告の Required Reason API 警告が出ないことだけ最終確認する。
2. **`AIMETER_APP_STORE` ビルド条件の伝播確認**：
   - ローカル Swift Package `AIMeterCore` へ `AIMETER_APP_STORE` が正しく伝播することを検証する（`DistributionConfiguration.swift` の分岐が実バイナリで意図どおり Store モードになること）。
3. **Store用収集・UI・Widget 接続と審査通りやすさの確認（`docs/APP_STORE_SOURCE_AUDIT.md` 解消）**：
   - FDベースの Store 用収集処理と許可状態・部分結果・古い結果表示を本体UIおよび App Group 共有（Widget）へ接続する。
   - `SettingsView.swift`（925行目「ローカルログの読み取りは準備中です。」等）を Store 版完成状態の文言に更新する。
   - 非対応連携（`gcloud` / Antigravity ローカル通信 / GitHub自動更新）がStore版で実行されないようにし、特に「アプリ内アップデート」ボタン等はエラー/無効ボタンに見えないよう非表示またはStore版仕様に整理する。
   - 初回起動時にメニューバーアイコンだけでなく初回説明ウィンドウが確実に前面表示され、審査員が迷わず操作できる状態にする。
4. **`StoreBuildGuard.swift` の解除と実機検証**：
   - 上記1〜3をすべて確認したあと、`AppStore/Configuration/StoreBuildGuard.swift` の `#error(...)` を解除する。
   - 実署名済みビルドを起動し、実ログがない空状態（審査員環境を想定）および合成データでの動作、WidgetKit（小・中・大）の更新を確認する。

## 詰まったら
- Sandbox 上でアクセス成立が確認できない入力経路がある場合は、無理に広範な権限を追加せず、`docs/APP_STORE_DESIGN.md` の方針どおり Store 版では非対応として切り離す。

## 完了したら
- テスト・実機検証で合格した範囲（および未検証範囲があればそれ）と、Release Archive が成功した事実を報告する。
