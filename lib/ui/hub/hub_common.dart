import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../../core/repository.dart';
import '../labels.dart';
import '../parts.dart';
import '../record_view.dart';
import 'hub_view.dart';
import 'search_page.dart';

/// ホームの各画面で共通に使う見出し・タイル・記録の行と、確認の操作。
extension HubCommon on HubViewState {
  /// 「さらに読み込む」ボタン。表示しきれていなければ残りの件数を示す。
  Widget moreButton(int total) => total <= shown
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Center(
            child: OutlinedButton(
              key: const Key('show-more'),
              onPressed: () => refresh(() => shown += HubViewState.pageSize),
              child: Text('さらに読み込む（残り${total - shown}件）'),
            ),
          ),
        );

  void open(String id) {
    final record = repo.records[id];
    if (record != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RecordView(controller: c, record: record),
        ),
      );
    }
  }

  /// 画面の見出し。labelは状態など、見出しの上に添える短い語（任意）。
  Widget title(String text, String subtitle, {String? label}) =>
      pageTitle(context, text, subtitle: subtitle, label: label);

  /// 欄の見出し。[trailing]は見出しの右に置く小さな操作。
  Widget sectionHeading(
    String text, {
    Key? key,
    String? note,
    List<Widget> trailing = const [],
  }) => sectionTitle(context, text, key: key, note: note, trailing: trailing);

  /// 同じ幅の札を、幅に合わせた列数で並べる。行ごとに高さをそろえる。
  Widget tileGrid(List<Widget> tiles, {int Function(double width)? columns}) =>
      LayoutBuilder(
        builder: (context, box) {
          if (tiles.isEmpty) return const SizedBox.shrink();
          final count =
              (columns?.call(box.maxWidth) ??
                      (box.maxWidth >= 680 ? tiles.length.clamp(1, 4) : 2))
                  .clamp(1, tiles.length);
          return Column(
            children: [
              for (var i = 0; i < tiles.length; i += count)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var j = i; j < i + count; j++) ...[
                          if (j > i) const SizedBox(width: 12),
                          Expanded(
                            child: j < tiles.length
                                ? tiles[j]
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      );

  /// ホームの件数の札。押すとその画面を開く。[highlight]は判断が要るものがあるときの印。
  Widget homeTile({
    required Key key,
    required IconData icon,
    required String title,
    required String caption,
    required VoidCallback onTap,
    bool highlight = false,
    bool compact = false,
  }) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final mark = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 18, color: scheme.primary),
    );
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
    );
    if (compact) {
      return InkWell(
        key: key,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              mark,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (highlight) ...[const SizedBox(width: 8), dot],
              Icon(
                Icons.chevron_right,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: InkWell(
        key: key,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [mark, const Spacer(), if (highlight) dot]),
              const SizedBox(height: 14),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                caption,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// アイデア一覧の印。束ねたアイデアと、未確認の似ているアイデアの数。
  String? ideaBadge(HubRecord r) {
    final group = repo.ideaGroupOf(r.sourceId),
        similar = repo.similarIdeas(r.sourceId).length;
    return [
      if (group != null)
        group.representative == r.sourceId
            ? '束ねたアイデアの代表（${group.ideas.length}件）'
            : '束ねたアイデア（${group.ideas.length}件）',
      if (similar > 0) '似ているアイデア $similar件',
    ].join(' · ').nullIfEmpty;
  }

  /// 記録の一覧の1行。題名・種類と状態と日時（1行）・印・検索の抜粋を並べ、押すと詳細を開く。
  Widget recordRow(
    HubRecord r, {
    Key? key,
    List<String>? words,
    String? badge,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      key: key,
      onTap: () => open(r.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (words != null)
                        searchKindLabels[HubRepository.searchKindOf(r)] ??
                            r.kind,
                      originLabel(r.origin),
                      stateLabel(r.status),
                      compactWhen(r),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (badge != null)
                    Text(
                      badge,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  if (words != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text.rich(
                        key: const Key('search-snippet'),
                        TextSpan(
                          children: highlightSpans(
                            searchSnippet(r.body, words),
                            words,
                            theme.colorScheme.primaryContainer,
                          ),
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 13,
                          height: 1.6,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (HubRepository.bundleKinds.contains(r.kind))
              BasketToggle(controller: c, record: r),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 記録の一覧。1枚の面に行を並べ、行の間に細い線を引く（1件ずつの枠を並べるより軽く、目で追いやすい）。
  Widget recordList(
    Iterable<HubRecord> records, {
    Key Function(HubRecord)? keyOf,
    List<String>? words,
    String? Function(HubRecord)? badgeOf,
  }) => groupCard([
    // 行ごとの鍵（検索結果の'search-result'など）は同じものが並ぶので、記録ごとに包んで兄弟の鍵を分ける。
    for (final r in records)
      KeyedSubtree(
        key: ValueKey('record-row-${r.id}'),
        child: recordRow(
          r,
          key: keyOf?.call(r),
          words: words,
          badge: badgeOf?.call(r),
        ),
      ),
  ]);

  Future<bool> confirmAction(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => HubAlertDialog(
          title: Text(title),
          onClose: () => Navigator.pop(context, false),
          content: SizedBox(width: 520, child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('やめる'),
            ),
            FilledButton(
              key: const Key('confirm-action'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  /// 置き場（プロジェクト未定もある）とキーで、今の一覧の項目を引く。
  NowItemRef? currentItem(String projectId, String key) {
    final r = c.repository;
    if (r == null) return null;
    // プロジェクト未定は本人が追加した行動だけ（連絡待ち・「いつかやる」の行動も含む）。
    final items = projectId == unassignedScope
        ? [
            for (final i in r.unassignedItems)
              if (i.action) i,
          ]
        : r.projects[projectId]?.nowItems ?? const <NowItemRef>[];
    return items.where((i) => i.key == key).firstOrNull;
  }

  /// 先の項目の置き場の名前（プロジェクトの名前か「プロジェクト未定」）。
  String scopeTitle(String scope) => scope == unassignedScope
      ? 'プロジェクト未定'
      : repo.projects[scope]?.title ?? scope;

  /// 別の画面（資料棚など）からメモを開く。
  void openRecordFrom(BuildContext from, HubRecord record) => Navigator.push(
    from,
    MaterialPageRoute(
      builder: (_) => RecordView(controller: c, record: record),
    ),
  );

  bool get busy => c.loading || c.saving || c.captureWarning != null;

  /// 最近のメモ・アイデアの一覧（[page]が ideas ならアイデア）。
  List<Widget> recordsView(String page) {
    final children = <Widget>[];
    final ideas = page == 'ideas';
    final records = ideas ? repo.ideas : repo.recent;
    children.add(
      title(
        ideas ? 'アイデア' : '最近のメモ',
        ideas ? '原文に戻りながら、育てたいアイデアを探します。' : '雑な思いつきも、作業の記録も、そのまま残せます。',
      ),
    );
    if (records.isEmpty) {
      children.add(emptyText(context, 'まだ記録がありません。'));
    } else {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '${records.length}件（新しい順）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
      children.add(
        recordList(records.take(shown), badgeOf: ideas ? ideaBadge : null),
      );
    }
    children.add(moreButton(records.length));
    return children;
  }
}
