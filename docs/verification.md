# 0.3.0の検証状況

2026-11-01。架空サンプル・一時Vault・専用エミュレーターを使用した確認結果です。実Vault・実モデル・Gateway・同期サービスへの接続や設定反映は含みません。

## 確認済み

- Flutter 3.41.5 / Dart 3.11.3。静的解析の指摘なし、共通66テスト成功。
- 読取上限、原文hash、訂正、receipt、検索、contextコピー、Vault切替、保存結果不明、二重操作、壊れたjournal、候補の採用・却下、採用先、適用停止、数値のプロジェクトID、コピー中の方針更新を検査。
- Dartが実保存したcapture・採用・却下・適用停止REQを固定参照の本体へ渡し、受理・本文/出典一致・重複排除・方針と履歴の再同期を確認。実モデルは不使用。
- Swiftのsnapshot検査14項目。件数・容量・symlink・1MiB超の除外・ディレクトリ移動時の識別・直下POLICY.mdの読取を確認。
- MacとAndroid API35/arm64で実bridgeを使い、サンプル閲覧・原文・検索・クリップボード・メモ保存・同じ操作の確認・既存ファイル不変を確認。
- 両OSで候補詳細・採用先の確認・採用/却下/適用停止REQの保存を確認。Macテストは専用のアプリcontainer内領域を使用。
- Androidエミュレーターの実SAF選択で、永続URI権限・Input保存・rename/readback・再確認・未対応provider拒否を確認。
- Mac release `.app` とAndroid release APKのビルド・通常起動・署名検証を確認。Macはarm64/macOS 12以降、ad-hoc署名でTeamIdentifierなし。Androidはcheckout専用の検証鍵によるAPK v2署名。

## ふりかえりとプロジェクト状態（0.3.0以降の追加）

- Linux上のFlutter 3.41.5で、静的解析の指摘なし、共通73テスト成功。
- Dartが保存したプロジェクト状態変更REQを固定参照の本体へ渡し、受理・定義への反映・重複排除・反映後の同期で依頼済み表示が外れることを確認。
- サンプルのREVIEW.mdの読取、停滞表示、状態変更ダイアログからの依頼保存をwidgetテストで確認。
- 休止→再開で定義が元のhashへ戻る場合も、古い依頼を未反映と扱わないことを、本体での連続した2回の変更で確認。
- 「サンプルで試す」の架空Vaultは初回だけ作成されるため、以前の版でサンプルを開いた端末ではREVIEW.mdが表示されません（アプリのデータを消さずに確認する方法は未整備です）。
- Vault直下のREVIEW.mdを読むSwift・Kotlinの変更は、MacのSwift snapshot検査（追加2項目）・両OSのビルド・実アプリでは未確認です。

## 完了・解決の報告、作業記録の下書き、前回からの変化（0.3.0以降の追加）

- Linux上のFlutter 3.41.5で、静的解析の指摘なし、共通77テスト成功。
- Dartが保存した完了報告・再開のREQを固定参照の本体へ渡し、受理・NOW項目一覧への反映・重複排除・同期後に「解決済み・完了」へ移ることを確認。
- Dartが保存した下書きの見送りREQと、下書きから作った入力（下書きIDとhash付き）を本体へ渡し、見送り・使用済みになることを確認。
- サンプルを開いたときに既読を記録し、NOWが変わったVaultを読み直すと一覧の印・プロジェクト画面の変化表示・NEWが出ることをwidgetテストで確認。
- 既読の記録が容量内に収まること、前方一致する別の項目を取り違えないこと、下書きからの入力をプロジェクト・hash・確認待ちで止めることを単体テストで確認。
- Swift・Kotlinの変更はありません。項目一覧と下書きは既存の`90_system/`のJSONとして読み、既読の記録は既存の`settings.json`に保存します。
- 以前の版でサンプルを開いた端末では、サンプルに項目一覧がないため完了報告のボタンが出ません。

## 書きかけの保持、記録が増えたときの読取、呼び名とキーワード（0.3.0以降の追加）

- Linux上のFlutter 3.41.5で、静的解析の指摘なし、共通108テスト成功。
- 書きかけのメモ: 閉じたフォームの本文を次に開いたときに戻すこと、アプリの一時停止（inactive）で待たずに残すこと、保存が確かめられたら消すこと、保存結果が不明なまま閉じた書きかけは同じ操作IDの確認へ戻して再送しないこと、容量上限（保存結果が不明な書きかけは捨てず本文だけを外す）と残さない設定、保存を始める前に操作IDを書きかけへ残すこと、保存結果が不明な書きかけは確認するまで閉じられないことをwidget・単体テストで確認。
- 読取: 固定参照の本体（MockLlm）で端末からのメモ40件を受け付けて整理したVaultを作り（`scripts/generate_growth_vault.mjs`）、アプリが読まない記録を除いても画面に出る内容（記録・受付状況・NOW・候補・方針・context）が変わらないこと、メモ1件あたりの読取が約7.3件（フォルダーを含む）から約4件に減ることを確認。差分読込の結合と、上限到達の表示をテストで確認。
- 呼び名とキーワード: Dartが保存した`project-definition`のREQを固定参照の本体へ渡し、受理・定義への反映・本文と状態の保持・重複排除・同期後に依頼済み表示が外れることを確認。プロジェクト画面からの依頼と、反映待ちの間に状態変更・定義変更を重ねられないことをwidgetテストで確認。
- 本体の固定参照を、HOMEの次の一手（本体#6）と定義変更を含む版へ進め、読取fixtureを再生成した。
- Swift・Kotlinの変更（読まない記録の除外、件数上限の変更、更新時刻と大きさによる差分読込、`drafts.json`の扱い）は、この環境にXcode・Android SDKがないため、ビルド・MacのSwift snapshot検査（`scripts/test_macos_snapshot.py`に除外・差分読込・書いた直後のファイルを引き継がないこと・更新時刻だけの変化の項目を追加済み）・実アプリでは未確認です。

## 制限・追加確認

- MacのNSOpenPanelによるフォルダー選択、bookmarkの別プロセス再起動復元・再選択は未完了です。サンプルの実bridge検査とは区別します。
- 実Android端末・メーカー固有provider・microSD・Syncthingとの実同期は未検証です。
- OSによる強制終了・電源断、volume UUIDを取得できないMacボリュームの再マウントを跨ぐ保持は未検証です。
- 適用停止理由の専用入力・履歴表示は未対応です。判断者・日時・対象snapshotは保持します。
- MacのDeveloper ID署名・公証・Intel Mac、Play公開は未対応です。検証APKの鍵はGitに含めません。

## 再検証

基本検証は `scripts/verify.sh`、release生成は `scripts/build.sh macos` と `scripts/build.sh android` です。上流protocol検査はDartテストから本体を呼び出します。

実アプリのサンプル検査は `flutter test integration_test/app_test.dart -d <device>`、候補操作と方針は `integration_test/review_test.dart`・`integration_test/scoped_policy_test.dart` を使います。実Vaultをテストに使わないでください。

Android SAFは `integration_test/saf_test.dart` の実行中にOS画面から専用の架空Vaultを選びます。

Mac bookmarkは `integration_test/macos_bookmark_test.dart` を `--dart-define=MAC_TEST_PHASE=choose`、プロセス終了後に `--dart-define=MAC_TEST_PHASE=restore` の順で実行します。両方へ同じ `--dart-define=MAC_TEST_OPERATION=<UUID>` を渡します。専用Vaultには `90_system/mac-test-marker.json`（`{"purpose":"context-hub-native-bookmark-test"}`）、別の架空ファイルへの `00_inbox/outside-link.md` symlink、1MiB超の `00_inbox/oversized.md` を用意します。テストはマーカーを確認してからInputへ保存します。

Macの増分ビルドで外側の署名sealが古く残る場合は、Flutterのbuild出力をcleanしてから再生成し、`codesign --verify --deep --strict` で成果物を確認します。署名identityやグローバル設定を変更して回避しません。
