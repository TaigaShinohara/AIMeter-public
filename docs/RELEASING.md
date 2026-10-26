# GitHub Releasesへの配布

この公開リポジトリはソースコードを提供しています。署名・公証済みの配布ZIPはまだ提供していません。
以下は、配布用バイナリを作成する際にリリース担当者が使う手順です。

配布対象はmacOS 14以降向けのUniversal Binary（arm64 / x86_64）です。
署名・公証に加え、配布するZIPからの初回起動、設定、Widgetの登録・表示・更新を検証してから公開します。
ソースコードの公開や自動テストの成功は、これらの実環境確認の代わりにはなりません。

## 初回設定

1. Apple Developer Programの有効なチームで、XcodeのSettings → Apple Accountsにサインインします。
2. Manage Certificatesで **Developer ID Application** 証明書と秘密鍵をこのMacに用意します。
   Apple Development / Apple Distribution / ad-hoc署名はこの配布には使えません。
   Webで作成する場合は、Keychain AccessでCSRを保存し、Apple Developerの
   Certificates → ＋ → Developer ID Application → G2からCSRを登録します。
   発行後の種類がDeveloper ID Applicationであることを確認し、
   ダウンロードした `.cer` をCSR作成時と同じMacのログインキーチェーンへ追加します。
3. `security find-identity -v -p codesigning` で証明書のSHA-1とTeam IDを確認します。
4. 公証用認証をKeychainに登録します。次のコマンドはApple ID、Team ID、
   App用パスワードを対話的に入力するため、秘密値をコマンド引数や履歴に残しません。

   ```sh
   xcrun notarytool store-credentials AIMeter-notary
   ```

   既存のApp Store Connect APIキーを使う場合も、許可されたチーム・用途を確認し、
   1Passwordから一時ファイルへ安全に渡してKeychainプロファイルを登録してください。
   他アプリの資格情報を無断で流用したり、秘密鍵・パスワードをリポジトリへ置いたりしないでください。
5. `gh auth status` で公開先 `TaigaShinohara/AIMeter-public` への権限を確認します。

Appleの公式手順：
[Developer ID証明書](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)、
[公証](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、
[公証のカスタマイズ](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

## ローカル検証とビルド

Xcode（macOS 26以降のSDK）、Python 3.9以降、GitHub CLIを使います。
先に実行中のビルド、メモリ、出力先の空き容量を確認してください。
ビルドは2並列です。GitHub Actionsは使用しません。

```sh
swift test -j 2
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

個人ログをテスト入力にせず、一時ディレクトリ内の合成データを使います。
テストが通った変更をコミットし、cleanなcheckoutで以下を実行します。
出力先はリポジトリの外にある、まだ存在しないディレクトリを指定してください。
以下のパス・version・build番号は例です。未使用のversionと、既存の配布版より大きいbuild番号を選びます。

```sh
python3 scripts/release.py build \
  --version 1.2.0 --build-number 4 \
  --output /private/tmp/AIMeter-release-1.2.0
```

HEADのGitアーカイブからビルドし、appとWidgetの両方にarm64 / x86_64が入っていること、
バージョン、システム外ライブラリへの依存がないことを確認します。
ソースSHAをapp内にも記録します。既存の `/Applications/AIMeter.app` を更新・起動せず、
Widget登録もしません。`build.log` にビルド結果を保存します。
この段階のappは配布できません。

## 署名・公証

```sh
python3 scripts/release.py notarize \
  --output /private/tmp/AIMeter-release-1.2.0 \
  --identity YOUR_40_CHARACTER_CERTIFICATE_SHA1 \
  --team YOUR_TEAM_ID \
  --keychain-profile AIMeter-notary
```

証明書の種類とTeam IDを確認し、Widget→appの順にhardened runtimeと
secure timestamp付きで署名します。署名時に `--deep` は使いません。
WidgetはSandboxを有効にし、表示専用の `~/.ai_meter_widget.json` への読取例外だけを設定します。
共有ファイルの所有者のみが読み書きできる権限（0600）は維持します。現在の実装はApp Group
コンテナを使っていないため、配布用署名には未使用のApp Group entitlementを含めません。
app本体はSandbox外で動作します。旧Python collectorは配布バンドルへ含めません。

Appleの結果が `Accepted` の場合に限り、公証チケットをappにstapleし、
署名・staple・Gatekeeperを検証してから配布ZIPを作ります。
`release.json` は成功時だけ生成するローカル検証記録です。アップロード対象は
`AIMeter-<version>-macos-universal.zip` と `SHA256SUMS` の2ファイルです。
作業ディレクトリ全体や公証ログ、資格情報はアップロードしません。

エラー時は処理が停止します。Appleから拒否された場合は `notary-result.json` のsubmission IDを使い、
`xcrun notarytool log <ID> --keychain-profile AIMeter-notary` で原因を確認してください。
待機は最大20分です。タイムアウト時はApple側で処理中の可能性があるため、状態を確認してから再実行します。
不合格の成果物にad-hoc署名を付けて公開する回避策はありません。

## 実環境確認と公開

初回は公証済みZIPを新しいmacOSユーザーなどの検証環境へ移し、個人ログを置かずに、
Finderからの起動、初期画面、合成データの表示、Widgetの登録・表示を確認してください。
Apple SiliconとIntelの両方を収録することと、両実機で動作を確認することは別です。
実機未確認のプラットフォーム・OSバージョンはリリースノートに明記してください。
警告が出た場合にGatekeeper無効化やquarantine属性削除をユーザーへ案内しないでください。

変更をレビュー・マージした後、公開を承認したリリース担当者が実行します。
実際に確認したMac・OS・起動・Widgetの結果と未確認範囲をMarkdownファイルへ記載してください。
その内容をReleaseの「動作確認の範囲」に掲載します。個人ログや資格情報を含めないでください。

```sh
python3 scripts/release.py publish \
  --output /private/tmp/AIMeter-release-1.2.0 \
  --validation-notes /private/tmp/AIMeter-validation.md
```

公開先は `TaigaShinohara/AIMeter-public` です。`scripts/release.py` の公開先定数を確認してください。
公開前に、配布ZIPのハッシュと展開後のappの署名・公証・Gatekeeperを再検証し、
ソースSHAがGitHubのmainへマージ済みであることを確認します。
タグ名 `v<version>` を指定したdraft Releaseを作り、GitHub側のasset digestがローカルのSHA-256に
一致した場合だけ公開します。既存タグ・Release・assetを上書きしません。
draftの段階ではGitタグが未作成の場合があるため、状態とassetの取得には
`gh release view` を使います。タグ経由のREST APIはこの段階で404になることがあります。
アップロード途中で失敗した場合はdraftが残る場合があります。GitHubでそのdraftとassetを
確認し、再開または新versionで作り直してください。自動削除・自動上書きは行いません。
