# macOS Widgetの表示

WidgetKitの小・中・大に対応し、残り割合、サービス名、期間・モデル群を表示します。表示件数は小が1件、中が最大3件、大が最大6件です。本体が保存した表示情報を読み、独自のログ収集やAPI通信は行いません。

## 表示の規則

- 小の率は28pt、中・大は18pt、名称12pt、補足11pt。主要数値の自動縮小は行わない。
- 中・大の名前列と66ptの率欄は全行で共通。バーの左右端と率の右端を揃える。
  量ON/OFF、通常サービスとquota-onlyでもバーの比較軸を動かさない。
- 期間・モデル群と使用量は独立した領域へ配置する。長い期間で量が押し出されない。
- 名称は1行。小の期間・モデル群は最大2行、中・大は1行。
  上限超過は末尾省略し、全文はAccessibilityと本体の確認経路へ残す。
- 公式値、設定上限の「約」、未取得を区別する。未取得にバーを作らず、既知の0%は塗り幅0。
- 使用量は設定ONの通常サービスだけ。quota-onlyにトークン量を作らない。
- 小・大のリセット、更新失敗、データなし／全無効の案内を保持する。
  中は表示にないリセットをAXへ追加しない。使用量OFF時はAXからも量を除く。
  大のリセットは左列へ置き、11ptを維持する。表示では接頭辞の「あと」を省き、AXには全文を残す。
- 使用量のAXは「利用量X、上限Y 単位」、未取得では「推定使用量」とする。
- 外周はWidgetKitの標準content marginsを使い、以前の追加12/14ptを重ねない。
  背景は共通SurfaceのcontainerBackgroundを使う。

## 構造

`AIMeterWidgetUI`のContentを本番・描画テストで共有し、Surfaceを本番・QA extensionで共有する。
本番ExtensionにはProvider、entry point、既存kindとaimeter://を残す。
UIはCoreだけに依存し、本体への依存や新しいデータ経路を作らない。

`AIMeterWidgetFixtures`、`AIMeterWidgetQAHost`、`AIMeterWidgetQAExtension`は検証専用。
QAのID・kind・URLは本番と分離し、compiled snapshotだけを返す。
QA entitlementsはsandboxのみで、本番App Group・home読取例外・network権限を含めない。
製品の依存グラフと通常のapp/ZIPにはQAコードやfixtureを含めない。

## 合成テスト

描画・幾何テストでは全3サイズ、使用量OFF/ON、0/1/2/3/6/7件、長文、未取得、quota-only、空状態、失敗、明暗と、残量の境界値を確認します。実Viewのframeを観測し、領域内への収まり、行の非重複、割合とバーの整列、0/100%の塗り、期間と量の独立領域を検証します。

テスト用content canvasは小128×128pt、中308×128pt、大308×308ptです。これは特定のOS配置に基づく条件であり、すべてのOS・配置の寸法を保証しません。ImageRendererはWidgetKitの自動余白や背景合成を再現しないため、画像サイズの一致だけで文字欠けやOS背景が正しいとは判定しません。

アクセシビリティは、情報元、使用量と上限の役割、長い名称の全文、数値表示設定との一致を確認します。実際のVoiceOver音声は別の確認です。

## ローカルQA

```sh
./scripts/build_widget_qa.sh
```

このスクリプトは `.build/widget-qa/AIMeterWidgetQA.app` を生成し、ビルド・署名だけを行います。インストールやOS登録は行いません。先に実行中のビルド、メモリ、空き容量を確認してください。

scratch先は `AIMETER_WIDGET_QA_SCRATCH_PATH` で指定できます。再導入時は `AIMETER_WIDGET_QA_BUILD_NUMBER` に正整数を指定し、appとappexのbuild番号を一緒に更新します。

実WidgetKitでは、ギャラリー、通知センター、デスクトップの各配置で全サイズを確認します。長文、未取得、更新失敗、データ未取得、末尾のリセット表示を含め、既存の本番Widgetや個人の設定に影響しない環境を使います。合成QAの登録・表示は、本体からの共有ファイル、Widget Sandbox、署名済み配布候補の動作確認の代わりにはなりません。

各対応OS、Intel実機、壁紙上の背景合成、実際のVoiceOver音声は別途確認してください。ソースのマージと配布アプリの公開も別の工程です。
