# 実OSでの合成セキュリティ検証

通常のSwift/Pythonテストに加えて、`scripts/verify_security_runtime.swift` は
productionの `BoundedInput`、`SharedStore.saveWidgetSnapshot`、`KeychainHelper` を
実OSの合成入力で検証する。
これはアプリを起動するツールではない。個人ログや既存APIキーを入力しない。

## 実行前の条件

実行中のbuild、メモリ、出力先の空き容量を先に確認する。
リポジトリ外に作成した自分専用の一時出力先を使い、既存成果物に上書きしない。
productionと異なるソースから作ったツールの結果を配布候補の結果へ流用しない。

以下の `OUTPUT` は新しい一時出力先、`IDENTITY` は許可されたDeveloper ID証明書の
SHA-1 fingerprintである。秘密鍵の値はコマンドへ渡さない。

```sh
swiftc -parse-as-library -D AIMETER_SECURITY_PROBE -target arm64-apple-macos14.0 \
  -module-cache-path "$OUTPUT/module-cache" \
  scripts/verify_security_runtime.swift \
  Sources/AIMeter/KeychainHelper.swift Sources/AIMeterCore/*.swift \
  -o "$OUTPUT/security-probe"
cp "$OUTPUT/security-probe" "$OUTPUT/security-probe-reader"
codesign --force --sign "$IDENTITY" --identifier com.local.AIMeter.security-probe \
  --options runtime --timestamp=none "$OUTPUT/security-probe"
codesign --force --sign - --identifier com.local.AIMeter.untrusted-security-probe \
  --options runtime --timestamp=none "$OUTPUT/security-probe-reader"
"$OUTPUT/security-probe" --untrusted-reader "$OUTPUT/security-probe-reader" \
  > "$OUTPUT/result.json"
```

この署名は検証ツールの識別用であり、公証済み配布アプリの署名検証を代替しない。
Intel用ツールのビルド・実行は別の対応環境で行い、arm64上の成功と区別する。
Coreの全ファイルを同じmoduleとしてコンパイルし、実際のWidgetモデル・検証・writerを使う。
現行Coreの依存はmacOS標準のFoundation/Darwin/CoreFoundation/SwiftUI/WidgetKitであり、
アプリ本体やWidget extensionのentry pointはこのコマンドに含めない。

## 検証する範囲

- 新規0700ディレクトリ内の合成ファイルについて、所有者・0600・extended ACL、
  atomic置換、集計用writerのsymlink/FIFO拒否とリンク先の保持を確認する。
- Widget表示cacheは別writerとして、明示した合成URLだけへ保存する。
  round trip、owner・0600・extended ACL、atomic置換、不正/1MiB超のsnapshotによる
  旧cache保持、rename失敗時のdestination・sentinel・別cache保持、temp回収を検査する。
- Widget writerではsymlink/FIFOのdestination自体をatomicに置換できることが正常動作である。
  readerがそれらを拒否し、writerが非ブロックで通常fileへ置換し、symlinkの元の参照先を
  変更しないことを確認する。不正/過大snapshotの拒否時にはsymlink自体も保持する。
- Widget用の通常親と、read ACEをfileへ継承する合成親を別々に作る。
  独立したcontrol fileにextended ACLが付くことを先に確認し、production writerの出力を検査する。
  owner・0600だけで成功にせず、継承されたextended ACLが残れば検査を失敗として記録する。
  probeがWidgetの出力ACLを消して合格にすることはしない。
- 新規custom Keychainだけを明示指定し、合成itemの保存・読取・更新・削除、
  locked時の拒否・既存値保持・legacy値保持を検証する。
- OSが作成したKeychainファイルのmodeを記録し、検証用の同じinodeだけを0600へ制限する。
- 別署名のreaderが同一UIDでも合成itemを読めないか確認する。
  パス検査失敗やitem不在はACL拒否の成功として数えない。
- default Keychain/search listを変更するAPIは呼ばない。作成直後とcleanup後に構成を比較し、
  OSが自動登録した場合は失敗として終了する。削除対象はその実行で作成に成功したrefだけである。

JSONは固定の検査名・真偽・OSStatus・非秘密のmode情報だけを記録する。
WidgetについてはACL entry数と合成過大snapshotのencoded byte数も記録する。
合成password/item値は出力しない。失敗や未要求のreader試験を成功扱いしない。
古いKeychain APIを使うため、現行SDKの非推奨警告が発生する。

## 配布候補で別途必要な確認

このツールの成功だけで、実アプリのKeychain ACLやWidget Sandboxが確認済みにはならない。
Widget writerの検査も、同じproduction helperへ合成URLを渡した実OS上の結果である。
署名候補本体が実際に作成したcache、別UIDからの実効拒否、WidgetKitの実appex/PIDに
よる読取・拒否・実表示は別に確認する。HOMEだけを変えた同一UIDの候補起動を隔離とみなさない。
同じsource SHAから作った署名候補を、個人ログ・実資格情報を置かない標準ユーザーで確認する。
その環境を用意できない場合は、未確認として記録する。

候補のapp/appex実署名・実entitlement、Apple公証・staple・Gatekeeper、GUI初回/継続/再起動、
Widget登録・表示・expiry、別UIDのfile拒否、使用するoptional APIの最小権限と失敗時動作は別に記録する。
Intelと最低対応macOS 14の実行確認も独立した項目であり、Universal収録やminimum OS設定の
静的検査を実行成功として報告しない。配布用の成果物は、この公開リポジトリの
検証したコミットから作り、ソースSHAと対応づける。
