import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import '../core/attention.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../storage/vault_access.dart';

/// アプリを閉じている間の確認（Androidだけ）。
///
/// 端末に同期済みのVaultを読み、アプリを開いている間に出ていない判断待ちがあれば通知を出す。
/// 端末内のフォルダーと設定ファイルを読むだけで、Vaultにも設定ファイルにも書かず、ネットワークにも接続しない。
/// 通知を出したらtrue。設定が無効・Vaultを読み切れない・増えていないときはfalse。
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
  // 読取が途中で終わったときは、片付いたものが残って見えることがあるため通知しない。
  if (!snapshot.recognized || snapshot.warnings.isNotEmpty) return false;
  // 記録の解釈は時間がかかることがあるため、端末の主スレッドを止めないよう別のisolateで行う。
  final notice = await compute(_noticeFor, (snapshot, settings.state));
  if (notice == null) {
    // 増えた分がほかの端末で片付いていたら、出したままの通知を消す。
    await access.clearAttentionNotification();
    return false;
  }
  await access.showAttentionNotification(
    key: notice.key,
    title: notice.title,
    text: notice.text,
  );
  return true;
}

/// アプリを開いている間に出ていない判断待ちの通知文。なければnull。
AttentionNotice? _noticeFor((VaultSnapshot, AttentionState) input) =>
    attentionNotice(input.$2.unknown(attentionItems(HubRepository(input.$1))));
