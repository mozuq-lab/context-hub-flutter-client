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
- Vault直下のREVIEW.mdを読むSwift・Kotlinの変更は、MacのSwift snapshot検査（追加2項目）・両OSのビルド・実アプリでは未確認です。

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
