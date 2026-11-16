# 審査準備チェックリスト：AIMeter（Mac App Store）

状態：`済み` / `不足` / `不要` / `未確認`
担当：`AIエージェント` / `開発者` / `ユーザー本人`

## 1. アカウントと契約

- [ ] Apple Developer Program が有効で、App Store Connect に提出権限のあるロールでログインできる — 状態：`未確認` / 担当：`ユーザー本人`
- [ ] 本人確認が完了している — 状態：`未確認` / 担当：`ユーザー本人`
- [ ] 必要な規約（Apple Developer Program License Agreement 等）に同意済み（無料アプリのため有料契約・税務・銀行は不要） — 状態：`未確認` / 担当：`ユーザー本人`
- [ ] アプリの登録枠（App ID、Widget ID、App Group、App Store Connect 上のアプリレコード）が確保済み — 状態：`不足`（`Store.xcconfig` が空欄） / 担当：`ユーザー本人`・`開発者`
- [ ] 2要素認証とアカウントの連絡先メールが現行のものになっている — 状態：`未確認` / 担当：`ユーザー本人`

## 2. アプリ側の技術要件

- [ ] 提出時期の下限 SDK（Xcode 26 以降）を満たすビルドである — 状態：`済み`（本機 Xcode 27.2 確認済み、実ビルドは未完了） / 担当：`開発者`
- [ ] 署名が本番配布用（Apple Distribution / Mac App Distribution）で、鍵の保管場所が記録されている — 状態：`不足`（鍵の生成・保管は本人が手順書で実施） / 担当：`ユーザー本人`・`開発者`
- [ ] `StoreBuildGuard.swift` のガードを外せるだけの Store 用収集・Widget分離・UI接続が完了している — 状態：`不足`（`docs/APP_STORE_SOURCE_AUDIT.md` 参照） / 担当：`開発者`
- [ ] 使っていない権限を削除し、残した権限が機能と対応している（App Sandbox 含む） — 状態：`未確認`（候補は `App.entitlements` に記載済み、実検証待ち） / 担当：`開発者`
- [x] `PrivacyInfo.xcprivacy` が実態（`UserDefaults` / `systemUptime` 等）と一致して同梱されている — 状態：`済み`（`AppStore/Resources/PrivacyInfo.xcprivacy` 作成・ターゲット登録済み。Archive時のPrivacy Reportで最終確認） / 担当：`AIエージェント`・`開発者`
- [ ] ビルド内に `com.apple.quarantine` 属性が含まれない — 状態：`未確認`（Archive 時に確認） / 担当：`開発者`
- [ ] クラッシュなく主要導線が通る（実Sandbox・実WidgetKit・初回未許可状態を含む） — 状態：`不足` / 担当：`開発者`
- [ ] アカウント削除導線がある — 状態：`不要`（アプリ内アカウント作成機能なし） / 担当：`AIエージェント`

## 3. 申告の実態合わせ

- [ ] データ棚卸し表が完成している（SDK分を含む） — 状態：`済み`（`AppStore/store-pack/aimeter/1.2.0/04_declarations/data-map.yaml`） / 担当：`AIエージェント`
- [ ] プライバシー申告（App Privacy）の下書きが棚卸し表と一致している — 状態：`済み`（`04_declarations/privacy-answers.md`） / 担当：`AIエージェント`
- [ ] プライバシーポリシーが公開URLで開け、棚卸しと一致している — 状態：`不足`（原稿は `03_legal/privacy-policy.md` に整備、公開URLの確定・疎通確認が必要） / 担当：`ユーザー本人`
- [ ] 権限ごとの理由文が用意できている — 状態：`済み`（`04_declarations/permission-justifications.md`） / 担当：`AIエージェント`
- [ ] 年齢レーティング質問への回答が実態と一致している — 状態：`済み`（`04_declarations/age-rating-answers.md`） / 担当：`AIエージェント`
- [ ] 課金・広告・アフィリエイトの申告材料が揃っている — 状態：`済み`（無料・なし、`04_declarations/pricing-and-iap.md`） / 担当：`AIエージェント`

## 4. 審査の再現性

- [ ] 審査用アカウントが動作する — 状態：`不要`（ログイン不要アプリ） / 担当：`AIエージェント`
- [ ] 審査用メモの下書きがある（初回説明、ローカルフォルダ選択手順、非対応連携の説明） — 状態：`済み`（`06_review/review-notes.md`） / 担当：`AIエージェント`
- [ ] 審査環境で実ログがない場合の動作・代替説明がある — 状態：`済み`（`review-notes.md` に記載、実機動作は開発者確認待ち） / 担当：`AIエージェント`・`開発者`
- [ ] サーバー側が審査期間中も稼働する見通しがある — 状態：`不要`（独自サーバーなし） / 担当：`AIエージェント`

## 5. 後続スキルへの入力

- [ ] 素材パック用リストを `store_listing_pack` へ渡した — 状態：`済み` / 担当：`AIエージェント`
- [ ] 提出実行用リストを `store_submission_ops` へ渡した — 状態：`済み` / 担当：`AIエージェント`
- [ ] 開発者でないと直せない項目に、手順と完了条件を付けた — 状態：`済み`（`AppStore/store-pack/aimeter/1.2.0/07_submission/handoff/`） / 担当：`AIエージェント`
