# 権限ごとの理由文（Mac App Store App Sandbox Entitlements）

`AppStore/Configuration/App.entitlements` および `Widget.entitlements` に記載されている権限候補に基づく。

1. **`com.apple.security.app-sandbox` (`true`)**
   - 理由：Mac App Store ガイドライン 2.4.5(i) に準拠し、アプリ本体および Widget Extension を App Sandbox 内で安全に動作させるため。

2. **`com.apple.security.files.user-selected.read-only` (`true`)**
   - 理由：利用者が標準のファイル選択パネルで明示的に選んだ AI ツールのローカルログフォルダ／ファイルのみを読み取り専用で集計するため。

3. **`com.apple.security.files.bookmarks.app-scope` (`true`)**
   - 理由：利用者が一度許可したローカルログフォルダへの読み取り権限を、アプリ再起動後も安全に復元して再集計できるようにするため。

4. **`com.apple.security.application-groups` (`$(AIMETER_STORE_APP_GROUP)`)**
   - 理由：本体アプリが集計した利用状況のサマリ（割合・更新時刻等）を、同一アプリ内の macOS Widget Extension へ安全に共有するため（Widget 側は独自にログやAPIへアクセスしません）。

5. **`com.apple.security.network.client` (`true`)**
   - 理由：利用者が任意で OpenAI 連携を有効化し Admin Key を設定した場合に限り、OpenAI 公式 API（`api.openai.com`）へ組織利用量を照会するため。
