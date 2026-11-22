import 'dart:convert';
import 'intake_features.dart' show unassignedScope;
import 'models.dart';
import 'parser.dart' show clip;
import 'repository.dart';
import 'today.dart';

/// Androidのホーム画面ウィジェットの表示設定。端末ごとの設定で、Vaultには書かない。
///
/// ホーム画面は周りの人からも見えるため、既定では件数と読込時刻だけを出す。
class HomeWidgetSettings {
  const HomeWidgetSettings({this.showText = false, this.projectId});

  /// 次の一手の本文とプロジェクト名を出すか。
  final bool showText;

  /// 表示を絞るプロジェクト。nullなら進行中のすべて。
  final String? projectId;

  Map<String, Object?> toJson() => {
    'showText': showText,
    if (projectId != null) 'project': projectId,
  };

  /// 読めない値は既定（件数だけ）として扱う。
  static HomeWidgetSettings fromJson(Object? value) {
    if (value is! Map) return const HomeWidgetSettings();
    final project = value['project'];
    return HomeWidgetSettings(
      showText: value['showText'] == true,
      projectId: project is String && project.isNotEmpty ? project : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetSettings &&
      other.showText == showText &&
      other.projectId == projectId;
  @override
  int get hashCode => Object.hash(showText, projectId);
}

/// ウィジェットに出す次の一手の行数と、1行の長さ。
const homeWidgetMaxLines = 3;
const homeWidgetLineChars = 48;

/// ネイティブへ渡すJSONの上限。ネイティブ側も同じ値で確かめる。
const homeWidgetMaxBytes = 4096;

/// ウィジェットに出す内容を、読込済みの記録から作る。
///
/// 表示用の文字列まで組み立てて渡し、ネイティブ側は並べるだけにする。
/// 本文を出す場合も、秘密情報らしい文字列は伏せる。
/// 「次の一手」の画面と同じく、期日が近い項目を先に並べ、見直す日が先の項目は数えず出さない。
/// 本人が[focus]（今日の3つ）に選んだ項目は、期日の近い項目よりも先に並べる。
Map<String, Object?> homeWidgetContent(
  HubRepository repo, {
  HomeWidgetSettings settings = const HomeWidgetSettings(),
  DateTime? now,
  List<TodayPick> focus = const [],
}) {
  final active = repo.actionableProjects;
  final review = repo.review.pendingRows.length;
  final scoped = settings.projectId != null;
  final chosen = scoped
      ? active.where((p) => p.id == settings.projectId).firstOrNull
      : null;
  // 選んだプロジェクトが進行中でなくなったら、ほかのプロジェクトへ広げずに何も出さない。
  final projects = scoped ? [?chosen] : active;
  final today = hubToday(now);
  // 行は（置き場のID・題・行）。置き場はプロジェクトか、プロジェクト未定（unassignedScope）。
  final soon = <(String, String, NowEntry, String, int)>[],
      rest = <(String, String, NowEntry)>[];
  for (final p in projects) {
    // 本人が追加して、まだNOWに反映されていない行動も次の一手として数える。
    for (final a in p.pendingActions) {
      rest.add((p.id, p.title, NowEntry('$actionLabel${a.text}')));
    }
    var order = 0;
    for (final e in p.entriesWithSource('next')) {
      order++;
      final item = e.itemKey == null
          ? null
          : p.nowItems.where((i) => i.key == e.itemKey).firstOrNull;
      if (item == null || !item.scheduled) {
        rest.add((p.id, p.title, e));
        continue;
      }
      final b = scheduleBucket(item.due, item.reviewAfter, today);
      if (b.hidden) continue;
      if (scheduleBucketLabels.containsKey(b.bucket)) {
        soon.add((p.id, p.title, e, item.due!, order));
      } else {
        rest.add((p.id, p.title, e));
      }
    }
  }
  // プロジェクトを決めずに本人が追加した行動（反映待ちを含む）。プロジェクトを選んで絞っているときは出さない。
  if (!scoped) {
    for (final a in repo.unassignedPendingActions) {
      rest.add((
        unassignedScope,
        'プロジェクト未定',
        NowEntry('$actionLabel${a.text}'),
      ));
    }
    // 本人が付けた期日が近い行動はプロジェクトの項目と一緒に先頭へ、見直す日まで休ませている行動は出さない。
    var order = 0;
    for (final i in repo.unassignedOwnActions) {
      order++;
      final row = (
        unassignedScope,
        'プロジェクト未定',
        NowEntry(i.display)..itemKey = i.key,
      );
      if (!i.scheduled) {
        rest.add(row);
        continue;
      }
      final b = scheduleBucket(i.due, i.reviewAfter, today);
      if (b.hidden) continue;
      if (scheduleBucketLabels.containsKey(b.bucket)) {
        soon.add((row.$1, row.$2, row.$3, i.due!, order));
      } else {
        rest.add(row);
      }
    }
  }
  soon.sort(
    (a, b) => a.$4.compareTo(b.$4) != 0
        ? a.$4.compareTo(b.$4)
        : a.$1.compareTo(b.$1) != 0
        ? a.$1.compareTo(b.$1)
        : a.$5.compareTo(b.$5),
  );
  final ordered = [for (final e in soon) (e.$1, e.$2, e.$3), ...rest];
  int rank((String, String, NowEntry) e) {
    final i = focus.indexWhere(
      (t) => t.projectId == e.$1 && t.itemKey == e.$3.itemKey,
    );
    return i < 0 ? focus.length : i;
  }

  // 安定した並べ替え（今日の3つの順、残りは元の順）。
  final entries = [
    for (final (i, e) in ordered.indexed) (rank(e), i, e),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final listed = [for (final e in entries) e.$3];
  // ロック画面にも出るため、本体の設定で足した規則も当てる。規則を確かめられないときは本文を出さない。
  final policy = repo.secretPolicy;
  String line(String title, String text) {
    final flat = policy.redact(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    final body = flat.length > homeWidgetLineChars
        ? '${clip(flat, homeWidgetLineChars)}…'
        : flat;
    return scoped ? body : '$body（${clip(title, 16)}）';
  }

  final known = scoped ? repo.projects[settings.projectId] : null;
  return {
    'schema_version': 1,
    'title': !scoped
        ? 'ContextHub'
        : settings.showText && known != null
        ? clip(known.title, 24)
        : '選んだプロジェクト',
    'counts': scoped && chosen == null
        ? '進行中ではありません · 確認待ち $review件'
        : '次の一手 ${entries.length}件 · 確認待ち $review件',
    'lines': settings.showText && policy.usable
        ? [
            for (final (_, title, e) in listed.take(homeWidgetMaxLines))
              line(title, e.text),
          ]
        : const <String>[],
    'footer': '読込 ${displayTime(repo.snapshot.loadedAt)}',
  };
}

/// ネイティブへ渡すJSON。上限を超える場合は本文を外して件数だけにする。
String encodeHomeWidget(Map<String, Object?> content) {
  final raw = jsonEncode(content);
  if (utf8.encode(raw).length <= homeWidgetMaxBytes) return raw;
  return jsonEncode({...content, 'lines': const <String>[]});
}
