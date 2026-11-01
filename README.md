# ContextHub Flutter

Mac・AndroidでContextHubのMarkdown Vaultを読む、探す、メモを追加するクライアントです。MITライセンス。iPad/iOSは対象外です。

プロジェクトの「現在地・次の一手・未解決・提案」、原文と出典・日時、最近のメモ、アイデア、本文検索、出典付きcontextコピー、Inputへのメモ/AI作業要約の追加に対応します。候補の確認待ち一覧・採用・却下も使えます。保存先はMarkdownのままです。

Androidはエミュレーターで検証済みです。Mac版はApple Silicon・macOS 12以降向けのreleaseビルドと、実アプリでのサンプル閲覧・保存・候補操作を確認しています。OSで選択したフォルダー権限の再起動復元は別項目として検証します。[検証状況と残事項](docs/verification.md)を確認してください。

ビルド済みの.app/APKはこのGitリポジトリには含めていません。利用する成果物は、下記の「ソースから検証・ビルド」の手順で生成します。

## 使い始める

Macは生成した `artifacts/ContextHub Flutter.app` をFinderから開きます。毎回ターミナルで起動する必要はありません。Androidは `artifacts/context-hub-flutter-android.apk` を端末へ転送し、本人の操作でインストールします。このAPKは手元検証用の署名です。

1. 初回は「サンプルで試す」で架空の内容を確認できます。
2. 「Vaultフォルダーを選ぶ」で既存の同期済みVaultのルートを選びます。Androidはローカルのファイル選択画面で、既存の同期先フォルダーを選んでアクセスを許可します。クラウドproviderやストレージ全体のルートは使いません。
3. プロジェクトを開き、要約から出典の原文へ移動します。「検索」はタイトル・本文を対象にします。
4. 「メモを追加」は雑な思いつきでも構いません。1〜8000文字、プロジェクト指定は任意です。AIの作業要約は未検証として扱います。
5. 同期後に「再読込」し、受付状況を確認します。
6. 「確認待ち」で候補の内容と原文を読み、採用・却下を依頼できます。[候補確認の使い方](docs/candidate-review.md)を参照してください。

「この端末のInputに保存」「Mini受領」「整理済み」は別の段階です。アプリは同期を実行しません。既存のSyncthing等がファイルを同期し、Mini側のContextHubが受領・整理します。Androidでは同期アプリがアクセスできる場所を選んでください。アプリ専用のサンプル領域は同期用ではありません。

生成物はAIによる未検証の要約です。原文・出典・訂正の注意を確認してください。コピー直前に変更を検出した場合は表示を更新して停止するので、内容を確認してもう一度コピーします。未知・破損・整合性未確認の記録がある場合もコピーを止めます。

## 保存確認待ち

同じ操作を再送して受付ファイルを増やすことはありません。フォームを保持したまま「同じ操作を確認」を使ってください。フォームを閉じた後は「受付状況」から確認できます。再起動後の未保存本文復元は保証しません。

確認情報が壊れた場合は新規保存を停止し、閲覧は続けます。アプリ専用領域やInputを削除してやり直す前に、[復旧とデータ保全](SECURITY.md)を確認してください。

## ソースから検証・ビルド

Flutter 3.41.5 / Dart 3.11.3、Node 24 / npm、MacはXcode、AndroidはSDKとJDK 21を使っています。Nodeは上流protocolの開発時検証専用で、端末上では不要です。

```sh
git submodule update --init
scripts/verify.sh
scripts/build.sh android
scripts/build.sh macos
```

読取テストのfixture（`assets/*.json`、`test/fixtures/numeric-policy.json`）は本体の生成物です。`scripts/check_fixture_drift.mjs` が固定参照の本体で再生成した出力と比較します。日時・ULID・hashだけを置換し、記録の種類・frontmatter/JSONの値・本文の書式・期待値の差を検出します。`flutter test`（`scripts/verify.sh` も含む）から実行されます。fixtureに含まれない `Input/`・`90_system/intake/`・`90_system/associations/` は対象外で、書き込み側はprotocolテストが確認します。submoduleを更新して差分が出た場合は、`node scripts/prepare_policy_fixtures.mjs` と `node scripts/prepare_numeric_policy_fixture.mjs` で再生成し、Dart側の読取を合わせます。本体のCIもこのクライアントの既定ブランチで同じ検査を行います。

FlutterがPATHにない場合は `FLUTTER_BIN=/path/to/flutter` を指定します。Androidは必要なら `JAVA_HOME` をAndroid Studio内のJDKへ指定します。MacでXcodeをコマンド単位に選ぶ場合は `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を指定します。

Macはプロジェクト内でSwift Package Managerを有効にしています。現行のMac依存にCocoaPodsは不要です。Xcode27.2のSDKが対応するmacOS 12以降・arm64を明示し、Intel用ビルドは対象にしていません。FlutterやXcodeのグローバル設定を切り替える必要はありません。

Xcode規約未承諾のエラーが出る場合は、本人がターミナルで `sudo env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -license` を実行し、内容を確認して同意する必要があります。スクリプトは規約に自動同意せず、グローバルのXcode選択も変更しません。

Androidビルドは `.local-signing/` にこのcheckout専用の検証鍵を作ります。継続して同じAPKを上書き更新するにはこの鍵を保全してください。公開配布用の鍵ではありません。APKの実端末へのインストール、Play配布、MacのDeveloper ID署名・公証は別途対応が必要です。

実機テストは `flutter test integration_test/app_test.dart -d <device>`。AndroidのSAFテストは専用の架空Vaultを用意し、`integration_test/saf_test.dart` 実行中にOSの選択画面で選びます。実Vaultをテストに使わないでください。[検証記録](docs/verification.md)に実施済みと未検証を分けて記載しています。

Macのbookmarkテストは `integration_test/macos_bookmark_test.dart` を `--dart-define=MAC_TEST_PHASE=choose`、プロセス終了後に `--dart-define=MAC_TEST_PHASE=restore` の順で実行します。`--dart-define=MAC_TEST_OPERATION=<同じUUID>` を両方へ渡し、OSの画面で同じ専用Vaultを選択します。専用Vaultの `90_system/mac-test-marker.json` に `{"purpose":"context-hub-native-bookmark-test"}` が必要です。symlink・容量超過の架空ファイルも使うため、詳細は検証記録を参照してください。

## 構成

- `lib/core/`: 上限付きsnapshotのMarkdown/frontmatter・receipt・訂正の読取、検索、context。
- `lib/storage/`: OSアクセス契約、本文を含まない操作journal、固定REQ IDによる保存確認。
- `lib/app/` / `lib/ui/`: 共通画面、Vault切替の応答管理、安全なMarkdownリンク。
- `macos/Runner/VaultBridge.swift` / `android/app/src/main/kotlin/.../VaultBridge.kt`: 限定されたネイティブアクセス。
- `vendor/context-hub`: 候補確認と採用先付き方針に対応する本体の公開commitをsubmoduleで固定。`scripts/verify.sh` が参照先を検査します。

原文/生成物の編集、AIチャット、同期・Gateway管理は含みません。承認後の正式データ作成はMini側が行います。データ処理と保存の詳細は[構成と制限](docs/architecture.md)を参照してください。

採用先付き方針は0.3.0で対応しています。元メモの指定・AI推定を確認して採用先を選び、採用履歴から適用停止を依頼できます。contextコピーには共通と対象projectの有効方針を全文含め、未同期ならコピーを止めます。[本体の使い方](vendor/context-hub/docs/policies.md)と[検証状況](docs/verification.md)を参照してください。
