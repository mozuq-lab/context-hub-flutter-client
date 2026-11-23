import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import '../core/attention.dart';
import '../core/due_notice.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../storage/vault_access.dart';

/// アプリを閉じている間の確認（Androidだけ）。
///
/// 端末に同期済みのVaultを読み、設定に応じて2種類の通知を出す。
/// - 確認待ちの通知: アプリを開いている間に出ていない判断待ちがあるとき。
/// - 期日の通知: 期限切れか今日が期日の項目があるとき（1日に1回まで）。
///
/// 端末内のフォルダーと設定ファイルを読むだけで、Vaultにも設定ファイルにも書かず、ネットワークにも接続しない。
/// どちらかの通知を出したらtrue。設定が無効・Vaultを読み切れない・知らせることがないときはfalse。
/// [now]はテスト用（期日の「今日」と、通知を控える時間帯に使う）。
Future<bool> runAttentionCheck(VaultAccess access, {DateTime? now}) async {
  final raw = await access.readState('settings.json');
  if (raw == null) return false;
  final value = jsonDecode(raw);
  if (value is! Map) return false;
  final settings = AttentionSettings.fromJson(value['attention']);
  final location = VaultLocation.fromJson(value);
  // アプリでまだ開いていないVaultは、どれが新しいかを判断できない。
  final attention =
      settings.notify && settings.state.identity == location.identity;
  if (!attention && !settings.due) return false;
  final snapshot = await access.readSnapshot(location);
  // 読取が途中で終わったときは、片付いたものが残って見えることがあるため通知しない。
  if (!snapshot.recognized || snapshot.warnings.isNotEmpty) return false;
  final clock = now ?? DateTime.now();
  // 記録の解釈は時間がかかることがあるため、端末の主スレッドを止めないよう別のisolateで行う。
  final notices = await compute(_noticesFor, (
    snapshot,
    settings.state,
    attention,
    settings.due ? hubToday(clock) : null,
  ));
  var shown = false;
  if (attention) {
    final notice = notices.attention;
    if (notice == null) {
      // 増えた分がほかの端末で片付いていたら、出したままの通知を消す。
      await access.clearAttentionNotification();
    } else {
      await access.showAttentionNotification(
        key: notice.key,
        title: notice.title,
        text: notice.text,
      );
      shown = true;
    }
  }
  // 記録の形式・整合性を確かめられないもの（画面に読取の注意が出るもの）があるときは、
  // 片付いた項目の記録やプロジェクトの項目一覧が欠けて数えが合わないことがあるため、通知も消去もしない。
  if (settings.due && notices.dueReadable) {
    final notice = notices.due;
    if (notice == null) {
      // 期日の来た項目がなくなったら、出したままの通知を消す（その日に通知した記録は端末に残る）。
      await access.clearAttentionNotification(kind: 'due');
    } else if (!dueQuietHour(clock.toLocal())) {
      await access.showAttentionNotification(
        key: notice.key,
        title: notice.title,
        text: notice.text,
        kind: 'due',
      );
      shown = true;
    }
  }
  return shown;
}

/// 確認待ちの通知文（アプリを開いている間に出ていない判断待ち）と、期日の通知文。それぞれなければnull。
/// [dueReadable]は、期日を数えるのに足りるだけ記録を読めたか（読取の注意がないか）。
({AttentionNotice? attention, DueNotice? due, bool dueReadable}) _noticesFor(
  (VaultSnapshot, AttentionState, bool, String?) input,
) {
  final (snapshot, state, attention, today) = input;
  final repo = HubRepository(snapshot);
  return (
    attention: attention
        ? attentionNotice(state.unknown(attentionItems(repo)))
        : null,
    due: today == null ? null : dueNotice(dueItems(repo, today), today),
    dueReadable: repo.warnings.isEmpty,
  );
}
