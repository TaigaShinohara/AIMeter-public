# ビルド参照

- 現在の状態：**未ビルド（`AppStore/Configuration/StoreBuildGuard.swift` の `#error` によりコンパイル停止中）**
- 対象プロジェクト：`AppStore/AIMeterStore.xcodeproj`
- 設定ファイル：`AppStore/Configuration/Store.xcconfig` + 未追跡の `AppStore/Configuration/Store.local.xcconfig`（本人が作成）
- バージョン / ビルド番号：`1.2.0` / `1`（`project.pbxproj` より）
- 実行対象OS：macOS 14.0 以降
- 本機確認済みツールチェーン：Xcode 27.2 (Build 27B52) ※ 2026-04-28 以降の最低要件（Xcode 26+）を満たす
- チェックサム / Archive パス：（Xcode Archive・App Store Connect アップロード完了後に記録）
- 必須確認：`com.apple.quarantine` 拡張属性がバンドル内に残っていないこと
