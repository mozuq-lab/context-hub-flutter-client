import 'dart:convert';
import '../core/attention.dart';
import '../core/repository.dart';
import '../storage/vault_access.dart';

/// アプリを閉じている間の確認（Androidだけ）。
///
/// 端末に同期済みのVaultを読み、アプリを開いている間に出ていない判断待ちがあれば通知を出す。
/// 端末内のフォルダーと設定ファイルを読むだけで、Vaultにも設定ファイルにも書かず、ネットワークにも接続しない。
/// 通知を出したらtrue。設定が無効・Vaultが読めない・増えていないときはfalse。
Future<bool> runAttentionCheck(VaultAccess access) async {
  final raw = await access.readState('settings.json');
  if (raw == null) return false;
  final value = jsonDecode(raw);
  if (value is! Map) return false;
  final settings = AttentionSettings.fromJson(value['attention']);
  if (!settings.notify) return false;
  final location = VaultLocation.fromJson(value);
  // アプリでまだ開いていないVaultは、どれが新しいかを判断できない。
  if (settings.state.identity != location.identity) return false;
  final snapshot = await access.readSnapshot(location);
  if (!snapshot.recognized) return false;
  final notice = attentionNotice(
    settings.state.unknown(attentionItems(HubRepository(snapshot))),
  );
  if (notice == null) return false;
  await access.showAttentionNotification(
    key: notice.key,
    title: notice.title,
    text: notice.text,
  );
  return true;
}
