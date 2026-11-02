# GitHub Releasesへの配布

この公開リポジトリはソースコードを提供しています。署名・公証済みアプリの配布Releaseはまだありません。以下は、リリース担当者が配布候補を準備し、明示的に公開を決定した際の手順です。

配布対象はmacOS 14以降向けのUniversal Binary（arm64 / x86_64）です。公開リポジトリのコミットから作り、署名・公証に加えて、実際の配布ZIPからの起動・設定・Widgetを確認します。ソースのマージや自動テストの成功は、配布物の公開や実環境での確認の代わりにはなりません。

公開先は `TaigaShinohara/AIMeter-public` です。`scripts/release.py` の公開先、アプリ内更新のリポジトリ・署名の信頼先、関連テストと案内を一致させてください。独自のforkや署名での配布が、公式のアプリ内更新で受け入れられるとは限りません。

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
   アプリ用パスワードを対話的に入力するため、秘密値をコマンド引数や履歴に残しません。

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

## 開発用buildとの区別

`./scripts/build_app.sh` は `.build/local-packages` にローカル用候補を新規生成し、設置・公証・公開はしません。
`./run.sh` は設置を明示的に許可して起動し、`AIMETER_INSTALL_TO_APPLICATIONS=0` のopt-outを保持します。
詳細は [配布・導入ガイド](../DISTRIBUTION_GUIDE.md#ローカルでアプリを作成する) を参照してください。
以下はcleanなGitソースからUniversalの配布候補を作る別の手順です。

アプリ内の「開発版に更新」には、GitHubのprereleaseとして公開した署名・公証済みの配布物を使います。
ローカル用ZIPは対象にできません。公開された開発版がない場合は更新を案内せず、利用中のアプリを保ちます。
mainの取得やローカルビルドを自動で行う機能ではありません。

## 配布候補の検証とビルド

Xcode（macOS 27以降のSDK）、Python 3.9以降、GitHub CLIを使います。
先に実行中のビルド、メモリ、出力先の空き容量を確認してください。
ビルドは2並列です。GitHub Actionsは使用しません。

```sh
swift test -j 2
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

個人ログをテスト入力にせず、一時ディレクトリ内の合成データを使います。
テストが通った変更をコミットし、cleanなcheckoutで以下を実行します。
出力先はリポジトリの外にある、まだ存在しないディレクトリを指定してください。
以下のパス・version・build番号は例です。公開済みのversionを再使用せず、新しい出力先を選んでください。

```sh
python3 scripts/release.py build \
  --version 1.2.0 --build-number 1 \
  --output /private/tmp/AIMeter-release-1.2.0-build1
```

HEADのGitアーカイブからビルドし、appとWidgetの両方にarm64 / x86_64が入っていること、
バージョン、システム外ライブラリへの依存がないことを確認します。
ソースSHAをapp内にも記録します。既存の `/Applications/AIMeter.app` を更新・起動せず、
Widget登録もしません。`build.log` にビルド結果を保存します。
この段階のappは配布できません。

通常buildと同じpackagerが、新しいbundleだけへ明示した実行ファイル・アイコン・LICENSE・Info.plistを入れます。
既存bundleの残留物を取り込まず、署名前後のファイル集合と、ZIP内のpath・bytes・modeをmanifestに照合します。
署名・公証に必要な既知のCodeResourcesとticketは保持し、Finder metadataやAppleDoubleをZIPへ追加しません。

## 署名・公証

```sh
python3 scripts/release.py notarize \
  --output /private/tmp/AIMeter-release-1.2.0-build1 \
  --identity YOUR_40_CHARACTER_CERTIFICATE_SHA1 \
  --team YOUR_TEAM_ID \
  --keychain-profile AIMeter-notary
```

証明書の種類とTeam IDを確認し、Widget→appの順にhardened runtimeと
secure timestamp付きで署名します。署名時に `--deep` は使いません。
WidgetはSandboxと表示専用の `.ai_meter_widget.json` への読取例外を維持します。
Swiftの読取先と開発用entitlementの一致を確認し、配布grantを派生させます。
署名後の `.appex` から実entitlementを取得し、旧集計JSONや追加権限がないことを検証します。現在の実装はApp Group
コンテナを使っていないため、配布用署名には未使用のApp Group entitlementを含めません。
app本体は従来どおりSandbox外で動作します。旧Python collectorは配布バンドルへ含めません。

Appleの結果が `Accepted` の場合に限り、公証チケットをappにstapleし、
署名・staple・Gatekeeperを検証してから配布ZIPを作ります。
`release.json` は成功時だけ生成し、署名済みbundleのmanifestも含むローカル検証記録です。アップロード対象は
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
その内容をReleaseの「動作確認の範囲」に掲載します。公開する情報はOS・版・ソースSHA・確認結果・制限に限定し、
個人ログ・認証情報・生のホームパス・利用量JSON・任意のメモを含めないでください。

```sh
python3 scripts/release.py publish \
  --output /private/tmp/AIMeter-release-1.2.0-build1 \
  --validation-notes /private/tmp/AIMeter-validation.md
```

公開前に、配布ZIPのハッシュ・manifestと、安全に展開したappの署名・公証・Gatekeeperを再検証し、
ソースSHAがGitHubのmainへマージ済みであることを確認します。
タグ名 `v<version>` を指定したdraft Releaseを作り、GitHub側のasset digestがローカルのSHA-256に
一致した場合だけ公開します。既存タグ・Release・assetを上書きしません。
draftの段階ではGitタグが未作成の場合があるため、状態とassetの取得には
`gh release view` を使います。タグ経由のREST APIはこの段階で404になることがあります。
アップロード途中で失敗した場合はdraftが残る場合があります。GitHubでそのdraftとassetを
確認し、再開または新versionで作り直してください。自動削除・自動上書きは行いません。

## 開発版の公開

安定版の公開前に変更を試す配布物も、上記のビルド・署名・公証・実環境確認を行います。
ビルド時に `--prerelease` を付けると、本体・Widgetの両方へ開発版のchannelを記録します。

```sh
python3 scripts/release.py build \
  --version 1.2.0 --build-number 1 \
  --output /private/tmp/AIMeter-development-1.2.0-build1 \
  --prerelease
```

同じ出力先を指定して上記の `notarize` を行い、実環境確認の結果を記録した後、
公開を承認したリリース担当者が `publish` にも `--prerelease` を付けます。

```sh
python3 scripts/release.py publish \
  --output /private/tmp/AIMeter-development-1.2.0-build1 \
  --validation-notes /private/tmp/AIMeter-validation.md \
  --prerelease
```

versionとbuild番号は安定版と同じ数値形式を維持します。この例のGitHubタグは
`v1.2.0-dev.1` となり、後の安定版タグ `v1.2.0` と分かれます。
アーカイブ名は `AIMeter-1.2.0-macos-universal.zip` のままです。
開発版のReleaseノートには開発版である旨とbuild番号を掲載し、GitHubのprereleaseに設定します。
ビルドと公開時のchannelが異なる場合は停止します。channelを記録していない旧候補は安定版にのみ使用できます。
draft作成時と公開時の両方で `--latest=false` を指定するため、最新安定版の指定を変えません。
draftのchannel・タグ・ソースSHAとアップロード済みハッシュを照合してから公開し、
同じ開発版タグの上書きは行いません。次の候補には新しいbuild番号を使ってください。

公開済みのprereleaseがなければ、アプリ内から開発版へ更新できません。
この手順の整備やコードのマージは、新しい配布物の公開を意味しません。
