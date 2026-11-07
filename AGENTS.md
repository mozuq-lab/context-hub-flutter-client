# ContextHub Flutter 開発ガイド

利用者向けの説明・ビルド手順は[README](README.md)にあります。このファイルは開発時だけに必要な規約・構成・検証手順をまとめます。

## 開発規約

- 対象はMac（Apple Silicon）とAndroid。iPad/iOSは対象外。Flutter/Dartで共通画面を作る。
- 日本語で報告・文書・コメントを書く。識別子は英語。既存Markdownが正本で、SQLiteは追加しない。
- 本体の固定公開版をvendor/context-hubへ置く。個人運用repo・実Vault・秘密・端末IDをコピーしない。
- 原文と生成物は編集しない。書込は本人操作に対応したInputの新しいcapture要求と、候補を明示確認した採用・却下・適用停止要求、定義hashに結び付けたプロジェクト状態変更要求と名前・別名・キーワードの変更要求、NOW項目キーに結び付けた完了報告、下書きhashに結び付けた見送り要求だけ。model/Gateway/Syncthing設定・サービス管理を追加しない。
- Androidは選択したローカルフォルダーへのSAF権限を利用。全ストレージ権限を要求しない。Macは選択したVaultの通常ファイルのみを扱い、symlinkとパス逸脱を拒否する。
- 読取は1ファイル1MiB、合計64MiB、読むファイル20000件・走査100000エントリー、深さ12。アプリが参照しない本体の記録（`snapshotSkippedPaths`）は数えず読まない。表示の再読込は更新時刻と大きさが変わらないファイルを前回の本文から引き継ぎ、確認を伴う操作（コピー・採用・依頼）は全体を読み直す。部分読取の注意、出典、未検証、訂正、競合、受付と整理の状態を保持する。
- 保存は操作IDとfingerprintを先にアプリ専用領域へ耐久記録。同じ操作を再作成しない。結果不明は確認のみ。壊れた確認情報は新規保存を止め、閲覧は継続する。
- 保存確認・同期・Mini受領・整理完了を区別する。読込時刻を同期完了と表示しない。
- 生HTML・外部画像を実行/取得しない。内部リンクは取得済みの記録だけ、外部http(s)は明示操作のみ。
- fixtureはサンプル/一時Vaultのみ。回帰はRED→GREEN。flutter analyze、flutter test、両OSのbuild、実アプリ検証を行い、未検証を明記する。
- 実Vault書込、モデル課金、環境設定/常駐サービス変更、公開・pushは別途対象と影響を示して承認を得る。可逆な開発とサンプル検証は継続する。
- ツールが生成する設計・実装計画・途中レビュー・進捗ログなどの中間成果物は `.agent-work/` などのGit対象外領域へ保存し、コミットしません。`docs/superpowers/`・`docs/reviews/`・作業用の計画/判断ログも公開対象外です。README・利用手順・構成説明・現在の制限・最終的な検証状況は公開資料として整え、途中経過を残しません。

## コード構成

- `lib/core/`: 上限付きsnapshotのMarkdown/frontmatter・receipt・訂正の読取、検索、context、候補一覧と方針の読取。
- `lib/storage/`: OSアクセス契約、本文を含まない操作journal、固定REQ IDによる保存確認、候補の採用・却下・適用停止要求の保存。
- `lib/app/` / `lib/ui/`: 共通画面、Vault切替の応答管理、安全なMarkdownリンク。
- `macos/Runner/VaultBridge.swift` / `android/app/src/main/kotlin/.../VaultBridge.kt`: 限定されたネイティブアクセス（MethodChannel）。
- `vendor/context-hub`: 本体の公開commitをsubmoduleで固定。protocol検査とfixture生成に使う。
- `scripts/`: 検証（`verify.sh`）、release生成（`build.sh`）、protocol検査とfixture生成のNodeスクリプト、MacのSwift snapshot検査（`test_macos_snapshot.py`）。

データ処理と保存の設計は[構成と制限](docs/architecture.md)、権限とデータ保全は[SECURITY.md](SECURITY.md)を参照してください。

## 開発環境

- Flutter 3.41.5 / Dart 3.11.3、Node 24 / npm、MacはXcode、AndroidはSDKとJDK 21。
- Nodeは上流protocolの開発時検証専用で、端末アプリには同梱しない。
- MacはプロジェクトでSwift Package Managerを有効にしている（`pubspec.yaml` の `enable-swift-package-manager`）。現行のMac依存にCocoaPodsは不要。Xcode 27.2のSDKが対応するmacOS 12以降・arm64を明示し、Intel用ビルドは対象外。FlutterやXcodeのグローバル設定は切り替えない。
- `FLUTTER_BIN`・`JAVA_HOME`・`DEVELOPER_DIR` はコマンド単位で指定する。スクリプトはXcode規約に自動同意せず、グローバルのXcode選択も変更しない。

## 基本検証

```sh
git submodule update --init
scripts/verify.sh
```

`scripts/verify.sh` は次を順に行います。

1. submoduleを取得し、`vendor/context-hub` が固定commitであることを確認する。
2. `npm ci --ignore-scripts` と `npm run build:protocol` で本体のcoreをビルドする。
3. `flutter pub get`、`flutter analyze --no-pub`、`flutter test --no-pub` を実行する。
4. Macでは `scripts/test_macos_snapshot.py` でSwiftのsnapshot検査を行う。

`flutter test` のprotocolテストは、Dartが保存したcapture・採用・却下・適用停止・プロジェクト状態変更・完了報告・下書きの見送りと入力化のREQを固定参照の本体（Node）へ渡し、受理・本文/出典一致・重複排除・方針と履歴の再同期を確認します。実モデルは使いません。

## 本体（submodule）とfixture

読取テストのfixture（`assets/*.json`、`test/fixtures/numeric-policy.json`）は本体の生成物です。`scripts/check_fixture_drift.mjs` が固定参照の本体で再生成した出力と比較します。日時・ULID・hashだけを置換し、記録の種類・frontmatter/JSONの値・本文の書式・期待値の差を検出します。`flutter test`（`test/fixture_drift_test.dart`、`scripts/verify.sh` も含む）から実行されます。fixtureに含まれない `Input/`・`90_system/intake/`・`90_system/associations/` は対象外で、書き込み側はprotocolテストが確認します。

本体のcommitを進めるときは、次をそろえて変更します。

1. `vendor/context-hub` を新しい本体commitへ更新する。
2. `scripts/verify.sh` の固定commit（`git -C vendor/context-hub rev-parse HEAD` との比較）を同じcommitへ更新する。
3. `flutter test` でfixtureとの差分が出た場合は、`node scripts/prepare_policy_fixtures.mjs` と `node scripts/prepare_numeric_policy_fixture.mjs` で再生成し、Dart側の読取を合わせる。

本体のCI（`client-contract` ジョブ）は、このクライアントの既定ブランチを取得し、submoduleの代わりに本体の対象commitを置いてfixture比較とDartテストを実行します（`continue-on-error` で、失敗しても本体のPRは止めません）。本体の変更で失敗した場合は、本体のmerge後にこのリポジトリでfixtureの再生成と読取の更新を行います。

## 実機・実アプリのテスト

実Vaultをテストに使わないでください。結果は[検証状況](docs/verification.md)に、実施済みと未検証を分けて記載します。

- サンプルの実アプリ検査: `flutter test integration_test/app_test.dart -d <device>`
- 候補操作と方針: `integration_test/review_test.dart`・`integration_test/scoped_policy_test.dart`
- Android SAF: 専用の架空Vaultを用意し、`integration_test/saf_test.dart` の実行中にOSの選択画面で選ぶ。
- Mac bookmark: `integration_test/macos_bookmark_test.dart` を `--dart-define=MAC_TEST_PHASE=choose`、プロセス終了後に `--dart-define=MAC_TEST_PHASE=restore` の順で実行する。両方へ同じ `--dart-define=MAC_TEST_OPERATION=<UUID>` を渡し、OSの画面で同じ専用Vaultを選ぶ。専用Vaultには `90_system/mac-test-marker.json`（`{"purpose":"context-hub-native-bookmark-test"}`）、別の架空ファイルへの `00_inbox/outside-link.md` symlink、1MiB超の `00_inbox/oversized.md` を用意する。テストはマーカーを確認してからInputへ保存する。

## release成果物

- `scripts/build.sh [all|macos|android]` で `artifacts/` へ生成する。`artifacts/` はGit対象外。
- Androidは `.local-signing/context-hub-test.jks` にcheckout専用の検証鍵を作り、APK v2で署名する。鍵はGitへ含めない（`.gitignore` 済み）。
- Macはad-hoc署名で、`codesign --verify --deep --strict` で成果物を確認する。増分ビルドで外側の署名sealが古く残る場合は、Flutterのbuild出力をcleanしてから再生成する。署名identityやグローバル設定を変更して回避しない。
- MacのDeveloper ID署名・公証、Intel Mac、Play公開は未対応。
