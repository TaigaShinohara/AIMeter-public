# 手順書：識別子登録・署名準備・Store.local.xcconfig 作成（AI Meter / Mac App Store）

## 目的と完了条件
- Apple Developer Portal で Mac App Store 用の識別子（App ID / Widget ID / App Group）を確保し、未追跡の `AppStore/Configuration/Store.local.xcconfig` と Mac App Store 配布用証明書を自分の環境で整える。
- 完了条件：
  1. Apple Developer Portal に App ID・Widget Extension ID・App Group が登録済みであること。
  2. `AppStore/Configuration/Store.local.xcconfig`（Git管理外）に全7項目が空欄なく設定されていること。
  3. Xcode の Signing & Capabilities で「Mac App Distribution」等の署名証明書とプロビジョニングプロファイルがエラーなく認識されていること（鍵の保管場所・有効期限を手元に記録）。

## 前提
- 有効な Apple Developer Program メンバーシップ（Account Holder または Admin 権限）
- 2要素認証が可能な本人端末
- リポジトリ：`AppStore/Configuration/Store.xcconfig` および `AppStore/.gitignore`

## 手順
1. Apple Developer Portal（`https://developer.apple.com/account`）→「Certificates, Identifiers & Profiles」を開く。
2. 「Identifiers」→「App Groups」から App Group（例：`group.<your-domain>.aimeter.store`）を新規登録する。
3. 「Identifiers」→「App IDs」で本体用 Bundle ID と Widget Extension 用 Bundle ID（例：`<本体ID>.widget`）を登録し、双方で App Groups ケイパビリティを有効化して手順2の App Group を紐付ける。
4. 「Certificates」および Xcode → Settings → Accounts で Mac App Store 配布用の署名証明書（Apple Distribution / Mac App Distribution）とインストーラ証明書（Mac Installer Distribution 等、Xcode の自動署名または手動プロファイル）を確認・作成する。
5. リポジトリの `AppStore/Configuration/Store.local.xcconfig` を新規作成（`AppStore/.gitignore` で無視対象であることを確認）し、以下の7項目を自分の確定値で埋める（`DistributionConfiguration.swift` の起動時検証を通すため、形式制約に注意）：
   - `AIMETER_STORE_APP_BUNDLE_ID = <確定した本体Bundle ID>`
   - `AIMETER_STORE_WIDGET_BUNDLE_ID = <確定したWidget Bundle ID>`
   - `AIMETER_STORE_DEVELOPMENT_TEAM = <10桁のTeam ID>`
   - `AIMETER_STORE_APP_GROUP = <確定したApp Group ID>`（※ 必ず `group.` または `<10桁TeamID>.` で始まる2セグメント以上の識別子）
   - `AIMETER_STORE_KEYCHAIN_SERVICE = <Store版専用のKeychainサービス名>`（※ 必ず GitHub版の `com.local.AIMeter` と異なるドット区切り識別子）
   - `AIMETER_STORE_WIDGET_KIND = <Store版専用のWidget Kind>`（※ 必ず `com.local.AIMeter.widget` と異なる識別子）
   - `AIMETER_STORE_URL_SCHEME = <Store版専用のURL Scheme>`（※ 必ず `aimeter`（大文字小文字問わず）と異なる英字始まりのスキーム。例：`aimeter-store`）

## 詰まったら
- 既存の GitHub 直接配布版と同じ Bundle ID / Keychain Service / App Group を流用しないこと（データ競合や署名不整合の原因になる）。

## 完了したら
- 次の事実のみを報告・記録する（秘密鍵・パスワード・証明書の値は送らない）：
  - 登録した Bundle ID / App Group 名（公開・管理ID）
  - 証明書の作成・保管場所と有効期限
  - `Store.local.xcconfig` 作成完了の事実

## 注意
- 署名鍵・証明書・APIキー（`.p8`）の秘密情報はこの手順書にもチャットにも貼り付けない。
