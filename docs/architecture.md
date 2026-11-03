# 構成と制限

Markdown Vaultが正本です。Dartが上限付きsnapshotの読取・検索・context作成・操作管理を担当し、Swift/Kotlinの限定MethodChannelがOSのファイルアクセスを担当します。Nodeは本体とのprotocol互換性を開発時に検査するためにだけ使い、端末アプリには同梱しません。

## データの読取

読取は1ファイル1MiB、合計64MiB、5000エントリー、深さ12までです。原文hash、訂正、生成物、候補一覧の依存hashを検査し、不明な状態ではcontextコピーや候補操作を停止します。方針の意味上の比較はJSONのキー順に依存しません。

contextコピーには共通と対象プロジェクトの有効方針を全文含めます。コピー前にsnapshotを再検査し、コピー中に到着した適用停止・承認記録も独立した再走査で検出します。未同期や容量上限による欠落を、反映済みとして扱いません。

Vault直下は、共通の有効方針`POLICY.md`と、本体が生成するふりかえり`REVIEW.md`だけを読みます。`REVIEW.md`は生成hashを照合し、手動変更や同期途中の可能性があれば注意を表示します。プロジェクトの停滞は、NOWの最終根拠から本体の既定と同じ14日を超えたかで判断します。

プロジェクト状態の変更依頼は、表示中の`project.md`のhashに結び付けます。依頼直前に再読込し、定義が変わっていれば保存しません。本体は同じhashのときだけ反映します。

## 依頼の保存

アプリは本人が確認したメモ・作業要約・採用・却下・適用停止・プロジェクト状態変更・NOW項目の完了報告・作業記録の下書きの見送りの要求だけをInputへ新規保存します。完了報告はNOWと同時に本体が書く項目一覧（`90_system/now-items/`）のキーに結び付け、下書きから作る入力には下書きIDとhashを付けます。前回見てからの変化は、プロジェクトごとに最後に開いたときのNOWの行を端末の`settings.json`に保存して比べます。正式データの作成と整理はMini側の本体が行います。

固定UUIDからREQ IDを決め、本文を含まないjournalへfingerprint・保存先・日時を先に記録します。同じ操作は再送せず確認だけを行います。未確定保存の本文は開いたフォームで保持し、再起動後の未保存本文復元は保証しません。

MacはNOFOLLOW・排他公開・file/dir fsyncを使います。保存先識別はbookmarkのバイトと分け、volume UUID（取得不可時はdevice番号）とinodeを使います。フォルダーのコピーは別Vaultです。AndroidのjournalはO_EXCLとfile/dir fsync、SAFのInputは一時ファイル・fsync・rename・本文readbackを使います。

## OSと運用の範囲

対象はApple SiliconのmacOS 12以降とAndroidです。Macのsecurity-scoped bookmark、AndroidのローカルExternalStorageProviderのSAF権限を利用します。全ストレージ権限・クラウドprovider・SQLite・新規サーバーは利用しません。

同期・モデル・Gateway・常駐サービスをアプリから操作しません。Macのbundle IDは `com.mozuqlab.contexthub.flutter`、Androidは `com.mozuqlab.context_hub_client` です。

OSフォルダー選択と再起動後の権限保持、実端末・実同期などの確認範囲は[検証状況](verification.md)、データ保全と復旧は[SECURITY.md](../SECURITY.md)を参照してください。
