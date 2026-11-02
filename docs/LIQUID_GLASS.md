# AIMeterのmacOS標準UIとLiquid Glass

残量と注意点を短時間で読み、必要なときに設定できることを優先する。メイン画面・メニューバー表示・現行設定内ヘルプは、OSが提供する背景、タイトルバー、ツールバー、フォームを使う。本文幅348pt、設定の最小860×560pt・初期980×680pt、利用状況の表示順とスクロール上限を維持する。

## ウィンドウと操作の面

デスクトップは通常のSwiftUI `Window` に `DesktopMeterView` を置き、Sceneの `.windowToolbarStyle(.unifiedCompact)` で標準タイトルと更新・ピン留め・設定を表示する。更新中は同じ16ptの領域に `ProgressView` を表示する。ピン留めは標準 `Toggle` で、固定・解除の状態をアクセシビリティ値でも伝える。

アプリが背景を `.clear`、`isOpaque = false`、透明タイトルバーへ上書きする処理と、独自ヘッダー・70ptの空白・独自の区切り線を撤去した。標準ウィンドウ内部のstyle maskや素材を手動で強制しない。`DesktopWidgetWindowAccessor` は、ピンによるlevel、Spaces、背景ドラッグ、表示状態、フレーム保存を担当する。`desktop-widget` 識別子と `AIMeterDesktopWidgetFrame` 保存キーを維持し、旧タイトルの探索にも対応する。

メニューバーは標準 `MenuBarExtra(.window)` を使い、内容内のコンパクトなタイトル・更新・設定と下部の操作を残す。デスクトップと共用の内容には全面の `NSVisualEffectView(.behindWindow)` を重ねない。標準の半透明や前面・非前面での変化はOSに任せる。

本文内の操作には標準のbordered、borderedProminent、borderlessを用途に応じて使う。ツールバーのボタンへ独自のガラス背景・ホバー・押下拡縮・フォーカス輪郭を重ねない。

## 情報を読む面

- サービス別の利用状況は標準 `GroupBox` に表示し、利用詳細は標準ポップオーバーの背景を使う。
- 要点表示 / 全枠表示はmacOS 27以降で標準 `Picker(.tabs)`、それ以前では `.segmented` を使う。
- 残量は標準 `Gauge(.linearCapacity)`、読込中は `ProgressView` を使う。サービスアイコン、数字の桁揃え、警告色、公式値・推定値・未取得の意味を維持する。
- リボの吹き出しは現在の形を保ち、`controlBackgroundColor` による通常の面を使う。警告の輪郭、折り返し、アクセシビリティの要約を維持する。

Liquid Glassを内容カードへ一律に適用しない。Appleはガラスを主に操作・ナビゲーション層へ使い、通常は適応的なregularを利用する方針を示している。clearは高い透明性が必要な限定用途として扱う。

公式資料: [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)、[AppKitの標準デザイン](https://developer.apple.com/videos/play/wwdc2025/310/)、[Liquid Glassの採用](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)。

## 設定とヘルプ

`NavigationSplitView` と標準sidebarの4分類、サービス一覧・詳細の構成を維持する。`SettingsForm` は `Form(.grouped)`、`SettingsSection` は標準 `Section`、ラベルと値は標準 `LabeledContent` を使う。以前の152pt固定ラベル幅、全面ガラス背景、設定NSWindowの透明化は使用しない。

入力行はSection直下へ配置し、ログパス編集やキー入力などの複合行はまとまりを保つ。設定内の現行ヘルプはアプリ情報・データと通信・Q&Aの各Sectionで構成する。検索と標準 `DisclosureGroup` を維持する。独立設定Windowと標準Settings Sceneは同じ `SettingsView` を使う。

設定の画面構成と、収集・認証・保存処理は分離する。OS管理のWidgetKitウィジェットのレイアウトは [WIDGET_LAYOUT.md](WIDGET_LAYOUT.md) を参照する。

## リボとアクセシビリティ

リボの球体、目、浮遊、まばたきは維持する。`LiquidBallArtwork` のガラスは球体内部のローカル `GlassEffectContainer` に隔離し、非前面時にガラスが目を覆う問題を再発させない。文字や情報カードを含む画面全体のガラスコンテナは使用しない。

通常UIはOSの透明度低減・高コントラスト・フォーカス・無効状態へ適応させる。リボの透明度低減、高コントラストの輪郭、視差効果低減による静止表示も維持する。macOS 14以降を対象とし、新しいガラス・Picker APIのavailability分岐を保つ。

## 検証

UIの変更では、348pt幅でのツールバー、長文の折り返し、GroupBox内の情報ボタン、設定の各分類、検索とDisclosureGroup、ピン留めのアクセシビリティ状態を確認する。独立設定Windowと標準Settings Sceneは同じ内容を表示する必要がある。

合成描画・UserDefaults・更新状態を使用する検証と、実MenuBarExtraや通常ウィンドウの操作は区別する。OS設定そのものを切り替える透明度低減・高コントラスト・視差効果低減、実際のVoiceOver音声、各対応OSとIntel実機での描画は、別途確認が必要である。個人ログ、資格情報、常用設定をテスト素材にしない。
