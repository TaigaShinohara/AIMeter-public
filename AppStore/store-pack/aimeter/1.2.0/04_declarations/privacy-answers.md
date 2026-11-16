# プライバシー申告への回答（App Store Connect / PrivacyInfo.xcprivacy）

`04_declarations/data-map.yaml` と一致させること。

## 1. App Store Connect「App Privacy（プライバシーの栄養ラベル）」
- **質問：** 「あなたまたはサードパーティのパートナーはこのアプリからデータを収集していますか？」
- **回答：** **いいえ、このアプリからデータを収集しません**
- **根拠：**
  - すべての集計処理はユーザーのMac内で完結し、開発者サーバーや第三者解析サーバーへの送信を行わない。
  - 任意のOpenAI連携は、ユーザー自身が保有するAdmin Keyを用いて `api.openai.com`（公式API）へ直接照会するものであり、開発者によるデータ収集に該当しない。
  - 第三者の解析SDK・広告SDK・クラッシュ収集SDKは一切組み込まれていない。

## 2. `PrivacyInfo.xcprivacy`（アプリ同梱用：開発者が新規作成・同梱する必要あり）
`Sources/` 内の実装確認に基づき、以下の宣言が必要：
- `NSPrivacyTracking`: `false`
- `NSPrivacyTrackingDomains`: `[]`
- `NSPrivacyCollectedDataTypes`: `[]`
- `NSPrivacyAccessedAPITypes`（Required Reason APIs）:
  - **UserDefaults (`NSPrivacyAccessedAPICategoryUserDefaults`)**
    - 使用箇所：`Sources/AIMeter/AIMeterApp.swift`, `StoreBookmarkStore.swift`, `CollectionIntroduction.swift`, `IntegrationSettingsObservation.swift` 等
    - 推奨理由コード：`CA92.1`（同一アプリ・App Group内での設定読み書き）
  - **System boot time / uptime (`NSPrivacyAccessedAPICategorySystemBootTime`)**
    - 使用箇所：`ProcessInfo.processInfo.systemUptime`（`StoreSafeFileTree.swift`, `StoreClaudeCollector.swift`, `StoreGeminiCollector.swift`, `StoreGrokCollector.swift`, `StoreCursorCollector.swift`, `BoundedAPIClient.swift`, `PrivateSnapshotManager.swift`）
    - 推奨理由コード：`35F9.1`（アプリ内での経過時間・タイムアウト計測。外部送信しない）
  - ※ `FileManager` / `stat` / `fstat` 等でファイルタイムスタンプ API が該当する場合は `C617.1`（ユーザー選択ファイルまたはアプリコンテナ内のタイムスタンプ参照）の追加要否を Xcode の Privacy Report で最終確認すること。
