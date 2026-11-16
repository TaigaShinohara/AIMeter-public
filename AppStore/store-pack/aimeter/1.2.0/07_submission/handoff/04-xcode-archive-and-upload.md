# 手順書：Xcode Archive・App Store Connect 入力・提出直前確認（AI Meter / Mac App Store）

## 目的と完了条件
- 完成した Store 版アプリを Xcode で Archive して App Store Connect へアップロードし、素材パックの正本から全項目を下書き入力して「審査へ提出」ボタンの直前状態にする。
- 完了条件：
  1. App Store Connect 上でビルド `1.2.0 (1)` の処理が完了し、バージョンページに紐付けられていること。
  2. アプリ名・サブタイトル・プロモーション文・説明・キーワード・スクショ・App Privacy・年齢レーティング・審査用メモ・URLがパック正本と一致して保存されていること。
  3. 提出ボタンは押さずに停止し、最終プレビュー確認をユーザー本人へ依頼できる状態になっていること。

## 前提
- `handoff/01` 〜 `03` がすべて完了し、`validate_pack.py` が合格していること。
- App Store Connect にアクセスできるアカウントでログイン済み（2要素認証対応可）であること。

## 手順
1. **Archive と Quarantine 確認**：
   - `AppStore/AIMeterStore.xcodeproj` を Xcode で開き、スキームの Archive を実行する（1プロセスずつ実行）。
   - 生成された `.xcarchive` 内に `com.apple.quarantine` 拡張属性がないことを確認する（例：`xattr -r -l <archive_path> | grep com.apple.quarantine` が空であること）。
2. **App Store Connect へアップロード**：
   - Xcode Organizer →「Distribute App」→「App Store Connect」→「Upload」を実行し、アップロード完了と App Store Connect 側での処理完了（メール通知または「アクティビティ」表示）を待つ。
3. **App Store Connect メタデータ・申告入力（素材パック正本より転記）**：
   - `01_copy/by-store/apple.md` からアプリ名・サブタイトル・プロモーション文・説明・キーワード・新機能を入力。
   - `02_images/screenshots/apple/macos/` からスクリーンショットを順番どおりアップロード。
   - `00_manifest.yaml` からプライバシーポリシーURL・サポートURLを入力。
   - `04_declarations/privacy-answers.md` に沿って「App Privacy（データを収集しない）」を回答・公開。
   - `04_declarations/age-rating-answers.md` に沿って年齢レーティング（4+）および輸出コンプライアンスを回答。
   - `04_declarations/pricing-and-iap.md` に沿って価格「無料（¥0）」・配信地域を設定。
   - `06_review/review-notes.md` から App Review Information（連絡先・メモ・サインイン不要）を入力。
4. **ビルド紐付けと保存（提出ボタン手前で停止）**：
   - 手順2のビルドを選択して「保存」を押す。
   - **「審査へ提出（Add for Review / Submit to App Review）」ボタンは押さずに停止**し、ユーザー本人に最終確認を依頼する。

## 注意
- 規約同意・有料契約・最終提出ボタンの確定はユーザー本人の明示承認なしに実行しないこと。
