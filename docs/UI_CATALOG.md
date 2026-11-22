# UIカタログ：AIMeter

- 最終更新：2026-11-22
- アート方針：`docs/ART_DIRECTION.md` の版 1.0 に準拠

## パーツ一覧（役割順）

| パーツ名 | 役割 | 正本の場所（コード／ファイル） | 状態 |
| --- | --- | --- | --- |
| `CharacterSummaryView` | 最重要の残量・鮮度をひとこと案内として伝える | `Sources/AIMeter/CharacterSummaryView.swift` | 使用中 |
| `LiquidBallArtwork` | アプリの生命感と親しみを添える球体キャラクター | `Sources/AIMeter/LiquidBallArtwork.swift` | 使用中 |
| `LiquidGlassSurface` | OS標準およびmacOS 26+のネイティブガラス面を提供する | `Sources/AIMeter/LiquidGlass.swift` | 使用中 |
| `UsageDisplayModePicker` | 要点表示／全枠表示を切り替える | `Sources/AIMeter/UsageDisplayModePicker.swift` | 使用中 |
| `ServiceUsageGroupBox`（`GroupBox`） | サービス別の利用状況とゲージをまとめて表示する | `Sources/AIMeter/AIMeterApp.swift` | 使用中 |
| `SettingsForm` | 設定画面の標準Grouped Form基盤 | `Sources/AIMeter/SettingsStyle.swift` | 使用中 |
| `SettingsSection` | 設定項目を意味のまとまりで区切る標準Section | `Sources/AIMeter/SettingsStyle.swift` | 使用中 |
| `SettingsLabeledContent` | 設定のラベルと値・コントロールを標準配置する | `Sources/AIMeter/SettingsStyle.swift` | 使用中 |
| `SettingsToggle` | 折り返し対応の設定用トグル行 | `Sources/AIMeter/SettingsStyle.swift` | 使用中 |
| `StoreSourcePickerView` | Mac App Store版での安全なフォルダ選択UI | `Sources/AIMeter/StoreSourcePickerView.swift` | 使用中 |
| `CollectionIntroductionView` | 初回起動時の1ページ1主張オンボーディングと収集同意 | `Sources/AIMeter/CollectionIntroduction.swift` | 使用中 |
| `HelpView` | 検索と閉じた質問から入るヘルプ | `Sources/AIMeter/HelpView.swift` | 使用中 |
| `WidgetContent` / `WidgetSurface` | 小・中・大ウィジェットの共通表示面 | `Sources/AIMeterWidgetUI/WidgetViews.swift` | 使用中 |

## パーツ詳細

### `CharacterSummaryView`

- 役割：本体・メニューバー最上部で、最も気にするべき残量や鮮度の問題を1つの短い案内として表示する。
- 使う場面：`DesktopMeterView`、メニューバー `MenuBarExtra` の最上部。
- 使わない場面：設定画面、ヘルプ画面、Widget。
- 状態：通常（案内）／ 警告（35%未満・15%未満）／ 更新中 ／ 未取得 ／ 失敗 ／ 表示サービスなし
- 狙い：開いて3秒以内に「今一番気にするべきこと」を迷わず伝える（主役）。
- アート方針との対応：文字の階層（状態ラベル＞案内文＞根拠・鮮度注記）、348pt幅での折り返し、警告色の限定使用。
- 実装の場所：`Sources/AIMeter/CharacterSummaryView.swift`

### `LiquidBallArtwork`

- 役割：透明な球体と2つの目（リボ）で、計器の冷たさを和らげる。
- 使う場面：`CharacterSummaryView` の左側。
- 使わない場面：設定、ヘルプ、リスト行のアイコン。
- 状態：浮遊・まばたき ／ 静止（`accessibilityReduceMotion` または非表示・遮蔽時）／ 透明度低減 ／ 高コントラスト
- 狙い：「静か・正確・親しみ」のうち「親しみ」を担い、数値だけの圧迫感を下げる。
- アート方針との対応：球体内部のみ `LiquidGlassSurface`（`clear`）を使用し、目や本文と分離する。
- 実装の場所：`Sources/AIMeter/LiquidBallArtwork.swift`

### `LiquidGlassSurface`

- 役割：macOS 26+ のネイティブ Liquid Glass（`clear`）と、macOS 14/15・透明度低減・高コントラスト時のフォールバックを統一的に提供する。
- 使う場面：`LiquidBallArtwork` 等の限定された立体・ガラス面。
- 使わない場面：情報カード（`GroupBox`）や設定画面の全面背景。
- 状態：通常（macOS 26+ ガラス）／ フォールバック（macOS 14/15）／ 透明度低減（不透明面）／ 高コントラスト（1pt枠線）
- 狙い：OS世代やアクセシビリティ設定に関わらず、破綻しない質感と可読性を保つ。
- アート方針との対応：全面ガラス禁止、アクセシビリティ対応。
- 実装の場所：`Sources/AIMeter/LiquidGlass.swift`

### `UsageDisplayModePicker`

- 役割：要点表示と全枠表示を切り替える。
- 使う場面：`DesktopMeterView`、メニューバー。
- 使わない場面：設定画面、Widget。
- 状態：要点 ／ 全枠（macOS 27+ は `.tabs`、それ以前は `.segmented`）
- 狙い：1画面の情報量を抑え、必要なときだけ全枠を展開できるようにする。
- アート方針との対応：認知負荷の上限（畳む・隠す）、OS標準コントロールの採用。
- 実装の場所：`Sources/AIMeter/UsageDisplayModePicker.swift`

### `SettingsForm` / `SettingsSection` / `SettingsLabeledContent` / `SettingsToggle`

- 役割：設定画面（一般、サービス連携、表示、ヘルプ）の見た目と余白を macOS 標準 `Form(.grouped)` に統一する。
- 使う場面：`SettingsView`、各設定タブ、`HelpView`。
- 使わない場面：メインの計器画面（`DesktopMeterView`）。
- 状態：通常 ／ 無効 ／ フォーカス
- 狙い：152pt固定幅などの独自レイアウトを排し、OS標準の落ち着いた設定体験を提供する。
- アート方針との対応：macOS 標準UI、余白と面による整理。
- 実装の場所：`Sources/AIMeter/SettingsStyle.swift`

### `CollectionIntroductionView`

- 役割：概要 → 表示選択 → 集計対象と同意の3ページで、明示開始までログを読まない境界を守る。
- 使う場面：初回の本体・メニューバー・設定。通常利用とWidgetには出さない。
- 状態：概要／表示の試し操作／対象選択・全オフ／戻る・設定へ・次へ。表示だけでは保存済み設定を変更しない。
- 狙い：最初の残量までの反復説明・称賛・自動送りをなくす。標準の `ProviderUsageSection` と `UsageDisplayModePicker` を流用し、サンプルと明記する。
- アート方針との対応：標準GroupBox、システム文字、静止したLiquidBall。新しい色や形を増やさない。
- 実装の場所：`Sources/AIMeter/CollectionIntroduction.swift`

### `HelpView`

- 役割：FAQ検索を主役にし、必要な回答だけDisclosureGroupで開く。
- 使う場面：設定の「ヘルプ & 情報」。メーターには置かない。
- 状態：質問一覧／検索／該当なし／回答・データ取扱いの展開。
- 狙い：以前の2種類のFAQを `HelpQuestions` に統一し、情報の食い違いと質問前の長い紹介をなくす。
- アート方針との対応：既存のSettingsForm・SettingsSection・DisclosureGroupを使用。通常版とStore版の取得・通信・回復手順を分ける。
- 実装の場所：`Sources/AIMeter/HelpView.swift`

### `WidgetContent` / `WidgetSurface`

- 役割：WidgetKit の小（1件）・中（最大3件）・大（最大6件）で、残量率・サービス名・期間・リセットを表示する。
- 使う場面：`AIMeterWidgetExtension` および QA 描画テスト。
- 使わない場面：アプリ本体。
- 状態：通常（公式値／目安）／ 未取得 ／ 更新失敗 ／ データなし・全無効
- 狙い：狭い Widget 領域でも比較軸（バーの左右端と率の右端）を揃え、誤読を防ぐ。
- アート方針との対応：等幅数字、固定サイズ（28pt/18pt/12pt/11pt）、標準 `containerBackground`。
- 実装の場所：`Sources/AIMeterWidgetUI/WidgetViews.swift`

## 統合候補・重複の記録

現在、役割が重複して統合が必要なパーツは確認されていない。設定系パーツは `SettingsStyle.swift` に集約済み、サービス色・アイコン解決は `LiquidGlass.swift` の `providerAccentColor` / `providerIconName` に集約済み。

## 廃止したパーツ

| パーツ名 | 廃止日 | 理由 | 代替パーツ |
| --- | --- | --- | --- |
| 独自ヘッダー・透明ウィンドウ背景・全面ガラス | 既存（`docs/LIQUID_GLASS.md` 記録） | 非前面時の可読性低下とOS標準UIからの逸脱を防ぐため | 標準 `Window` + `.unifiedCompact` ツールバー + `GroupBox` |

## 補足の到達性

一般の保存仕様、OpenAI/GCPの任意連携、キー保守、Antigravityの取得補足、Storeの隠しフォルダ操作は既存のDisclosureGroupへ整理する。操作後の失敗・未適用・保存状態は折りたたみの外に残す。既存の部品のバリエーションとして扱い、新しいトークンは追加しない。監査と比較は `INFORMATION_DESIGN.md` を参照。
