# AIMeter

macOSのメニューバーとウィジェットに、AIツールの利用量を表示するSwiftUIアプリです。
Codex、Gemini / Antigravity、Claude Code、Grok Bot、GitHub Copilot、Windsurf、Cursorのローカルデータを集計します。
各AIサービスとは独立した非公式ツールです。表示値にはログからの推定や設定した上限が含まれ、サービスの公式請求額・残量と一致するとは限りません。

## 動作・ビルド環境

- 実行対象：macOS 14以降
- ビルド：macOS 26 SDKを含むXcode（macOS 26のUI APIを使用）
- Swift Package Manager。外部Swiftパッケージへの依存なし
- 通常のアプリ動作にPythonは不要。旧収集スクリプトのテストにはPython 3.9以降を使用

## 公開内容

このリポジトリではソースコードを公開しています。配布用の署名・公証済みアプリはまだ公開していません。
利用するには、以下の環境でソースコードからビルドしてください。GitHubが生成するソースコードのZIPはアプリ本体ではありません。

新規macOSユーザーでの初回起動・設定・Widget実表示、Intel実機・macOS 14での実行、任意APIの実接続は未確認です。

## ビルドとテスト

```sh
git clone https://github.com/TaigaShinohara/AIMeter-public.git
cd AIMeter-public
swift build -c release -j 2
swift test -j 2
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

テストは一時ディレクトリの合成データを使い、個人の利用ログやAPI資格情報を必要としません。

アプリバンドルだけを作成する場合は、次のコマンドを使います。

```sh
AIMETER_INSTALL_TO_APPLICATIONS=0 ./scripts/build_app.sh
```

このスクリプトはローカルの開発用署名ID（なければad-hoc署名）を使います。
生成物は開発用で、配布用の署名・公証済みアプリではありません。
環境変数を指定せず `./scripts/build_app.sh` を実行すると、`/Applications` が書込み可能な場合は
既存の `AIMeter.app` を更新してWidgetを登録します。
`./run.sh`、`make run`、`Launch AIMeter.command` も必要に応じてこのビルド処理を実行し、アプリを起動します。
手順と機能は [配布・導入ガイド](DISTRIBUTION_GUIDE.md) を参照してください。
署名・公証・GitHub Releases公開の手動手順は [リリース担当者向けガイド](docs/RELEASING.md) にあります。

## データと通信

- ローカル収集は各ツールの既定パス、または設定画面で指定したパスを読み取ります。アプリ本体はApp Sandboxによるホーム配下への制限を持ちません。
- 集計結果は `~/.ai_meter_usage.json` に保存し、所有者だけが読み書きできる権限（0600）を設定します。ログ本文をこの集計ファイルへ保存する設計ではありません。
- macOSのWidgetは、本体が `~/.ai_meter_widget.json`（0600）へ保存した表示情報を読みます。有効サービス、期間、手入力、任意APIの取得結果を本体と共有します。APIキーやログ本文は含めません。本体の終了中は最後の表示情報を使い、独自にログやAPIを集計しません。
- Widget用の表示情報が未取得・欠損・不正な場合は起動・更新を案内し、全サービスが無効の場合は設定を案内します。サンプル値はギャラリープレビューに限って使用します。OS側の都合によりWidgetへの反映には時間がかかる場合があります。
- 任意のOpenAI連携を設定すると、OpenAIの組織利用量・費用APIへ認証付きで通信します。Admin KeyはmacOS Keychainに保存します。
- 任意のGCP連携では、ローカルの `gcloud` が発行するトークンでGoogle Cloud Monitoringへ通信します。GCP Project IDはアプリ設定に保存します。`gcloud` は既定の候補パスにある所有者・権限を確認できる実行ファイルのみを使用します。
- 上記APIへの送信にローカルのプロンプト本文は使用しません。
- 大きすぎるファイル・行、過剰な探索件数、不正な数値は拒否します。入力制限に達した収集では以前の集計ファイルを保持します。ログのルートにsymlinkを指定した場合は拒否するため、実体のパスを指定してください。時間制限は協調的な検査であり、OSのI/Oタイムアウトではありません。

個人ログ、集計ファイル、APIキーをIssueやPull Requestに添付しないでください。
セキュリティ上の問題は [SECURITY.md](SECURITY.md) の手順で報告してください。

## ライセンス

[MIT License](LICENSE)
