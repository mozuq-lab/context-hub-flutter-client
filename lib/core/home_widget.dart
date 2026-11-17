import 'dart:convert';
import 'models.dart';
import 'parser.dart' show clip;
import 'repository.dart';

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
Map<String, Object?> homeWidgetContent(
  HubRepository repo, {
  HomeWidgetSettings settings = const HomeWidgetSettings(),
  DateTime? now,
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
  final soon = <(HubProject, NowEntry, String, int)>[],
      rest = <(HubProject, NowEntry)>[];
  for (final p in projects) {
    var order = 0;
    for (final e in p.entriesWithSource('next')) {
      order++;
      final item = e.itemKey == null
          ? null
          : p.nowItems.where((i) => i.key == e.itemKey).firstOrNull;
      if (item == null || !item.scheduled) {
        rest.add((p, e));
        continue;
      }
      final b = scheduleBucket(item.due, item.reviewAfter, today);
      if (b.hidden) continue;
      if (scheduleBucketLabels.containsKey(b.bucket)) {
        soon.add((p, e, item.due!, order));
      } else {
        rest.add((p, e));
      }
    }
  }
  soon.sort(
    (a, b) => a.$3.compareTo(b.$3) != 0
        ? a.$3.compareTo(b.$3)
        : a.$1.id.compareTo(b.$1.id) != 0
        ? a.$1.id.compareTo(b.$1.id)
        : a.$4.compareTo(b.$4),
  );
  final entries = [for (final e in soon) (e.$1, e.$2), ...rest];
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
            for (final (p, e) in entries.take(homeWidgetMaxLines))
              line(p.title, e.text),
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
