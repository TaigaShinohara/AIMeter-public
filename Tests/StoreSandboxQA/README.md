# Store Sandbox QA（未実行の合成ハーネス）

このハーネスは、利用者が選択したフォルダについて、署名済みSandboxアプリのbookmark保存・復元と、パス置換時の実際の挙動を観察するためのものです。AIMeter本体、Widget、実ログ、APIキー、既存設定を使用しません。実行・署名・審査はこのファイルの作成時には行っていません。

## 安全な実行条件

- 個人データやAPI資格情報のない**専用macOS標準ユーザー**のGUIセッションで実施します。既存のAIMeterアプリやWidgetを起動・変更しません。
- プロセス起動前に実行中のSwift/Xcodeビルド、メモリ、出力先の空き容量を確認し、ビルドは一つずつ `-j 2` で実行します。新規の一時出力先を使い、既存アプリのインストール、上書き、Widget登録をしません。
- `AIMETER_SANDBOX_QA_ROOT` は `/private/tmp/aimeter-store-sandbox-qa-` と小文字の16進32文字だけからなる、今回新規に作成するディレクトリを指定します。`fixture.py init` は親FD相対に新規作成し、owner・0700・開いたFDとディレクトリエントリのdev/inodeを照合します。fixtureの操作は保持したroot FD相対の固定名に限定されます。
- fixtureは単独の専用ユーザーだけが操作し、他のプロセスによる改変がないことを確認します。rootを既存のフォルダへのリンクや共有場所に向けないでください。想定外のオブジェクトやfixture生成の途中失敗は中止し、そのまま保持します。
- QAアプリのBundle IDを通常のAIMeterや既存の検証アプリと重複しないものに変更し、専用のUserDefaults/コンテナを使用します。署名・entitlementの確認が取れず、または既存コンテナに接続する可能性があれば実行しません。
- 本アプリは任意パスの入力欄を持たず、選択先は指定root配下の固定 `base/selected` のみを受け入れます。マーカー読取前には開いたFDのパスがfixture内の許可された固定候補か確認し、固定名の通常ファイルを最大64バイトだけ読みます。マーカーやbookmarkの生値とローカルパスは表示・記録しません。固定の結果コードだけがアプリ画面に表示されます。

## ビルドと署名の準備

以下は実行例であり、署名済みであることを自動保証するものではありません。対象のTeamで使用できる**別のQA Bundle ID**と、既存の開発用署名IDを担当者が確認します。署名鍵やトークンをコマンド引数やログへ出さず、証明書の識別子だけを使います。必要なプロビジョニングの可否は実際のTeam・署名方法に依存し、未確認です。必要な登録や本人認証が発生した場合は別途その操作を扱います。

```sh
QA_ROOT="/private/tmp/aimeter-store-sandbox-qa-$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
python3 Tests/StoreSandboxQA/fixture.py init "$QA_ROOT"
QA_BUILD="$(mktemp -d /private/tmp/aimeter-store-qa-build-XXXXXXXX)"
QA_APP="$QA_BUILD/StoreSandboxQA.app"
mkdir -p "$QA_APP/Contents/MacOS"
cp Tests/StoreSandboxQA/Info.plist "$QA_APP/Contents/Info.plist"
# QA_BUNDLE_ID は確認済みの一意なQA用Bundle ID。
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $QA_BUNDLE_ID" "$QA_APP/Contents/Info.plist"
xcrun --sdk macosx swiftc -j 2 -parse-as-library Tests/StoreSandboxQA/StoreSandboxQA.swift -o "$QA_APP/Contents/MacOS/StoreSandboxQA"
# QA_SIGN_IDENTITY は既存の開発用署名ID。鍵やトークンは指定しない。
codesign --sign "$QA_SIGN_IDENTITY" --options runtime --entitlements Tests/StoreSandboxQA/Sandbox.entitlements "$QA_APP"
codesign --verify --strict "$QA_APP"
```

署名済みappから実際のidentifierとentitlementsを取得し、sandbox、user-selected.read-only、bookmarks.app-scopeが有効で、network・App Group・home-relative例外がないことを確認します。必要なプロファイルと署名元のTeamも照合します。署名できない、想定外の権限が付いている、identifierが既存アプリと一致する場合は中止します。実行後はActivity MonitorのSandbox列などでも対象プロセスのSandboxが有効か別途確認します。ad-hoc署名やテストの成功だけを実署名Sandbox検証の代用にしません。

## 試験

アプリ実行にはGUIセッションが必要です。同一の `QA_ROOT` を明示して、署名済みapp内の実行ファイルを起動します。フォルダ選択画面では `QA_ROOT/base/selected` **だけ**を本人が選びます。アプリは別の場所の選択を拒否します。rootの値は当該セッションの操作者が管理し、結果報告にパスやbookmarkを載せません。

```sh
AIMETER_SANDBOX_QA_ROOT="$QA_ROOT" "$QA_APP/Contents/MacOS/StoreSandboxQA"
```

1. **対照**：選択前に「未許可の対照」を押します。`OUTSIDE_CONTROL_DENIED` はopen拒否、`OUTSIDE_CONTROL_INCONCLUSIVE` は不成立であり拒否の証明ではありません。`OUTSIDE_CONTROL_OPENED` なら環境に想定外のアクセスがあるため中止します。
2. **選択と復元**：「1 選択・保存」で合成フォルダを選びます。`BOOKMARK_SAVED_NOT_YET_VERIFIED` は保存操作のみです。一度アプリを終了し、同じ署名・Bundle ID・rootで再起動して「2 復元・権限開始」を押します。`SCOPE_STARTED` を確認してから対照を再度実行します。選択取消で既存選択を変更しないことも別に確認します。
3. **通常読取**：「3 lstat」→「4 root open」→「5 marker確認」の順に押します。`INSIDE_MARKER_OBSERVED` は合成対象を開けた結果であり、実アプリの収集成功を意味しません。
4. **置換**：各ケースに新しいfixtureを使い、選択・保存・scope開始まで行います。アプリの各ボタン間で止め、別のターミナルから下記の**一つだけ**を実行して再開します。操作は合成fixture内部で対象を移動し、削除しません。

   ```sh
   python3 Tests/StoreSandboxQA/fixture.py replace-root "$QA_ROOT"
   python3 Tests/StoreSandboxQA/fixture.py replace-parent "$QA_ROOT"
   python3 Tests/StoreSandboxQA/fixture.py replace-directory "$QA_ROOT"
   ```

   scope開始後かつlstat前、lstat後かつroot open前、root open後の3つの時点をそれぞれ別fixtureで試します。`replace-root` は最終要素、`replace-parent` は親を合成outsideへのリンクに置き換え、`replace-directory` は同種の別ディレクトリへ置き換えます。移動先の既存オブジェクトを上書きしないようmacOS `renameatx_np(RENAME_EXCL)` を使用し、APIまたは対象filesystemが非対応なら失敗として止めます。途中の段階で失敗したfixtureは自動修復・削除せず保持します。実際の出力を、拒否・失敗、元の合成marker、外側の合成markerに分けて記録します。`OUTSIDE_MARKER_OBSERVED` は置換後の外側markerを読んだ事実であり、選択時の対象とFDの一致を証明しない結果です。`LSTAT_FAILED` や `ROOT_OPEN_FAILED` だけではSandboxが拒否したと断定しません。
5. **終了**：「権限終了」またはアプリを終了し、QA appのプロセス終了を確認します。生成したfixtureや一時アプリは自動削除しません。削除は対象確認と別の許可があるまで行いません。

試験結果には、ケース名、観測された固定コード、macOS/Xcodeの版、署名の種類、entitlementの確認結果、実施・未実施を記録します。必要なGUI操作は本人が行い、個人ログ、APIキー、bookmarkの中身、ローカルパス、markerの生値を添付しません。

## 判定の限界と停止条件

- このハーネスのbookmarkは実アプリとは別のBundle IDと署名・コンテナであり、実アプリやWidgetで同じ結果になる保証はありません。Appleによる審査承認でもありません。
- `lstat` と `fstat` の一致は、**最初のlstat前**の選択先・親の置換を検出できません。bookmarkの解決成功、scope開始、同一のパス・inodeだけで選択時の原本との同一性を証明しません。inodeの再利用、同一inodeの内容変更、移動、再起動、再マウントや異なるファイルシステムは別途条件を分けます。
- この試験は操作者が合成fixtureを制御する限定的な再現です。同一ユーザーの敵対的プロセス、対象OS全版、実利用者のフォルダ、ネットワークボリュームに対する安全性は証明しません。rootの初期取得と選択の原子的な結合も未証明です。
- fixtureの作成・操作では親FDを開いてrootのowner・mode・dev/inodeを照合し、操作前後に親エントリとの一致を確認します。ただし、`mkdir`の成功から最初の`stat`までに同一ユーザーがrootを置換する競合や、照合後にroot自体を移動する競合は防止できません。保持FDは既に開いたディレクトリを指し続けるため、検出前の処理が移動後の位置で行われる可能性もあります。専用ユーザーでfixtureを単独管理し、他のプロセスが同時に変更できる状況では実行しないでください。
- `test_fixture.py` は手動QAとは別に合成rootを自ら作る回帰テストです。テストのrootも自動削除せず、一時領域に保持します。手動QAのfixtureは変更しません。
- `FD_OUTSIDE_FIXTURE_REJECTED`、予期しない署名・権限、fixture外の選択、環境の破損、想定外の第三者プロセスによるfixture変更、アプリが実データへ触れる可能性が生じた場合は**即中止**します。範囲外へのアクセス成功を対策完了と扱わず、内容を追加で読まずに原因を調べます。
- 追加のroot取得方法、実Widget、Intel、macOS 14、実API、Apple審査と配布は対象外です。
