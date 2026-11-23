import 'models.dart';
import 'repository.dart';

/// 期日の通知の対象になる1件。期限切れか今日が期日の項目。
class DueItem {
  const DueItem(this.key, this.bucket, {this.open = false});

  /// 項目キー。
  final String key;

  /// [ScheduleBucket.overdue]か[ScheduleBucket.today]。
  final ScheduleBucket bucket;

  /// 「次の一手」の画面の未解決の欄に並ぶ項目。
  final bool open;
}

/// 期限切れか今日が期日の項目を、「次の一手」の画面と同じ区分で集める。
///
/// 進行中のプロジェクトの次の一手・未解決と、プロジェクトを決めずに本人が追加した行動が対象。
/// 完了・解決にした項目と誤りとして外した項目（NOWの行に結び付かない）、連絡待ちの印を付けた項目、
/// 「いつかやる」へ移した項目、見直す日が先で休ませている項目は数えない。
/// この端末から完了・解決や日付の変更を依頼して反映を待っている項目も、本人が対応済みなので数えない。
List<DueItem> dueItems(HubRepository repo, String today) {
  final items = <DueItem>[], seen = <String>{};
  void add(NowItemRef item, {bool open = false}) {
    if (!item.scheduled || item.resolved || item.waiting || item.someday) {
      return;
    }
    if (repo.itemRequestIdFor(item.key) != null ||
        repo.scheduleRequestIdFor(item.key) != null) {
      return;
    }
    final b = scheduleBucket(item.due, item.reviewAfter, today);
    if (b.hidden) return;
    if (b.bucket != ScheduleBucket.overdue &&
        b.bucket != ScheduleBucket.today) {
      return;
    }
    if (!seen.add(item.key)) return;
    items.add(DueItem(item.key, b.bucket, open: open));
  }

  for (final project in repo.actionableProjects) {
    for (final section in const ['next', 'open']) {
      for (final entry in project.entriesWithSource(section)) {
        final item = project.itemOf(entry);
        if (item != null) add(item, open: section == 'open');
      }
    }
  }
  for (final item in repo.unassignedOwnActions) {
    add(item);
  }
  return items;
}

/// 端末の通知に出す期日の知らせ。件数だけで、項目の本文とプロジェクト名は入れない。
class DueNotice {
  const DueNotice(this.key, this.title, this.text);

  /// 同じ日に繰り返し通知しないための鍵（その日の日付）。
  final String key;
  final String title, text;
}

/// 期日の通知の文を作る。[items]が空ならnull。
///
/// 鍵はその日の日付にして、1日に1回までにする（同じ日に件数が変わっても知らせ直さない）。
DueNotice? dueNotice(List<DueItem> items, String today) {
  if (items.isEmpty) return null;
  final overdue = items.where((i) => i.bucket == ScheduleBucket.overdue).length,
      due = items.length - overdue,
      open = items.where((i) => i.open).length;
  final parts = [if (overdue > 0) '期限切れ $overdue件', if (due > 0) '今日 $due件'];
  return DueNotice(
    today,
    '期日の来た項目が${items.length}件あります',
    '${parts.join(' · ')}'
        '${open > 0 ? '（うち未解決の欄に$open件）' : ''}'
        '。この端末に同期済みの内容です',
  );
}

/// 端末の通知で人を起こさないよう、期日の通知を控える時間帯（端末の時刻で22時〜7時）。
/// 控えた分は、朝以降の確認で知らせる。
bool dueQuietHour(DateTime local) => local.hour < 7 || local.hour >= 22;
