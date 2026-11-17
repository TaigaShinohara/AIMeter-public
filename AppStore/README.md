# Mac App Store用の未完成プロジェクト

このプロジェクトはストア版の構成を検討するための骨格です。コンパイルを停止していたビルドガード（`StoreBuildGuard.swift`）は、実署名・Sandboxでの実証が完了したため解除済みで、Store ターゲットはビルド可能になりました。ただし配布と審査提出は、別途、手順書04の承認ゲートに従って進めます。GitHub配布用のビルド手順とは独立しています。

本体とWidgetは既存のSwiftソースとローカルSwift Packageの共通モジュールを参照します。Bundle ID、Widget ID、Developer Team、App Groupは未確定です。`Configuration/Store.xcconfig` の空欄は値の確認が必要な設定名を示すだけで、Appleでの登録や権限の取得を意味しません。未追跡のローカル設定を使う場合は、既存ファイルや秘密情報をGitへ含めないでください。

権限ファイルにはsandbox、ユーザー選択の読取、ブックマーク、通信、App Groupの候補を記載しています。App Groupや識別子は未設定で、署名・プロビジョニングでの成立は未検証です。従来版とのKeychain、Widget、共有ファイル、更新処理の分離基盤はありますが、入力選択・安全な収集処理への接続が完成していません。これらをストア版で分離・検証する前にガードを除去しないでください。

本体とWidgetのビルド条件には `AIMETER_APP_STORE` を指定しています。ローカルSwift Packageの `AIMeterCore` へはXcodeのビルド設定が伝播しないため、`Package.swift` がマニフェスト評価時の環境変数 `AIMETER_APP_STORE=1` を検出した場合に限り、同じ define を `AIMeterCore` へ追加します（直接配布ビルドでは未設定のため挙動は変わりません）。実際のXcodeビルドでこの経路が意図どおり働くかは未検証です。本体とWidgetはそれぞれ起動時にStoreの配布設定を必須として検証します。URL schemeは本体Info.plistに登録しますが、実アプリでの起動先は未検証です。フラグの適用、展開後の両Info.plistとentitlementの一致、URL登録と実バイナリの検証を用意するまで、ガードを外せません。

App Store向けの署名、アーカイブ、実環境のWidgetKit、各連携の互換性、Appleの審査適合性は未検証です。登録・審査提出・公開はこの骨格の作成には含みません。
