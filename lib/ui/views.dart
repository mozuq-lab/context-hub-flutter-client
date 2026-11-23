import 'dart:async';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'package:uuid/uuid.dart';
import '../app/controller.dart';
import '../core/calendar.dart';
import '../core/models.dart';
import '../core/happened.dart';
import '../core/intake_features.dart' show unassignedScope;
import '../core/repository.dart';
import '../core/secrets.dart';
import '../core/templates.dart';
import '../core/today.dart';
import '../storage/capture_service.dart';
import '../storage/basket_store.dart';
import '../storage/draft_store.dart';
import '../storage/vault_access.dart' show PickedAttachment;
import '../core/people.dart';
import '../core/related.dart';
import '../core/parser.dart' show clip;
import 'markdown_view.dart';
import 'people_view.dart';
import 'template_view.dart';
import 'review_view.dart';
import 'guided_view.dart';
import 'shortcuts.dart';
import 'notice.dart';
import 'ask_view.dart';
import 'reference_shelf.dart';
import 'parts.dart';
import 'theme.dart';

export 'notice.dart';

/// 秘密情報らしい文字列があれば、保存の前に知らせる。
/// 保存する本文（伏せ字にしたもの、またはそのまま）を返す。戻って直すならnull。
///
/// [secrets]はVaultの伏せ字の規則で、本体の設定で追加した規則も同じく知らせる。
/// 追加規則を確かめられないときも保存は止めず、組み込み規則で知らせる（知らせるだけの補助のため）。
Future<String?> checkSecretsBeforeSave(
  BuildContext context,
  String text, {
  SecretPolicy? secrets,
}) async {
  final rules = secrets == null || !secrets.usable
      ? SecretPolicy.builtin
      : secrets;
  final findings = rules.find(text);
  if (findings.isEmpty) return text;
  final choice = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: const Key('secret-warning'),
      title: const Text('秘密情報らしい文字列があります'),
      content: SizedBox(
        width: 480,
        child: Text(
          '${describeSecrets(findings)}に見える文字列があります。\n\n'
          '保存したメモは、同期先のすべての端末とバックアップに残り、後から消せません（訂正しても元のメモは残ります）。'
          '読み取り用のAIへは伏せ字にして渡しますが、本当に秘密の値なら「伏せ字にして保存」を選んでください。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('戻って直す'),
        ),
        TextButton(
          key: const Key('secret-keep'),
          onPressed: () => Navigator.pop(dialog, 'keep'),
          child: const Text('そのまま保存'),
        ),
        FilledButton(
          key: const Key('secret-redact'),
          onPressed: () => Navigator.pop(dialog, 'redact'),
          child: const Text('伏せ字にして保存'),
        ),
      ],
    ),
  );
  return switch (choice) {
    'redact' => rules.redact(text),
    'keep' => text,
    _ => null,
  };
}

class NoticeBox extends StatelessWidget {
  const NoticeBox(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tone = error ? scheme.error : scheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 16, 11),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: dark ? .14 : .07),
        borderRadius: BorderRadius.circular(hubRadiusSmall),
        border: Border.all(color: tone.withValues(alpha: dark ? .3 : .18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              error ? Icons.error_outline : Icons.info_outline,
              size: 17,
              color: tone,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.55,
                color: error ? scheme.error : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HubView extends StatefulWidget {
  const HubView({
    super.key,
    required this.controller,
    required this.page,
    required this.onNavigate,
    this.searchFocus,
  });
  final HubController controller;
  final String page;
  final void Function(String) onNavigate;

  /// 検索欄のフォーカス。キーボード操作（⌘F）で検索を開いたときに入力欄へ移る。
  final FocusNode? searchFocus;
  @override
  State<HubView> createState() => _HubViewState();
}

/// 一致箇所の前後を抜き出す。最初に見つかった語の少し前から始める。
/// 本文は検索と同じくNFKCで正規化してから探す（全角・半角の違いでも一致箇所を示す）。
String searchSnippet(String body, List<String> words) {
  final text = unicode.nfkc(body).replaceAll(RegExp(r'\s+'), ' ').trim();
  var start = 0;
  for (final w in words) {
    final m = RegExp(RegExp.escape(w), caseSensitive: false).firstMatch(text);
    if (m != null) {
      start = m.start > 40 ? m.start - 40 : 0;
      break;
    }
  }
  if (start > text.length) start = text.length;
  var end = start + 160 < text.length ? start + 160 : text.length;
  // サロゲートペアの途中で切らない。
  bool low(int i) =>
      i > 0 && i < text.length && (text.codeUnitAt(i) & 0xFC00) == 0xDC00;
  if (low(start)) start--;
  if (low(end)) end--;
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}

/// 抜粋の中の検索語を強調する。大文字・小文字は区別しない。
List<TextSpan> highlightSpans(String text, List<String> words, Color color) {
  // 長い語を先に試し、「a|ab」のように一部だけ強調しない。
  final pattern =
      (words.where((w) => w.isNotEmpty).toList()
            ..sort((a, b) => b.length.compareTo(a.length)))
          .map(RegExp.escape)
          .join('|');
  if (pattern.isEmpty) return [TextSpan(text: text)];
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in RegExp(pattern, caseSensitive: false).allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    spans.add(
      TextSpan(
        text: m.group(0),
        style: TextStyle(fontWeight: FontWeight.bold, backgroundColor: color),
      ),
    );
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

class _HubViewState extends State<HubView> {
  String query = '';
  final queryController = TextEditingController();

  /// 検索の絞り込み。本体の `ctx find` の --project・--kind・期間・--sort に対応する。
  String? searchProject;
  final Set<String> selectedKinds = {};
  int? searchDays;
  String searchSort = 'relevance';

  /// 一覧・検索結果は[pageSize]件ずつ表示し、「さらに読み込む」で古い記録へさかのぼる。
  static const pageSize = 50;
  int shown = pageSize;
  Object? _searchKey;
  List<HubRecord> _searchResults = const [];

  /// 「次の一手」画面で表示する欄（next または open）。
  String nextSection = 'next';

  /// 期日の通知から開いた回数（[HubController.dueOpened]）のうち、画面に反映した分。
  int _dueOpened = 0;

  /// 「次の一手」画面の手間の目安での絞り込み（[effortFilters]のキー）。nullならすべて。
  String? effortFilter;

  /// 「次の一手」画面の場所・道具の札での絞り込み。nullならすべて、[contextFilterNone]なら札なし、ほかは札そのもの。
  String? contextFilter;

  /// 「次の一手」画面のプロジェクト未定のメモは[unassignedPageSize]件ずつ並べ、「さらに表示」で残りを出す。
  static const unassignedPageSize = 10;
  int unassignedShown = unassignedPageSize;

  /// ホームに並べる、プロジェクト未定のメモと確認待ちのプロジェクト案の数。
  static const homeUnassigned = 3, homeProposals = 3;

  /// ホームの「今週の気づき」は、欄ごとに先頭の1件を出す。「ほかN件を表示」で残りも出す。
  bool insightsExpanded = false;
  HubController get c => widget.controller;
  HubRepository get repo => c.repository!;

  @override
  void initState() {
    super.initState();
    _visit();
  }

  @override
  void didUpdateWidget(HubView old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page) {
      shown = pageSize;
      unassignedShown = unassignedPageSize;
      insightsExpanded = false;
      _visit();
    }
  }

  @override
  void dispose() {
    queryController.dispose();
    super.dispose();
  }

  /// 検索条件を変えたら、表示件数を最初のページに戻す。
  void updateSearch(void Function() change) => setState(() {
    change();
    shown = pageSize;
  });

  SearchFilter get searchFilter {
    final now = DateTime.now();
    return SearchFilter(
      project: searchProject,
      kinds: {...selectedKinds},
      since: searchDays == null
          ? null
          : now.subtract(Duration(days: searchDays!)),
      sort: searchSort,
    );
  }

  /// 「さらに読み込む」ボタン。表示しきれていなければ残りの件数を示す。
  Widget moreButton(int total) => total <= shown
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Center(
            child: OutlinedButton(
              key: const Key('show-more'),
              onPressed: () => setState(() => shown += pageSize),
              child: Text('さらに読み込む（残り${total - shown}件）'),
            ),
          ),
        );

  /// プロジェクトを開いたら、前回見たときとの比較を固定してから既読にする。
  void _visit() {
    final page = widget.page;
    if (!page.startsWith('project:')) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.page == page) c.beginVisit(page.substring(8));
    });
  }

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

  /// ホームの見出し。今日の日付と、読み込んだ記録の量。
  Widget homeHeader(DateTime now) {
    final theme = Theme.of(context);
    const week = ['月', '火', '水', '木', '金', '土', '日'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${now.month}月${now.day}日（${week[now.weekday - 1]}）',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          Text('今日、どこから始める？', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            '${repo.projects.length}プロジェクト · ${repo.recent.length}件のメモ · 読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

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

  /// ホームのプロジェクトの札。先頭の次の一手と状態、前回見てからの変化を示す。
  Widget projectCard(HubProject project, DateTime now) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final pinned = repo.isPinned(project.id);
    return Card(
      child: InkWell(
        key: Key('project-${project.id}'),
        onTap: () => widget.onNavigate('project:${project.id}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 6, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('pin-${project.id}'),
                    tooltip: pinned ? 'ピン留めを外す' : 'ピン留めして先頭に表示',
                    isSelected: pinned,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => togglePin(project),
                    icon: const Icon(Icons.push_pin_outlined, size: 18),
                    selectedIcon: const Icon(Icons.push_pin, size: 18),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // 本人が追加して反映待ちの行動は、本体と同じく作業要約の次の一手より前に示す。
                      project.pendingActions.firstOrNull?.text != null
                          ? '$actionLabel${project.pendingActions.first.text}（反映待ち）'
                          // 連絡待ちの行は、自分では進められないので先頭の次の一手にしない。
                          : project.activeEntries('next').firstOrNull?.text ??
                                '次の一手はまだ作られていません。',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      projectStatusLine(project, now),
                      key: Key('project-status-${project.id}'),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (changeLabel(c.changesSince(project)) case final label?)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          label,
                          key: Key('project-changes-${project.id}'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    if (project.drafts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '作業記録の下書き ${project.drafts.length}件',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
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

  @override
  Widget build(BuildContext context) {
    if (widget.page == 'review') return ReviewView(controller: c);
    final children = <Widget>[];
    if (repo.snapshot.limitReached) {
      children.add(
        const Padding(
          key: Key('snapshot-limit'),
          padding: EdgeInsets.only(bottom: 12),
          child: NoticeBox(
            'Vaultの記録が多く、アプリが一度に読める上限に達しました。一部の記録を読めていないため、読み取り済みのメモが「読み取り前」に見えたり、確認待ちの候補や方針が欠けたりすることがあります。文脈のコピーは止まります。Vaultの記録そのものは失われていません。',
            error: true,
          ),
        ),
      );
    }
    for (final warning in repo.warnings) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: NoticeBox(warning, error: true),
        ),
      );
    }
    final page = widget.page;
    if (page.startsWith('project:')) {
      final project = repo.projects[page.substring(8)];
      if (project == null) {
        children.add(const Text('このVaultにプロジェクトがありません。'));
      } else {
        children.addAll(projectView(project));
      }
    } else if (page == 'people') {
      children.addAll(peopleView());
    } else if (page.startsWith('person:')) {
      final person = repo.people[page.substring(7)];
      if (person == null) {
        children.add(
          const Text('この人は登録されていません。外された可能性があります。', key: Key('person-missing')),
        );
      } else {
        children.addAll(personView(person));
      }
    } else if (page == 'digest') {
      children.addAll(digestView());
    } else if (page == 'next') {
      children.addAll(nextView());
    } else if (page == 'someday') {
      children.addAll(somedayView());
    } else if (page == 'weekly') {
      children.addAll(weeklyView());
    } else if (page == 'home') {
      final now = DateTime.now();
      children.add(homeHeader(now));
      for (final (index, warning) in repo.backup.warnings(now).indexed) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: NoticeBox(
              warning,
              key: Key('home-backup-warning-$index'),
              error: true,
            ),
          ),
        );
      }
      if (repo.backup.line(now) case final line?) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              line,
              key: const Key('home-backup'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        );
      }
      // 本人が今日やると決めたものを、いちばん上に置く。
      children.addAll(todaySection(compact: true));
      // 今週の気づきは、行動につながる欄（次の一手）より前に置く。
      children.addAll(insightsHome());
      // 件数の札。毎日開く画面への入口を横に並べ、件数と要点だけを示す。
      // プロジェクトを決めずに本人が追加した行動も、次の一手として数える。
      final actionable = repo.actionableProjects,
          ownUnassigned = repo.unassignedActionCount,
          nextCount =
              actionable.fold<int>(0, (n, p) => n + p.nextCount) +
              ownUnassigned,
          nextProjects = actionable.where((p) => p.nextCount > 0).length;
      // 確認待ちは、同じ対象を指すプロジェクト案を1件と数える。
      final review = c.review!;
      final stale = repo.orderedProjects
          .where((p) => !p.merged && p.stale(now))
          .toList();
      final somedayDays = repo.intakeFeatures.somedayReviewDays,
          somedayStale = repo.staleSomedayEntries(hubToday()).length;
      // 狭い画面では札を横に並べず、1枚の面に行として並べる。
      children.add(
        LayoutBuilder(
          builder: (context, box) {
            final compact = box.maxWidth < 560;
            final tiles = [
              homeTile(
                key: const Key('home-next'),
                icon: Icons.checklist_outlined,
                title: '次の一手 $nextCount件',
                caption: nextCount == 0
                    ? '進行中のプロジェクトに次の一手はありません'
                    : nextProjects == 0
                    ? 'プロジェクト未定から'
                    : ownUnassigned > 0
                    ? '進行中の$nextProjectsプロジェクトとプロジェクト未定から'
                    : '進行中の$nextProjectsプロジェクトから',
                compact: compact,
                onTap: () => widget.onNavigate('next'),
              ),
              homeTile(
                key: const Key('home-review'),
                icon: Icons.fact_check_outlined,
                title: '確認待ち ${review.pendingRows.length}件',
                caption: review.attention.isEmpty
                    ? 'AIの提案を、採用するか却下するか決めます'
                    : '要確認 ${review.attention.length}件 · AIの提案を、採用するか却下するか決めます',
                // 判断を待つ候補があれば印を付ける。
            highlight: review.pendingRows.isNotEmpty,
                compact: compact,
                onTap: () => widget.onNavigate('review'),
              ),
              homeTile(
                key: const Key('home-digest'),
                icon: Icons.event_note_outlined,
                title: repo.digestDocument == null
                    ? 'ふりかえり（未生成）'
                    : '直近${repo.digestDocument!.periodDays ?? 7}日のふりかえり',
                caption: stale.isEmpty
                    ? '動いたプロジェクトと現在地の変化を見ます'
                    : '停滞しているプロジェクト ${stale.length}件 · 続けるか休止・完了にするかを決めます',
                highlight: stale.isNotEmpty,
                compact: compact,
                onTap: () => widget.onNavigate('digest'),
              ),
              // 「いつかやる」は件数と、見直していない件数だけを示す（中身は専用の画面で見直す）。
              if (repo.somedayEntries.isNotEmpty)
                homeTile(
                  key: const Key('home-someday'),
                  icon: Icons.inventory_2_outlined,
                  title: 'いつかやる ${repo.somedayEntries.length}件',
                  caption: somedayStale > 0
                      ? '$somedayDays日以上見直していないもの$somedayStale件'
                      : '今は取り組まないことの置き場 · すべて$somedayDays日以内に見直し済み',
                  compact: compact,
                  onTap: () => widget.onNavigate('someday'),
                ),
            ];
            return compact ? groupCard(tiles) : tileGrid(tiles);
          },
        ),
      );
      if (repo.unassignedMemos.isNotEmpty || ownUnassigned > 0) {
        // プロジェクトに結び付いていないメモの行動と、プロジェクトを決めずに追加した行動は、
        // どのプロジェクトの次の一手にも出ない。ここで拾う。
        final own = repo.unassignedOwnActions,
            counts = [
              if (ownUnassigned > 0) '行動$ownUnassigned件',
              if (repo.unassignedTotal > 0) 'メモ${repo.unassignedTotal}件',
            ].join('・');
        void openNext() {
          nextSection = 'next';
          widget.onNavigate('next');
        }

        children.add(sectionHeading('プロジェクト未定'));
        children.add(
          groupCard([
            ListTile(
              key: const Key('home-unassigned'),
              leading: const Icon(Icons.lightbulb_outline),
              title: Text('プロジェクト未定の次の一手 $counts'),
              subtitle: Text(
                repo.unassignedMemos.isEmpty
                    ? 'プロジェクトを決めずに追加した行動'
                    : repo.intakeFeatures.unassignedItems
                    ? 'プロジェクトに結び付いていないメモの、タスク候補とAIの提案（未検証）など · 次の一手で完了・却下'
                    : 'プロジェクトに結び付いていないメモの、タスク候補とAIの提案（未検証） · 完了の報告はできません',
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: openNext,
            ),
            for (final action in repo.unassignedPendingActions.take(
              homeUnassigned,
            ))
              ListTile(
                key: Key('home-unassigned-pending-${action.requestId}'),
                dense: true,
                contentPadding: const EdgeInsets.fromLTRB(56, 0, 16, 0),
                title: Text(
                  '$actionLabel${action.text}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('反映待ち（${intakeStateLabel(action.state)}）'),
                onTap: openNext,
              ),
            for (final item in own.take(
              (homeUnassigned - repo.unassignedPendingActions.length).clamp(
                0,
                homeUnassigned,
              ),
            ))
              ListTile(
                key: Key('home-unassigned-action-${item.key.substring(0, 12)}'),
                dense: true,
                contentPadding: const EdgeInsets.fromLTRB(56, 0, 16, 0),
                title: Text(
                  item.display,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: switch (itemRecordLabel(item)) {
                  '' => null,
                  final label => Text(label),
                },
                onTap: openNext,
              ),
            for (final memo in repo.unassignedMemos.take(
              (homeUnassigned - ownUnassigned).clamp(0, homeUnassigned),
            ))
              ListTile(
                key: Key('home-unassigned-${memo.inputId}'),
                dense: true,
                contentPadding: const EdgeInsets.fromLTRB(56, 0, 16, 0),
                title: Text(
                  memo.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    hubToday(memo.at),
                    memo.ownWords ? '本人のメモ' : 'AIの要約・未検証',
                    if (memo.task) 'AIがタスクと分類',
                    if (memo.suggestions.isNotEmpty)
                      'AI提案: ${memo.suggestions.first}',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  final record = repo.inputRecord(memo.inputId);
                  if (record != null) open(record.id);
                },
              ),
          ]),
        );
      }
      // プロジェクト。統合済みのプロジェクトは変化の印を出さないので、件数にも数えない。
      final changed = repo.projects.values
          .where((p) => !p.merged && c.changesSince(p)?.isEmpty == false)
          .length;
      final mergedProjects = repo.projects.values
          .where((p) => p.merged)
          .toList();
      // 統合済みのプロジェクトは後ろの「統合済み」にまとめるので、ピン留めの先頭には数えない。
      final pinnedCount = repo.pinnedProjects.where((p) => !p.merged).length;
      children.add(
        sectionHeading(
          'プロジェクト',
          trailing: [
            if (changed > 0)
              TextButton(
                key: const Key('mark-all-seen'),
                onPressed: markAllSeen,
                child: const Text('すべて既読にする'),
              ),
            if (pinnedCount > 0)
              TextButton(
                key: const Key('reorder-pins'),
                onPressed: reorderPins,
                child: const Text('並び替え'),
              ),
          ],
        ),
      );
      if (changed > 0 || pinnedCount > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                if (changed > 0)
                  Text(
                    '前回見てから変化のあったプロジェクト $changed件',
                    key: const Key('home-changes'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (pinnedCount > 0)
                  Text(
                    'ピン留め $pinnedCount件を先頭に表示（この端末だけの並び）',
                    key: const Key('home-pins'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        );
      }
      if (repo.projects.isEmpty) {
        children.add(
          Text(
            'プロジェクトはまだありません。メモはproject未指定でも追加できます。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      }
      final listed = repo.orderedProjects.where((p) => !p.merged).toList();
      if (repo.usesAreas) {
        // 領域を付けていれば、本人の語彙の順に領域ごとにまとめ、領域なしは最後にする（本体のHOMEと同じ並び）。
        final areas = orderAreas(listed.map((p) => p.area), repo.areaVocabulary);
        final filter = areas.contains(areaFilter) ||
                (areaFilter == noAreaLabel && areas.contains(null))
            ? areaFilter
            : null;
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  key: const Key('area-filter-all'),
                  label: const Text('すべての領域'),
                  selected: filter == null,
                  onSelected: (_) => setState(() => areaFilter = null),
                ),
                for (final a in areas)
                  ChoiceChip(
                    key: Key('area-filter-${a ?? noAreaLabel}'),
                    label: Text(a ?? noAreaLabel),
                    selected: filter == (a ?? noAreaLabel),
                    onSelected: (_) =>
                        setState(() => areaFilter = a ?? noAreaLabel),
                  ),
              ],
            ),
          ),
        );
        for (final a in areas) {
          if (filter != null && filter != (a ?? noAreaLabel)) continue;
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                a ?? noAreaLabel,
                key: Key('area-heading-${a ?? noAreaLabel}'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          );
          children.add(
            tileGrid([
              for (final project in listed.where((p) => p.area == a))
                projectCard(project, now),
            ], columns: (width) => width >= 640 ? 2 : 1),
          );
        }
      } else {
        children.add(
          tileGrid([
            for (final project in listed) projectCard(project, now),
          ], columns: (width) => width >= 640 ? 2 : 1),
        );
      }
      if (mergedProjects.isNotEmpty) {
        // 統合済みのプロジェクトは入力を統合先のものとして読むため、小さくまとめて統合先を示す。
        children.add(const SizedBox(height: 12));
        children.add(
          groupCard([
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                '統合済み（${mergedProjects.length}件）',
                key: const Key('merged-projects'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final project in mergedProjects)
              ListTile(
                key: Key('project-${project.id}'),
                dense: true,
                title: Text(project.title),
                subtitle: Text(
                  projectStatusLine(project, now),
                  key: Key('project-status-${project.id}'),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => widget.onNavigate('project:${project.id}'),
              ),
          ]),
        );
      }
      // 判断が要るもの。プロジェクト案は、根拠のメモが多いものから数件を出す（依頼を保存済みのものは除く）。
      // 週次レビューは最後に見直してからの日数を示し、間隔を過ぎたら促す（通知は出さない）。
      // 停滞しているプロジェクトは、その場で開いて状態を決められるようにする。
      final proposals = [
        for (final (index, item) in review.pendingRows.indexed)
          if (item.kind == 'project' && review.requestIdFor(item.id) == null)
            (index, item, review.groupMembers(item).length + 1),
      ]..sort((a, b) => b.$3 != a.$3 ? b.$3 - a.$3 : a.$1.compareTo(b.$1));
      final weekly = repo.weeklyReview;
      final decide = [
        for (final (_, item, memos) in proposals.take(homeProposals))
          ListTile(
            key: Key('home-proposal-${item.id}'),
            leading: const Icon(Icons.create_new_folder_outlined),
            title: Text(
              'プロジェクト案: ${item.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('採用するとプロジェクトを作ります · 元のメモ$memos件'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ReviewDetail(
                  controller: c,
                  id: item.id,
                  identity: c.location!.identity,
                ),
              ),
            ),
          ),
        if (weekly != null)
          ListTile(
            key: const Key('home-weekly'),
            leading: const Icon(Icons.event_repeat_outlined),
            title: Text(
              switch (weekly.daysSinceReview(hubToday(now))) {
                null => '週次レビュー: まだ見直した記録がありません',
                0 => '週次レビュー: 今日見直しました',
                final d => '週次レビュー: 前回から$d日',
              },
              style: weekly.due(hubToday(now))
                  ? TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
            ),
            subtitle: weekly.due(hubToday(now))
                ? Text(
                    c.weeklyProgress != null
                        ? '続きから再開できます'
                        : '${weekly.intervalDays}日以上空いています · 一覧を順に点検します',
                  )
                : null,
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => widget.onNavigate('weekly'),
          ),
        for (final p in stale.take(3))
          ListTile(
            key: Key('home-stale-${p.id}'),
            leading: const Icon(Icons.hourglass_empty_outlined),
            title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            // 望む結果を添え、続けるか・完了にするかを判断しやすくする。
            subtitle: Text(
              '$projectStaleDays日以上、新しいメモがありません${p.outcomeLines.isEmpty ? '' : '\n望む結果: ${p.outcomeLines.join(' / ')}'}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => widget.onNavigate('project:${p.id}'),
          ),
      ];
      if (decide.isNotEmpty) {
        children.add(sectionHeading('見直しと判断'));
        children.add(groupCard(decide));
      }
      children.add(
        sectionHeading(
          '最近のメモ',
          key: const Key('home-recent'),
          trailing: [
            if (repo.recent.length > 5)
              TextButton(
                key: const Key('home-recent-all'),
                onPressed: () => widget.onNavigate('recent'),
                child: const Text('すべて見る'),
              ),
          ],
        ),
      );
      if (repo.recent.isNotEmpty) children.add(recordList(repo.recent.take(5)));
      // 保存と反映の状況は1行にまとめ、詳細は「保存と反映」で見る。
      // 受け取られた依頼は記録として残り続けるので、数えるのはまだ受け取られていないものと問題だけ。
      final waiting = repo.intake.where((s) => s.state == 'waiting').length,
          failing = repo.intake
              .where(
                (s) =>
                    const ['failed', 'rejected', 'conflict'].contains(s.state),
              )
              .length;
      if (waiting + failing + c.pending.length > 0) {
        final problem = failing + c.pending.length > 0;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: InkWell(
              key: const Key('home-status'),
              borderRadius: BorderRadius.circular(hubRadiusSmall),
              onTap: () => widget.onNavigate('intake'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      problem ? Icons.error_outline : Icons.sync_outlined,
                      size: 16,
                      color: problem
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // 問題があるときだけ件数を並べ、なければ反映待ちの件数だけを示す。
                        problem
                            ? '保存と反映: 失敗 $failing件 · 保存確認待ち ${c.pending.length}件（開いて確かめる）'
                            : '保存と反映: Mac miniの受け取り待ち $waiting件',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    } else if (page == 'search') {
      children.addAll(searchView());
    } else if (page == 'ask') {
      children.add(
        title(
          '記録に聞く',
          'メモと作業要約だけを根拠に答えます。答えの文ごとに根拠の記録が付きます。\n読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
        ),
      );
      children.add(AskPanel(controller: c, onRecord: open));
    } else if (page == 'basket') {
      children.addAll(basketView());
    } else if (page == 'intake') {
      children.add(
        title(
          '保存と反映',
          'この端末で保存したものが、Mac miniに受け取られ、反映されるまでを示します。同期の後に再読込すると進みます。',
        ),
      );
      for (final result in c.pending) {
        children.add(
          Card(
            child: ListTile(
              title: const Text('保存確認待ち'),
              subtitle: Text(result.requestId),
              trailing: TextButton(
                onPressed: c.saving
                    ? null
                    : () async {
                        try {
                          final r = await c.confirm(result.operationId);
                          if (context.mounted) {
                            notice(
                              context,
                              r.saved
                                  ? 'この端末に保存されています'
                                  : 'まだ保存を確認できません。同じ操作IDを保持しています。',
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            notice(context, HubController.message(e));
                          }
                        }
                      },
                child: const Text('同じ操作を確認'),
              ),
            ),
          ),
        );
      }
      if (repo.intake.isEmpty && c.pending.isEmpty) {
        children.add(emptyText(context, 'この端末から保存したものはありません。'));
      }
      if (repo.intake.isNotEmpty) {
        children.add(
          groupCard([
            for (final status in repo.intake)
              ListTile(
                title: Text(intakeStateLabel(status.state)),
                subtitle: Text(
                  [
                    status.title,
                    timeLabel(status.at),
                    if (status.detail.isNotEmpty) status.detail,
                    ?intakeNextStep(status.state),
                  ].join('\n'),
                  style: const TextStyle(height: 1.7),
                ),
                onTap: () {
                  showDialog<void>(
                    context: context,
                    // 閉じるときは、ダイアログ自身のcontextで閉じる。画面のcontextで閉じると、
                    // 本文の領域のNavigatorから一覧の画面を外してしまい、ダイアログは残る。
                    builder: (dialog) => AlertDialog(
                      title: Text(intakeStateLabel(status.state)),
                      content: SelectableText('${status.id}\n${status.detail}'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: const Text('閉じる'),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ]),
        );
      }
    } else {
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
          recordList(
            records.take(shown),
            badgeOf: ideas ? ideaBadge : null,
          ),
        );
      }
      children.add(moreButton(records.length));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: pageMaxWidth),
        child: ListView(
          key: ValueKey('${c.location?.handle}:$page'),
          padding: pagePadding(context),
          children: children,
        ),
      ),
    );
  }

  /// 文脈かご。選んだ記録を並べ、出典・方針付きの1つの文章としてコピーする。
  List<Widget> basketView() {
    final ids = c.basket.ids, missing = c.missingInBasket.toSet();
    final out = <Widget>[
      title(
        '文脈かご',
        '別のAIに渡す記録を集めます。コピーすると、出典と注意書き付きの1つの文章になります。中身はこの端末だけに残ります。',
      ),
    ];
    if (ids.isEmpty) {
      out.add(
        const Text(
          'かごは空です。記録の一覧や詳細で ⊕ を押すと、ここに入ります。',
          key: Key('basket-empty'),
        ),
      );
      return out;
    }
    out.add(
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            key: const Key('copy-bundle'),
            onPressed: c.loading || missing.isNotEmpty
                ? null
                : () async {
                    try {
                      final result = await c.bundleContext();
                      await Clipboard.setData(ClipboardData(text: result.text));
                      if (mounted) {
                        notice(
                          context,
                          result.omitted.isEmpty
                              ? '${result.included.length}件をまとめてコピーしました'
                              : '${result.included.length}件をコピーしました。上限に収まらない${result.omitted.length}件は省き、末尾にIDを示しています',
                        );
                      }
                    } catch (e) {
                      if (mounted) notice(context, HubController.message(e));
                    }
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: Text('${ids.length}件をまとめてコピー'),
          ),
          SegmentedButton<int>(
            key: const Key('basket-limit'),
            segments: [
              for (final limit in Basket.limits)
                ButtonSegment(value: limit, label: Text('$limit字')),
            ],
            selected: {c.basket.maxChars},
            onSelectionChanged: (v) => c.setBasketLimit(v.first),
          ),
          TextButton(
            key: const Key('basket-clear'),
            onPressed: () async {
              final yes = await showDialog<bool>(
                context: context,
                builder: (dialog) => AlertDialog(
                  title: const Text('かごを空にしますか'),
                  content: Text('${ids.length}件をかごから外します。記録そのものは消えません。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('やめる'),
                    ),
                    FilledButton(
                      key: const Key('basket-clear-confirm'),
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('空にする'),
                    ),
                  ],
                ),
              );
              if (yes == true) await c.clearBasket();
            },
            child: const Text('かごを空にする'),
          ),
        ],
      ),
    );
    out.add(const SizedBox(height: 8));
    out.add(
      Text(
        '上限（${c.basket.maxChars}字）に収まらない記録は、本文の途中で切らずに丸ごと省きます。方針は必ず含めます。',
        style: noteStyle(context),
      ),
    );
    if (missing.isNotEmpty) {
      out.add(
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: NoticeBox(
            'このVaultで見つからない記録があります。同期を待つか、かごから外してからコピーしてください。',
            error: true,
          ),
        ),
      );
    }
    out.add(const SizedBox(height: 16));
    final rows = <Widget>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i], record = repo.records[id];
      rows.add(
        ListTile(
          key: Key('basket-item-$i'),
          contentPadding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          leading: Text(
            '${i + 1}',
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          title: Text(
            record == null || missing.contains(id)
                ? '見つからない記録'
                : record.title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: record == null || missing.contains(id)
              ? const Text('同期で消えたか、まだ届いていません。')
              : Text(
                  '${searchKindLabels[HubRepository.searchKindOf(record)] ?? record.kind} · ${originLabel(record.origin)} · ${recordWhen(record)}'
                  '${(repo.correctionChainOf(id)?.length ?? 1) > 1 ? '\n訂正あり（最新の訂正の本文を渡します）' : ''}',
                  style: noteStyle(context),
                ),
          onTap: record == null || missing.contains(id)
              ? null
              : () => open(id),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('basket-up-$i'),
                tooltip: '上へ',
                onPressed: i == 0 ? null : () => c.moveInBasket(i, i - 1),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                key: Key('basket-down-$i'),
                tooltip: '下へ',
                onPressed: i == ids.length - 1
                    ? null
                    : () => c.moveInBasket(i, i + 1),
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                key: Key('basket-remove-$i'),
                tooltip: 'かごから外す',
                onPressed: () => c.removeFromBasket(id),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      );
    }
    if (rows.isNotEmpty) out.add(groupCard(rows));
    return out;
  }

  /// 検索画面。検索語と、プロジェクト・種類・期間・並び順の絞り込み。
  List<Widget> searchView() {
    // 同期で消えたプロジェクトが選ばれたままにならないようにする。
    if (searchProject != null && !repo.projects.containsKey(searchProject)) {
      searchProject = null;
    }
    final words = HubRepository.searchTokens(query);
    final filter = searchFilter;
    final unassignedShelf =
        repo.referenceIndex != null &&
        (repo.unassignedReferences.isNotEmpty ||
            repo.unassignedRemovedReferences.isNotEmpty);
    final out = <Widget>[
      title('検索', 'タイトルと本文から探します。語は空白で区切ります。絞り込みだけでも一覧できます。'),
      if (unassignedShelf)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('unassigned-shelf'),
              style: compactOutlinedStyle(context),
              onPressed: showUnassignedShelf,
              icon: const Icon(Icons.bookmarks_outlined, size: 18),
              label: Text(
                'プロジェクト未定の資料（${repo.unassignedReferences.length}件）',
              ),
            ),
          ),
        ),
      TextField(
        key: const Key('search-query'),
        controller: queryController,
        focusNode: widget.searchFocus,
        decoration: const InputDecoration(
          hintText: '思い出したいことを入力',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (v) => updateSearch(() => query = v),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: DropdownButtonFormField<String>(
              key: const Key('search-project'),
              style: fieldTextStyle(context),
              initialValue: searchProject ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'プロジェクト'),
              items: [
                const DropdownMenuItem(value: '', child: Text('すべて')),
                for (final p in repo.orderedProjects)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(p.title, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) =>
                  updateSearch(() => searchProject = v == '' ? null : v),
            ),
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<int>(
              key: const Key('search-period'),
              style: fieldTextStyle(context),
              initialValue: searchDays ?? 0,
              decoration: const InputDecoration(labelText: '期間'),
              items: const [
                DropdownMenuItem(value: 0, child: Text('すべて')),
                DropdownMenuItem(value: 7, child: Text('直近7日')),
                DropdownMenuItem(value: 30, child: Text('直近30日')),
                DropdownMenuItem(value: 90, child: Text('直近90日')),
                DropdownMenuItem(value: 365, child: Text('直近1年')),
              ],
              onChanged: (v) =>
                  updateSearch(() => searchDays = v == 0 ? null : v),
            ),
          ),
          SegmentedButton<String>(
            key: const Key('search-sort'),
            segments: const [
              ButtonSegment(value: 'relevance', label: Text('一致の多い順')),
              ButtonSegment(value: 'newest', label: Text('新しい順')),
            ],
            selected: {words.isEmpty ? 'newest' : searchSort},
            onSelectionChanged: words.isEmpty
                ? null
                : (v) => updateSearch(() => searchSort = v.first),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kind in searchKinds)
            FilterChip(
              key: Key('search-kind-$kind'),
              // 複数を選べる札は、色だけに頼らず印でも選んだことを示す。
              showCheckmark: true,
              label: Text(searchKindLabels[kind]!),
              selected: selectedKinds.contains(kind),
              onSelected: (on) => updateSearch(
                () => on ? selectedKinds.add(kind) : selectedKinds.remove(kind),
              ),
            ),
          if (filter.active)
            TextButton(
              key: const Key('search-clear'),
              onPressed: () => updateSearch(() {
                searchProject = null;
                selectedKinds.clear();
                searchDays = null;
              }),
              child: const Text('条件をクリア'),
            ),
        ],
      ),
      const SizedBox(height: 20),
    ];
    if (words.isEmpty && !filter.active) {
      out.add(const Text('語を入力するか、条件で絞り込んでください。'));
      return out;
    }
    // 画面の再構築（入力・続きの読み込み・保存中の通知）ごとに全件を検索し直さない。
    final key = (
      repo,
      query,
      searchProject,
      (selectedKinds.toList()..sort()).join(','),
      searchDays,
      searchSort,
    );
    if (_searchKey != key) {
      _searchKey = key;
      _searchResults = repo.search(query, filter);
    }
    final results = _searchResults;
    out.add(
      Text(
        '${results.length}件',
        key: const Key('search-count'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
    out.add(const SizedBox(height: 10));
    if (results.isNotEmpty) {
      out.add(
        recordList(
          results.take(shown),
          keyOf: (_) => const Key('search-result'),
          words: words,
          badgeOf: (r) =>
              searchProject != null &&
                  repo.projectRelation(r, searchProject!) == 'estimated'
              ? 'AI推定の関連（帰属未確定）'
              : null,
        ),
      );
    }
    out.add(moreButton(results.length));
    return out;
  }

  /// 状態と最終根拠からの日数を1行で示す。
  String projectStatusLine(HubProject project, DateTime now) {
    final target = project.mergeTarget;
    if (target != null) {
      return '統合済み（統合先: ${repo.projects[target]?.title ?? target}）';
    }
    final days = project.daysSinceEvidence(now);
    return [
      project.lifecycleLabel +
          (project.lifecycle == project.status ? '' : '（${project.status}）'),
      days == null ? '最終根拠なし' : '最終根拠から$days日',
      if (project.stale(now)) '停滞（$projectStaleDays日超）',
    ].join(' · ');
  }

  /// ふりかえりの先頭に置く、週次レビューを始める（続きから再開する）入口。本体が対応していなければ出さない。
  Widget? weeklyEntry() {
    final review = repo.weeklyReview;
    if (review == null && !repo.intakeFeatures.weeklyReview) return null;
    final today = hubToday(),
        progress = c.weeklyProgress,
        due = review?.due(today) ?? true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: ListTile(
          key: const Key('digest-weekly'),
          leading: Icon(
            Icons.fact_check_outlined,
            color: due ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(
            progress != null
                ? '週次レビューを続きから再開（${weeklyStepLabels[progress.step]}）'
                : '週次レビューを始める',
          ),
          subtitle: Text(
            '${weeklyLastLine(review, today)}確認待ち・プロジェクト未定の行動・進行中のプロジェクト・停滞・連絡待ち・期日・いつかやるを順に点検します。',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => widget.onNavigate('weekly'),
        ),
      ),
    );
  }

  List<Widget> digestView() {
    final digest = repo.digestDocument, weekly = weeklyEntry();
    if (digest == null) {
      return [
        title('ふりかえり', 'Mac miniがふりかえりを作ると、ここに表示されます。'),
        ?weekly,
        const Text('ふりかえりはまだ生成されていません。'),
      ];
    }
    return [
      title(
        '直近${digest.periodDays ?? 7}日のふりかえり',
        '生成: ${timeLabel(digest.generatedAt)} · 読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
      ),
      ?weekly,
      for (final warning in digest.warnings)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(warning),
        ),
      const SizedBox(height: 4),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: SafeMarkdown(
            key: const Key('digest-body'),
            text: digest.body,
            sourcePath: 'REVIEW.md',
            controller: c,
            onRecord: open,
          ),
        ),
      ),
    ];
  }

  /// 手で書き換えたため更新が止まったNOWの説明と、生成版に戻す操作。
  Widget conflictPanel(HubProject project, NowConflict conflict) {
    final requested = repo.conflictRequestIdFor(project.id) != null;
    const shown = 8;
    final lines = conflict.manualLines;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        key: const Key('now-conflict'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '現状の更新が止まっています',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '現状の自動で作られる部分が手で書き換えられているため、${timeLabel(project.generatedAt)}の生成から更新されていません。'
                '下の内容は止まった時点のものです${conflict.count > 1 ? '（新しい版の退避${conflict.count}件）' : ''}。',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 10),
              Text(
                lines.isEmpty
                    ? '手で変えた行は見つかりませんでした（行の削除や並べ替えだけの可能性があります）。'
                    : '手で変えた行${conflict.comparedWithGenerated ? '' : '（最新の生成版との違い。生成側の変化も含みます）'}:',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontSize: 13,
                ),
              ),
              for (final line in lines.take(shown))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    style: noteStyle(context),
                  ),
                ),
              if (lines.length > shown)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'ほか${lines.length - shown}行',
                    style: noteStyle(context),
                  ),
                ),
              const SizedBox(height: 12),
              if (requested)
                const NoticeBox('生成版に戻す依頼を送りました。Mac miniで処理されると最新の現状が表示されます。')
              else
                OutlinedButton.icon(
                  key: const Key('conflict-resolve'),
                  onPressed: c.loading || c.saving || c.captureWarning != null
                      ? null
                      : () => resolveConflict(project, conflict),
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('生成版に戻す'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> resolveConflict(HubProject project, NowConflict conflict) async {
    if (!await confirmAction(
      '現状を生成版に戻す',
      '${conflict.manualLines.isEmpty ? '' : '手で変えた${conflict.manualLines.length}行を、このプロジェクトのメモとして保存してから、'}'
          'Mac miniが最新の入力から現状を作り直します。現状の自動で作られる部分の外に書いたメモは残ります。'
          '置き換える前の現状の全文は本体の記録に残ります。',
      '生成版に戻す',
    )) {
      return;
    }
    try {
      final result = await c.requestConflictResolve(
        project.id,
        conflict.nowHash,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '生成版に戻す依頼を保存しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<void> changeStatus(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final status = await showDialog<String>(
      context: context,
      builder: (_) => ProjectStatusDialog(
        project: project,
        outcomeSupported: repo.intakeFeatures.projectOutcome != null,
      ),
    );
    if (status == null || !mounted) return;
    try {
      final result = await c.requestProjectStatus(project.id, hash, status);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '状態の変更を依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<void> changeDefinition(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final next = await showDialog<ProjectDefinitionDraft>(
      context: context,
      builder: (_) => ProjectDefinitionDialog(
        project: project,
        outcomeLimits: repo.intakeFeatures.projectOutcome,
      ),
    );
    if (next == null || !mounted) return;
    try {
      final result = await c.requestProjectDefinition(project.id, hash, next);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '${next.outcome == null ? '呼び名とキーワード' : '呼び名・キーワード・望む結果'}の変更を依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// ほかのプロジェクトへの統合を依頼する。統合先は本人が選び、両方の定義hashに結び付ける。
  Future<void> mergeProject(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final into = await showDialog<HubProject>(
      context: context,
      builder: (_) => ProjectMergeDialog(
        project: project,
        candidates: [
          for (final p in repo.orderedProjects)
            if (p.id != project.id && !p.merged && p.definitionHash != null) p,
        ],
      ),
    );
    final intoHash = into?.definitionHash;
    if (into == null || intoHash == null || !mounted) return;
    try {
      final result = await c.requestProjectMerge(
        project.id,
        hash,
        into.id,
        intoHash,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '統合を依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 統合の取り消しを依頼する。統合元は統合前の状態に戻る。
  Future<void> unmergeProject(HubProject project) async {
    final into = repo.projects[project.mergedInto];
    final hash = project.definitionHash, intoHash = into?.definitionHash;
    if (into == null || hash == null || intoHash == null) return;
    if (!await confirmAction(
          '統合を取り消す',
          '「${project.title}」を「${into.title}」から切り離し、統合前の状態に戻すよう依頼します。\n\n'
              '「${project.title}」を指定したメモ・完了報告・日付は、このプロジェクトのものとして読む形に戻ります。'
              '統合で「${into.title}」に足した呼び名とキーワードのうち、残っているものは外します。原文と記録は変わりません。',
          '取り消しを依頼',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestProjectMerge(
        project.id,
        hash,
        into.id,
        intoHash,
        unmerge: true,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '統合の取り消しを依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<bool> confirmAction(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
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

  Future<void> reportItem(
    HubProject project,
    NowItemRef item,
    String action,
  ) async {
    final resolve = action == 'resolve',
        verb = item.section == 'next' ? '完了' : '解決',
        resolveLabel = item.repeating ? '定例をやめる' : '$verbにする';
    // 外したときに起きたこと（読み直し・関連の変更）だけを、元に戻ると伝える。
    final undo = switch (item.exclusionReason) {
      'misread' => '誤りとして外したときのメモの読み直しも元に戻ります。',
      'wrong-project' when !repo.itemOwnedByProject(project.id, item) =>
        '誤りとして外したときのメモの読み直しと、このプロジェクトとの関連の変更も元に戻ります。',
      _ => '',
    };
    if (!await confirmAction(
          resolve ? resolveLabel : '未解決に戻す',
          '${item.display}\n\n${resolve ? 'この項目を現状の「解決済み・完了」へ移すよう依頼します。原文とAIの読み取り結果は変わりません。' : 'この項目を現状の元の欄へ戻すよう依頼します。$undo'}',
          resolve ? resolveLabel : '戻す',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestItemResolution(
        project.id,
        item.key,
        action,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '報告を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 手間の目安を選んで依頼する。目安は本人が選び、AIは推測しない。[projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> effortItem(String projectId, NowItemRef item) async {
    final choice = await showDialog<({String? effort})>(
      context: context,
      builder: (_) => EffortDialog(item: item),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestItemEffort(
        projectId,
        item.key,
        choice.effort,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '手間の目安を依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 場所・道具の札を選んで依頼する。札は本人が選び、AIは付けない。語彙の一覧もここから変えられる。
  /// [projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> contextsItem(String projectId, NowItemRef item) async {
    final choice = await showDialog<({List<String>? contexts})>(
      context: context,
      builder: (_) => ContextsDialog(
        item: item,
        vocabulary: () => repo.contextVocabulary,
        editVocabulary: editContextVocabulary,
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestItemContexts(
        projectId,
        item.key,
        choice.contexts,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '場所・道具の札を依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 場所・道具の札の一覧（語彙）を編集して、Vaultの好みとして依頼する。依頼したらtrue。
  Future<bool> editContextVocabulary() async {
    final next = await showDialog<List<String>>(
      context: context,
      builder: (_) => ContextVocabularyDialog(
        current: repo.contextVocabulary,
        pending: repo.contextVocabularyPending,
      ),
    );
    if (next == null || !mounted) return false;
    try {
      final result = await c.requestContextVocabulary(next);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '札の一覧を依頼しました。Mac miniで処理されると、ほかの端末にも同じ一覧が出ます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// ホームのプロジェクト一覧の領域での絞り込み（この端末の表示だけ）。nullはすべて、[noAreaLabel]は領域なし。
  String? areaFilter;

  /// 次の一手を手順に分ける・直す・外す依頼。手順は本人が書き、AIは作らない。
  Future<void> stepsItem(String projectId, NowItemRef item) async {
    final choice = await showDialog<({ItemSteps? steps})>(
      context: context,
      builder: (_) => StepsDialog(item: item),
    );
    if (choice == null || !mounted) return;
    await sendSteps(
      projectId,
      item,
      choice.steps,
      choice.steps == null ? '手順を外す依頼をしました' : '手順を依頼しました',
    );
  }

  /// 今の手順を終えた（[delta]が1）・1つ戻す（-1）依頼。手順の全体を送る。
  Future<void> moveStep(String projectId, NowItemRef item, int delta) async {
    final steps = item.steps;
    if (steps == null) return;
    final done = steps.done + delta;
    if (done < 0 || done > steps.items.length) return;
    await sendSteps(
      projectId,
      item,
      ItemSteps(steps.items, done),
      delta > 0 ? '手順を進める依頼をしました' : '手順を1つ戻す依頼をしました',
    );
  }

  Future<void> sendSteps(
    String projectId,
    NowItemRef item,
    ItemSteps? steps,
    String done,
  ) async {
    try {
      final result = await c.requestItemSteps(
        projectId,
        item.key,
        steps,
        seen: item.steps,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '$done。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// プロジェクトの領域を選んで依頼する。語彙の一覧もここから変えられる。
  Future<void> changeArea(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final choice = await showDialog<({String? area})>(
      context: context,
      builder: (_) => AreaDialog(
        current: project.area,
        choices: () => repo.areasInUse,
        editVocabulary: editAreaVocabulary,
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestProjectArea(project.id, hash, choice.area);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '領域を依頼しました。Mac miniで処理されるとプロジェクト一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 領域の一覧（語彙と並び）を編集して、Vaultの好みとして依頼する。依頼したらtrue。
  Future<bool> editAreaVocabulary() async {
    final next = await showDialog<List<String>>(
      context: context,
      builder: (_) => AreaVocabularyDialog(
        current: repo.areaVocabulary,
        pending: repo.areaVocabularyPending,
      ),
    );
    if (next == null || !mounted) return false;
    try {
      final result = await c.requestAreaVocabulary(next);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '領域の一覧を依頼しました。Mac miniで処理されると、ほかの端末にも同じ一覧と並びが出ます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// 連絡待ちの印（相手・頼んだ日）を依頼する。見直す日を変えたときは、続けて日付も依頼する（見直す日は期日と同じ記録）。
  /// [projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> waitItem(String projectId, NowItemRef item) async {
    final choice = await showDialog<({String? who, String since, String? reviewAfter})>(
      context: context,
      builder: (_) => WaitDialog(item: item, suggestions: waitingWhoSuggestions()),
    );
    if (choice == null || !mounted) return;
    final changed =
        !item.waiting ||
        item.waitingSince != choice.since ||
        item.waitingWho != choice.who;
    var sent = false;
    try {
      var saved = true;
      if (changed) {
        saved = (await c.requestItemWait(
          projectId,
          item.key,
          who: choice.who,
          since: choice.since,
        )).saved;
        sent = true;
      }
      // 見直す日は今の日付の記録に重ねる（期日と繰り返しは保つ）。日付の依頼が反映待ちなら送らない。
      // 期日は、ダイアログを開いている間に別の端末で変わっていることがあるため、読み直した項目のものを使う。
      final current = currentItem(projectId, item.key) ?? item;
      final review = choice.reviewAfter != current.reviewAfter;
      if (saved && review && mounted) {
        if (repo.scheduleRequestIdFor(item.key) != null) {
          notice(
            context,
            '${sent ? '連絡待ちを依頼しました。' : ''}日付の依頼が反映待ちのため、見直す日は送りませんでした。反映後に「期日を変える」から付けてください。',
          );
          return;
        }
        saved = (await c.requestItemSchedule(
          projectId,
          item.key,
          current.due,
          choice.reviewAfter,
        )).saved;
      }
      if (mounted) {
        notice(
          context,
          !saved
              ? '保存結果を確認できません。保存と反映から同じ操作を確認してください。'
              : sent
              ? '連絡待ちを依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '見直す日を依頼しました。Mac miniで処理されると現状と一覧に反映されます。',
        );
      }
    } catch (e) {
      if (mounted) {
        // 連絡待ちを保存した後に見直す日の依頼が断られたときは、連絡待ちは保存したことも示す。
        notice(
          context,
          sent
              ? '連絡待ちは依頼しましたが、見直す日は送れませんでした: ${HubController.message(e)}'
              : HubController.message(e),
        );
      }
    }
  }

  /// 項目を「いつかやる」へ移す、または元の欄（次の一手・未解決）へ戻すよう依頼する。移すかは本人が決め、AIは移さない。
  /// [projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> somedayItem(String projectId, NowItemRef item) async {
    final back = item.someday;
    if (!await confirmAction(
          back ? '「いつかやる」から戻す' : '「いつかやる」へ移す',
          back
              ? '${item.display}\n\n項目を元の欄（${item.section == 'next' ? '次の一手' : '未解決'}）へ戻すよう依頼します。'
              : '${item.display}\n\n今は取り組まない項目として「いつかやる」へ移すよう依頼します。次の一手の件数やホーム画面の一覧からは外れ、「いつかやる」の画面でまとめて見直せます。いつでも戻せます。${item.action ? '' : '\n\nAIが書いた行は、次の作業要約で言い回しが変わると「いつかやる」から外れます（Mac miniのHOMEに示します）。長く置くなら、先に「自分の行動にする」で引き取ってください。'}',
          back ? '戻す' : '移す',
        ) ||
        !mounted) {
      return;
    }
    await somedayRequest(
      () => c.requestItemSomeday(projectId, item.key, back ? 'back' : 'move'),
      back ? '戻す依頼を保存しました。' : '「いつかやる」へ移す依頼を保存しました。',
    );
  }

  /// 本人が追加した行動を、別の置き場（進行中のプロジェクト・プロジェクト未定）へ移すよう依頼する。
  /// [fromScope]は今の置き場。移す先は本人が選び、付けていた日付・手間の目安などは移した先へ引き継ぐ。
  Future<void> moveAction(String fromScope, NowItemRef item) async {
    final unassigned = repo.intakeFeatures.unassignedActions;
    final targets = [
      for (final p in repo.actionableProjects)
        if (!p.merged &&
            p.id != fromScope &&
            repo.projectMergeRequestIdFor(p.id) == null)
          (id: p.id, title: p.title),
      if (fromScope != unassignedScope && unassigned)
        (id: unassignedScope, title: 'プロジェクト未定'),
    ];
    if (targets.isEmpty) {
      notice(context, '移せる進行中のプロジェクトがありません。');
      return;
    }
    final to = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        key: const Key('move-action-dialog'),
        title: Text(
          fromScope == unassignedScope ? 'プロジェクトへ移す' : '別の置き場へ移す',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '${item.display}\n\n移す先を選んでください。期日・見直す日・繰り返し・手間の目安・連絡待ち・「いつかやる」は、移した先の行動に引き継ぎます。元に戻すときは、移した先でもう一度移します。「今日の3つ」に選んでいたときは外すので、移した後に選び直してください。',
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
          ),
          for (final t in targets)
            SimpleDialogOption(
              key: Key('move-action-to-${t.id}'),
              onPressed: () => Navigator.of(dialog).pop(t.id),
              child: Text(t.title),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: TextButton(
                key: const Key('move-action-cancel'),
                onPressed: () => Navigator.of(dialog).pop(),
                child: const Text('キャンセル'),
              ),
            ),
          ),
        ],
      ),
    );
    if (to == null || !mounted) return;
    try {
      final result = await c.requestMoveAction(fromScope, item.key, to);
      // 移すと項目キーが変わり、元の選択は見つからなくなるため、今日の3つ・持ち越しから外す。
      final today = c.today;
      if (result.saved &&
          (today.picked(item.key) ||
              today.carry.any((p) => p.itemKey == item.key))) {
        try {
          await c.setToday(fromScope, item.key, false);
        } catch (_) {
          // 外せなくても、移す依頼は保存済み。
        }
      }
      if (mounted) {
        notice(
          context,
          result.saved
              ? '行動を移す依頼を保存しました。Mac miniで処理されると移した先に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 「いつかやる」の依頼を送り、結果を知らせる。
  /// 保存できたかを返す。
  Future<bool> somedayRequest(
    Future<CaptureResult> Function() send,
    String done,
  ) async {
    try {
      final result = await send();
      if (mounted) {
        notice(
          context,
          result.saved
              ? '${done}Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

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

  /// 連絡待ちの印を外すよう依頼する。項目は元の欄（次の一手・未解決）へ戻る。
  Future<void> unwaitItem(String projectId, NowItemRef item) async {
    if (!await confirmAction(
          '連絡待ちを外す',
          '${item.display}\n\n連絡待ちの印を外し、項目を元の欄へ戻すよう依頼します。返事が来て終わった場合は、外さずに「${item.section == 'next' ? '完了にする' : '解決にする'}」も使えます。',
          '外す',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestItemWait(projectId, item.key);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '連絡待ちを外す依頼を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 連絡待ちの相手の候補。いま連絡待ちにしている項目の相手から作る（端末には保存しない）。
  List<String> waitingWhoSuggestions() {
    final names = <String>{};
    for (final p in repo.projects.values) {
      for (final i in p.nowItems) {
        if (i.waiting && i.waitingWho != null) names.add(i.waitingWho!);
      }
    }
    for (final i in repo.unassignedWaitingActions) {
      if (i.waitingWho != null) names.add(i.waitingWho!);
    }
    return (names.toList()..sort()).take(8).toList();
  }

  /// AIの読み違いなどを、理由を選んで「誤り」として外すよう依頼する。完了・解決には数えない。
  Future<void> excludeItem(HubProject project, NowItemRef item) async {
    final choice = await showDialog<({String reason, String? note})>(
      context: context,
      builder: (_) => ExcludeDialog(
        item: item,
        owned: repo.itemOwnedByProject(project.id, item),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestItemResolution(
        project.id,
        item.key,
        'exclude',
        reason: choice.reason,
        note: choice.note,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '報告を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// プロジェクト未定の行を完了にする（resolve）・却下する（exclude。理由は「もう古い」）・未解決へ戻す（reopen）。
  Future<void> reportUnassigned(NowItemRef item, String action) async {
    final (title, body, ok) = switch (action) {
      'resolve' => ('完了にする', 'この行を完了にして、一覧から外します。', '完了にする'),
      'exclude' when item.action => (
        '却下する',
        'この行動はやらないものとして、一覧から外します。',
        '却下する',
      ),
      'exclude' => ('却下する', 'この行はやらないものとして、一覧から外します。メモは残ります。', '却下する'),
      _ => ('元に戻す', 'この行を一覧へ戻します。', '戻す'),
    };
    if (!await confirmAction(title, '${item.display}\n\n$body', ok) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestItemResolution(
        unassignedScope,
        item.key,
        action,
        reason: action == 'exclude' ? 'outdated' : null,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '保存しました。Mac miniで処理されると一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 本人が決めた行動を次の一手に追加する。[project]を渡すとそのプロジェクトに決まり、渡さないと進行中のプロジェクトから選ぶ。
  /// 本体が対応していれば、プロジェクトを決めない「プロジェクト未定」も選べる（[unassigned]なら最初からそれを選ぶ）。
  /// [from]はAIが読み取った行（提案・作業要約の次の一手・プロジェクト未定の行）を行動にするときの元の行。
  /// AIの行を行動にするときは、元の行のプロジェクトのほかに「プロジェクト未定」も選べる。
  Future<void> addAction({
    HubProject? project,
    ActionSource? from,
    bool unassigned = false,
  }) async {
    final choices = project != null
        ? [project]
        : repo.actionableProjects.where((p) => !p.merged).toList();
    final allowUnassigned =
        repo.intakeFeatures.unassignedActions &&
        (project == null || from != null);
    if (choices.isEmpty && !allowUnassigned) {
      notice(context, '追加できる進行中のプロジェクトがありません。');
      return;
    }
    // 新しく足す行動には、対応した本体なら手間の目安と札を一緒に付けられる（AIの行を引き取るときは、元の行の札と目安を本体が写す）。
    final features = repo.intakeFeatures;
    final value =
        await showDialog<
          ({
            String projectId,
            String text,
            String? effort,
            List<String>? contexts,
          })
        >(
          context: context,
          builder: (_) => ActionDialog(
            projects: choices,
            from: from,
            allowUnassigned: allowUnassigned,
            unassigned: unassigned || choices.isEmpty,
            effortChoice: from == null && features.actionEffort,
            contextChoices: from == null && features.actionContexts
                ? repo.contextVocabulary
                : null,
          ),
        );
    if (value == null || !mounted) return;
    final checked = await checkSecretsBeforeSave(
      context,
      value.text,
      secrets: repo.secretPolicy,
    );
    if (checked == null || !mounted) return;
    if (!validActionText(checked)) {
      notice(context, '伏せ字にすると$actionTextChars文字を超えます。文面を短くしてください。');
      return;
    }
    try {
      final result = await c.requestAction(
        value.projectId,
        checked,
        from: from,
        effort: value.effort,
        contexts: value.contexts,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? value.projectId == unassignedScope
                    ? '次の一手への追加を保存しました。Mac miniで処理されるとプロジェクト未定の一覧に反映されます。'
                    : '次の一手への追加を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 反映待ちの行動の1行。
  Widget pendingActionRow(PendingAction action) => Padding(
    key: Key('pending-action-${action.requestId}'),
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$actionLabel${action.text}',
          style: const TextStyle(fontSize: 15),
        ),
        Text(
          '反映待ち（${intakeStateLabel(action.state)}）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  /// 期日・見直す日（と繰り返し）を依頼する。依頼を保存できたらtrue。[projectId]は項目の置き場（プロジェクト未定もある）。
  Future<bool> scheduleItem(String projectId, NowItemRef item) async {
    // 繰り返しに対応した本体にだけ、繰り返しを選ばせて送る（古い本体は知らない欄を断るため）。
    final repeatable = repo.intakeFeatures.repeat;
    final value =
        await showDialog<
          ({String? due, String? reviewAfter, RepeatRule? repeat})
        >(
          context: context,
          builder: (_) =>
              ScheduleDialog(item: item, repeatSupported: repeatable),
        );
    if (value == null || !mounted) return false;
    try {
      final result = await c.requestItemSchedule(
        projectId,
        item.key,
        value.due,
        value.reviewAfter,
        withRepeat: repeatable,
        repeat: value.repeat,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '日付を依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// 人の一覧。最後に出てきた日の新しい順。登録の依頼もここから送る。
  List<Widget> peopleView() {
    final people = repo.orderedPeople,
        waiting = repo.pendingPersonAdds,
        supported = repo.intakeFeatures.people;
    return [
      title('人', '登録した人の名前が出てくる記録と、関わる次の一手・未解決を集めます。名前の一致はAIを使わずに判定します。'),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: const Key('person-add'),
          onPressed:
              !supported || c.captureWarning != null || c.loading || c.saving
              ? null
              : addPerson,
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: const Text('人を登録'),
        ),
      ),
      if (!supported)
        const Padding(
          key: Key('people-unsupported'),
          padding: EdgeInsets.only(top: 12),
          child: NoticeBox(
            'Mac miniの本体がまだ人ごとの見返しに対応していません。本体を更新すると、人を登録できるようになります。',
          ),
        ),
      const SizedBox(height: 16),
      if (people.isEmpty && waiting.isEmpty)
        emptyText(
          context,
          'まだ登録した人はいません。よく一緒に仕事をする人や、返事を待っている人を登録すると、その人が出てくる記録をまとめて見返せます。',
          key: const Key('people-empty'),
        ),
      // 1人ずつの枠を並べず、1枚の面に行を並べる（最近のメモなどの一覧とそろえる）。
      if (people.isNotEmpty || waiting.isNotEmpty)
        groupCard([
          for (final person in people)
            ListTile(
              key: Key('person-${person.id}'),
              leading: const Icon(Icons.person_outline),
              title: Text(person.name),
              subtitle: Text(
                [
                  if (person.aliases.isNotEmpty)
                    '呼び名: ${person.aliases.join('、')}',
                  person.page == null
                      ? '一覧はまだ作られていません（次のAI読み取りで作られます）'
                      : '最後に出てきた日: ${person.lastSeen == null ? 'まだありません' : displayTime(person.lastSeen).substring(0, 10)} · 記録 ${person.records}件 · 未完了の項目 ${person.openItems}件',
                ].join('\n'),
                style: const TextStyle(height: 1.6),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onNavigate('person:${person.id}'),
            ),
          for (final pending in waiting)
            ListTile(
              key: Key('pending-person-${pending.personId}'),
              enabled: false,
              leading: const Icon(Icons.hourglass_empty),
              title: Text(pending.name),
              subtitle: Text(
                pending.state == 'accepted'
                    ? 'Mac miniが受け取り済み。人の定義の同期を待っています。'
                    : '登録を依頼済み（Mac miniでの処理を待っています）',
              ),
            ),
        ]),
    ];
  }

  /// 1人の画面。本体が作った一覧（SUMMARY.md）を、元の記録へのリンク付きで読む。
  List<Widget> personView(HubPerson person) {
    final page = person.page,
        requested = repo.personRequestIdFor(person.id) != null,
        busy =
            !repo.intakeFeatures.people ||
            c.captureWarning != null ||
            c.loading ||
            c.saving ||
            requested;
    return [
      title(
        label: '人',
        person.name,
        [
          if (person.aliases.isNotEmpty) '呼び名: ${person.aliases.join('、')}',
          if (page != null)
            '生成: ${timeLabel(page.generatedAt)} · 読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
        ].join('\n'),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('person-edit'),
            onPressed: busy ? null : () => editPerson(person),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('名前と呼び名'),
          ),
          OutlinedButton.icon(
            key: const Key('person-remove'),
            onPressed: busy ? null : () => removePerson(person),
            icon: const Icon(Icons.person_remove_outlined, size: 18),
            label: const Text('登録を外す'),
          ),
        ],
      ),
      if (requested)
        const Padding(
          key: Key('person-requested'),
          padding: EdgeInsets.only(top: 12),
          child: NoticeBox('この人への依頼が反映待ちです。Mac miniで処理されると反映されます。'),
        ),
      const SizedBox(height: 16),
      if (page == null)
        const Text(
          'まだ一覧が作られていません。Mac miniで次のAI読み取りが終わり、同期されると表示されます。',
          key: Key('person-page-missing'),
          style: TextStyle(height: 1.7),
        )
      else ...[
        for (final warning in page.warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NoticeBox(warning),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: SafeMarkdown(
              key: const Key('person-body'),
              text: page.body,
              sourcePath: personPagePath(person.id),
              controller: c,
              onRecord: open,
            ),
          ),
        ),
      ],
    ];
  }

  Future<void> addPerson() async {
    final personId = newPersonId();
    final next = await showDialog<PersonDraft>(
      context: context,
      builder: (_) => PersonDialog(people: repo.peopleForOverlap),
    );
    if (next == null || !mounted) return;
    await sendPerson(
      () => c.requestPerson(personId, 'add', draft: next),
      '「${next.name}」の登録を依頼しました。Mac miniで処理されると、次のAI読み取りから一覧が作られます。',
    );
  }

  Future<void> editPerson(HubPerson person) async {
    final next = await showDialog<PersonDraft>(
      context: context,
      builder: (_) =>
          PersonDialog(person: person, people: repo.peopleForOverlap),
    );
    if (next == null || !mounted) return;
    await sendPerson(
      () => c.requestPerson(
        person.id,
        'edit',
        expectedHash: person.definitionHash,
        draft: next,
      ),
      '名前と呼び名の変更を依頼しました。Mac miniで処理されると反映されます。',
    );
  }

  Future<void> removePerson(HubPerson person) async {
    if (!await confirmAction(
          '${person.name}の登録を外す',
          '人の登録と、この人の一覧（SUMMARY.md）を消すよう依頼します。メモや作業要約などの記録は消えません。あとでもう一度登録できます。',
          '登録を外す',
        ) ||
        !mounted) {
      return;
    }
    await sendPerson(
      () => c.requestPerson(
        person.id,
        'remove',
        expectedHash: person.definitionHash,
      ),
      '登録を外す依頼をしました。Mac miniで処理されると反映されます。',
    );
  }

  Future<void> sendPerson(
    Future<CaptureResult> Function() send,
    String done,
  ) async {
    try {
      final result = await send();
      if (mounted) {
        notice(
          context,
          result.saved ? done : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 定例の今の回を完了にする・見送る。本体が次の回の期日を付け、項目は欄に残る。
  Future<void> completeRound(
    String projectId,
    NowItemRef item,
    String action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(occurrenceActionLabels[action]!),
        content: SizedBox(
          width: 480,
          child: Text(
            '${item.display}\n\n期日 ${item.due}（${item.repeat!.label}）の回を${action == 'done' ? '完了にします' : '見送ります'}。'
            '項目は欄に残り、Mac miniで処理されると期日が次の回へ進みます。定例をやめるときは「…」の「定例をやめる」を使ってください。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('やめる'),
          ),
          FilledButton(
            key: Key('round-$action-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(occurrenceActionLabels[action]!),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await c.requestItemOccurrence(
        projectId,
        item.key,
        action,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '${occurrenceActionLabels[action]}を依頼しました。Mac miniで処理されると、次の回の期日が現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 本体が生成するプロジェクトの経緯（HISTORY.md）を開く。
  void showHistory(HubProject project) =>
      showGenerated(project, project.history, '経緯', 'HISTORY.md', 'history');

  /// プロジェクトの資料棚を開く。本体が資料の一覧を書いていれば、名前を変える・外す・戻すができる画面にし、
  /// 一覧のない（古い）本体では、本体が生成する資料（REFERENCES.md）をそのまま示す。
  /// URLは押したときだけ外部のブラウザで開く（http・httpsだけ）。
  void showShelf(HubProject project) {
    if (repo.referenceIndex == null) {
      showGenerated(project, project.shelf, '資料', 'REFERENCES.md', 'shelf');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReferenceShelfPage(
          controller: c,
          projectId: project.id,
          title: project.title,
          onRecord: openRecordFrom,
          onGenerated: project.shelf == null
              ? null
              : () => showGenerated(
                  project,
                  project.shelf,
                  '資料',
                  'REFERENCES.md',
                  'shelf',
                ),
        ),
      ),
    );
  }

  /// どのプロジェクトにも結び付いていない資料の棚を開く。
  void showUnassignedShelf() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ReferenceShelfPage(
        controller: c,
        projectId: null,
        title: 'プロジェクト未定',
        onRecord: openRecordFrom,
      ),
    ),
  );

  /// 別の画面（資料棚など）からメモを開く。
  void openRecordFrom(BuildContext from, HubRecord record) => Navigator.push(
    from,
    MaterialPageRoute(
      builder: (_) => RecordView(controller: c, record: record),
    ),
  );

  /// プロジェクトごとの生成ビュー（経緯・資料）を開く。
  void showGenerated(
    HubProject project,
    HubDigest? history,
    String label,
    String fileName,
    String keyName,
  ) {
    if (history == null) return;
    // 本文と同じ読込の時刻を示す（開いたまま再読込しても、本文は開いたときのもの）。
    final loadedAt = repo.snapshot.loadedAt;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('${project.title}の$label')),
          body: ListView(
            key: Key('$keyName-view'),
            padding: pagePadding(context).copyWith(bottom: 48),
            children: [
              Text(
                '生成: ${timeLabel(history.generatedAt)} · 読み込み: ${timeLabel(loadedAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final warning in history.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: NoticeBox(warning),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  child: SafeMarkdown(
                    key: Key('$keyName-body'),
                    text: history.body,
                    sourcePath: '10_projects/${project.id}/$fileName',
                    controller: c,
                    onRecord: open,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「片付いたかも」が違うときに、そのメモからの候補を見送る。項目は未解決のまま残る。
  Future<void> dismissHint(
    HubProject project,
    NowItemRef item,
    NowItemHint hint,
  ) async {
    if (!await confirmAction(
          '「片付いたかも」を見送る',
          '${item.display}\n\n根拠のメモ: 「${hint.quote}」\n\nこのメモからの候補を見送るよう依頼します。項目は${item.section == 'next' ? '次の一手' : '未解決'}に残ります。',
          '見送る',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestHintDismiss(
        project.id,
        item.key,
        hint.inputId,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '見送りを保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// AIが「片付いたかも」と示した根拠。完了にするかは本人が決める。
  Widget hintBox(HubProject project, NowItemRef item, NowItemHint hint) {
    final scheme = Theme.of(context).colorScheme,
        memo = repo.inputRecord(hint.inputId),
        pending = repo.hintDismissRequestIdFor(item.key, hint.inputId) != null,
            // 完了・解決を報告済みなら、見送りは不要。
            reported =
            repo.itemRequestIdFor(item.key) != null;
    return Container(
      key: Key('hint-${item.key.substring(0, 12)}-${hint.inputId}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '片付いたかも（AIの推定・未確認）',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            '「${hint.quote}」',
            style: const TextStyle(fontSize: 13),
          ),
          Wrap(
            spacing: 8,
            children: [
              if (memo != null)
                TextButton.icon(
                  key: const Key('hint-memo'),
                  onPressed: () => open(memo.id),
                  icon: const Icon(Icons.article_outlined, size: 15),
                  label: Text(
                    memo.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (reported)
                const SizedBox.shrink()
              else if (pending)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text('見送り済み（反映待ち）', style: noteStyle(context)),
                )
              else
                TextButton.icon(
                  key: Key('dismiss-hint-${item.key.substring(0, 12)}'),
                  onPressed: busy
                      ? null
                      : () => dismissHint(project, item, hint),
                  icon: const Icon(Icons.close, size: 15),
                  label: const Text('まだ終わっていない'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> dismissDraft(GitDraft draft) async {
    if (!await confirmAction(
          '下書きを見送る',
          '${draft.repo}のコミット${draft.commitCount}件から作った下書きを見送ります。見送ったコミットは、以後の下書きに含まれません。',
          '見送る',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestGitDraftDismiss(draft.id, draft.hash);
      if (mounted) {
        notice(
          context,
          result.saved ? '見送りを依頼しました。' : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  bool get busy => c.loading || c.saving || c.captureWarning != null;

  /// 「今日やる」「今日から外す」。選んだ項目はこの端末だけに残し、Vaultには書かない。
  Widget todayToggle(String projectId, String key) {
    final focus = c.today, on = focus.picked(key);
    return TextButton.icon(
      key: Key('today-${key.substring(0, 12)}'),
      // 3つ埋まっている間は、外す操作だけを受け付ける。
      onPressed: !on && focus.full ? null : () => setToday(projectId, key, !on),
      icon: Icon(on ? Icons.wb_sunny : Icons.wb_sunny_outlined, size: 15),
      label: Text(on ? '今日の3つから外す' : '今日やる'),
    );
  }

  Future<void> setToday(String projectId, String key, bool on) async {
    try {
      await c.setToday(projectId, key, on);
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<void> dropCarried(String key) async {
    try {
      await c.dropCarried(key);
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 持ち越した項目に期日を付ける。依頼を保存できたら、持ち越しの確認から外す。
  Future<void> scheduleCarried(TodayEntry entry) async {
    if (!await scheduleItem(entry.pick.projectId, entry.item!)) return;
    await dropCarried(entry.pick.itemKey);
  }

  /// ホームと「次の一手」の先頭に置く「今日の3つ」と、前の日からの持ち越しの確認。
  List<Widget> todaySection({bool compact = false}) {
    final focus = c.today,
        picks = [for (final p in focus.picks) todayEntry(repo, p)],
        carry = [for (final p in focus.carry) todayEntry(repo, p)];
    final scheme = Theme.of(context).colorScheme;
    Widget projectLink(TodayEntry e) => InkWell(
      onTap: e.project == null
          ? null
          : () => widget.onNavigate('project:${e.project!.id}'),
      child: Text(
        e.unassigned ? 'プロジェクト未定' : e.project?.title ?? e.pick.projectId,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
    Widget pickRow(TodayEntry e) {
      final key = e.pick.itemKey,
          reported = repo.itemRequestIdFor(key) != null,
          finished = e.done || reported || e.someday;
      return KeyedSubtree(
        key: Key('today-pick-${key.substring(0, 12)}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            projectLink(e),
            Text(
              e.text,
              style: finished
                  ? TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: scheme.onSurfaceVariant,
                    )
                  : null,
            ),
            if (e.missing)
              Text(
                '見つかりません。言い換えられたか、片付いた可能性があります。',
                style: TextStyle(fontSize: 12, color: scheme.error),
              )
            else if (e.done)
              Text(
                e.item!.excluded
                    ? (e.unassigned ? '却下しました' : '誤りとして外しました')
                    : '片付きました',
                style: const TextStyle(fontSize: 12),
              )
            else if (reported)
              Text('報告済み（反映待ち）', style: noteStyle(context))
            else if (e.someday)
              const Text('「いつかやる」へ移しました', style: TextStyle(fontSize: 12)),
            rowActions(
              context,
              Wrap(
                spacing: 2,
                children: [
                  if (!finished && !e.missing)
                    TextButton.icon(
                      key: Key('today-resolve-${key.substring(0, 12)}'),
                      onPressed: busy
                          ? null
                          : () => e.unassigned
                                ? reportUnassigned(e.item!, 'resolve')
                                : reportItem(e.project!, e.item!, 'resolve'),
                      icon: const Icon(Icons.check_circle_outline, size: 15),
                      label: Text(e.item!.section == 'next' ? '完了にする' : '解決にする'),
                    ),
                  TextButton.icon(
                    key: Key('today-remove-${key.substring(0, 12)}'),
                    onPressed: () => setToday(e.pick.projectId, key, false),
                    icon: const Icon(Icons.close, size: 15),
                    label: const Text('今日の3つから外す'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget carryRow(TodayEntry e) {
      final key = e.pick.itemKey,
              // 日付が変わった後に片付いた・報告した項目は、続けたり日付を付けたりできない。
              closed =
              e.missing ||
              e.done ||
              e.someday ||
              repo.itemRequestIdFor(key) != null;
      return KeyedSubtree(
        key: Key('today-carry-${key.substring(0, 12)}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            projectLink(e),
            Text(e.text),
            if (e.missing)
              Text(
                '見つかりません。言い換えられたか、片付いた可能性があります。',
                style: TextStyle(fontSize: 12, color: scheme.error),
              )
            else if (closed)
              const Text('片付いたか、報告済みです。', style: TextStyle(fontSize: 12)),
            Text(
              e.pick.carried >= todayCarryNudge
                  ? '${e.pick.carried}日続けて持ち越しています。小さく分けると進めやすいかもしれません。'
                  : '${e.pick.carried}日持ち越し',
              key: Key('today-carried-${key.substring(0, 12)}'),
              style: TextStyle(
                fontSize: 12,
                color: e.pick.carried >= todayCarryNudge ? scheme.error : null,
              ),
            ),
            rowActions(
              context,
              Wrap(
                spacing: 2,
                children: [
                  if (!closed)
                    TextButton.icon(
                      key: Key('today-keep-${key.substring(0, 12)}'),
                      onPressed: focus.full
                          ? null
                          : () => setToday(e.pick.projectId, key, true),
                      icon: const Icon(Icons.wb_sunny_outlined, size: 15),
                      label: const Text('今日も続ける'),
                    ),
                  // プロジェクト未定の行には、本人が追加した行動にだけ、対応した本体のときに期日を付けられる。
                  if (!closed &&
                      e.item != null &&
                      (!e.unassigned ||
                          (e.item!.action &&
                              repo.intakeFeatures.unassignedRecords)) &&
                      repo.scheduleRequestIdFor(key) == null)
                    TextButton.icon(
                      key: Key('today-schedule-${key.substring(0, 12)}'),
                      onPressed: busy ? null : () => scheduleCarried(e),
                      icon: const Icon(Icons.event_outlined, size: 15),
                      label: const Text('期日を付ける'),
                    ),
                  TextButton.icon(
                    key: Key('today-drop-${key.substring(0, 12)}'),
                    onPressed: () => dropCarried(key),
                    icon: const Icon(Icons.close, size: 15),
                    label: const Text('今日はやらない'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return [
      if (carry.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            key: const Key('today-carry'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '前の日から持ち越した項目（${carry.length}件）',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    focus.full
                        ? '今日の3つは埋まっています。続けるなら、先に今日の3つから外してください。'
                        : '今日も続けるか、期日を付けるか、今日はやらないかを選んでください。',
                    style: noteStyle(context),
                  ),
                  const SizedBox(height: 4),
                  ...dividedRows([for (final e in carry) carryRow(e)]),
                  // 最後の行の操作と見分けられるよう、線で区切る。
                  const Divider(height: 1),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const Key('today-carry-clear'),
                      onPressed: () async {
                        try {
                          await c.clearCarried();
                        } catch (e) {
                          if (mounted) {
                            notice(context, HubController.message(e));
                          }
                        }
                      },
                      child: const Text('すべて外す'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (picks.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            key: const Key('today'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '今日の3つ（${picks.length}/$todayMax）',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  ...dividedRows([for (final e in picks) pickRow(e)]),
                ],
              ),
            ),
          ),
        )
      else if (!compact)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            '次の一手・未解決の「今日やる」から、今日手を付けるものを$todayMax つまで選べます（この端末だけに残ります）。',
            key: const Key('today-empty'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ];
  }

  /// プロジェクトをピン留めする、または外す（この端末の並びだけ。Vaultには書かない）。
  Future<void> togglePin(HubProject project) async {
    try {
      await c.setPinned(project.id, !repo.isPinned(project.id));
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<void> reorderPins() => showDialog<void>(
    context: context,
    builder: (_) => PinOrderDialog(controller: c),
  );

  Future<void> markAllSeen() async {
    try {
      await c.markAllSeen();
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 行動にできるAIの読み取りの行なら、その元の行。作業要約の次の一手（キー付きの未完了の項目）と「提案」の行が対象。
  ActionSource? actionSourceOf(
    HubProject project,
    String section,
    NowEntry entry,
  ) {
    if (section == 'proposals') return repo.proposalSource(entry);
    if (section != 'next' || entry.itemKey == null) return null;
    // 完了などの報告・日付や定例の回の依頼が反映待ちの項目は、行動にしない（受付の順で依頼が断られるため）。
    if (repo.itemRequestIdFor(entry.itemKey!) != null ||
        repo.scheduleRequestIdFor(entry.itemKey!) != null) {
      return null;
    }
    final item = project.nowItems
        .where((i) => i.key == entry.itemKey)
        .firstOrNull;
    if (item == null || item.action || item.resolved) return null;
    return ActionSource(inputId: item.inputId, text: item.text, key: item.key);
  }

  bool _calendarOpening = false;

  /// 期日を端末のカレンダーへ渡す。カレンダーはクラウドへ同期されることが多いため、伏せ字の規則を確かめられないときは渡さない。
  /// [projectId]と[projectTitle]は項目の置き場（プロジェクト未定の行動は[unassignedScope]と「プロジェクト未定」）。
  Future<void> addToCalendar(
    String projectId,
    String projectTitle,
    NowItemRef item,
  ) async {
    final secrets = repo.secretPolicy;
    if (secrets.problem case final problem?) {
      notice(context, problem);
      return;
    }
    final event = dueEvent(
      projectId,
      projectTitle,
      item,
      hide: secrets.redact,
      withText: repo.intakeFeatures.calendarTitles == 'item',
    );
    if (event == null || _calendarOpening) return;
    // 続けて押しても作成画面を重ねて開かない。
    _calendarOpening = true;
    try {
      await c.access.addToCalendar(event);
    } catch (_) {
      if (mounted) notice(context, 'カレンダーを開けませんでした。端末にカレンダーのアプリがあるか確かめてください。');
    } finally {
      _calendarOpening = false;
    }
  }

  /// 手順の「…」の操作（分ける・直す・1つ戻す・外す）。[enabled]でなければ出さない。
  List<PopupMenuEntry<VoidCallback>> stepsMenu(
    String projectId,
    NowItemRef item,
    String tag,
    bool enabled,
  ) => [
    if (enabled)
      PopupMenuItem(
        key: Key('steps-$tag'),
        value: () => stepsItem(projectId, item),
        child: Text(item.steps == null ? '手順に分ける' : '手順を直す・外す'),
      ),
    if (enabled && (item.steps?.done ?? 0) > 0)
      PopupMenuItem(
        key: Key('steps-back-$tag'),
        value: () => moveStep(projectId, item, -1),
        child: const Text('手順を1つ戻す'),
      ),
  ];

  /// 今の手順を終えたと報告するボタン。手順がない・すべて終えていればnull（元の項目の完了は本人が別に報告する）。
  Widget? stepButton(String projectId, NowItemRef item, String tag) {
    final steps = item.steps;
    if (steps == null || steps.finished) return null;
    return TextButton.icon(
      key: Key('steps-next-$tag'),
      onPressed: busy ? null : () => moveStep(projectId, item, 1),
      icon: const Icon(Icons.skip_next_outlined, size: 15),
      label: Text('手順${steps.done + 1}を終えた'),
    );
  }

  /// 項目の操作。よく使う「完了」（定例は「今回を完了」）と「今日やる」だけを並べ、残りは「…」にまとめる。
  List<Widget> itemButtons(
    HubProject project,
    String section,
    NowEntry entry,
    NowItemRef item,
  ) {
    final key = item.key, tag = key.substring(0, 12);
    // 完了・解決の報告が反映待ちの間は、ほかの操作を出さない（本体が断るため）。
    if (repo.itemRequestIdFor(key) != null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('報告済み（反映待ち）', style: noteStyle(context)),
        ),
      ];
    }
    final scheduling = repo.scheduleRequestIdFor(key) != null,
            // 手間の目安。依頼が反映待ちの間は出さない。
            effortPending =
            repo.effortRequestIdFor(key) != null,
        effort = repo.intakeFeatures.effort && !project.merged,
        // 場所・道具の札。依頼が反映待ちの間は出さない。
        contextsPending = repo.contextsRequestIdFor(key) != null,
        contexts = repo.intakeFeatures.contexts && !project.merged,
        // 手順（次の一手だけ）。依頼が反映待ちの間は出さない。
        stepsPending = repo.stepsRequestIdFor(key) != null,
        steps =
            repo.intakeFeatures.steps &&
            !project.merged &&
            section == 'next' &&
            !item.resolved,
        // 連絡待ちの印。依頼が反映待ちの間は出さない。
        waitPending = repo.waitRequestIdFor(key) != null,
        wait = repo.intakeFeatures.wait && !project.merged,
        // 「いつかやる」へ移す・戻す。依頼が反映待ちの間は出さない。連絡待ちの項目には出さない。
        somedayPending = repo.somedayRequestIdFor(key) != null,
        // 休止中・完了のプロジェクトはプロジェクトごと「いつかやる」に並ぶので、項目を移すのは進行中だけ（戻すのは出す）。
        someday =
            repo.intakeFeatures.someday &&
            !project.merged &&
            (project.active || item.someday),
            // 定例の今の回を片付ける。日付の依頼が反映待ちの間は出さない。
            rounds =
            item.repeating && repo.intakeFeatures.occurrence && !scheduling,
        from = !project.merged && repo.intakeFeatures.actions
            ? actionSourceOf(project, section, entry)
            : null,
        // 本人が追加した行動は、別のプロジェクト・プロジェクト未定へ移せる。ほかの依頼が反映待ちの間は出さない。
        movable =
            item.action &&
            section == 'next' &&
            !item.resolved &&
            !project.merged &&
            repo.projectMergeRequestIdFor(project.id) == null &&
            repo.correctionRequestIdForInput(item.inputId) == null &&
            repo.intakeFeatures.actionMoves &&
            !scheduling &&
            !effortPending &&
            !contextsPending &&
            !stepsPending &&
            !waitPending &&
            !somedayPending,
        calendar =
            c.access.calendarSupported &&
            validScheduleDate(item.due) &&
            !item.resolved;
    final more = <PopupMenuEntry<VoidCallback>>[
      ...stepsMenu(project.id, item, tag, steps && !stepsPending),
      if (!scheduling)
        PopupMenuItem(
          key: Key('schedule-$tag'),
          value: () => scheduleItem(project.id, item),
          child: Text(item.scheduled ? '期日を変える' : '期日を付ける'),
        ),
      if (effort && !effortPending)
        PopupMenuItem(
          key: Key('effort-$tag'),
          value: () => effortItem(project.id, item),
          child: Text(item.effort == null ? '手間の目安を付ける' : '手間の目安を変える'),
        ),
      if (contexts && !contextsPending)
        PopupMenuItem(
          key: Key('contexts-$tag'),
          value: () => contextsItem(project.id, item),
          child: Text(item.contexts.isEmpty ? '場所・道具の札を付ける' : '場所・道具の札を変える'),
        ),
      if (wait && !waitPending && !somedayPending && !item.someday)
        PopupMenuItem(
          key: Key('wait-$tag'),
          value: () => waitItem(project.id, item),
          child: Text(item.waiting ? '連絡待ちを変える' : '連絡待ちにする'),
        ),
      if (wait && !waitPending && item.waiting)
        PopupMenuItem(
          key: Key('unwait-$tag'),
          value: () => unwaitItem(project.id, item),
          child: const Text('連絡待ちを外す'),
        ),
      if (someday && !somedayPending && !waitPending && !item.waiting)
        PopupMenuItem(
          key: Key('someday-$tag'),
          value: () => somedayItem(project.id, item),
          child: Text(item.someday ? '「いつかやる」から戻す' : '「いつかやる」へ移す'),
        ),
      if (rounds)
        PopupMenuItem(
          key: Key('round-skip-$tag'),
          value: () => completeRound(project.id, item, 'skip'),
          child: Text(occurrenceActionLabels['skip']!),
        ),
      if (item.repeating)
        PopupMenuItem(
          key: Key('resolve-$tag'),
          value: () => reportItem(project, item, 'resolve'),
          child: const Text('定例をやめる'),
        ),
      if (from != null)
        PopupMenuItem(
          key: Key(
            'take-action-${digest('${from.inputId}\n${from.text}').substring(0, 12)}',
          ),
          enabled: !c.composing,
          value: () => addAction(project: project, from: from),
          child: const Text('自分の行動にする'),
        ),
      if (movable)
        PopupMenuItem(
          key: Key('move-action-$tag'),
          enabled: !c.composing,
          value: () => moveAction(project.id, item),
          child: const Text('別の置き場へ移す'),
        ),
      // 本人が付けた期日だけを、端末のカレンダーの予定作成画面へ渡す。保存するかはカレンダーで本人が決める。
      if (calendar)
        PopupMenuItem(
          key: Key('calendar-$tag'),
          value: () => addToCalendar(project.id, project.title, item),
          child: const Text('カレンダーに入れる'),
        ),
      PopupMenuItem(
        key: Key('exclude-$tag'),
        value: () => excludeItem(project, item),
        child: const Text('誤りとして外す'),
      ),
    ];
    return [
      if (rounds)
        TextButton.icon(
          key: Key('round-done-$tag'),
          onPressed: busy
              ? null
              : () => completeRound(project.id, item, 'done'),
          icon: const Icon(Icons.task_alt, size: 15),
          label: Text(occurrenceActionLabels['done']!),
        )
      else if (!item.repeating)
        TextButton.icon(
          key: Key('resolve-$tag'),
          onPressed: busy ? null : () => reportItem(project, item, 'resolve'),
          icon: const Icon(Icons.check_circle_outline, size: 15),
          label: Text(section == 'next' ? '完了にする' : '解決にする'),
        ),
      if (scheduling)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('期日を依頼済み（反映待ち）', style: noteStyle(context)),
        ),
      if (effortPending)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('目安を依頼済み（反映待ち）', style: noteStyle(context)),
        ),
      if (contextsPending)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('札を依頼済み（反映待ち）', style: noteStyle(context)),
        ),
      if (stepsPending)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('手順を依頼済み（反映待ち）', style: noteStyle(context)),
        ),
      if (steps && !stepsPending) ?stepButton(project.id, item, tag),
      if (waitPending)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('連絡待ちを依頼済み（反映待ち）', style: noteStyle(context)),
        ),
      if (somedayPending)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('「いつかやる」を依頼済み（反映待ち）', style: noteStyle(context)),
        ),
      // 今日の3つ（この端末だけ）。
      todayToggle(project.id, key),
      PopupMenuButton<VoidCallback>(
        key: Key('item-more-$tag'),
        enabled: !busy,
        tooltip: 'ほかの操作',
        icon: const Icon(Icons.more_horiz, size: 18),
        onSelected: (action) => action(),
        itemBuilder: (_) => more,
      ),
    ];
  }

  /// NOWの1行。プロジェクト画面と「次の一手」画面で共通に使う。
  Widget nowEntry(
    HubProject project,
    String section,
    NowEntry entry,
    Set<String> added, {
    double top = 12,
  }) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (added.contains(SeenItem.of(section, entry)?.id))
          Text(
            'NEW',
            key: const Key('new-entry'),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        SafeMarkdown(
          text: entry.text,
          sourcePath: repo.records[project.nowRecordId]?.path ?? '',
          controller: c,
          onRecord: open,
        ),
        for (final warning in entry.warnings)
          entryNote(
            context,
            warning,
            problem: !softEntryNotes.contains(warning),
          ),
        // 連絡待ちの相手と頼んでからの日数（NOWの本文には相手を書かないため、ここで示す）。
        if (project.itemOf(entry) case final item? when item.waiting)
          Text(
            waitingLabel(item, hubToday()),
            key: Key('waiting-label-${item.key.substring(0, 12)}'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 4),
        if (entry.itemKey case final key?)
          if (project.nowItems.where((i) => i.key == key).firstOrNull
              case final item?)
            for (final hint in item.hints) hintBox(project, item, hint),
        rowActions(
          context,
          Wrap(
            spacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (entry.itemKey case final key?)
                if (project.nowItems.where((i) => i.key == key).firstOrNull
                    case final item?)
                  ...itemButtons(project, section, entry, item)
                else if (repo.itemRequestIdFor(key) != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text('報告済み（反映待ち）', style: noteStyle(context)),
                  ),
              // 「提案」の行は、自分の行動にするのが主な操作なので、そのまま出す。
              if (entry.itemKey == null &&
                  !project.merged &&
                  repo.intakeFeatures.actions)
                if (actionSourceOf(project, section, entry) case final from?)
                  TextButton.icon(
                    key: Key(
                      'take-action-${digest('${from.inputId}\n${from.text}').substring(0, 12)}',
                    ),
                    onPressed: busy || c.composing
                        ? null
                        : () => addAction(project: project, from: from),
                    icon: const Icon(Icons.person_add_alt, size: 15),
                    label: const Text('自分の行動にする'),
                  ),
              for (final id in entry.references)
                sourceLink(
                  context,
                  key: const Key('source-record'),
                  onPressed: () => open(id),
                  label: repo.records[id]?.title ?? '出典を確認',
                ),
            ],
          ),
        ),
      ],
    ),
  );

  /// 進行中のプロジェクトの「次の一手」（または未解決）を、ピン留めしたものから順に、残りは最新の根拠が新しい順にまとめる。
  /// 本人が付けた期日が過ぎた・今日・7日以内の項目はプロジェクトをまたいで先頭に出し、見直す日が先の項目はたたむ。
  List<Widget> nextView() {
    // 期日の通知から開いたら、通知で数えた項目が隠れないよう、次の一手の欄に戻して絞り込みを外す。
    if (c.dueOpened != _dueOpened) {
      _dueOpened = c.dueOpened;
      nextSection = 'next';
      effortFilter = null;
      contextFilter = null;
    }
    final now = DateTime.now(),
        today = hubToday(now),
        projects = repo.actionableProjects,
        section = nextSection,
        // 次の一手には、本人が追加して反映待ちの行動も数える。
        // プロジェクトを決めずに本人が追加した行動も数える（AIの読み取りの行は数えない）。
        count = {
          'next':
              projects.fold<int>(0, (n, p) => n + p.nextCount) +
              repo.unassignedActionCount,
          'open': projects.fold<int>(
            0,
            (n, p) => n + p.activeEntries('open').length,
          ),
        },
        empty = projects
            .where(
              (p) => section == 'next'
                  ? p.nextCount == 0
                  : p.activeEntries(section).isEmpty,
            )
            .toList();
    // 前回見てから増えた行。この画面では既読にしない。
    final added = {
      for (final p in projects)
        p.id:
            c.changesSince(p)?.added.map((i) => i.id).toSet() ??
            const <String>{},
    };
    // 末尾の番号はNOWでの並び順。期日とプロジェクトが同じ項目の順を保つために使う。
    // プロジェクトとNOWの行がnullの項目は、プロジェクトを決めずに本人が追加した行動。
    final front =
            <ScheduleBucket, List<(HubProject?, NowEntry?, NowItemRef, int)>>{},
        resting = <(HubProject?, NowEntry?, NowItemRef, int)>[],
        listed = <String, List<NowEntry>>{},
        // プロジェクト未定の行動のうち、期日の欄・休ませている項目に出さないもの。
        ownListed = <NowItemRef>[],
        // 本人が連絡待ちの印を付けた項目。一覧・件数・期日の欄から外し、「連絡待ち」にまとめる。
        // 見直す日が来たものは、先頭の「連絡待ちの確認」にも出す。
        waits = <(HubProject?, NowEntry?, NowItemRef, int)>[],
        // 次の一手の画面に出す、未解決の欄の連絡待ち（HOMEと同じく、次の一手の画面でもまとめて示す）。
        openWaits = Set<NowEntry>.identity();
    // 手間の目安での絞り込み。目安に対応した本体のときだけ使う。
    final efforts = repo.intakeFeatures.effort,
        filter = efforts ? effortFilter : null;
    // 場所・道具の札での絞り込み。札に対応した本体のときだけ使う。手間の目安と両方選ぶと、両方に合う項目だけを出す。
    final contextsOn = repo.intakeFeatures.contexts,
        tags = contextsOn ? repo.contextTagsInUse : const <String>[],
        contextChoice = contextsOn && contextFilter != null
            ? (contextFilter == contextFilterNone || tags.contains(contextFilter)
                  ? contextFilter
                  : null)
            : null,
        filtering = filter != null || contextChoice != null;
    // 選んでいた札が選択肢から消えたら、絞り込みを外したことにする（後で札が戻っても、黙って絞り込み直さない）。
    if (contextFilter != null && contextChoice == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && contextFilter != null) {
          setState(() => contextFilter = null);
        }
      });
    }
    var matched = 0, somedays = 0;
    for (final project in projects) {
      final rest = <NowEntry>[];
      var order = 0;
      for (final entry in project.entriesWithSource(section)) {
        order++;
        final item = project.itemOf(entry);
        // 「いつかやる」へ移した項目は、件数にも一覧にも出さず、「いつかやる」の画面にまとめる。
        if (item != null && item.someday) {
          somedays++;
          continue;
        }
        if (item != null && item.waiting) {
          waits.add((project, entry, item, order));
          continue;
        }
        // 項目に結び付かない行は目安も札も分からないので、絞り込み中は出さない（「目安なし」「札なし」とも言えない）。
        if (filtering && item == null) continue;
        if (!effortFits(filter, item?.effort)) continue;
        if (!contextFits(contextChoice, item?.contexts ?? const [])) continue;
        if (item == null || !item.scheduled) {
          matched++;
          rest.add(entry);
          continue;
        }
        final b = scheduleBucket(item.due, item.reviewAfter, today);
        // 見直す日まで休ませている項目は畳んで示すので、絞り込みの「該当なし」の判定には数えない。
        if (!b.hidden) matched++;
        if (b.hidden) {
          resting.add((project, entry, item, order));
        } else if (scheduleBucketLabels.containsKey(b.bucket)) {
          front.putIfAbsent(b.bucket, () => []).add((
            project,
            entry,
            item,
            order,
          ));
        } else {
          rest.add(entry);
        }
      }
      listed[project.id] = rest;
      if (section == 'next') {
        var openOrder = 0;
        for (final entry in project.entriesWithSource('open')) {
          openOrder++;
          final item = project.itemOf(entry);
          if (item == null || !item.waiting) continue;
          openWaits.add(entry);
          waits.add((project, entry, item, order + openOrder));
        }
      }
    }
    // プロジェクトを決めずに本人が追加した行動も、期日が近いものはプロジェクトの項目と一緒に先頭へ出し、
    // 見直す日が先のものはたたむ（日付は、対応した本体が付けたものだけが載る）。
    if (section == 'next') {
      var waitOrder = 0;
      for (final item in repo.unassignedWaitingActions) {
        waits.add((null, null, item, ++waitOrder));
      }
      var order = 0;
      for (final item in repo.unassignedOwnActions) {
        order++;
        if (!effortFits(filter, item.effort)) continue;
        if (!contextFits(contextChoice, item.contexts)) continue;
        final b = item.scheduled
            ? scheduleBucket(item.due, item.reviewAfter, today)
            : null;
        if (b == null || !b.hidden) matched++;
        if (b != null && b.hidden) {
          resting.add((null, null, item, order));
        } else if (b != null && scheduleBucketLabels.containsKey(b.bucket)) {
          front.putIfAbsent(b.bucket, () => []).add((null, null, item, order));
        } else {
          ownListed.add(item);
        }
      }
    }
    for (final list in front.values) {
      list.sort(
        (a, b) => a.$3.due!.compareTo(b.$3.due!) != 0
            ? a.$3.due!.compareTo(b.$3.due!)
            : (a.$1?.id ?? unassignedScope).compareTo(
                    b.$1?.id ?? unassignedScope,
                  ) !=
                  0
            ? (a.$1?.id ?? unassignedScope).compareTo(
                b.$1?.id ?? unassignedScope,
              )
            : a.$4.compareTo(b.$4),
      );
    }
    // 連絡待ちは頼んだ日の古い順（同じ日は置き場とNOWでの並び順）。
    // 見直す日が来た確認は絞り込みに関係なく先頭に出し、残りの連絡待ちは目安で絞り込んでいる間は出さない。
    waits.sort(
      (a, b) => a.$3.waitingSince!.compareTo(b.$3.waitingSince!) != 0
          ? a.$3.waitingSince!.compareTo(b.$3.waitingSince!)
          : (a.$1?.id ?? unassignedScope).compareTo(
                  b.$1?.id ?? unassignedScope,
                ) !=
                0
          ? (a.$1?.id ?? unassignedScope).compareTo(b.$1?.id ?? unassignedScope)
          : a.$4.compareTo(b.$4),
    );
    final checks = [
          for (final w in waits)
            if (waitingCheckDue(w.$3, today)) w,
        ],
        // 確認に出したものは、下の「連絡待ち」には重ねて出さない（同じ操作が2か所に並ばないように）。
        waitRest = [
          if (!filtering)
            for (final w in waits)
              if (!waitingCheckDue(w.$3, today)) w,
        ];
    Widget crossEntry((HubProject?, NowEntry?, NowItemRef, int) e) =>
        switch (e) {
          (final HubProject project, final NowEntry entry, _, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              InkWell(
                onTap: () => widget.onNavigate('project:${project.id}'),
                child: Text(
                  openWaits.contains(entry)
                      ? '${project.title}・未解決'
                      : project.title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              nowEntry(
                project,
                openWaits.contains(entry) ? 'open' : section,
                entry,
                added[project.id]!,
                top: 2,
              ),
            ],
          ),
          (_, _, final item, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Text(
                'プロジェクト未定',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              unassignedOwnRow(item, top: 2),
            ],
          ),
        };
    final scheme = Theme.of(context).colorScheme;
    // 絞り込みの1行。見出しの語に続けて、小さな札を並べる。
    Widget filterRow(String label, List<Widget> chips) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 札が折り返しても、2行目は札の列の頭にそろえる。文字を大きくした端末でも語は縮めない。
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 76),
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: chips,
            ),
          ),
        ],
      ),
    );
    return [
      title(
        '次の一手',
        '期日が近いものから並びます。プロジェクトに結び付いていないものは「プロジェクト未定」にあります。\n読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
      ),
      ...todaySection(),
      Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<String>(
            key: const Key('next-section'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(
                value: 'next',
                label: Text('次の一手 ${count['next']}件'),
              ),
              ButtonSegment(
                value: 'open',
                label: Text('未解決 ${count['open']}件'),
              ),
            ],
            selected: {section},
            onSelectionChanged: (v) => setState(() => nextSection = v.single),
          ),
          if (section == 'next' &&
              c.repository?.intakeFeatures.actions == true &&
              (projects.any((p) => !p.merged) ||
                  repo.intakeFeatures.unassignedActions))
            TextButton.icon(
              key: const Key('next-add-action'),
              onPressed: busy || c.composing ? null : () => addAction(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('次の一手を追加'),
            ),
        ],
      ),
      if ((efforts || contextsOn) && count[section] != 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (efforts)
                filterRow('手間の目安', [
                  for (final (value, label) in [
                    (null, 'すべて'),
                    for (final e in effortFilters.entries) (e.key, e.value),
                  ])
                    ChoiceChip(
                      key: Key('effort-filter-${value ?? 'all'}'),
                      label: Text(label),
                      visualDensity: VisualDensity.compact,
                      selected: filter == value,
                      onSelected: (_) => setState(() => effortFilter = value),
                    ),
                ]),
              if (contextsOn)
                filterRow('場所・道具', [
                  for (final (value, label) in [
                    (null, 'すべて'),
                    for (final t in tags) (t, t),
                    (contextFilterNone, '札なし'),
                  ])
                    ChoiceChip(
                      key: Key(switch (value) {
                        null => 'context-filter-all',
                        contextFilterNone => 'context-filter-none',
                        final t => 'context-filter-tag-$t',
                      }),
                      label: Text(label),
                      visualDensity: VisualDensity.compact,
                      selected: contextChoice == value,
                      onSelected: (_) => setState(() => contextFilter = value),
                    ),
                  IconButton(
                    key: const Key('context-vocabulary-edit'),
                    tooltip: '札の一覧を編集',
                    visualDensity: VisualDensity.compact,
                    onPressed: busy ? null : () => editContextVocabulary(),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                  ),
                ]),
            ],
          ),
        ),
      const SizedBox(height: 4),
      if (checks.isNotEmpty) ...[
        sectionHeading(
          '連絡待ちの確認（${checks.length}件）',
          key: const Key('next-waiting-checks'),
          note:
              '見直す日が来た連絡待ちです。返事が来ていれば「連絡待ちを外す」か完了に、まだなら催促して見直す日を付け直してください。',
        ),
        entryCard([for (final e in checks) crossEntry(e)]),
      ],
      if (projects.isEmpty && front.isEmpty && resting.isEmpty && waits.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: emptyText(context, '進行中のプロジェクトはありません。'),
        )
      else if (filtering && count[section] != 0 && matched == 0)
        Padding(
          key: const Key('effort-filter-empty'),
          padding: const EdgeInsets.only(top: 20),
          child: emptyText(
            context,
            '「${[if (filter != null) effortFilters[filter], if (contextChoice != null) contextChoice == contextFilterNone ? '札なし' : '@$contextChoice'].join('・')}」に合う${sectionLabels[section]}はありません。目安と札は各項目の「…」から付けられます。',
          ),
        )
      else if (count[section] == 0)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: emptyText(
            context,
            section == 'next'
                ? '進行中のプロジェクトに次の一手はありません。'
                : '進行中のプロジェクトに未解決はありません。',
          ),
        ),
      for (final bucket in [
        ScheduleBucket.overdue,
        ScheduleBucket.today,
        ScheduleBucket.week,
      ])
        if (front[bucket] case final entries?) ...[
          sectionTitle(
            context,
            '${scheduleBucketLabels[bucket]}（${entries.length}件）',
            key: Key('next-bucket-${bucket.name}'),
            color: bucket == ScheduleBucket.overdue ? scheme.error : null,
          ),
          entryCard([for (final e in entries) crossEntry(e)]),
        ],
      for (final project in projects)
        if (listed[project.id]! case final entries
            when entries.isNotEmpty ||
                (section == 'next' &&
                    !filtering &&
                    project.pendingActions.isNotEmpty)) ...[
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: InkWell(
              key: Key('next-project-${project.id}'),
              borderRadius: BorderRadius.circular(hubRadiusSmall),
              onTap: () => widget.onNavigate('project:${project.id}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            project.title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            projectStatusLine(project, now),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          entryCard([
            if (section == 'next' && !filtering)
              for (final action in project.pendingActions)
                pendingActionRow(action),
            for (final entry in entries)
              nowEntry(project, section, entry, added[project.id]!),
          ]),
        ],
      // 行をすべて片付けた後も、元に戻せるよう「完了・却下した行」を出す。目安・札で絞り込んでいる間は、
      // 合う本人の行動だけを出す（AIの行とメモには目安も札もない）。
      if (section == 'next' &&
          !filtering &&
          (repo.unassignedMemos.isNotEmpty ||
              repo.unassignedActionCount > 0 ||
              (repo.intakeFeatures.unassignedItems &&
                  repo.closedUnassigned.isNotEmpty)))
        ...unassignedGroup(ownListed)
      else if (section == 'next' && filtering && ownListed.isNotEmpty) ...[
        sectionHeading('プロジェクト未定', key: const Key('next-unassigned')),
        entryCard([
          for (final item in ownListed) unassignedOwnRow(item),
        ], key: const Key('unassigned-own')),
      ],
      // 連絡待ちのまとまり。見直す日が来たものは、先頭の「連絡待ちの確認」に出している。
      if (waitRest.isNotEmpty) ...[
        sectionHeading(
          '連絡待ち（${waitRest.length}件）',
          key: const Key('next-waiting'),
          note:
              '人に頼んだこと・返事を待っていることです。${sectionLabels[section]}の件数には入れていません。頼んだ日の古い順です。見直す日を付けると、その日に先頭の「連絡待ちの確認」へ出ます。',
        ),
        entryCard([for (final e in waitRest) crossEntry(e)]),
      ],
      if (resting.isNotEmpty) ...[
        const SizedBox(height: 24),
        Card(
          child: ExpansionTile(
            key: const Key('next-resting'),
            title: Text('見直す日まで休ませている項目（${resting.length}件）'),
            subtitle: const Text('見直す日が来ると元の一覧に戻ります。'),
            childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            // 行の操作が次の行に付いて見えないよう、ほかの一覧と同じく線で区切る。
            children: dividedRows([
              for (final e in resting) crossEntry(e),
            ], gap: 4),
          ),
        ),
      ],
      if (empty.isNotEmpty && count[section] != 0)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            '${sectionLabels[section]}がないプロジェクト: ${empty.map((p) => p.title).join('、')}',
            key: const Key('next-empty-projects'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      // 移した項目の数（プロジェクト未定の行動は次の一手の画面にだけ数える）。
      if (somedays + (section == 'next' ? repo.unassignedSomedayCount : 0)
          case final n when n > 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: InkWell(
            key: const Key('next-someday'),
            onTap: () => widget.onNavigate('someday'),
            child: Text(
              '「いつかやる」へ移した${sectionLabels[section]}$n件は、「いつかやる」の画面にあります。',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
    ];
  }

  /// 週次レビューで使う段（今週の気づきがあるときだけ先頭に「今週の気づき」を置く）。
  List<String> get weeklyStepIds => [
    for (final s in weeklySteps)
      if (s != 'insights' || (repo.insights?.items.isNotEmpty ?? false)) s,
  ];

  /// 点検の一覧の行のうち、今の項目一覧で[keep]に合う項目（片付いた行・状態が変わった行は除く）。
  /// プロジェクトの項目はNOWの行と一緒に、プロジェクト未定の行動は項目だけを返す。
  List<(WeeklyItem, HubProject?, NowEntry?, NowItemRef)> weeklyRows(
    List<WeeklyItem> rows,
    bool Function(NowItemRef item, WeeklyItem row) keep,
  ) {
    final result = <(WeeklyItem, HubProject?, NowEntry?, NowItemRef)>[];
    for (final w in rows) {
      if (w.scope == unassignedScope) {
        final item = currentItem(unassignedScope, w.key);
        if (item != null && !item.resolved && keep(item, w)) {
          result.add((w, null, null, item));
        }
        continue;
      }
      final project = repo.projects[w.scope];
      if (project == null || !project.active || project.merged) continue;
      final entry = project
          .entriesWithSource(w.section)
          .where((e) => project.itemOf(e)?.key == w.key)
          .firstOrNull;
      final item = entry == null ? null : project.itemOf(entry);
      if (item != null && !item.resolved && keep(item, w)) {
        result.add((w, project, entry, item));
      }
    }
    return result;
  }

  /// 点検の行。置き場の名前（と[head]）の下に、次の一手の画面と同じ行と操作を出す。
  Widget weeklyRow(
    (WeeklyItem, HubProject?, NowEntry?, NowItemRef) row, {
    String? head,
  }) {
    final (w, project, entry, item) = row;
    final place = project == null
        ? 'プロジェクト未定'
        : '${project.title}${w.section == 'open' ? '・未解決' : ''}';
    return Column(
      key: Key('weekly-row-${w.key.substring(0, 12)}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: project == null
              ? null
              : () => widget.onNavigate('project:${project.id}'),
          child: Text(
            head == null ? place : '$place · $head',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        if (project != null && entry != null)
          nowEntry(project, w.section, entry, const {}, top: 2)
        else
          unassignedOwnRow(item, top: 2),
      ],
    );
  }

  /// 長く残っている項目（期日・連絡待ち・いつかやるを付けたものは除く）。
  List<(WeeklyItem, HubProject?, NowEntry?, NowItemRef)> get weeklyLingering =>
      weeklyRows(
        repo.weeklyReview?.lingering ?? const [],
        (i, _) => !i.waiting && !i.someday && !i.scheduled,
      );

  /// 連絡待ちの行（印を外した項目は除く）。
  List<(WeeklyItem, HubProject?, NowEntry?, NowItemRef)> get weeklyWaiting =>
      weeklyRows(repo.weeklyReview?.waiting ?? const [], (i, _) => i.waiting);

  /// 期日の行（期日を付け直した・連絡待ちやいつかやるにした項目は除く）。
  List<(WeeklyItem, HubProject?, NowEntry?, NowItemRef)> get weeklyDated =>
      weeklyRows(
        repo.weeklyReview?.dated ?? const [],
        (i, w) => !i.waiting && !i.someday && i.due == w.date,
      );

  /// 次の一手も連絡待ちもない進行中のプロジェクト（足した行動が反映待ちのものは除く）。
  List<HubProject> get weeklyEmptyProjects => [
    for (final p in repo.weeklyReview?.projects ?? const <WeeklyProject>[])
      if (p.empty)
        if (repo.projects[p.id] case final project?
            when project.active &&
                !project.merged &&
                project.nextCount == 0 &&
                project.waitingEntries('next').isEmpty &&
                project.waitingEntries('open').isEmpty)
          project,
  ];

  /// 停滞している進行中のプロジェクト（長く止まっている順）。本体の点検の一覧と同じ日数（`project_stale_days`）で判断する。
  List<HubProject> get weeklyStaleProjects => [
    for (final p in repo.weeklyReview?.projects ?? const <WeeklyProject>[])
      if (p.stale)
        if (repo.projects[p.id] case final project?
            when project.active && !project.merged)
          project,
  ]..sort(
          (a, b) => (a.lastEvidenceAt ?? DateTime(0)).compareTo(
            b.lastEvidenceAt ?? DateTime(0),
          ),
        );

  /// 段ごとの残りの件数（点検の対象が数えられない段はnull）。
  int? weeklyRemaining(String step, DateTime now) => switch (step) {
    'inbox' =>
      (c.review?.pendingRows.length ?? 0) +
          repo.projects.values.fold<int>(
            0,
            (n, p) => n + (p.merged ? 0 : p.drafts.length),
          ),
    'unassigned' =>
      repo.unassignedActionCount +
          repo.unassignedItems.where((i) => !i.action && !i.resolved).length,
    'projects' => weeklyEmptyProjects.length + weeklyLingering.length,
    'stale' => weeklyStaleProjects.length,
    'waiting' => weeklyWaiting.length,
    'dates' => weeklyDated.length,
    'someday' => repo.staleSomedayEntries(hubToday(now)).length,
    _ => null,
  };

  /// 最後に見直した日の1行。
  String weeklyLastLine(WeeklyReview? review, String today) {
    final days = review?.daysSinceReview(today);
    if (review == null) return '本体がまだ点検の一覧を作っていません。';
    if (days == null) return '週次レビューを見直した記録はまだありません。';
    return '最後に見直したのは${review.lastReviewOn}（${days == 0 ? '今日' : '$days日前'}）です。${review.due(today) ? '${review.intervalDays}日以上空いています。' : ''}';
  }

  /// プロジェクトを1行で示し、次の一手を足す・状態を変える操作を添える（次の一手がない・停滞しているプロジェクト）。
  Widget weeklyProjectRow(HubProject project, DateTime now, {String? note}) =>
      KeyedSubtree(
        key: Key('weekly-project-${project.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => widget.onNavigate('project:${project.id}'),
              child: Text(
                project.title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              note ?? projectStatusLine(project, now),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            // 望む結果を添え、再開するか・休止か・完了かを判断しやすくする。
            if (project.outcomeLines.isNotEmpty)
              Text(
                '望む結果: ${project.outcomeLines.join(' / ')}',
                key: Key('weekly-outcome-${project.id}'),
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (repo.intakeFeatures.actions)
                  OutlinedButton.icon(
                    key: Key('weekly-add-${project.id}'),
                    style: compactOutlinedStyle(context),
                    onPressed: busy || c.composing
                        ? null
                        : () => addAction(project: project),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('次の一手を追加'),
                  ),
                if (project.definitionHash != null)
                  OutlinedButton(
                    key: Key('weekly-status-${project.id}'),
                    style: compactOutlinedStyle(context),
                    onPressed:
                        busy ||
                            c.composing ||
                            repo.projectStatusRequestIdFor(project.id) != null
                        ? null
                        : () => changeStatus(project),
                    child: Text(
                      repo.projectStatusRequestIdFor(project.id) != null
                          ? '状態の変更を依頼済み'
                          : '休止・完了にする',
                    ),
                  ),
              ],
            ),
          ],
        ),
      );

  /// 週次レビューの段の行を1枚の面にまとめる。行の間に線を引き、操作がどの行のものかを分かりやすくする。
  /// 1行で完結する行（ListTile）は、上下の余白を足さない（[gap]を0にする）。
  Widget weeklyCard(List<Widget> rows, {double gap = 12}) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 14, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: dividedRows(rows, gap: gap),
      ),
    ),
  );

  Widget weeklyHeading(String text, {Key? key}) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 8),
    child: Text(
      text,
      key: key,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  /// 週次レビューの画面。本体が作った点検の一覧を、決まった順に1段ずつ進める。
  /// 各段の行は次の一手・いつかやる・確認待ちの画面と同じ操作がその場でできる。進み具合は端末だけに残し、
  /// 最後の段で本人が「見直した」と報告する（AIは報告しない）。
  List<Widget> weeklyView() {
    final now = DateTime.now(),
        today = hubToday(now),
        review = repo.weeklyReview,
        features = repo.intakeFeatures;
    if (!features.weeklyReview && review == null) {
      return [
        title('週次レビュー', '週に1回、決まった順に一覧を点検します。'),
        const Text('Mac miniの本体が週次レビューに対応していません。本体を更新すると使えます。'),
      ];
    }
    if (review == null) {
      return [
        title('週次レビュー', '週に1回、決まった順に一覧を点検します。'),
        const Text(
          '本体がまだ点検の一覧を作っていません。Mac miniで処理されると表示されます。',
          key: Key('weekly-missing'),
        ),
      ];
    }
    final steps = weeklyStepIds,
        stored = c.weeklyProgress?.step,
        step = stored != null && steps.contains(stored) ? stored : steps.first,
        index = steps.indexOf(step);
    void go(String next) {
      c.setWeeklyStep(next);
    }

    final body = <Widget>[];
    switch (step) {
      case 'insights':
        body
          ..add(
            const Text(
              'AIが今週のメモをまとめて読み直した気づきです（未検証）。根拠のメモを開いて確かめ、気になったことは次の段で行動にしてください。',
              style: TextStyle(fontSize: 12),
            ),
          )
          ..add(const SizedBox(height: 12))
          ..addAll(insightsHome());
      case 'inbox':
        final rows = c.review?.pendingRows ?? const [],
            drafts = [
              for (final p in repo.orderedProjects)
                if (!p.merged && p.drafts.isNotEmpty) p,
            ];
        body.add(
          const Text(
            'AIが見つけたプロジェクト案・知識と方針の候補と、コミット履歴から作った作業記録の下書きです。開いて内容と元のメモを確かめ、採用・却下・見送りを決めてください。',
            style: TextStyle(fontSize: 12),
          ),
        );
        body.add(const SizedBox(height: 12));
        if (rows.isEmpty && drafts.isEmpty) {
          body.add(const Text('確認待ちはありません。', key: Key('weekly-inbox-empty')));
        }
        if (rows.isNotEmpty) {
          body.add(
            weeklyCard([
              for (final i in rows)
                ListTile(
                  key: Key('weekly-review-${i.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(i.title),
                  subtitle: Text('${i.label} · ${reviewState(i)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ReviewDetail(
                        controller: c,
                        id: i.id,
                        identity: c.location!.identity,
                      ),
                    ),
                  ),
                ),
            ], gap: 0),
          );
        }
        if (drafts.isNotEmpty) {
          body.add(const SizedBox(height: 12));
          body.add(
            weeklyCard([
              for (final p in drafts)
                ListTile(
                  key: Key('weekly-drafts-${p.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('${p.title}: 作業記録の下書き ${p.drafts.length}件'),
                  subtitle: const Text('プロジェクトの画面で、入力にするか見送るかを決めます'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onNavigate('project:${p.id}'),
                ),
            ], gap: 0),
          );
        }
      case 'unassigned':
        body.add(
          const Text(
            'どのプロジェクトにも結び付いていない行動と、メモから出たタスク・提案です。行動にする・完了・却下を選んでください。',
            style: TextStyle(fontSize: 12),
          ),
        );
        body.add(const SizedBox(height: 12));
        if (repo.unassignedMemos.isNotEmpty || repo.unassignedActionCount > 0) {
          body.addAll(unassignedGroup(repo.unassignedOwnActions));
        } else {
          body.add(
            const Text(
              'プロジェクト未定の行動はありません。',
              key: Key('weekly-unassigned-empty'),
            ),
          );
        }
      case 'projects':
        final empty = weeklyEmptyProjects,
            lingering = weeklyLingering,
            hinted = [
              for (final p in review.projects)
                if (p.hints > 0)
                  if (repo.projects[p.id] case final project?
                      when project.active && !project.merged)
                    (project, p.hints),
            ];
        body.add(
          Text(
            '進行中のプロジェクトを1つずつ確かめます。次の一手がなければ足すか、休止・完了にします。根拠のメモから次の一手は${review.nextStaleDays}日、未解決は${review.openStaleDays}日以上たった項目は、まだ続けるかを決めてください（期日・見直す日を付けた項目は除いています）。',
            style: const TextStyle(fontSize: 12),
          ),
        );
        // 領域を付けていれば、先に領域ごとの数を見渡す（進行中のない領域・長く動いていない領域を示す）。
        if (repo.usesAreas) {
          body.add(const SizedBox(height: 12));
          body.add(
            Column(
              key: const Key('weekly-areas'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('領域を見渡す', style: Theme.of(context).textTheme.titleSmall),
                for (final a in repo.areaOverview(now))
                  Text(
                    '${a.area ?? noAreaLabel}: 進行中 ${a.active}件・休止 ${a.paused}件・完了 ${a.done}件${a.noActive ? '（進行中なし）' : a.quiet ? '（30日以上動いていない）' : ''}',
                    key: Key('weekly-area-${a.area ?? noAreaLabel}'),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.7,
                      color: a.noActive || a.quiet
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
              ],
            ),
          );
        }
        if (empty.isEmpty && lingering.isEmpty && hinted.isEmpty) {
          body.add(const SizedBox(height: 12));
          body.add(
            const Text(
              '次の一手がないプロジェクトも、長く残っている項目もありません。',
              key: Key('weekly-projects-empty'),
            ),
          );
        }
        if (empty.isNotEmpty) {
          body.add(
            weeklyHeading(
              '次の一手がないプロジェクト（${empty.length}件）',
              key: const Key('weekly-empty-projects'),
            ),
          );
          body.add(
            weeklyCard([for (final p in empty) weeklyProjectRow(p, now)]),
          );
        }
        if (lingering.isNotEmpty) {
          body.add(
            weeklyHeading(
              '長く残っている項目（${lingering.length}件）',
              key: const Key('weekly-lingering'),
            ),
          );
          body.add(
            weeklyCard([
              for (final r in lingering)
                weeklyRow(r, head: '根拠から${waitingDays(r.$1.date, today)}日'),
            ]),
          );
        }
        if (review.lingeringTotal > review.lingering.length) {
          body.add(
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'ほかに${review.lingeringTotal - review.lingering.length}件あります（根拠の古い${review.lingering.length}件だけを並べています）。',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          );
        }
        if (hinted.isNotEmpty) {
          body.add(weeklyHeading('片付いたかも'));
          body.add(
            weeklyCard([
              for (final (project, n) in hinted)
                ListTile(
                  key: Key('weekly-hints-${project.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('${project.title}: 片付いたかも $n件'),
                  subtitle: const Text('AIが完了・解決の可能性を見つけた項目です。プロジェクトの画面で確かめます'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onNavigate('project:${project.id}'),
                ),
            ], gap: 0),
          );
        }
      case 'stale':
        final stale = weeklyStaleProjects;
        body.add(
          Text(
            '最終根拠から${review.projectStaleDays}日を超えて新しい入力がない進行中のプロジェクトです。次の一手を足して再開するか、休止・完了にしてください。',
            style: const TextStyle(fontSize: 12),
          ),
        );
        body.add(const SizedBox(height: 12));
        body.add(
          stale.isEmpty
              ? const Text(
                  '停滞しているプロジェクトはありません。',
                  key: Key('weekly-stale-empty'),
                )
              : weeklyCard([for (final p in stale) weeklyProjectRow(p, now)]),
        );
      case 'waiting':
        final rows = weeklyWaiting;
        body.add(
          const Text(
            '人に頼んだこと・返事を待っていることです。返事が来ていれば印を外すか完了に、まだなら催促して見直す日を付け直してください。',
            style: TextStyle(fontSize: 12),
          ),
        );
        body.add(const SizedBox(height: 12));
        body.add(
          rows.isEmpty
              ? const Text('連絡待ちはありません。', key: Key('weekly-waiting-empty'))
              : weeklyCard([
                  for (final r in rows)
                    weeklyRow(
                      r,
                      head:
                          '${r.$1.check ? '見直す日が来た · ' : ''}頼んでから${waitingDays(r.$1.date, today)}日',
                    ),
                ]),
        );
      case 'dates':
        final rows = weeklyDated;
        body.add(
          const Text(
            '期限切れと、今日・7日以内の期日です。期限切れは日付を付け直すか片付け、来週の期日を確かめてください。',
            style: TextStyle(fontSize: 12),
          ),
        );
        body.add(const SizedBox(height: 12));
        body.add(
          rows.isEmpty
              ? const Text(
                  '期限切れと7日以内の期日はありません。',
                  key: Key('weekly-dates-empty'),
                )
              : weeklyCard([
                  for (final r in rows)
                    weeklyRow(
                      r,
                      // 一覧を作った日より後に開いても合うよう、区分は今日の日付から決め直す。
                      head:
                          '${r.$1.date.compareTo(today) < 0
                              ? '期限切れ'
                              : r.$1.date == today
                              ? '今日'
                              : '7日以内'} ${r.$1.date}',
                    ),
                ]),
        );
        if (review.datedTotal > review.dated.length) {
          body.add(
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'ほかに${review.datedTotal - review.dated.length}件あります。次の一手の画面で確かめてください。',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          );
        }
      case 'someday':
        final days = features.somedayReviewDays,
            stale = repo.staleSomedayEntries(today);
        body.add(
          Text(
            '今は取り組まないことの置き場です。$days日以上見直していないものについて、始める・そのまま・やめるを選んでください。',
            style: const TextStyle(fontSize: 12),
          ),
        );
        body.add(const SizedBox(height: 12));
        if (stale.isEmpty) {
          body.add(
            Text(
              repo.somedayEntries.isEmpty
                  ? '「いつかやる」は空です。'
                  : '「いつかやる」の${repo.somedayEntries.length}件は、すべて$days日以内に見直しています。',
              key: const Key('weekly-someday-empty'),
            ),
          );
        } else {
          body.add(
            weeklyCard([for (final e in stale) somedayRow(e, today, days)]),
          );
        }
        if (repo.somedayEntries.isNotEmpty) {
          body.add(
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('weekly-someday-all'),
                onPressed: () => widget.onNavigate('someday'),
                child: Text('「いつかやる」をすべて見る（${repo.somedayEntries.length}件）'),
              ),
            ),
          );
        }
      default:
        final left = [
          for (final s in steps)
            if (weeklyRemaining(s, now) case final n? when n > 0)
              '${weeklyStepLabels[s]} $n件',
        ];
        final requested = repo.weeklyReviewRequestId != null,
            doneToday = review.lastReviewOn == today;
        body.add(
          Text(
            left.isEmpty
                ? 'すべての段を確かめました。'
                : '残っているもの: ${left.join('・')}。残っていても、今週はここまでと決めたなら見直したと報告できます。',
            key: const Key('weekly-finish-left'),
          ),
        );
        body.add(const SizedBox(height: 16));
        body.add(
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('weekly-done'),
              onPressed:
                  busy ||
                      c.composing ||
                      requested ||
                      doneToday ||
                      !features.weeklyReview
                  ? null
                  : () async {
                      try {
                        // 段は残し、反映待ちの表示をこの段で見せる。反映されると最後の見直しが変わり、進み具合は使わなくなる。
                        final result = await c.requestWeeklyReview();
                        if (!mounted) return;
                        notice(
                          context,
                          result.saved
                              ? '見直したことを報告しました。Mac miniで処理されると、HOMEとふりかえりに日付が出ます。'
                              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
                        );
                      } catch (e) {
                        if (mounted) notice(context, HubController.message(e));
                      }
                    },
              icon: const Icon(Icons.check, size: 18),
              label: Text(
                requested
                    ? '見直したことを報告済み（反映待ち）'
                    : doneToday
                    ? '今日の見直しは記録済み'
                    : '見直した',
              ),
            ),
          ),
        );
        body.add(const SizedBox(height: 8));
        body.add(
          const Text(
            '見直した日はVaultに記録され、HOMEとふりかえりに最後の見直しからの日数が出ます。報告するのは本人だけで、AIは報告しません。',
            style: TextStyle(fontSize: 12),
          ),
        );
    }
    return [
      title(
        '週次レビュー',
        '${weeklyLastLine(review, today)}\n上から順に確かめ、その場で判断します。途中でやめても、この端末では7日のあいだ続きから再開できます。\n点検の一覧の作成: ${timeLabel(review.generatedAt)} · 読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
      ),
      Wrap(
        key: const Key('weekly-steps'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (i, s) in steps.indexed)
            ChoiceChip(
              key: Key('weekly-step-$s'),
              label: Text(
                '${i + (steps.first == 'insights' ? 0 : 1)}. ${weeklyStepLabels[s]}${switch (weeklyRemaining(s, now)) {
                  final n? when n > 0 => ' $n',
                  _ => '',
                }}',
              ),
              selected: s == step,
              onSelected: (_) => go(s),
            ),
        ],
      ),
      const SizedBox(height: 20),
      Text(
        weeklyStepLabels[step]!,
        key: const Key('weekly-step-title'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      ...body,
      const SizedBox(height: 24),
      Row(
        children: [
          if (index > 0)
            OutlinedButton.icon(
              key: const Key('weekly-back'),
              onPressed: () => go(steps[index - 1]),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('前の段'),
            ),
          const Spacer(),
          if (index < steps.length - 1)
            FilledButton.icon(
              key: const Key('weekly-next'),
              onPressed: () => go(steps[index + 1]),
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text('次へ: ${weeklyStepLabels[steps[index + 1]]}'),
            ),
        ],
      ),
    ];
  }

  /// 「いつかやる」の画面。本人が移した項目・休止中のプロジェクト・置いたアイデアを、見直していない順に並べる。
  /// 行ごとに「始める・そのまま・やめる」を選ぶ。どれを移すか・始めるかは本人が決め、AIは決めない。
  List<Widget> somedayView() {
    final today = hubToday(),
        entries = repo.somedayEntries,
        days = repo.intakeFeatures.somedayReviewDays,
        stale = repo.staleSomedayEntries(today).length;
    if (!repo.intakeFeatures.someday && entries.isEmpty) {
      return [
        title('いつかやる', '今は取り組まないことの置き場です。'),
        const Text('Mac miniの本体が「いつかやる」に対応していません。本体を更新すると使えます。'),
      ];
    }
    return [
      title(
        'いつかやる',
        '今は取り組まない次の一手・未解決、休止中のプロジェクト、置いておくアイデアです。最後に見直した日の古い順です。'
            '\n$days日以上見直していないもの: $stale件 · 読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
      ),
      if (repo.somedayGeneratedAt == null)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            '本体がまだ一覧を作っていません。Mac miniで処理されると表示されます。',
            key: Key('someday-missing'),
          ),
        )
      else if (entries.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            '「いつかやる」は空です。次の一手・未解決の「…」の「「いつかやる」へ移す」や、アイデアの画面から置けます。',
            key: Key('someday-empty'),
          ),
        ),
      if (entries.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 14, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: dividedRows([
                for (final e in entries) somedayRow(e, today, days),
              ]),
            ),
          ),
        ),
      const SizedBox(height: 12),
      const Text(
        '始める: 項目は元の欄へ戻し、休止中のプロジェクトは進行中にします。アイデアは始めた記録を残し、続けて次の一手を追加できます。\n'
        'そのまま: 見直した日だけを今日にします（一覧の後ろへ回ります）。\n'
        'やめる: 項目は「誤り（古い情報）」として外し、プロジェクトは完了にし、アイデアは一覧から外します。原文のメモは残ります。',
        style: TextStyle(fontSize: 12),
      ),
    ];
  }

  /// 「いつかやる」の1行。種類ごとの依頼が反映待ちなら、操作の代わりにそう示す。
  Widget somedayRow(SomedayEntry e, String today, int reviewDays) {
    final tag = digest(e.ref).substring(0, 12),
        stale = e.stale(today, reviewDays),
        project = e.kind == 'project' ? repo.projects[e.id] : null,
        item = e.kind == 'item' ? currentItem(e.scope!, e.id) : null,
        pending = switch (e.kind) {
          'item' =>
            repo.somedayRequestIdFor(e.id) != null ||
                repo.itemRequestIdFor(e.id) != null ||
                repo.waitRequestIdFor(e.id) != null,
          'project' =>
            repo.somedayReviewRequestIdFor('project', e.id) != null ||
                repo.projectStatusRequestIdFor(e.id) != null,
          _ => repo.somedayReviewRequestIdFor('idea', e.id) != null,
        },
        // 操作に使う今の状態が読めない行（項目一覧やプロジェクトの定義が古い・欠けている）には操作を出さない。
        actionable =
            repo.intakeFeatures.someday &&
            switch (e.kind) {
              'item' => item != null && item.someday,
              'project' =>
                project != null &&
                    !project.merged &&
                    project.lifecycle == 'paused' &&
                    project.definitionHash != null,
              _ => repo.ideaRecord(e.id) != null,
            },
        kind = switch (e.kind) {
          'item' => e.place ?? '',
          'project' => '休止中のプロジェクト',
          _ => 'アイデア',
        },
        sinceLabel = switch (e.kind) {
          'item' => '移した日',
          'project' => '休止した日',
          _ => '置いた日',
        },
        age = e.days(today);
    return KeyedSubtree(
      key: Key('someday-$tag'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => openSomeday(e),
            child: Text(
              e.kind == 'item' ? '${e.label}${e.title}' : e.title,
              style: const TextStyle(fontSize: 15),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (kind.isNotEmpty) kind,
              if (e.since != null) '$sinceLabel ${e.since}',
              age == null
                  ? '見直した記録なし'
                  : e.reviewed == e.since
                  ? '置いてから$age日'
                  : '見直してから$age日',
            ].join(' · '),
            style: TextStyle(
              fontSize: 12,
              color: stale ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          if (pending)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('依頼済み（反映待ち）', style: noteStyle(context)),
            )
          else if (actionable)
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  key: Key('someday-start-$tag'),
                  onPressed: busy ? null : () => startSomeday(e, item, project),
                  icon: const Icon(Icons.play_arrow_outlined, size: 15),
                  label: const Text('始める'),
                ),
                TextButton.icon(
                  key: Key('someday-keep-$tag'),
                  onPressed: busy || e.reviewed == today
                      ? null
                      : () => keepSomeday(e),
                  icon: const Icon(Icons.schedule, size: 15),
                  label: Text(e.reviewed == today ? '今日見直し済み' : 'そのまま'),
                ),
                TextButton.icon(
                  key: Key('someday-drop-$tag'),
                  onPressed: busy ? null : () => dropSomeday(e, item, project),
                  icon: const Icon(Icons.close, size: 15),
                  label: const Text('やめる'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 「いつかやる」の行の元を開く。項目は置き場、プロジェクトはその画面、アイデアは記録。
  void openSomeday(SomedayEntry e) {
    switch (e.kind) {
      // プロジェクト未定の行動は、移している間はほかの一覧に出ない。この画面で始める・そのまま・やめるを選ぶ。
      case 'item' when e.scope == unassignedScope:
        notice(context, 'プロジェクト未定の行動です。この画面の「始める」で次の一手へ戻せます。');
      case 'item':
        widget.onNavigate('project:${e.scope}');
      case 'project':
        widget.onNavigate('project:${e.id}');
      default:
        if (repo.ideaRecord(e.id) case final record?) open(record.id);
    }
  }

  /// 始める。項目は元の欄へ戻し、プロジェクトは進行中にし、アイデアは始めた記録を残して次の一手の追加を開く。
  Future<void> startSomeday(
    SomedayEntry e,
    NowItemRef? item,
    HubProject? project,
  ) async {
    final (body, ok) = switch (e.kind) {
      'item' => ('この項目を元の欄（${e.section == 'open' ? '未解決' : '次の一手'}）へ戻すよう依頼します。', '戻す'),
      'project' => ('このプロジェクトを進行中に戻すよう依頼します。', '進行中にする'),
      _ => (
        repo.intakeFeatures.actions
            ? 'このアイデアを始めたと記録し、「いつかやる」から外すよう依頼します。続けて最初の次の一手を追加できます（追加しなくても構いません）。'
            : 'このアイデアを始めたと記録し、「いつかやる」から外すよう依頼します。',
        '始める',
      ),
    };
    if (!await confirmAction('始める', '${e.title}\n\n$body', ok) || !mounted) {
      return;
    }
    switch (e.kind) {
      case 'item':
        await somedayRequest(
          () => c.requestItemSomeday(e.scope!, e.id, 'back'),
          '元の欄へ戻す依頼を保存しました。',
        );
      case 'project':
        await somedayRequest(
          () => c.requestProjectStatus(e.id, project!.definitionHash!, 'active'),
          '進行中にする依頼を保存しました。',
        );
      default:
        final saved = await somedayRequest(
          () => c.requestSomedayReview('idea', e.id, 'start'),
          '始めた記録を依頼しました。',
        );
        if (saved && mounted && repo.intakeFeatures.actions) await addAction();
    }
  }

  /// そのまま（見直した日だけを今日にする）。
  Future<void> keepSomeday(SomedayEntry e) => somedayRequest(
    () => e.kind == 'item'
        ? c.requestItemSomeday(e.scope!, e.id, 'keep')
        : c.requestSomedayReview(e.kind, e.id, 'keep'),
    '見直した日を依頼しました。',
  );

  /// やめる。項目は「誤り（古い情報）」として外し、プロジェクトは完了にし、アイデアは一覧から外す。
  Future<void> dropSomeday(
    SomedayEntry e,
    NowItemRef? item,
    HubProject? project,
  ) async {
    final (body, ok) = switch (e.kind) {
      'item' => (
        'この項目はやらないものとして、「誤り（古い情報）」として外すよう依頼します。元のメモは残り、外した項目は元に戻せます。',
        '外す',
      ),
      'project' => (
        [
          'このプロジェクトを完了にするよう依頼します。記録は残り、あとで進行中に戻せます。',
          // 完了の判断の基準として、本人が書いた望む結果を添える（状態の変更と同じ）。
          if (project?.outcomeLines case final lines? when lines.isNotEmpty)
            '望む結果:\n${lines.join('\n')}\nこれを満たしたかを確かめてから完了にしてください。',
        ].join('\n\n'),
        '完了にする',
      ),
      _ => ('このアイデアをやめたと記録し、「いつかやる」から外すよう依頼します。アイデアの記録は残ります。', 'やめる'),
    };
    if (!await confirmAction('やめる', '${e.title}\n\n$body', ok) || !mounted) {
      return;
    }
    await somedayRequest(
      () => switch (e.kind) {
        'item' => c.requestItemResolution(
          e.scope!,
          e.id,
          'exclude',
          reason: 'outdated',
        ),
        'project' => c.requestProjectStatus(
          e.id,
          project!.definitionHash!,
          'done',
        ),
        _ => c.requestSomedayReview('idea', e.id, 'drop'),
      },
      'やめる依頼を保存しました。',
    );
  }

  /// ホームの「今週の気づき」。本体の週次の統合が、たまったメモをまとめて読み直した結果（AI生成・未検証）。
  /// 項目ごとに根拠のメモを開いて確かめられる。本体で無効のとき・結果がないときは何も出さない。
  List<Widget> insightsHome() {
    final insights = repo.insights;
    if (insights == null) return const [];
    final now = DateTime.now(),
        items = insights.items,
        age = insights.ageDays(now),
        widgets = <Widget>[];
    if (insights.failure != null) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: NoticeBox(
            '週次の統合（今週の気づき）の前回の実行が失敗しました（${insights.failure}）。${items.isEmpty ? '' : '前回までの気づきを表示しています。'}やり直し方は、VaultのHOME.mdの「失敗と競合」にあります。',
            key: const Key('home-insights-failure'),
          ),
        ),
      );
    }
    if (insights.recordProblems > 0) {
      widgets.add(
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: NoticeBox(
            '週次の統合の記録に読めないものがあり、自動の実行が止まっています。VaultのHOME.mdの「失敗と競合」で場所を確認してください。',
            key: Key('home-insights-records'),
          ),
        ),
      );
    }
    if (items.isEmpty) {
      // 項目はあるが、根拠のメモがまだこの端末に届いていない。
      if (insights.waiting > 0) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '今週の気づき: 根拠のメモがこの端末に届いていない${insights.waiting}件は、同期で届いてから表示します。',
              key: const Key('home-insights-waiting'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      }
      return widgets;
    }
    // たたんでいる間は、欄ごとに先頭の1件だけを出す。
    final shownKeys = <String>{};
    for (final section in insightSectionLabels.keys) {
      final inSection = items.where((i) => i.section == section);
      shownKeys.addAll(
        (insightsExpanded ? inSection : inSection.take(1)).map((i) => i.key),
      );
    }
    final hidden = items.length - shownKeys.length;
    widgets.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                key: const Key('home-insights'),
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text('今週の気づき ${items.length}件'),
                subtitle: Text(
                  [
                    '${hubToday(insights.createdAt)}に、たまったメモをAIがまとめて読み直した結果（AIの推定・未検証）',
                    if (insights.mode == 'quiet') '新しいメモが少なかったので、以前のメモの見直しが中心',
                    if (insights.stale(now)) '$age日前の結果',
                    if (insights.waiting > 0)
                      '根拠のメモが届いていない${insights.waiting}件は、届いてから表示',
                  ].join(' · '),
                ),
              ),
              // 1件ずつ線で区切り、欄の名前・本文・根拠・反応をその中にまとめる。
              // 線がないと、反応のボタンが次の気づきの上に付いているように見えていた。
              for (final section in insightSectionLabels.keys)
                for (final (i, item) in items
                    .where(
                      (i) => i.section == section && shownKeys.contains(i.key),
                    )
                    .indexed) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  insightEntry(item, firstInSection: i == 0),
                ],
              if (hidden > 0 || insightsExpanded) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
                  child: TextButton(
                    key: const Key('home-insights-more'),
                    onPressed: () =>
                        setState(() => insightsExpanded = !insightsExpanded),
                    child: Text(insightsExpanded ? 'たたむ' : 'ほか$hidden件を表示'),
                  ),
                ),
              ] else
                const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    return widgets;
  }

  /// 今週の気づきの項目へ反応を付ける（同じ反応をもう一度押すと外す）。
  Future<void> reactToInsight(
    String runId,
    InsightItem item,
    String reaction,
  ) async {
    try {
      final result = await c.requestInsightReaction(runId, item.key, reaction);
      if (mounted && !result.saved) {
        notice(context, '保存結果を確認できません。保存と反映から同じ操作を確認してください。');
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 今週の気づきの1件。本文はAIが書いたもので、そのまま文字として出す（Markdownとして解釈しない）。
  /// 反応（役に立った・的外れ）を付けられ、問いと止まっている意図には答えられる。
  Widget insightEntry(InsightItem item, {bool firstInSection = false}) {
    // 反応と答えに対応していない本体には、依頼を出さない。
    final runId = repo.insights?.feedback == true ? repo.insights?.runId : null;
    final (:reaction, :pending) = repo.insightReactionOf(item);
    final theme = Theme.of(context);
    // 根拠・答えのメモへのリンクは、本文の下に小さく並べる。
    Widget memoLink(Key key, IconData icon, String label, String inputId) =>
        sourceLink(
          context,
          key: key,
          icon: icon,
          label: label,
          onPressed: () {
            final record = repo.inputRecord(inputId);
            if (record != null) open(record.id);
          },
        );
    Widget links(String label, List<Widget> children) => Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 2),
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        ...children,
      ],
    );
    return Padding(
      key: Key('home-insight-${item.key}'),
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 欄の名前は各件の頭に付ける（たたんだ欄を開いても、どの欄の気づきかが分かる）。
          Text(
            insightSectionLabels[item.section] ?? item.section,
            key: firstInSection ? Key('home-insights-${item.section}') : null,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(item.text, style: const TextStyle(height: 1.6)),
          if (item.firstStep != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '最初の一歩: ${item.firstStep}',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ),
          const SizedBox(height: 4),
          links('根拠', [
            for (final source in item.sources)
              memoLink(
                Key('home-insight-source-${item.key}-${source.inputId}'),
                Icons.article_outlined,
                '${hubToday(source.at)}のメモ${source.corrected ? '（訂正あり）' : ''}',
                source.inputId,
              ),
          ]),
          if (item.answers.isNotEmpty)
            links('答え', [
              for (final answer in item.answers)
                memoLink(
                  Key('home-insight-answered-${item.key}-${answer.inputId}'),
                  Icons.chat_bubble_outline,
                  '${hubToday(answer.at)}のメモ',
                  answer.inputId,
                ),
            ]),
          // 反応と答えるは、根拠の下にこの気づきへの操作としてまとめる。
          if (runId != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: rowActions(
                context,
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final value in const ['useful', 'off-target'])
                      ChoiceChip(
                        key: Key('home-insight-$value-${item.key}'),
                        label: Text(insightReactionLabels[value]!),
                        avatar: Icon(
                          value == 'useful'
                              ? Icons.thumb_up_alt_outlined
                              : Icons.thumb_down_alt_outlined,
                          size: 14,
                        ),
                        labelStyle: const TextStyle(fontSize: 12.5),
                        // 印と文字の間を詰める（既定では印の後ろが広く空く）。
                        labelPadding: const EdgeInsets.only(left: 2, right: 6),
                        visualDensity: VisualDensity.compact,
                        selected: reaction == value,
                        tooltip: reaction == value ? 'もう一度押すと反応を外します' : null,
                        onSelected: busy
                            ? null
                            : (_) => reactToInsight(
                                runId,
                                item,
                                reaction == value ? 'none' : value,
                              ),
                      ),
                    if (insightAnswerSections.contains(item.section))
                      TextButton.icon(
                        key: Key('home-insight-answer-${item.key}'),
                        onPressed: busy
                            ? null
                            : () => showCapture(
                                context,
                                c,
                                answer: InsightAnswerTarget(
                                  runId: runId,
                                  itemKey: item.key,
                                  question: item.text,
                                ),
                              ),
                        icon: const Icon(Icons.edit_note, size: 18),
                        label: const Text('答える'),
                      ),
                    if (pending)
                      Text(
                        '反映待ち',
                        key: Key('home-insight-pending-${item.key}'),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 「次の一手」画面の「プロジェクト未定」。プロジェクトを決めずに本人が追加した行動を先に、
  /// どのプロジェクトにも結び付いていないメモの、AIによるタスクの分類と次の一手の提案を新しい順に並べる。
  /// 本体が対応していれば、行ごとに今日やる・完了・却下・自分の行動にするができる。
  /// [own]は、ここに並べる本人の行動（期日の欄・休ませている項目に出したものを除く）。
  List<Widget> unassignedGroup(List<NowItemRef> own) {
    final memos = repo.unassignedMemos,
        listed = memos.take(unassignedShown).toList(),
        rest = repo.unassignedTotal - memos.length,
        actionable = repo.intakeFeatures.unassignedItems,
        closed = actionable ? repo.closedUnassigned : const <NowItemRef>[],
        pending = repo.unassignedPendingActions,
        // 件数は、期日の欄などに出した行動も含めた全体。
        total = repo.unassignedActionCount,
        moved = repo.unassignedOwnActions.length - own.length,
        counts = [
          if (total > 0) '行動$total件',
          if (repo.unassignedTotal > 0) 'メモ${repo.unassignedTotal}件',
        ];
    return [
      sectionHeading(
        counts.isEmpty ? 'プロジェクト未定' : 'プロジェクト未定（${counts.join('・')}）',
        key: const Key('next-unassigned'),
      ),
      if (own.isNotEmpty || pending.isNotEmpty) ...[
        entryCard([
          for (final action in pending) pendingActionRow(action),
          for (final item in own) unassignedOwnRow(item),
        ], key: const Key('unassigned-own')),
        const SizedBox(height: 12),
      ],
      if (moved > 0) ...[
        Text(
          '期日が近い・見直す日まで休ませている行動$moved件は、上の期日の欄と「見直す日まで休ませている項目」にあります。',
          key: const Key('unassigned-moved'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
      ],
      if (listed.isNotEmpty || rest > 0) ...[
        Text(
          actionable
              ? 'どのプロジェクトにも属さないメモから、AIがタスクと見た行と提案です（未検証）。やるなら「今日やる」、やらないなら「却下」で一覧から外せます。'
              : 'どのプロジェクトにも属さないメモから、AIがタスクと見た行と提案です（未検証）。メモがプロジェクトに結び付くと、そのプロジェクトへ移ります。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
      ],
      if (listed.isNotEmpty)
        entryCard([
          for (final memo in listed) unassignedEntry(memo, actionable),
        ]),
      if (memos.length > listed.length)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Center(
            child: OutlinedButton(
              key: const Key('unassigned-more'),
              onPressed: () =>
                  setState(() => unassignedShown += unassignedPageSize),
              child: Text('さらに表示（残り${memos.length - listed.length}件）'),
            ),
          ),
        )
      else if (rest > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'ほか$rest件は、ここに載せていない古いメモか、原文がこの端末に届いていないメモ、訂正の反映を待っているメモです。',
            key: const Key('unassigned-rest'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (closed.isNotEmpty)
        ExpansionTile(
          key: const Key('unassigned-closed'),
          tilePadding: EdgeInsets.zero,
          title: Text(
            '完了・却下した行（${closed.length}件）',
            style: const TextStyle(fontSize: 14),
          ),
          children: [for (final item in closed) closedUnassignedRow(item)],
        ),
    ];
  }

  /// プロジェクト未定の1行（メモの本文か提案）の操作。本体の項目一覧に載っていない行には出さない。
  Widget unassignedActions(String inputId, String text) {
    final item = repo.unassignedRow(inputId, text);
    if (item == null || item.resolved) return const SizedBox.shrink();
    // 行動にした行は、操作を出さない（本体が一覧を作り直すと外れる）。
    if (repo.takenOver(item.inputId, item.text)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('自分の行動にしました（反映待ち）', style: noteStyle(context)),
      );
    }
    return unassignedItemActions(item, takeOver: true);
  }

  /// プロジェクト未定の項目の操作（今日やる・完了・却下）。[takeOver]ならAIの行を自分の行動にする操作も出す。
  /// 本人が追加した行動には、対応した本体のとき、期日・手間の目安・定例の回の操作も「…」に出す。
  Widget unassignedItemActions(NowItemRef item, {bool takeOver = false}) {
    if (repo.itemRequestIdFor(item.key) != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('操作済み（反映待ち）', style: noteStyle(context)),
      );
    }
    final tag = item.key.substring(0, 12),
        // 行動にする先は、進行中のプロジェクトかプロジェクト未定。引き取った行を一覧から外すのは
        // プロジェクトを決めない行動に対応した本体だけなので、対応前の本体には出さない。
        canTake =
            takeOver && !item.action && repo.intakeFeatures.unassignedActions,
        records = item.action && repo.intakeFeatures.unassignedRecords,
        scheduling = repo.scheduleRequestIdFor(item.key) != null,
        effortPending = repo.effortRequestIdFor(item.key) != null,
        effort = records && repo.intakeFeatures.effort,
        contextsPending = repo.contextsRequestIdFor(item.key) != null,
        contexts = records && repo.intakeFeatures.contexts,
        stepsPending = repo.stepsRequestIdFor(item.key) != null,
        steps =
            records &&
            repo.intakeFeatures.steps &&
            item.section == 'next' &&
            !item.resolved,
        waitPending = repo.waitRequestIdFor(item.key) != null,
        wait = records && repo.intakeFeatures.wait,
        somedayPending = repo.somedayRequestIdFor(item.key) != null,
        someday = records && repo.intakeFeatures.someday,
        rounds =
            records &&
            item.repeating &&
            repo.intakeFeatures.occurrence &&
            !scheduling,
        calendar =
            records &&
            c.access.calendarSupported &&
            validScheduleDate(item.due) &&
            !item.resolved,
        // 本人が追加した行動は、進行中のプロジェクトへ移せる。ほかの依頼が反映待ちの間は出さない。
        movable =
            item.action &&
            !item.resolved &&
            repo.intakeFeatures.actionMoves &&
            repo.intakeFeatures.unassignedActions &&
            repo.correctionRequestIdForInput(item.inputId) == null &&
            !scheduling &&
            !effortPending &&
            !contextsPending &&
            !stepsPending &&
            !waitPending &&
            !somedayPending;
    final more = <PopupMenuEntry<VoidCallback>>[
      ...stepsMenu(unassignedScope, item, 'unassigned-$tag', steps && !stepsPending),
      if (movable)
        PopupMenuItem(
          key: Key('unassigned-move-$tag'),
          enabled: !c.composing,
          value: () => moveAction(unassignedScope, item),
          child: const Text('プロジェクトへ移す'),
        ),
      if (records && !scheduling)
        PopupMenuItem(
          key: Key('unassigned-schedule-$tag'),
          value: () => scheduleItem(unassignedScope, item),
          child: Text(item.scheduled ? '期日を変える' : '期日を付ける'),
        ),
      if (effort && !effortPending)
        PopupMenuItem(
          key: Key('unassigned-effort-$tag'),
          value: () => effortItem(unassignedScope, item),
          child: Text(item.effort == null ? '手間の目安を付ける' : '手間の目安を変える'),
        ),
      if (contexts && !contextsPending)
        PopupMenuItem(
          key: Key('unassigned-contexts-$tag'),
          value: () => contextsItem(unassignedScope, item),
          child: Text(item.contexts.isEmpty ? '場所・道具の札を付ける' : '場所・道具の札を変える'),
        ),
      if (wait && !waitPending && !somedayPending && !item.someday)
        PopupMenuItem(
          key: Key('unassigned-wait-$tag'),
          value: () => waitItem(unassignedScope, item),
          child: Text(item.waiting ? '連絡待ちを変える' : '連絡待ちにする'),
        ),
      if (wait && !waitPending && item.waiting)
        PopupMenuItem(
          key: Key('unassigned-unwait-$tag'),
          value: () => unwaitItem(unassignedScope, item),
          child: const Text('連絡待ちを外す'),
        ),
      if (someday && !somedayPending && !waitPending && !item.waiting)
        PopupMenuItem(
          key: Key('unassigned-someday-$tag'),
          value: () => somedayItem(unassignedScope, item),
          child: Text(item.someday ? '「いつかやる」から戻す' : '「いつかやる」へ移す'),
        ),
      if (rounds)
        PopupMenuItem(
          key: Key('unassigned-round-skip-$tag'),
          value: () => completeRound(unassignedScope, item, 'skip'),
          child: Text(occurrenceActionLabels['skip']!),
        ),
      if (calendar)
        PopupMenuItem(
          key: Key('unassigned-calendar-$tag'),
          value: () => addToCalendar(unassignedScope, 'プロジェクト未定', item),
          child: const Text('カレンダーに入れる'),
        ),
    ];
    return rowActions(
      context,
      Wrap(
        spacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          todayToggle(unassignedScope, item.key),
          // 定例の行動は、今の回を完了にする（行動は残る）。定例をやめるときは「完了」。
          if (rounds)
            TextButton.icon(
              key: Key('unassigned-round-done-$tag'),
              onPressed: busy
                  ? null
                  : () => completeRound(unassignedScope, item, 'done'),
              icon: const Icon(Icons.task_alt, size: 15),
              label: Text(occurrenceActionLabels['done']!),
            ),
          TextButton.icon(
            key: Key('unassigned-resolve-$tag'),
            onPressed: busy ? null : () => reportUnassigned(item, 'resolve'),
            icon: const Icon(Icons.check_circle_outline, size: 15),
            label: Text(rounds ? '定例をやめる' : '完了'),
          ),
          TextButton.icon(
            key: Key('unassigned-reject-$tag'),
            onPressed: busy ? null : () => reportUnassigned(item, 'exclude'),
            icon: const Icon(Icons.close, size: 15),
            label: const Text('却下'),
          ),
          if (scheduling && records)
            Text('期日を依頼済み（反映待ち）', style: noteStyle(context)),
          if (effortPending && records)
            Text('目安を依頼済み（反映待ち）', style: noteStyle(context)),
          if (contextsPending && records)
            Text('札を依頼済み（反映待ち）', style: noteStyle(context)),
          if (stepsPending && records)
            Text('手順を依頼済み（反映待ち）', style: noteStyle(context)),
          if (steps && !stepsPending)
            ?stepButton(unassignedScope, item, 'unassigned-$tag'),
          if (waitPending && records)
            Text('連絡待ちを依頼済み（反映待ち）', style: noteStyle(context)),
          if (somedayPending && records)
            Text('「いつかやる」を依頼済み（反映待ち）', style: noteStyle(context)),
          if (more.isNotEmpty)
            PopupMenuButton<VoidCallback>(
              key: Key('unassigned-more-$tag'),
              enabled: !busy,
              tooltip: 'ほかの操作',
              icon: const Icon(Icons.more_horiz, size: 18),
              onSelected: (action) => action(),
              itemBuilder: (_) => more,
            ),
          if (canTake)
            TextButton.icon(
              key: Key('unassigned-take-$tag'),
              onPressed: busy || c.composing
                  ? null
                  : () => addAction(
                      from: ActionSource(
                        inputId: item.inputId,
                        text: item.text,
                        key: item.key,
                      ),
                      unassigned: true,
                    ),
              icon: const Icon(Icons.person_add_alt, size: 15),
              label: const Text('自分の行動にする'),
            ),
        ],
      ),
    );
  }

  /// プロジェクトを決めずに本人が追加した行動の1行。本人が付けた日付と手間の目安を本文の下に示す。
  Widget unassignedOwnRow(NowItemRef item, {double top = 12}) => Padding(
    key: Key('unassigned-action-${item.key.substring(0, 12)}'),
    padding: EdgeInsets.only(top: top, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.display,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            height: 1.6,
          ),
        ),
        if (itemRecordLabel(item) case final label when label.isNotEmpty)
          Text(
            label,
            key: Key('unassigned-label-${item.key.substring(0, 12)}'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (item.waiting)
          Text(
            waitingLabel(item, hubToday()),
            key: Key('waiting-label-${item.key.substring(0, 12)}'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        unassignedItemActions(item),
      ],
    ),
  );

  /// 完了・却下した行。未解決へ戻せる。
  Widget closedUnassignedRow(NowItemRef item) => ListTile(
    key: Key('unassigned-closed-${item.key.substring(0, 12)}'),
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(item.display, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(item.excluded ? '却下' : '完了'),
    trailing: repo.itemRequestIdFor(item.key) != null
        ? Text('反映待ち', style: noteStyle(context))
        : TextButton(
            key: Key('unassigned-reopen-${item.key.substring(0, 12)}'),
            onPressed: busy ? null : () => reportUnassigned(item, 'reopen'),
            child: const Text('元に戻す'),
          ),
  );

  /// プロジェクト未定のメモ1件。本体が対応していれば行ごとに操作を付け、いつでも元のメモを開ける。
  Widget unassignedEntry(UnassignedMemo memo, bool actionable) {
    final record = repo.inputRecord(memo.inputId);
    final theme = Theme.of(context);
    return Padding(
      key: Key('unassigned-${memo.inputId}'),
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${hubToday(memo.at)} · ${memo.ownWords ? '本人のメモ' : 'AIの要約・未検証'}${memo.task ? ' · AIがタスクと分類' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          Text(
            memo.text,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              height: 1.6,
            ),
          ),
          if (actionable && memo.task)
            unassignedActions(memo.inputId, memo.text),
          // 本文と同じ提案や重なった提案は、同じ行（同じキー）なので操作を1回だけ出す。
          // AIの提案は、左に細い線を引いて本文と分ける。
          for (final (index, suggestion) in memo.suggestions.indexed)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 2,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI提案: $suggestion',
                    style: const TextStyle(height: 1.6),
                  ),
                  if (actionable &&
                      !(memo.task && suggestion == memo.text) &&
                      !memo.suggestions.take(index).contains(suggestion))
                    unassignedActions(memo.inputId, suggestion),
                ],
              ),
            ),
          if (record != null)
            sourceLink(
              context,
              key: Key('unassigned-open-${memo.inputId}'),
              onPressed: () => open(record.id),
              label: '元のメモを開く',
            ),
        ],
      ),
    );
  }

  /// プロジェクトの画面の先頭に置く望む結果。書いていなければ、対応した本体のときだけ書く操作を出す。
  Widget projectOutcome(HubProject project, bool editable) {
    final lines = project.outcomeLines,
        supported = repo.intakeFeatures.projectOutcome != null;
    if (lines.isEmpty && !supported) return const SizedBox.shrink();
    final edit = supported
        ? TextButton.icon(
            key: const Key('project-outcome-edit'),
            onPressed: editable ? () => changeDefinition(project) : null,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: Text(lines.isEmpty ? '望む結果を書く' : '望む結果を直す'),
          )
        : null;
    // 書いていないときは1行だけにし、画面の先頭を大きく押し下げない。
    if (lines.isEmpty) {
      return Padding(
        key: const Key('project-outcome'),
        padding: const EdgeInsets.only(bottom: 6),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(
              '望む結果（何をもって完了か）: 未記入',
              key: const Key('project-outcome-empty'),
              style: inlineLabelStyle(context),
            ),
            ?edit,
          ],
        ),
      );
    }
    return Padding(
      key: const Key('project-outcome'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '望む結果（何をもって完了か）',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              SelectableText(
                lines.join('\n'),
                key: const Key('project-outcome-text'),
                style: const TextStyle(height: 1.6),
              ),
              if (edit != null)
                Align(alignment: Alignment.centerRight, child: edit),
            ],
          ),
        ),
      ),
    );
  }

  /// プロジェクトの領域（本人が付けた責任の範囲）と、付ける・変える操作。領域に対応していない本体では、付いていても示すだけ。
  Widget projectArea(HubProject project, bool editable) {
    final supported = repo.intakeFeatures.areas;
    if (project.area == null && !supported) return const SizedBox.shrink();
    return Padding(
      key: const Key('project-area'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(
            '領域: ${project.area ?? '未設定'}',
            key: const Key('project-area-label'),
            style: inlineLabelStyle(context),
          ),
          if (supported)
            TextButton.icon(
              key: const Key('project-area-edit'),
              onPressed: editable ? () => changeArea(project) : null,
              icon: const Icon(Icons.folder_outlined, size: 16),
              label: Text(project.area == null ? '領域を付ける' : '領域を変える'),
            ),
        ],
      ),
    );
  }

  List<Widget> projectView(HubProject project) {
    final now = DateTime.now(),
        requested = repo.projectStatusRequestIdFor(project.id) != null,
        defining =
            repo.projectDefinitionRequestIdFor(project.id) != null ||
            repo.projectAreaRequestIdFor(project.id) != null,
        merging = repo.projectMergeRequestIdFor(project.id) != null,
        mergeTarget = repo.projects[project.mergeTarget],
        sources = repo.mergedSources(project.id),
            // 統合と取り消しは、統合済みのプロジェクトでも依頼できる（取り消しのため）。
            mergeable =
            !c.loading &&
            !c.saving &&
            !requested &&
            !defining &&
            !merging &&
            c.captureWarning == null &&
            project.definitionHash != null,
        editable =
            !c.loading &&
            !c.saving &&
            !requested &&
            !defining &&
            !merging &&
            !project.merged &&
            c.captureWarning == null &&
            project.definitionHash != null,
        changes = c.changesSince(project, visit: true),
        added = changes?.added.map((i) => i.id).toSet() ?? const <String>{};
    final theme = Theme.of(context);
    // 見出しの下の操作は、行の操作より一回り大きいが、本文より目立たない大きさにそろえる。
    final actionStyle = compactOutlinedStyle(context);
    // 本体がいつも付ける「未検証の要約」の注意は、欄の見出しの下に小さく添える（毎回の大きな注意にしない）。
    final summaryNote = project.warnings.where(
          (w) => w == HubProject.summaryWarning,
        ),
        problems = project.warnings.where((w) => w != HubProject.summaryWarning);
    return [
      title(
        label: 'プロジェクト · ${project.lifecycleLabel}',
        project.title,
        '${projectStatusLine(project, now)}\n最新の根拠: ${timeLabel(project.lastEvidenceAt)} · 要約の生成: ${timeLabel(project.generatedAt)}',
      ),
      projectOutcome(project, editable),
      projectArea(project, editable),
      if (project.stale(now))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '最終根拠から$projectStaleDays日を超えて新しい入力がありません。再開するか、休止・完了にするかを判断してください。${project.outcomeLines.isEmpty ? '' : '\n望む結果: ${project.outcomeLines.join(' / ')}'}',
            key: const Key('project-stale'),
          ),
        ),
      if (requested)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox('状態の変更を依頼済みです。Mac miniで処理されると反映されます。'),
        ),
      if (project.nowConflict case final conflict?)
        conflictPanel(project, conflict),
      if (mergeTarget != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NoticeBox(
                'このプロジェクトは「${mergeTarget.title}」に統合済みです。このプロジェクトを指定したメモ・完了報告・日付は、統合先のものとして読みます。現在地と次の一手は統合先で確認してください。',
                key: const Key('project-merged'),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('project-merge-target'),
                    onPressed: () =>
                        widget.onNavigate('project:${mergeTarget.id}'),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: Text('統合先「${mergeTarget.title}」を開く'),
                  ),
                  // 取り消せるのは直接の統合先からだけ（本体と同じ）。
                  if (project.mergedInto == mergeTarget.id)
                    OutlinedButton.icon(
                      key: const Key('project-unmerge'),
                      onPressed: mergeable
                          ? () => unmergeProject(project)
                          : null,
                      icon: const Icon(Icons.call_split, size: 18),
                      label: const Text('統合を取り消す'),
                    ),
                ],
              ),
            ],
          ),
        ),
      if (sources.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '統合されたプロジェクト: ${sources.map((p) => p.title).join('、')}\nこれらを指定したメモ・完了報告・日付も、このプロジェクトのものとして読んでいます。',
            key: const Key('project-merge-sources'),
          ),
        ),
      if (merging)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '統合（または取り消し）を依頼済みです。Mac miniで処理されると反映されます。',
            key: Key('project-merge-requested'),
          ),
        ),
      if (defining)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '呼び名とキーワード（または望む結果・領域）の変更を依頼済みです。Mac miniで処理されると反映されます。',
            key: Key('project-definition-requested'),
          ),
        ),
      // メモがどのプロジェクトのものかを見分ける手がかり。
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SelectableText(
          '呼び名: ${project.aliases.isEmpty ? 'なし' : project.aliases.join('・')} · キーワード: ${project.keywords.isEmpty ? 'なし' : project.keywords.join('・')}（メモを見分ける手がかり）',
          key: const Key('project-terms'),
          style: theme.textTheme.bodySmall,
        ),
      ),
      for (final warning in problems)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(warning),
        ),
      if (changes != null && !changes.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            [
              '前回見てから: 新しい項目${changes.added.length}件・外れた項目${changes.removed.length}件',
              for (final item in changes.removed.take(5))
                '外れた（${sectionLabels[item.section] ?? item.section}）: ${item.text.isEmpty ? '（本文は記録していません）' : item.text}',
              if (changes.removed.length > 5)
                'ほか${changes.removed.length - 5}件',
            ].join('\n'),
            key: const Key('project-changes'),
          ),
        ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            key: const Key('project-pin'),
            style: actionStyle,
            onPressed: () => togglePin(project),
            icon: Icon(
              repo.isPinned(project.id)
                  ? Icons.push_pin
                  : Icons.push_pin_outlined,
              size: 18,
            ),
            label: Text(repo.isPinned(project.id) ? 'ピン留めを外す' : 'ピン留め'),
          ),
          OutlinedButton.icon(
            key: const Key('project-history'),
            style: actionStyle,
            onPressed: project.history == null
                ? null
                : () => showHistory(project),
            icon: const Icon(Icons.timeline, size: 18),
            label: Text(project.history == null ? '経緯（未生成）' : '経緯'),
          ),
          // 資料のページは、資料のあるプロジェクトにだけ本体が作る。資料の一覧を書く本体なら、空の資料棚も開ける。
          // 統合済みのプロジェクトの資料は統合先にまとまるので、統合先の資料を開く。
          if ((mergeTarget ?? project).shelf != null ||
              repo.referenceIndex != null)
            OutlinedButton.icon(
              key: const Key('project-shelf'),
              style: actionStyle,
              onPressed: () => showShelf(mergeTarget ?? project),
              icon: const Icon(Icons.bookmarks_outlined, size: 18),
              label: Text(mergeTarget == null ? '資料' : '資料（統合先）'),
            ),
          OutlinedButton.icon(
            key: const Key('project-guided'),
            style: actionStyle,
            onPressed: c.loading || c.captureWarning != null
                ? null
                : () => showGuided(context, c, project: project.id),
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('質問に答える'),
          ),
          OutlinedButton.icon(
            key: const Key('copy-context'),
            style: actionStyle,
            onPressed: c.loading
                ? null
                : () async {
                    try {
                      final text = await c.context(project.id);
                      await Clipboard.setData(ClipboardData(text: text));
                      if (mounted) {
                        notice(context, '別のAIに渡す文章をコピーしました');
                      }
                    } catch (e) {
                      if (mounted) {
                        notice(context, HubController.message(e));
                      }
                    }
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('AIに渡す文章をコピー'),
          ),
          // ふだん使わない変更は「…」にまとめる。
          PopupMenuButton<VoidCallback>(
            key: const Key('project-more'),
            tooltip: 'ほかの操作',
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('project-status'),
                enabled: editable,
                value: () => changeStatus(project),
                child: const Text('状態を変える（休止・完了など）'),
              ),
              PopupMenuItem(
                key: const Key('project-definition'),
                enabled: editable,
                value: () => changeDefinition(project),
                child: Text(
                  repo.intakeFeatures.projectOutcome == null
                      ? '呼び名とキーワードを変える'
                      : '呼び名・キーワード・望む結果を変える',
                ),
              ),
              // 手で書いた統合先が見つからない・循環している定義は、直すまで統合を依頼できない（本体が断る）。
              if (!project.merged && project.mergedInto == null)
                PopupMenuItem(
                  key: const Key('project-merge'),
                  // ほかのプロジェクトの統合先になっているプロジェクトは、統合元にできない（本体と同じ）。
                  enabled: mergeable && sources.isEmpty,
                  value: () => mergeProject(project),
                  child: const Text('ほかのプロジェクトへ統合'),
                ),
            ],
          ),
        ],
      ),
      for (final section in [
        ('current', '現在地'),
        ('next', '次の一手'),
        ('open', '未解決'),
        ('proposals', '提案'),
      ]) ...[
        sectionHeading(
          section.$2,
          note: section.$1 == 'current' && summaryNote.isNotEmpty
              ? summaryNote.first
              : null,
          trailing: [
            // 本人が決めた行動を、AIの整理を待たずに次の一手へ載せる。統合済みのプロジェクトには追加しない。
            if (section.$1 == 'next' &&
                !project.merged &&
                c.repository?.intakeFeatures.actions == true)
              TextButton.icon(
                key: const Key('project-add-action'),
                onPressed: busy || c.composing
                    ? null
                    : () => addAction(project: project),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('次の一手を追加'),
              ),
          ],
        ),
        entryCard([
          if (section.$1 == 'next')
            for (final action in project.pendingActions)
              pendingActionRow(action),
          if (project.sections[section.$1]!.isEmpty &&
              (section.$1 != 'next' || project.pendingActions.isEmpty))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'まだAIが読み取っていません。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final entry in project.sections[section.$1]!)
            nowEntry(project, section.$1, entry, added),
        ]),
      ],
      if (project.resolvedItems.isNotEmpty) ...[
        sectionHeading('解決済み・完了（本人報告）'),
        Card(
          key: const Key('resolved-items'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in project.resolvedItems)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${item.section == 'next' ? '完了' : '解決'}: ${item.display}（${timeLabel(item.resolvedAt)}）',
                        ),
                      ),
                      repo.itemRequestIdFor(item.key) != null
                          ? const Text(
                              '報告済み（反映待ち）',
                              style: TextStyle(fontSize: 12),
                            )
                          : TextButton(
                              key: Key('reopen-${item.key.substring(0, 12)}'),
                              onPressed: busy
                                  ? null
                                  : () => reportItem(project, item, 'reopen'),
                              child: const Text('未解決に戻す'),
                            ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
      if (project.excludedItems.isNotEmpty) ...[
        sectionHeading(
          '誤りとして外した項目（本人報告）',
          note: '完了・解決には数えません。理由と一言は、次からのAI読み取りでAIへ渡します。',
        ),
        Card(
          key: const Key('excluded-items'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in project.excludedItems)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${item.section == 'next' ? '次の一手' : '未解決'}: ${item.display}\n理由: ${exclusionReasonLabels[item.exclusionReason]}${item.exclusionNote == null ? '' : '（${item.exclusionNote}）'}（${timeLabel(item.resolvedAt)}）',
                        ),
                      ),
                      repo.itemRequestIdFor(item.key) != null
                          ? const Text(
                              '報告済み（反映待ち）',
                              style: TextStyle(fontSize: 12),
                            )
                          : TextButton(
                              key: Key('reopen-${item.key.substring(0, 12)}'),
                              onPressed: busy
                                  ? null
                                  : () => reportItem(project, item, 'reopen'),
                              child: const Text('未解決に戻す'),
                            ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
      if (project.drafts.isNotEmpty) ...[
        sectionHeading(
          '作業記録の下書き',
          note: '設定したリポジトリのコミット件名から作った下書きです。本文を確かめて直し、メモとして保存するか、見送ってください。',
        ),
        for (final draft in project.drafts)
          Card(
            key: Key('draft-${draft.id}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${draft.repo} · コミット${draft.commitCount}件 · 作成 ${timeLabel(draft.createdAt)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(draft.text),
                  const SizedBox(height: 8),
                  if (repo.draftRequestIdFor(draft.id) != null)
                    Text('操作済み（反映待ち）', style: noteStyle(context))
                  else
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonal(
                          key: Key('draft-use-${draft.id}'),
                          onPressed: busy || c.composing
                              ? null
                              : () => showCapture(context, c, draft: draft),
                          child: const Text('メモとして保存'),
                        ),
                        TextButton(
                          key: Key('draft-dismiss-${draft.id}'),
                          onPressed: busy ? null : () => dismissDraft(draft),
                          child: const Text('見送る'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
      if (project.notes.trim().isNotEmpty) ...[
        sectionHeading('手動メモ'),
        SafeMarkdown(
          text: project.notes,
          sourcePath: repo.records[project.nowRecordId]?.path ?? '',
          controller: c,
          onRecord: open,
        ),
        const SizedBox(height: 24),
      ],
      if (project.nowRecordId != null)
        TextButton(
          onPressed: () => open(project.nowRecordId!),
          child: const Text('現状の本文と出典・日時を開く'),
        ),
    ];
  }
}

/// 記録を文脈かごに入れる・外すボタン。かごの変化に合わせて表示を変える。
class BasketToggle extends StatelessWidget {
  const BasketToggle({
    super.key,
    required this.controller,
    required this.record,
    this.labeled = false,
  });
  final HubController controller;
  final HubRecord record;

  /// 記録の詳細では文字付きのボタンにする。
  final bool labeled;

  Future<void> _toggle(BuildContext context) async {
    try {
      final added = await controller.toggleBasket(record.id);
      if (context.mounted) {
        notice(
          context,
          added
              ? '文脈かごに入れました（${controller.basket.ids.length}件）'
              : '文脈かごから外しました',
        );
      }
    } catch (e) {
      if (context.mounted) notice(context, HubController.message(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final inside = controller.inBasket(record.id);
      if (labeled) {
        return TextButton.icon(
          key: const Key('record-basket'),
          onPressed: () => _toggle(context),
          icon: Icon(
            inside ? Icons.check_circle : Icons.add_circle_outline,
            size: 18,
          ),
          label: Text(inside ? 'かごから外す' : '文脈かごに入れる'),
        );
      }
      return IconButton(
        key: Key('basket-toggle-${record.id}'),
        tooltip: inside ? '文脈かごから外す' : '文脈かごに入れる',
        onPressed: () => _toggle(context),
        // 一覧の行では主役の題名より目立たないよう、小さめ・控えめの色にする（入っているときだけ強調色）。
        icon: Icon(
          inside ? Icons.check_circle : Icons.add_circle_outline,
          size: 20,
          color: inside
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    },
  );
}

class RecordView extends StatelessWidget {
  const RecordView({super.key, required this.controller, required this.record});
  final HubController controller;
  final HubRecord record;
  void open(BuildContext context, String id) {
    final r = controller.repository?.records[id];
    if (r != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RecordView(controller: controller, record: r),
        ),
      );
    }
  }

  /// 原文の訂正。最新の訂正に対して書き、反映待ちの間は重ねて訂正しない。
  Widget correctionPanel(BuildContext context) {
    final repo = controller.repository;
    final chain = repo?.correctionChainOf(record.id);
    if (repo == null || chain == null) return const SizedBox.shrink();
    final latest = chain.last,
        requestId = repo.correctionRequestIdFor(record.id);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (latest.id != record.id)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NoticeBox(
                'この記録には新しい訂正があります（${latest.sourceId}）。訂正は最新の本文に対して書きます。',
              ),
            ),
          if (requestId != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NoticeBox(
                chain.first.kind == 'action'
                    ? '行動の文面の訂正を送りました。Mac miniに届くまで、現状の次の一手は直す前の文面のままです（$requestId）。'
                    : '訂正を送りました。Mac miniに届いてAIが読み取るまで、要約は訂正前の内容のままです（$requestId）。',
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('write-correction'),
                style: compactOutlinedStyle(context),
                icon: const Icon(Icons.edit_note, size: 18),
                label: Text(
                  chain.first.kind == 'action' ? '行動の文面を直す' : '訂正を書く',
                ),
                onPressed:
                    requestId != null ||
                        controller.saving ||
                        controller.composing
                    ? null
                    : () => showCorrection(
                        context,
                        controller,
                        record.id,
                        latest,
                      ),
              ),
              // 続きを書く操作も、訂正と同じ行に並べる（前のメモ・続きのリンクは下の続きの欄に出す）。
              if (repo.intakeFeatures.continues &&
                  (chain.first.kind == 'memo' ||
                      chain.first.kind == 'work-summary'))
                OutlinedButton.icon(
                  key: const Key('write-continuation'),
                  style: compactOutlinedStyle(context),
                  icon: const Icon(Icons.subdirectory_arrow_right, size: 18),
                  label: const Text('続きを書く'),
                  onPressed: controller.saving || controller.composing
                      ? null
                      : () => showCapture(
                          context,
                          controller,
                          continues: chain.first,
                        ),
                ),
              if (latest.id != record.id)
                TextButton(
                  onPressed: () => open(context, latest.id),
                  child: const Text('最新の訂正を開く'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// メモに添えたファイル（PDF・画像など）。訂正を見ているときも元のメモのファイルを示す。
  Widget attachmentPanel(BuildContext context) {
    final root =
        controller.repository?.correctionChainOf(record.id)?.first ?? record;
    final file = root.attachment;
    if (file == null) return const SizedBox.shrink();
    return Padding(
      key: const Key('record-attachment'),
      padding: const EdgeInsets.only(top: 16),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          const Icon(Icons.attach_file, size: 18),
          Text('添えたファイル: ${file.label}'),
          if (controller.access.attachmentsSupported)
            OutlinedButton(
              key: const Key('record-attachment-open'),
              style: compactOutlinedStyle(context),
              onPressed: () => openHubFile(context, controller, file),
              child: const Text('開く'),
            ),
        ],
      ),
    );
  }

  /// 整理（AIの読み取り）に失敗したメモの、失敗の理由と「整理をやり直す」。
  /// 本人が頼んだ1件だけを、次の整理でもう一度試す（本体が1回だけ試し、原文は変えない）。
  /// 資料棚に載っているか、と資料に加える・名前を変える・外す・戻す操作。資料の一覧を書く本体にだけ出す。
  Widget referencePanel(BuildContext context) {
    final repo = controller.repository;
    if (repo == null || repo.referenceIndex == null) {
      return const SizedBox.shrink();
    }
    // 訂正を見ているときも、資料の記録は元の入力に付ける。
    final root = repo.correctionChainOf(record.id)?.first ?? record;
    if (root.kind != 'memo' && root.kind != 'work-summary') {
      return const SizedBox.shrink();
    }
    final inputId = root.sourceId;
    final entry = repo.referenceEntryOf(inputId),
        removed = entry == null ? repo.removedReferenceOf(inputId) : null,
        pending = repo.referenceRequestIdFor(inputId) != null,
        editable = repo.intakeFeatures.references && !controller.saving;
    final status = entry != null
        ? '資料棚にあります: ${entry.label}${entry.addedByPerson ? '' : '（AIが参考資料と読み取り）'}'
        : removed != null
        ? '資料棚から外しています。'
        : '資料棚にはありません。';
    return Padding(
      key: const Key('reference-panel'),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status,
            key: const Key('reference-status'),
            style: const TextStyle(fontSize: 12),
          ),
          if (pending)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '資料棚への依頼が反映待ちです。',
                key: Key('reference-requested'),
                style: TextStyle(fontSize: 12),
              ),
            )
          else if (repo.intakeFeatures.references)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (entry == null && removed == null)
                    OutlinedButton.icon(
                      key: const Key('reference-add'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('資料に加える'),
                      onPressed: editable
                          ? () => renameReference(
                              context,
                              controller,
                              inputId,
                              adding: true,
                            )
                          : null,
                    ),
                  if (removed != null)
                    OutlinedButton.icon(
                      key: const Key('reference-restore'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('資料棚に戻す'),
                      onPressed: editable
                          ? () => sendReferenceMark(
                              context,
                              controller,
                              inputId,
                              'add',
                              title: removed.title,
                              done: '資料棚に戻す依頼をしました。',
                            )
                          : null,
                    ),
                  if (entry != null) ...[
                    OutlinedButton.icon(
                      key: const Key('reference-rename'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('資料の名前を変える'),
                      onPressed: editable
                          ? () => renameReference(
                              context,
                              controller,
                              inputId,
                              current: entry.title,
                              aiSummary: entry.aiSummary,
                            )
                          : null,
                    ),
                    OutlinedButton.icon(
                      key: const Key('reference-remove'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
                      label: const Text('資料棚から外す'),
                      onPressed: editable
                          ? () => removeReference(
                              context,
                              controller,
                              inputId,
                              entry.label,
                            )
                          : null,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget retryPanel(BuildContext context) {
    final repo = controller.repository;
    if (repo == null) return const SizedBox.shrink();
    final attempts = repo.failedAttemptsFor(record.sourceId);
    if (attempts == null) return const SizedBox.shrink();
    final retryable = repo.organizeRetryable(record.sourceId);
    final requested = repo.organizeRetryRequestIdFor(record.sourceId) != null,
        queued = repo.organizeRetryQueued(record.sourceId),
        supported = repo.intakeFeatures.organizeRetry,
        error = repo.organizeErrorFor(record.sourceId);
    return Padding(
      key: const Key('organize-retry-panel'),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AIの読み取り（整理）に失敗しています（$attempts回試しました）。原文は残っています。',
            style: const TextStyle(fontSize: 12),
          ),
          if (error != null && error.isNotEmpty)
            Text(
              '理由: ${clip(error.replaceAll(RegExp(r'\s+'), ' '), 160)}',
              key: const Key('organize-error'),
              style: const TextStyle(fontSize: 12),
            ),
          if (requested || queued)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                queued
                    ? 'やり直しを頼みました。次の整理でもう一度試します。'
                    : 'やり直しを依頼済みです（反映待ち）。',
                key: const Key('organize-retry-requested'),
                style: const TextStyle(fontSize: 12),
              ),
            )
          else if (supported && !retryable)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '訂正が届いている（または依頼中の）メモは、訂正した後のメモが整理されます。',
                key: Key('organize-retry-superseded'),
                style: TextStyle(fontSize: 12),
              ),
            )
          else if (supported)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                key: const Key('organize-retry'),
                icon: const Icon(Icons.refresh),
                label: const Text('整理をやり直す'),
                onPressed: controller.saving
                    ? null
                    : () async {
                        try {
                          final result = await controller.requestOrganizeRetry(
                            record.sourceId,
                          );
                          if (context.mounted) {
                            notice(
                              context,
                              result.saved
                                  ? 'やり直しを依頼しました。次の整理でもう一度試します。'
                                  : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            notice(context, HubController.message(e));
                          }
                        }
                      },
              ),
            ),
        ],
      ),
    );
  }

  /// 続き。前のメモとこのメモの続きをたどり、このメモの続きを書ける（訂正とは別に、前のメモを残したまま追記する）。
  Widget continuationPanel(BuildContext context) {
    final repo = controller.repository;
    final chain = repo?.correctionChainOf(record.id);
    if (repo == null || chain == null) return const SizedBox.shrink();
    final root = chain.first;
    if (root.kind != 'memo' && root.kind != 'work-summary') {
      return const SizedBox.shrink();
    }
    final previous = repo.previousOf(root),
        missing = root.metadata['continues_input_id'],
        later = repo.continuationsOf(root.sourceId);
    // 続きを書く操作は訂正の欄に並べるので、ここには前のメモと続きがあるときだけ出す。
    if (previous == null && missing == null && later.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget link(HubRecord r) => TextButton(
      key: Key('continuation-${r.sourceId}'),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
      ),
      onPressed: () => open(context, r.id),
      child: Text(
        '${timeLabel(r.at)} ${clip(r.title.replaceAll(RegExp(r'\s+'), ' '), 60)}',
        textAlign: TextAlign.left,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (previous != null) ...[
            const Text('前のメモ', style: TextStyle(fontSize: 12)),
            link(previous),
          ] else if (missing is String)
            Text(
              '前のメモ（$missing）はまだ届いていません。',
              style: const TextStyle(fontSize: 12),
            ),
          if (later.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('続き（${later.length}件）', style: const TextStyle(fontSize: 12)),
            for (final r in later) link(r),
          ],
        ],
      ),
    );
  }

  /// 似ているアイデアと束ねたアイデア。束ねる・別の話にする判断を依頼できる。
  /// アイデアを「いつかやる」に置く操作。置いてあれば、そう示す（見直しは「いつかやる」の画面で行う）。
  Widget ideaSomedayPanel(BuildContext context) {
    final repo = controller.repository;
    final id = record.sourceId;
    if (repo == null || !repo.intakeFeatures.someday) {
      return const SizedBox.shrink();
    }
    final Widget child;
    if (repo.somedayReviewRequestIdFor('idea', id) != null) {
      child = Text('「いつかやる」を依頼済み（反映待ち）', style: noteStyle(context));
    } else if (repo.somedayIdea(id)) {
      child = const Text(
        '「いつかやる」に置いています。見直しは「いつかやる」の画面で行います。',
        key: Key('idea-someday-listed'),
        style: TextStyle(fontSize: 12),
      );
    } else if (repo.somedayGeneratedAt == null) {
      // 本体の一覧がまだないときは、置いてあるか分からないので操作を出さない。
      return const SizedBox.shrink();
    } else {
      child = OutlinedButton.icon(
        key: const Key('idea-someday'),
        onPressed: controller.saving || controller.loading
            ? null
            : () => sendIdeaSomeday(context, controller, id, record.title),
        icon: const Icon(Icons.inventory_2_outlined, size: 18),
        label: const Text('「いつかやる」に置く'),
      );
    }
    return Padding(padding: const EdgeInsets.only(top: 16), child: child);
  }

  Widget ideaPanel(BuildContext context) {
    final repo = controller.repository;
    if (repo == null) return const SizedBox.shrink();
    final me = record.sourceId,
        group = repo.ideaGroupOf(me),
        similar = repo.similarIdeas(me);
    if (group == null && similar.isEmpty) return const SizedBox.shrink();
    final busy = controller.saving || controller.loading;
    Widget pairActions(String other, {required bool candidate}) {
      final requestId = repo.ideaLinkRequestIdFor(me, other);
      if (requestId != null) {
        return Text(
          '依頼済み（$requestId）。Mac miniで処理されると反映されます。',
          style: const TextStyle(fontSize: 12),
        );
      }
      return Wrap(
        spacing: 8,
        children: [
          if (candidate)
            FilledButton.tonal(
              key: Key('idea-link-$other'),
              onPressed: busy
                  ? null
                  : () => sendIdeaLink(context, controller, me, other, 'link'),
              child: const Text('同じ話として束ねる'),
            ),
          TextButton(
            key: Key('idea-separate-$other'),
            onPressed: busy
                ? null
                : () =>
                      sendIdeaLink(context, controller, me, other, 'separate'),
            child: Text(candidate ? '別の話' : '束から外す'),
          ),
        ],
      );
    }

    Widget ideaCard(String id, {String? note, Widget? actions}) {
      final r = repo.ideaRecord(id)!;
      return Card(
        key: Key('idea-related-$id'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.title),
                subtitle: note == null ? null : Text(note),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(context, r.id),
              ),
              ?actions,
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (group != null) ...[
            sectionTitle(
              context,
              '束ねたアイデア（${group.ideas.length}件）',
              top: 0,
              note: '本人が同じ話と判断したアイデアです。検索では1件にまとめて表示します（本体の検索）。',
            ),
            for (final id in group.ideas.where((id) => id != me))
              ideaCard(
                id,
                note: [
                  if (id == group.representative) '代表（元のメモが最も新しい）',
                  if (!group.linksDirectly(me, id)) '別のアイデアを通して束ねています',
                ].join(' · ').nullIfEmpty,
                actions: group.linksDirectly(me, id)
                    ? pairActions(id, candidate: false)
                    : null,
              ),
            const SizedBox(height: 16),
          ],
          if (similar.isNotEmpty) ...[
            sectionTitle(
              context,
              '似ているアイデア（${similar.length}件）',
              top: 0,
              note: '文字の重なりから見つけた候補です（AIは使っていません）。同じ話なら束ねると、どこまで考えたかを1か所で追えます。違う話なら「別の話」を選ぶと、次から候補に出しません。',
            ),
            for (final c in similar)
              ideaCard(
                c.other(me),
                note: '似ている度合い ${c.score.toStringAsFixed(2)}',
                actions: pairActions(c.other(me), candidate: true),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('記録の詳細'),
      actions: [
        if (HubRepository.bundleKinds.contains(record.kind))
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: BasketToggle(
              controller: controller,
              record: record,
              labeled: true,
            ),
          ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: pagePadding(context).copyWith(bottom: 48),
          children: [
            Text(
              record.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '${originLabel(record.origin)} · ${stateLabel(record.status)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (happenedOf(record) case final h?)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${h.date}のこと（${displayTime(h.recordedAt)}に記録）',
                  key: const Key('record-happened'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 20),
            for (final warning in record.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NoticeBox(warning),
              ),
            // 本文は1枚の面に載せ、下の操作や出典と分ける。
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: SafeMarkdown(
                  text: record.body,
                  sourcePath: record.path,
                  controller: controller,
                  onRecord: (id) => open(context, id),
                ),
              ),
            ),
            if (record.kind == 'idea')
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => ideaSomedayPanel(context),
              ),
            if (record.kind == 'idea')
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => ideaPanel(context),
              ),
            if (const [
              'memo',
              'work-summary',
              'action',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => correctionPanel(context),
              ),
            if (const [
              'memo',
              'work-summary',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => continuationPanel(context),
              ),
            if (const [
              'memo',
              'work-summary',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => retryPanel(context),
              ),
            if (const ['memo', 'correction'].contains(record.kind))
              attachmentPanel(context),
            if (const [
              'memo',
              'work-summary',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => referencePanel(context),
              ),
            sectionTitle(context, '出典・日時', top: 32),
            SelectableText(
              '${record.sourceId}\n${record.path}\n入力元: ${record.source}\n${recordTimeLines(record)}\nMac miniが受け取った時刻: ${timeLabel(record.receivedAt)}\n生成: ${timeLabel(record.generatedAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                height: 1.9,
              ),
            ),
            for (final id in record.references)
              TextButton(
                onPressed: () => open(context, id),
                child: Text(controller.repository?.records[id]?.title ?? '出典'),
              ),
          ],
        ),
      ),
    ),
  );
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// 似ているアイデアの組を束ねる・別の話にする依頼を、確認してから保存する。
/// アイデアを「いつかやる」に置く依頼。置くかは本人が決め、AIは置かない。
Future<void> sendIdeaSomeday(
  BuildContext context,
  HubController c,
  String ideaId,
  String title,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('「いつかやる」に置く'),
      content: Text(
        '「$title」を、今は取り組まないアイデアとして「いつかやる」に置くよう依頼します。「いつかやる」の画面で、ほかの項目と一緒に見直せます。アイデアと元のメモは変わりません。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('idea-someday-confirm'),
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('置く'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final result = await c.requestSomedayReview('idea', ideaId, 'add');
    if (context.mounted) {
      notice(
        context,
        result.saved
            ? '「いつかやる」に置く依頼を保存しました。Mac miniで処理されると反映されます。'
            : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
      );
    }
  } catch (e) {
    if (context.mounted) notice(context, HubController.message(e));
  }
}

Future<void> sendIdeaLink(
  BuildContext context,
  HubController c,
  String me,
  String other,
  String action,
) async {
  final repo = c.repository;
  // 確認の画面に出す時点の内容を覚えておき、確認の間に変わっていれば依頼しない。
  final seenMe = c.ideaSeenHash(me), seenOther = c.ideaSeenHash(other);
  if (seenMe == null || seenOther == null) {
    notice(context, 'アイデアが見つかりません。再読込してください。');
    return;
  }
  final title = repo?.ideaRecord(other)?.title ?? other;
  final linked = repo?.ideaGroupOf(me)?.linksDirectly(me, other) ?? false;
  final (heading, body, verb) = action == 'link'
      ? ('同じ話として束ねる', '「$title」と同じ話として束ねるよう依頼します。アイデアと元のメモは変わりません。', '束ねる')
      : linked
      ? ('束から外す', '「$title」との束ねを外すよう依頼します。次からは似ているアイデアの候補にも出しません。', '外す')
      : ('別の話にする', '「$title」とは別の話として、次から候補に出さないよう依頼します。', '別の話にする');
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(heading),
      content: Text('$body依頼は保存され、Mac miniで処理されると反映されます。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('idea-link-confirm'),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(verb),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final result = await c.requestIdeaLink(
      me,
      other,
      action,
      seenA: seenMe,
      seenB: seenOther,
    );
    if (context.mounted) {
      notice(
        context,
        result.saved
            ? '依頼を保存しました。Mac miniで処理されると反映されます。'
            : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
      );
    }
  } catch (e) {
    if (context.mounted) notice(context, HubController.message(e));
  }
}

/// ホームに出す「前回見てからの変化」。記録がない・変化がなければnull。
const sectionLabels = {'current': '現在地', 'next': '次の一手', 'open': '未解決'};

String? changeLabel(ProjectChanges? changes) {
  if (changes == null || changes.isEmpty) return null;
  return [
    if (changes.added.isNotEmpty) '新着${changes.added.length}',
    if (changes.removed.isNotEmpty) '外れた${changes.removed.length}',
  ].join(' · ');
}

String timeLabel(DateTime? value) => value == null ? '未取得' : displayTime(value);

/// 一覧に出す記録の日時。出来事の日付があれば「YYYY-MM-DDのこと（…に記録）」とし、正午に置いた時刻は出さない。
String recordWhen(HubRecord record) {
  final h = happenedOf(record);
  return h == null
      ? timeLabel(record.at ?? record.generatedAt)
      : '${h.date}のこと（${displayTime(h.recordedAt)}に記録）';
}

/// 一覧の1行に収める短い日時。今日・昨日はそう書き、今年の日付は年と時間帯（JST）を省く。
/// 出来事の日付があれば「M月D日のこと」とする（正午に置いた時刻は出さない）。
String compactWhen(HubRecord record, [String? today]) {
  final h = happenedOf(record);
  final now = today ?? hubToday();
  String day(String date) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(date);
    if (m == null) return date;
    final md = '${int.parse(m[2]!)}月${int.parse(m[3]!)}日';
    return m[1] != now.substring(0, 4) ? '${m[1]}年$md' : md;
  }

  String stamp(String label) {
    final m = RegExp(r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})').firstMatch(label);
    if (m == null) return label;
    final date = m[1]!, time = m[2]!;
    if (date == now) return '今日 $time';
    if (date == addScheduleDays(now, -1)) return '昨日 $time';
    return '${day(date)} $time';
  }

  // 出来事の日付は今日より前しか指定できない。一覧は書いた順に並ぶので、書いた日時も添える。
  if (h != null) {
    final when = h.date == addScheduleDays(now, -1) ? '昨日' : day(h.date);
    return '$whenのこと · ${stamp(displayTime(h.recordedAt))}に記録';
  }
  return stamp(timeLabel(record.at ?? record.generatedAt));
}

/// 記録の詳細の日時。出来事の日付があれば、その日と実際に書いた日時を示す（発生日時はその日の正午に置いた値なので出さない）。
String recordTimeLines(HubRecord record) {
  final h = happenedOf(record);
  return h == null
      ? '発生: ${timeLabel(record.at)}'
      : '出来事の日付: ${h.date}（本人が指定）\n記録: ${displayTime(h.recordedAt)}';
}

String originLabel(String origin) => switch (origin) {
  'user-note' => '本人のメモ',
  'ai-self-report' => 'AIの作業自己報告・未検証',
  'ai-generated' => 'AI生成・未検証',
  _ => origin,
};
String stateLabel(String state) => switch (state) {
  'waiting' => 'Mac miniの受け取り待ち',
  'accepted' => 'Mac miniが受け取り',
  'organized' => '読み取り済み',
  'failed' => '読み取り失敗',
  'rejected' => '受け付けられず',
  'conflict' => '競合',
  'uncertain' => '保存確認待ち',
  'unknown' => '整合性未確認',
  'action' => '本人が追加した行動（AIは書き換えません）',
  _ => state,
};

/// 「保存と反映」の段階。保存済み → Mac miniが受け取り済み → 反映済み／失敗。
String intakeStateLabel(String state) => switch (state) {
  'waiting' => '保存済み · Mac miniの受け取り待ち',
  'accepted' => 'Mac miniが受け取り済み',
  'organized' => '反映済み',
  'failed' => '失敗 · AIの読み取りがうまくいきませんでした',
  'rejected' => '失敗 · 受け付けられませんでした',
  'conflict' => '失敗 · 同期が競合しています',
  'uncertain' => '保存確認待ち',
  'unknown' => '状態を確認できません',
  _ => stateLabel(state),
};

/// 失敗したときに次にすること。
String? intakeNextStep(String state) => switch (state) {
  'rejected' => '次に: 理由を読み、必要なら元の画面から操作し直してください。',
  'conflict' ||
  'unknown' => '次に: 同期が終わるのを待って再読込してください。続くときはMac miniの同期を確認してください。',
  'failed' => '次に: Mac miniの本体が動いているか確認してください。元のメモは残っています。',
  _ => null,
};

Future<void> showCapture(
  BuildContext context,
  HubController c, {
  GitDraft? draft,
  InsightAnswerTarget? answer,
  HubRecord? continues,
}) async {
  if (c.composing) {
    return;
  }
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CaptureDialog(
        controller: c,
        draft: draft,
        answer: answer,
        continues: continues,
      ),
    );
  } finally {
    c.composing = false;
  }
}

Future<void> showCorrection(
  BuildContext context,
  HubController c,
  String recordId,
  HubRecord latest,
) async {
  if (c.composing) return;
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          CorrectionDialog(controller: c, recordId: recordId, latest: latest),
    );
  } finally {
    c.composing = false;
  }
}

/// 元のメモを残したまま、訂正後の全文を新しい入力として送るフォーム。
class CorrectionDialog extends StatefulWidget {
  const CorrectionDialog({
    super.key,
    required this.controller,
    required this.recordId,
    required this.latest,
  });
  final HubController controller;
  final String recordId;

  /// 訂正チェーンの最新の記録。本文を下書きにし、この入力IDを訂正対象にする。
  final HubRecord latest;
  @override
  State<CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<CorrectionDialog> {
  late final text = TextEditingController(text: widget.latest.body.trimRight());
  final operation = const Uuid().v4();

  /// 本人が追加した行動の文面を直す。行動と同じく1行・200文字以内にする。
  late final bool action =
      widget.controller.repository
          ?.correctionChainOf(widget.recordId)
          ?.first
          .kind ==
      'action';
  String? error;
  CaptureResult? result;
  bool busy = false;

  /// 新しい訂正が届いて、この下書きの訂正対象が古くなった。保存は出さず、閉じて開き直してもらう。
  bool targetChanged = false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (action && !validActionText(text.text)) {
      setState(
        () => error = '行動の文面は1行・$actionTextChars文字以内で、前後に空白を付けずに入力してください。',
      );
      return;
    }
    if (text.text.trim().isEmpty || text.text.length > 8000) {
      setState(() => error = '訂正文は1〜8000文字で入力してください。');
      return;
    }
    final checked = await checkSecretsBeforeSave(
      context,
      text.text,
      secrets: widget.controller.repository?.secretPolicy,
    );
    if (checked == null || !mounted) return;
    if (checked != text.text) {
      if (checked.length > 8000) {
        setState(() => error = '伏せ字にすると8000文字を超えます。訂正文を短くしてください。');
        return;
      }
      if (action && !validActionText(checked)) {
        setState(() => error = '伏せ字にすると$actionTextChars文字を超えます。文面を短くしてください。');
        return;
      }
      text.text = checked;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await widget.controller.requestCorrection(
        operation,
        widget.recordId,
        widget.latest.sourceId,
        text.text,
      );
      if (mounted) setState(() => result = r);
    } catch (e) {
      // 保存前に止まった場合は、本文を直してもう一度保存できる。
      if (mounted) {
        setState(() {
          error = HubController.message(e);
          targetChanged = e is CorrectionTargetChanged;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirm() async {
    setState(() => busy = true);
    try {
      final r = await widget.controller.confirm(operation);
      if (mounted) setState(() => result = r);
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = result != null;
    // ⌘Return（Ctrl+Enter）で「訂正を保存」と同じ操作をする。
    return CallbackShortcuts(
      bindings: {
        saveFormActivator: () {
          if (!busy && !locked && !targetChanged) submit();
        },
        // Escは、訂正文を書き換えていない（変換中でもない）ときだけ「フォームを閉じる」と同じ操作をする。
        // 書きかけの訂正を誤って捨てないため。
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!busy &&
              !text.value.composing.isValid &&
              text.text == widget.latest.body.trimRight()) {
            Navigator.pop(context);
          }
        },
      },
      // Mac以外では入力欄が自動で選ばれないため、開いた直後からキーが届くよう受け口を置く（ソフトキーボードは開かない）。
      child: Focus(
        autofocus: !usesCommandKey,
        skipTraversal: true,
        child: PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text(action ? '行動の文面を直す' : 'メモを訂正する'),
            content: SizedBox(
              width: 620,
              child: DialogScroll(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '訂正対象: ${widget.latest.sourceId}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      action
                          ? '直した後の文面を1行で書いてください。元の文面は原文に残ります。Mac miniで処理されると現状の次の一手が直した文面になります。付けた日付は直した後の行動に引き継がれます。'
                          : '訂正後の全文を書いてください。元のメモは残り、訂正として追加されます。Mac miniのAIが読み取るまで、要約や現状は訂正前の内容のままです。',
                      style: noteStyle(context),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('correction-text'),
                      controller: text,
                      // Macではキーボードで開いたまま書けるよう、本文へ移る。
                      autofocus: usesCommandKey,
                      readOnly: locked || busy,
                      minLines: action ? 1 : 5,
                      maxLines: action ? 1 : 12,
                      // 行動の文面は本体と同じ数え方（UTF-16の単位）で示し、保存の前に確かめる。
                      maxLength: action ? null : 8000,
                      decoration: InputDecoration(
                        alignLabelWithHint: true,
                        counterText: action
                            ? '${text.text.length} / $actionTextChars'
                            : null,
                      ),
                      onChanged: action ? (_) => setState(() {}) : null,
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: NoticeBox(error!, error: true),
                      ),
                    if (result != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: NoticeBox(
                          result!.saved
                              ? 'この端末に訂正を保存しました'
                              : '保存確認待ちです。再送せず同じ操作を確認してください。',
                        ),
                      ),
                    if (locked)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          '操作ID: $operation',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: Text(result?.saved == true ? '閉じる' : 'フォームを閉じる'),
              ),
              if (!locked && !targetChanged)
                FilledButton(
                  key: const Key('save-correction'),
                  onPressed: busy ? null : submit,
                  child: const Text('訂正を保存'),
                ),
              if (locked && result?.saved != true)
                FilledButton(
                  onPressed: busy ? null : confirm,
                  child: const Text('同じ操作を確認'),
                ),
              if (busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CaptureDialog extends StatefulWidget {
  const CaptureDialog({
    super.key,
    required this.controller,
    this.draft,
    this.answer,
    this.continues,
  });
  final HubController controller;

  /// 続きとして書く前のメモ（訂正を除いた元の入力の記録）。前のメモで指定したプロジェクトを初期値にする。
  final HubRecord? continues;

  /// 作業記録の下書きから入力を作る場合の下書き。本文とプロジェクトを初期値にする。
  final GitDraft? draft;

  /// 今週の気づきの問いに答える場合の対象。答えはふつうのメモとして保存し、どの問いへの答えかをmetaで添える。
  final InsightAnswerTarget? answer;
  @override
  State<CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<CaptureDialog> {
  final text = TextEditingController();
  String operation = const Uuid().v4();
  String kind = 'memo';
  String? project, error;

  /// 本人が選んだ出来事の日付（YYYY-MM-DD）。今日のことならnull。
  String? happenedOn;

  /// 資料として保存するか（AIの分類に関係なく資料棚に載せる）と、本人が付ける資料の名前。
  bool reference = false;
  final referenceTitle = TextEditingController();

  /// メモに添えるファイル（端末で選んだもの。名前は本体の規則で整えたもの）。ファイルを添えたメモは資料として保存する。
  PickedAttachment? attachment;

  /// 戻した書きかけで選んでいたファイルの名前（ファイルは戻せないため、選び直してもらう）。
  String? _lostAttachment;

  /// ファイルを添えられるか。下書きから作る入力と問いへの答えには出さず、端末と本体の両方が対応しているときだけ。
  bool get _canAttach =>
      _canReference &&
      widget.draft == null &&
      widget.controller.attachmentsAvailable;

  ({int maxBytes, int nameMaxBytes}) get _attachmentLimits =>
      widget.controller.repository?.intakeFeatures.attachmentLimits ??
      (maxBytes: 0, nameMaxBytes: fileNameMaxBytes);

  Future<void> _pickAttachment() async {
    try {
      final picked = await widget.controller.pickAttachment();
      if (picked == null || !mounted) return;
      final max = _attachmentLimits.maxBytes;
      final problem = picked.bytes < 1
          ? '空のファイルは添えられません。'
          : picked.bytes > max
          ? 'ファイルが大きすぎます（上限${fileLimitLabel(max)}を超えています）。小さくしてから選び直してください。'
          : (widget.controller.repository?.secretInReferenceTitle(
                  picked.name,
                ) ??
                false)
          ? fileNameSecretMessage
          : null;
      setState(() {
        error = problem;
        if (problem != null) return;
        attachment = picked;
        _lostAttachment = null;
        // ファイルを添えたメモは、資料として保存するメモにする。
        reference = true;
        kind = 'memo';
      });
      _schedulePersist();
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    }
  }

  Widget _attachmentChooser(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (attachment case final file?)
          InputChip(
            key: const Key('capture-attachment'),
            avatar: const Icon(Icons.attach_file, size: 18),
            label: Text(
              '${file.name}（${fileSizeLabel(file.bytes)}）',
              overflow: TextOverflow.ellipsis,
            ),
            deleteButtonTooltipMessage: 'ファイルを外す',
            onDeleted: locked
                ? null
                : () {
                    setState(() => attachment = null);
                    _schedulePersist();
                  },
          )
        else
          OutlinedButton.icon(
            key: const Key('capture-attach'),
            style: compactOutlinedStyle(context),
            icon: const Icon(Icons.attach_file, size: 18),
            label: const Text('ファイルを添える（PDF・画像など）'),
            onPressed: locked || busy ? null : _pickAttachment,
          ),
        if (attachment != null)
          fieldNote(
            context,
            'ファイルはMac miniのVault（05_files）に置き、資料棚から開けます。中身はAIへ渡さず、AIが読むのはメモの本文だけです。何のファイルかを本文に書いておくと探しやすくなります（空ならファイル名を本文にします）。',
            key: const Key('capture-attachment-note'),
          )
        else if (_lostAttachment case final name?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: NoticeBox(
              '書きかけで選んでいたファイル（$name）は戻せません。添える場合は選び直してください。',
              key: const Key('capture-attachment-lost'),
            ),
          ),
      ],
    ),
  );

  /// 資料として保存できるか。問いへの答えは資料にせず、対応前の本体にも出さない。
  bool get _canReference =>
      widget.answer == null &&
      (widget.controller.repository?.intakeFeatures.references ?? false);

  /// 資料の名前の上限（本体が示す値）。
  int get _referenceTitleMax =>
      widget.controller.repository?.intakeFeatures.referenceTitleMax ??
      referenceTitleChars;

  /// 送る資料の名前（前後の空白を除き、空ならnull）。
  String? get _referenceTitleValue {
    final v = referenceTitle.text.trim();
    return v.isEmpty ? null : v;
  }

  Widget _referenceChooser(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CheckboxListTile(
        key: const Key('capture-reference'),
        contentPadding: EdgeInsets.zero,
        visualDensity: formTileDensity,
        horizontalTitleGap: formTileGap,
        controlAffinity: ListTileControlAffinity.leading,
        value: reference,
        // ファイルを添えたメモは、必ず資料として保存する。
        onChanged: locked || attachment != null
            ? null
            : (v) {
                setState(() => reference = v ?? false);
                _schedulePersist();
              },
        title: Text('資料として保存', style: formTileTitle(context)),
        subtitle: Text(
          attachment != null
              ? 'ファイルを添えたメモは資料として保存します。'
              : 'AIの分類に関係なく、資料棚に載せます。アイデアや提案としては扱いません。',
        ),
      ),
      if (_canAttach) _attachmentChooser(context),
      if (reference) ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('capture-reference-title'),
          controller: referenceTitle,
          enabled: !locked,
          // 上限は本体と同じくUTF-16の長さで数える（絵文字は2と数える）。超えた分は保存の前に知らせる。
          buildCounter:
              (context, {required currentLength, required isFocused, maxLength}) =>
                  Text(
                    '${referenceTitle.text.trim().length}/$_referenceTitleMax',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
          decoration: const InputDecoration(
            labelText: '資料の名前（任意）',
            helperText: '空のままなら、AIが読み取った要約を資料の名前にします。後から変えられます。',
            helperMaxLines: 3,
          ),
        ),
      ],
    ],
  );

  /// 出来事の日付を選べるか。下書き・問いへの答えは今日の記録なので出さず、対応前の本体にも出さない。
  bool get _canBackdate =>
      widget.draft == null &&
      widget.answer == null &&
      (widget.controller.repository?.intakeFeatures.happenedOn ?? false);

  /// 本体の設定でさかのぼれる日数。
  int get _maxBackdateDays =>
      widget.controller.repository?.intakeFeatures.maxBackdateDays ??
      defaultMaxBackdateDays;

  Future<void> _pickHappenedOn() async {
    // 暦日で数える（端末の夏時間をまたいでも1日ずれないよう、時刻の引き算にしない）。
    final today = hubToday(),
        last = DateTime.parse(addScheduleDays(today, -1)),
        first = DateTime.parse(addScheduleDays(today, -_maxBackdateDays));
    final current = happenedOn != null ? DateTime.parse(happenedOn!) : last;
    final picked = await showDatePicker(
      context: context,
      initialDate: current.isBefore(first) || current.isAfter(last)
          ? last
          : current,
      firstDate: first,
      lastDate: last,
      helpText: 'いつのことか',
    );
    if (picked == null || !mounted) return;
    setState(() => happenedOn = scheduleDate(picked));
    _schedulePersist();
  }

  Widget _happenedChooser(BuildContext context) {
    final today = hubToday(),
        yesterday = addScheduleDays(today, -1),
        dayBefore = addScheduleDays(today, -2);
    final custom =
        happenedOn != null &&
        happenedOn != yesterday &&
        happenedOn != dayBefore;
    void choose(String? value) {
      setState(() => happenedOn = value);
      _schedulePersist();
    }

    return Column(
      key: const Key('memo-happened'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        fieldLabel(context, 'いつのこと'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, value) in [
              ('今日', null),
              ('昨日', yesterday),
              if (_maxBackdateDays >= 2) ('おととい', dayBefore),
            ])
              ChoiceChip(
                key: Key('memo-happened-${value ?? 'today'}'),
                label: Text(label),
                selected: happenedOn == value,
                onSelected: locked ? null : (_) => choose(value),
              ),
            ChoiceChip(
              key: const Key('memo-happened-pick'),
              label: Text(custom ? happenedOn! : '日付を選ぶ…'),
              selected: custom,
              onSelected: locked ? null : (_) => _pickHappenedOn(),
            ),
          ],
        ),
        if (happenedOn != null)
          fieldNote(
            context,
            'この日の出来事として記録します。経緯や現在地はこの日の順に並び、本文の「明日」「来週」もこの日を基準に読まれます。',
            top: 8,
          ),
      ],
    );
  }

  CaptureResult? result;
  bool busy = false, locked = false;

  // ---- 書きかけの保持（端末内のみ） ----
  String? _draftKey;
  bool _ready = false, _keepDrafts = true, _finished = false;

  /// 保存結果が不明な書きかけで、「同じ操作を確認」を一度でも行ったか。行うまでは書きかけを閉じられない。
  bool _confirmedOnce = false;

  /// 戻した書きかけの日時。戻していなければnull。
  DateTime? _restoredAt;
  int _formGeneration = 0;
  Timer? _debounce;
  AppLifecycleListener? _lifecycle;

  DraftStore get _drafts => widget.controller.drafts;

  // ---- 書いている途中の関係ありそうな記録（端末内の記録だけで探す） ----
  bool _showRelated = true;
  List<RelatedRecord> _related = const [];

  /// 探す長さの本文で探し終え、1件も見つからなかったときの、比べた記録の数。それ以外はnull。
  /// 何も出ないと、探していないのか見つからなかったのかが分からないため、見つからなかったことを一言出す。
  int? _relatedNone;
  Timer? _relatedTimer;

  /// 入力が止まってから探す。比べるのは端末に読み込んだ記録だけで、ネットワークにもAIにも送らない。
  void _scheduleRelated() {
    _relatedTimer?.cancel();
    _relatedTimer = Timer(const Duration(milliseconds: 600), _findRelated);
  }

  Future<void> _findRelated() async {
    if (!mounted) return;
    final repo = widget.controller.repository;
    if (!_showRelated || locked || widget.answer != null || repo == null) {
      if (_related.isNotEmpty || _relatedNone != null) {
        setState(() {
          _related = const [];
          _relatedNone = null;
        });
      }
      return;
    }
    // 記録の特徴は読み込みごとに1回だけ作る（記録が多ければ別のisolateで作り、入力を止めない）。
    final RelatedIndex index;
    try {
      index = await relatedIndex(repo);
    } catch (_) {
      return; // 探せなくても入力は続ける。
    }
    // 待つ間に閉じた・設定を止めたときは、古い結果を出さない。
    if (!mounted || !_showRelated) return;
    // 待つ間に読み直したときは、新しい記録で探し直す（前の記録の結果や件数を残さない）。
    if (widget.controller.repository != repo) {
      _scheduleRelated();
      return;
    }
    final next = relatedRecords(
      repo,
      text.text,
      index: index,
      project: project,
    );
    final none = next.isEmpty && relatedSearchable(text.text)
        ? index.features.length
        : null;
    // 読み直しで点や本文が変わることがあるので、毎回置き換える。
    if (next.isNotEmpty || _related.isNotEmpty || none != _relatedNone) {
      setState(() {
        _related = next;
        _relatedNone = none;
      });
    }
  }

  Future<void> _setShowRelated(bool value) async {
    setState(() {
      _showRelated = value;
      if (!value) {
        _related = const [];
        _relatedNone = null;
      }
    });
    if (value) _findRelated();
    try {
      await _drafts.setRelatedEnabled(value);
    } catch (_) {
      // 設定を残せなくても入力は続ける。
    }
  }

  /// 関係ありそうな記録の一覧。開く・文脈かごに入れる・同じプロジェクトで保存するを選べる。
  Widget _relatedBox() {
    final repo = widget.controller.repository,
        scheme = Theme.of(context).colorScheme;
    if (repo == null) return const SizedBox.shrink();
    return Container(
      key: const Key('related-records'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(hubRadiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '前に書いた、関係ありそうな記録',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          fieldNote(
            context,
            '同じことを書いていないか、続きの話ではないかを確かめられます。この端末に読み込んだ記録だけを、文字の重なりで探しています。',
            top: 2,
          ),
          // 行ごとの「…で保存する」が次の行に付いて見えないよう、線で区切る。
          for (final (i, hit) in _related.indexed) ...[
            if (i > 0) const Divider(height: 17),
            _relatedRow(repo, hit),
          ],
        ],
      ),
    );
  }

  Widget _relatedRow(HubRepository repo, RelatedRecord hit) {
    final owner = hit.owner == null ? null : repo.projects[hit.owner];
    final inferred = hit.related.where((id) => id != hit.owner);
    // 本人が指定したプロジェクトは、まだ同期されていなくてもAI推定とは書かない。
    final where = owner != null
        ? owner.title
        : hit.owner != null
        ? hit.owner!
        : inferred.isNotEmpty
        ? '${repo.projects[inferred.first]?.title ?? inferred.first}（AI推定）'
        : 'プロジェクト未定';
    final canUseProject =
        owner != null &&
        !owner.merged &&
        project == null &&
        widget.draft == null &&
        !locked;
    return Padding(
      key: Key('related-${hit.root.id}'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hit.latest.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  '${timeLabel(hit.root.at).split(' ').first} · $where${hit.latest.kind == 'correction' ? ' · 訂正あり' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  searchSnippet(hit.latest.body, hit.shared.take(5).toList()),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (canUseProject)
                  TextButton(
                    key: Key('related-project-${hit.root.id}'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () {
                      setState(() {
                        project = owner.id;
                        _formGeneration++;
                      });
                      _schedulePersist();
                    },
                    child: Text('「${owner.title}」で保存する'),
                  ),
              ],
            ),
          ),
          IconButton(
            key: Key('related-open-${hit.root.id}'),
            tooltip: '開く（同じ内容なら、開いた画面から訂正を書けます）',
            icon: const Icon(Icons.open_in_new, size: 18),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    RecordView(controller: widget.controller, record: hit.root),
              ),
            ),
          ),
          BasketToggle(controller: widget.controller, record: hit.root),
        ],
      ),
    );
  }

  // ---- ひな形（端末内のみ） ----
  static const _editTemplates = '\u0000edit';
  List<MemoTemplate> _templates = defaultTemplates;
  final _textFocus = FocusNode();

  /// ひな形を本文へ差し込む。本文が空なら全体、空でなければ末尾へ足す。
  void _applyTemplate(MemoTemplate template) {
    final next = insertTemplate(text.text, template.body);
    if (next.text.length > 8000) {
      setState(() => error = 'ひな形を差し込むと8000文字を超えます。本文を短くしてください。');
      return;
    }
    final preset = template.projects[widget.controller.location?.identity];
    final projects = widget.controller.repository?.projects ?? const {};
    setState(() {
      error = null;
      text.value = TextEditingValue(
        text: next.text,
        selection: TextSelection.collapsed(offset: next.cursor),
      );
      // ひな形の既定のプロジェクトは、未指定のときだけ使う（本人が選んだものを変えない）。
      if (widget.draft == null &&
          project == null &&
          preset != null &&
          projects.containsKey(preset)) {
        // 統合済みのプロジェクトが既定なら、統合先にする。
        project = projects[preset]!.mergeTarget ?? preset;
        _formGeneration++;
      }
    });
    _textFocus.requestFocus();
    _schedulePersist();
  }

  /// ひな形の見出しを本文へ差し込むメニュー。
  Widget _templateMenu(BuildContext context) => PopupMenuButton<String>(
    key: const Key('template-menu'),
    tooltip: 'ひな形の見出しを本文へ差し込む',
    onSelected: (id) {
      if (id == _editTemplates) {
        _manageTemplates();
        return;
      }
      for (final t in _templates) {
        if (t.id == id) _applyTemplate(t);
      }
    },
    itemBuilder: (context) => [
      for (final t in _templates)
        PopupMenuItem(
          key: Key('template-item-${t.id}'),
          value: t.id,
          child: Text(t.name, overflow: TextOverflow.ellipsis),
        ),
      if (_templates.isNotEmpty) const PopupMenuDivider(),
      const PopupMenuItem(
        key: Key('template-manage'),
        value: _editTemplates,
        child: Text('ひな形を編集…'),
      ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.playlist_add,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            'ひな形',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    ),
  );

  /// メモの種類の切り替え。ふつうのメモと、AIの作業の報告（作業要約）の2つを横に並べ、どちらか1つを選ぶ。
  Widget _kindChooser(BuildContext context) => SegmentedButton<String>(
    key: const Key('memo-kind'),
    showSelectedIcon: false,
    style: SegmentedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    // 2つは同じ幅になる。狭い画面では印を外し、「AIの作業要約」が途中で折り返さないようにする。
    segments: [
      ButtonSegment(
        value: 'memo',
        icon: wideKindChooser(context)
            ? const Icon(Icons.edit_note, size: 18)
            : null,
        label: const Text('メモ', key: Key('memo-kind-memo')),
        tooltip: '思いつき・疑問・作業の記録など、ふつうはこちら',
      ),
      ButtonSegment(
        value: 'work-summary',
        icon: wideKindChooser(context)
            ? const Icon(Icons.smart_toy_outlined, size: 18)
            : null,
        label: const Text('AIの作業要約', key: Key('memo-kind-work-summary')),
        tooltip: 'AIが書いた作業の報告を貼るとき（未検証として扱う）',
      ),
    ],
    selected: {kind},
    // ファイルを添えたメモは、種類を変えない（ファイルはメモにだけ添える）。
    onSelectionChanged: locked || attachment != null
        ? null
        : (v) {
            setState(() => kind = v.first);
            _schedulePersist();
          },
  );

  Future<void> _manageTemplates() async {
    await showDialog<void>(
      context: context,
      builder: (_) => TemplateManagerDialog(controller: widget.controller),
    );
    final next = await widget.controller.templates.list();
    if (mounted) setState(() => _templates = next);
  }

  @override
  void initState() {
    super.initState();
    _initial();
    final answer = widget.answer;
    _draftKey = widget.controller.draftKey(
      gitDraftId: widget.draft?.id,
      answerTo: answer == null ? null : '${answer.runId}/${answer.itemKey}',
      continues: widget.continues?.sourceId,
    );
    text.addListener(_schedulePersist);
    text.addListener(_scheduleRelated);
    referenceTitle.addListener(_schedulePersist);
    _lifecycle = AppLifecycleListener(
      onInactive: _persistNow,
      onHide: _persistNow,
      onPause: _persistNow,
    );
    _restore();
  }

  void _initial() {
    final draft = widget.draft;
    text.text = draft?.text ?? '';
    kind = 'memo';
    // 続きは、プロジェクトを指定しなければ本体が前のメモのプロジェクトを引き継ぐ（統合を戻したときも前のメモと一緒に動く）。
    project = draft?.projectId;
    happenedOn = null;
    reference = false;
    referenceTitle.text = '';
    attachment = null;
    _lostAttachment = null;
  }

  /// 続きでプロジェクトを指定しないときに引き継ぐ、前のメモのプロジェクトの名前（統合済みなら統合先）。続きでない・指定がなければnull。
  String? get _inheritedTitle {
    final repo = widget.controller.repository,
        id = widget.continues?.metadata['project'];
    if (repo == null || id is! String) return null;
    return repo.projects[repo.resolveProject(id)]?.title;
  }

  /// 前回の書きかけを戻す。保存済みの操作の書きかけは消し、保存結果が不明なものは確認へ戻す。
  Future<void> _restore() async {
    final key = _draftKey;
    try {
      _templates = await widget.controller.templates.list();
      _showRelated = await _drafts.relatedEnabled();
      if (key == null) return;
      _keepDrafts = await _drafts.enabled();
      final stored = await _drafts.read(key);
      if (stored == null) return;
      final draft = widget.draft;
      final projects = widget.controller.repository?.projects ?? const {};
      if ((draft != null && stored.gitDraftHash != draft.hash) ||
          (draft != null && stored.project != draft.projectId)) {
        // 下書きが作り直された場合、古い本文は戻さない。
        await _drafts.remove(key);
        return;
      }
      final op = stored.operationId;
      final state = op == null
          ? null
          : await widget.controller.operationState(op);
      if (state == 'saved') {
        await _drafts.remove(key);
        return;
      }
      if (!mounted || text.text != (draft?.text ?? '')) return;
      text.text = stored.text;
      kind = widget.answer != null ? 'memo' : stored.kind;
      project = draft != null
          ? draft.projectId
          : stored.project != null && projects.containsKey(stored.project)
          ? stored.project
          : null;
      // 日付が古くなって選べなくなった書きかけは、今日のことに戻す。
      happenedOn =
          _canBackdate &&
              validHappenedOn(stored.happenedOn, maxDays: _maxBackdateDays)
          ? stored.happenedOn
          : null;
      reference = _canReference && stored.reference;
      referenceTitle.text = reference ? stored.referenceTitle ?? '' : '';
      // 保存の記録を作る前に止まった書きかけ（ファイルを写している途中など）も、ファイルは戻せないため選び直してもらう。
      _lostAttachment = reference && (op == null || state == null)
          ? stored.attachmentName
          : null;
      _restoredAt = stored.updatedAt;
      if (op != null && state != null) {
        // 保存を試みた操作は、同じ操作IDで確認だけを行う（再送しない）。
        operation = op;
        locked = true;
        result = CaptureResult(op, '', 'uncertain');
      }
    } catch (_) {
      // 書きかけを戻せなくても入力は始められる。
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }

  void _schedulePersist() {
    if (!_ready) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _persistNow);
  }

  void _persistNow() {
    _debounce?.cancel();
    _debounce = null;
    _persist();
  }

  /// 書きかけを残さない設定では、保存を試みた操作IDだけを残す（本文は[DraftStore]が外す）。
  Future<void> _persist() async {
    final key = _draftKey;
    if (key == null || !_ready || _finished) return;
    if (!_keepDrafts && !locked) return;
    await _drafts.write(
      key,
      WritingDraft(
        text: text.text.length > DraftStore.maxChars
            ? text.text.substring(0, DraftStore.maxChars)
            : text.text,
        kind: kind,
        project: project,
        gitDraftHash: widget.draft?.hash,
        operationId: locked ? operation : null,
        happenedOn: happenedOn,
        reference: reference,
        referenceTitle: reference ? _referenceTitleValue : null,
        attachmentName: reference ? attachment?.name ?? _lostAttachment : null,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _finish() async {
    _finished = true;
    _debounce?.cancel();
    final key = _draftKey;
    if (key != null) await _drafts.remove(key);
  }

  /// 戻した書きかけを捨て、最初の状態から書き直す。
  Future<void> _discard() async {
    final key = _draftKey;
    _debounce?.cancel();
    if (key != null) await _drafts.remove(key);
    if (!mounted) return;
    setState(() {
      _initial();
      _related = const [];
      _relatedNone = null;
      operation = const Uuid().v4();
      locked = false;
      result = null;
      error = null;
      _restoredAt = null;
      _confirmedOnce = false;
      _formGeneration++;
    });
  }

  Future<void> _setKeepDrafts(bool value) async {
    setState(() => _keepDrafts = value);
    await _drafts.setEnabled(value);
    if (value) await _persist();
  }

  @override
  void dispose() {
    if (_debounce?.isActive == true) _persistNow();
    _debounce?.cancel();
    _lifecycle?.dispose();
    text.removeListener(_schedulePersist);
    text.removeListener(_scheduleRelated);
    referenceTitle.removeListener(_schedulePersist);
    _relatedTimer?.cancel();
    text.dispose();
    referenceTitle.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Future<void> _settled(CaptureResult r) async {
    if (r.saved) {
      await _finish();
    } else {
      await _persist();
    }
  }

  Future<void> submit() async {
    // 中身を書かなかったひな形の見出しは保存しない。文字数は取り除いた後の本文で数える。
    var body = stripEmptyTemplateHeadings(
      text.text,
      templateHeadings(_templates),
    );
    if (body.trim().isEmpty && text.text.trim().isNotEmpty) {
      setState(() => error = 'ひな形の見出しだけで、中身がありません。見出しの下に書いてから保存してください。');
      return;
    }
    final file = attachment;
    if (file != null && (!_canAttach || kind != 'memo' || !reference)) {
      setState(() => error = 'ファイルを添えられなくなりました（本体か保存先が変わりました）。ファイルを外してから保存してください。');
      return;
    }
    // ファイルだけを添えたときは、ファイル名を本文にする。
    if (body.trim().isEmpty && file != null) body = file.name;
    if (body.trim().isEmpty || body.length > 8000) {
      setState(() => error = '本文は1〜8000文字で入力してください。');
      return;
    }
    // 日をまたいで開いていたなどで選べない日付になったときは、保存の前に選び直してもらう。
    if (_canBackdate &&
        happenedOn != null &&
        !validHappenedOn(happenedOn, maxDays: _maxBackdateDays)) {
      setState(
        () => error = '「いつのこと」の日付は、昨日から$_maxBackdateDays日前までで選び直してください。',
      );
      return;
    }
    final title = _canReference && reference ? _referenceTitleValue : null;
    if (title != null &&
        !validReferenceTitle(title, max: _referenceTitleMax)) {
      setState(
        () => error = '資料の名前は1行・$_referenceTitleMax文字以内で書いてください。',
      );
      return;
    }
    if (title != null &&
        (widget.controller.repository?.secretInReferenceTitle(title) ??
            false)) {
      setState(() => error = referenceTitleSecretMessage);
      return;
    }
    final checked = await checkSecretsBeforeSave(
      context,
      body,
      secrets: widget.controller.repository?.secretPolicy,
    );
    if (checked == null || !mounted) return;
    if (checked != body && checked.length > 8000) {
      setState(() => error = '伏せ字にすると8000文字を超えます。本文を短くしてください。');
      return;
    }
    // 保存する本文（空の見出しを除き、選んだ場合は伏せ字にしたもの）を画面にも示す。
    if (checked != text.text) text.text = checked;
    setState(() {
      busy = true;
      locked = true;
      error = null;
    });
    // 保存中に終了されても同じ操作の確認へ戻れるよう、先に操作IDを書きかけへ残す。
    _debounce?.cancel();
    await _persist();
    try {
      final r = await widget.controller.save(
        CaptureDraft(
          operationId: operation,
          text: text.text,
          kind: kind,
          project: project,
          gitDraftId: widget.draft?.id,
          gitDraftHash: widget.draft?.hash,
          meta: widget.answer?.meta,
          happenedOn: _canBackdate ? happenedOn : null,
          maxBackdateDays: _maxBackdateDays,
          continues: widget.continues?.sourceId,
          reference: _canReference && reference,
          referenceTitle: title,
          referenceTitleMax: _referenceTitleMax,
          attachment: file,
          attachmentMaxBytes: _attachmentLimits.maxBytes,
          fileNameMaxBytes: _attachmentLimits.nameMaxBytes,
        ),
      );
      await _settled(r);
      if (mounted) {
        setState(() => result = r);
      }
    } catch (e) {
      // 保存の記録（journal）を作る前に止まった場合（ファイルを写せなかった・形式の誤りなど）は、直して送り直せるようにする。
      // 写しかけのファイルと重ならないよう、次の保存は別の操作IDにする。記録後に結果が不明になった場合は、同じ操作IDで確認する。
      final state = await widget.controller.operationState(operation);
      if (mounted) {
        setState(() {
          error = HubController.message(e);
          if (state == null) {
            locked = false;
            operation = const Uuid().v4();
          }
        });
        if (state == null) {
          // 保存中に消した関係ありそうな記録を、鍵が外れたので探し直す。
          _scheduleRelated();
          await _persist();
        }
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> confirmSame() async {
    setState(() => busy = true);
    try {
      final r = await widget.controller.confirm(operation);
      await _settled(r);
      if (mounted) {
        setState(() {
          result = r;
          _confirmedOnce = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = HubController.message(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  // ⌘Return（Ctrl+Enter）で「Inputへ保存」と同じ操作をする。
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      saveFormActivator: () {
        if (!busy && _ready && !locked) submit();
      },
      // Escは、本文が空（変換中でもない）ときだけ「フォームを閉じる」と同じ操作をする。書きかけを誤って捨てないため。
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (!busy &&
            !text.value.composing.isValid &&
            text.text.trim().isEmpty) {
          Navigator.pop(context);
        }
      },
    },
    // Mac以外では入力欄が自動で選ばれないため、開いた直後からキーが届くよう受け口を置く（ソフトキーボードは開かない）。
    child: Focus(
      autofocus: !usesCommandKey,
      skipTraversal: true,
      child: PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: Text(
            widget.answer != null
                ? '問いに答える'
                : widget.continues != null
                ? '続きを書く'
                : widget.draft == null
                ? '思いつきを、そのまま。'
                : '下書きから入力を作る',
          ),
          content: SizedBox(
            width: 620,
            child: !_ready
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : DialogScroll(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        fieldNote(
                          context,
                          '保存先: ${widget.controller.location?.name ?? ''}',
                          top: 0,
                        ),
                        if (_restoredAt != null && result?.saved != true) ...[
                          const SizedBox(height: 12),
                          NoticeBox(
                            locked
                                ? '前回、保存結果を確かめられないまま閉じた書きかけです（${timeLabel(_restoredAt)}）。同じ内容を送り直さず、「同じ操作を確認」を押してください。'
                                : '前回の書きかけを戻しました（${timeLabel(_restoredAt)}）。',
                            key: const Key('draft-restored'),
                          ),
                          // 保存結果が不明なまま閉じた書きかけは、同じ操作を確かめてからでないと閉じられない。
                          // 先に閉じると新しい操作IDで同じ内容を送り直しやすくなるため。
                          if (!locked || _confirmedOnce)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                key: const Key('draft-discard'),
                                onPressed: busy ? null : _discard,
                                child: Text(
                                  locked ? '書きかけを閉じて新しく書く' : '書きかけを破棄して新しく書く',
                                ),
                              ),
                            ),
                        ],
                        if (widget.continues case final previous?) ...[
                          const SizedBox(height: 12),
                          NoticeBox(
                            '前のメモの続きとして保存します。前のメモは変わりません。Mac miniのAI読み取りでは、前のメモを前提として読みます。\n前のメモ: ${clip(previous.title.replaceAll(RegExp(r'\s+'), ' '), 80)}',
                            key: const Key('continues-previous'),
                          ),
                        ],
                        if (widget.answer case final answer?) ...[
                          const SizedBox(height: 12),
                          Container(
                            key: const Key('answer-question'),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '今週の気づきの問い（AIの推定・未検証）',
                                  style: noteStyle(context),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  answer.question,
                                  style: const TextStyle(height: 1.6),
                                ),
                              ],
                            ),
                          ),
                          fieldNote(
                            context,
                            '答えはふつうのメモとして保存し、この問いへの答えだと分かるように記録します。次の週の読み直しで使われます。',
                            top: 8,
                          ),
                        ],
                        const SizedBox(height: 16),
                        // 種類は、本文の上に2つの切り替えで並べる（ほとんどはメモのまま）。ひな形は、収まれば同じ行の右に、狭い画面では次の行に置く。
                        if (widget.answer == null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                _kindChooser(context),
                                if (!locked) _templateMenu(context),
                              ],
                            ),
                          ),
                        // 下書きから作る入力では、下の案内が同じことを伝えるので出さない。
                        if (widget.answer == null &&
                            widget.draft == null &&
                            kind == 'work-summary')
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: fieldNote(
                              context,
                              'AIが書いた作業の報告を貼るときの種類です。AIの自己報告（未検証）として読み取り、プロジェクトの現在地・次の一手の材料にします。',
                              key: const Key('memo-kind-note'),
                              top: 0,
                            ),
                          ),
                        TextField(
                          key: const Key('memo-text'),
                          controller: text,
                          focusNode: _textFocus,
                          // Macではキーボードで開いたまま書けるよう、本文へ移る。
                          autofocus: usesCommandKey,
                          readOnly: locked,
                          minLines: 5,
                          maxLines: 10,
                          maxLength: 8000,
                          decoration: InputDecoration(
                            hintText: widget.answer != null
                                ? '1行からで構いません'
                                : '断片的なメモ、疑問、あとで考えたいこと…',
                            alignLabelWithHint: true,
                          ),
                        ),
                        if (_related.isNotEmpty && _showRelated && !locked)
                          _relatedBox()
                        else if (_relatedNone case final count?
                            when _showRelated && !locked)
                          fieldNote(
                            context,
                            count == 0
                                ? '比べられる前の記録が、まだこの端末にありません。'
                                : '関係ありそうな前の記録は見つかりませんでした（この端末の$count件と、文字の重なりで比べました）。',
                            key: const Key('related-none'),
                            top: 4,
                          ),
                        fieldGap,
                        DropdownButtonFormField<String>(
                          key: ValueKey('memo-project-$_formGeneration'),
                          initialValue: project ?? '',
                          isExpanded: true,
                          style: fieldTextStyle(context),
                          decoration: const InputDecoration(
                            labelText: 'プロジェクト（任意）',
                          ),
                          items: [
                            // 続きでは、指定しなければ本体が前のメモのプロジェクトを引き継ぐので、そのとおりに示す。
                            DropdownMenuItem(
                              value: '',
                              child: Text(
                                _inheritedTitle == null
                                    ? '指定しない'
                                    : '前のメモと同じ（$_inheritedTitle）',
                              ),
                            ),
                            // 統合済みのプロジェクトは選ばせない（統合先を選ぶ）。
                            for (final p
                                in (widget
                                            .controller
                                            .repository
                                            ?.projects
                                            .values ??
                                        const <HubProject>[])
                                    .where((p) => !p.merged || p.id == project))
                              DropdownMenuItem(
                                value: p.id,
                                child: Text(
                                  p.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          // 下書きは同じプロジェクトの入力でだけ使用済みになるため、プロジェクトを固定する。
                          onChanged: locked || widget.draft != null
                              ? null
                              : (v) {
                                  setState(() => project = v == '' ? null : v);
                                  _schedulePersist();
                                  _scheduleRelated();
                                },
                        ),
                        if (_canBackdate) ...[
                          fieldGap,
                          _happenedChooser(context),
                        ],
                        if (_canReference) ...[
                          const SizedBox(height: 12),
                          _referenceChooser(context),
                        ],
                        if (widget.draft != null && kind == 'work-summary')
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: NoticeBox(
                              '作業要約として保存すると、プロジェクトの現在地・次の一手はこの本文から作られます。次の一手を書き足してください。',
                            ),
                          ),
                        fieldNote(
                          context,
                          '保存すると、同期の後にMac miniが受け取り、AIが読み取ります。進み具合は「保存と反映」で見られます。',
                          top: 16,
                        ),
                        // この端末だけの設定は、メモの中身の欄と見出しで分けて、控えめにまとめる。
                        if (_draftKey != null || widget.answer == null) ...[
                          fieldGap,
                          fieldLabel(context, 'この端末の設定'),
                        ],
                        if (_draftKey != null)
                          CheckboxListTile(
                            key: const Key('keep-drafts'),
                            contentPadding: EdgeInsets.zero,
                            visualDensity: formTileDensity,
                            horizontalTitleGap: formTileGap,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _keepDrafts,
                            onChanged: (v) => _setKeepDrafts(v ?? true),
                            title: Text(
                              '書きかけをこの端末に残す',
                              style: formTileTitle(context),
                            ),
                            subtitle: const Text(
                              'フォームを閉じたりアプリが終了したりしても、次に開いたときに続きから書けます。保存が確かめられたら消します。Vaultには書きません。',
                            ),
                          ),
                        if (widget.answer == null)
                          CheckboxListTile(
                            key: const Key('show-related'),
                            contentPadding: EdgeInsets.zero,
                            visualDensity: formTileDensity,
                            horizontalTitleGap: formTileGap,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _showRelated,
                            onChanged: (v) => _setShowRelated(v ?? true),
                            title: Text(
                              '書いている途中に、関係ありそうな過去の記録を出す',
                              style: formTileTitle(context),
                            ),
                            subtitle: const Text(
                              'この端末に読み込んだ記録だけを比べます。ネットワークにもAIにも送りません。',
                            ),
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: NoticeBox(error!, error: true),
                          ),
                        if (result != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: NoticeBox(
                              result!.saved
                                  ? 'この端末に保存しました'
                                  : '保存確認待ちです。再送せず同じ操作を確認してください。',
                            ),
                          ),
                        if (locked)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: SelectableText(
                              '操作ID: $operation',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: Text(result?.saved == true ? '閉じる' : 'フォームを閉じる'),
            ),
            if (!locked)
              FilledButton(
                key: const Key('save-memo'),
                onPressed: busy || !_ready ? null : submit,
                child: const Text('メモとして保存'),
              ),
            if (locked && result?.saved != true)
              FilledButton(
                key: const Key('confirm-same'),
                onPressed: busy ? null : confirmSame,
                child: const Text('同じ操作を確認'),
              ),
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    ),
  );
}

/// ピン留めしたプロジェクトの並びを変える。並びはこの端末にだけ保存し、Vaultには書かない。
class PinOrderDialog extends StatelessWidget {
  const PinOrderDialog({super.key, required this.controller});
  final HubController controller;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) notice(context, HubController.message(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final projects =
          controller.repository?.pinnedProjects ?? const <HubProject>[];
      return AlertDialog(
        key: const Key('pin-order-dialog'),
        title: const Text('ピン留めの並び'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: DialogScroll(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ピン留めしたプロジェクトは、メニュー・ホーム・「次の一手」の先頭にこの順で並びます。並びはこの端末にだけ保存し、Vaultやほかの端末には伝わりません。',
                  style: noteStyle(context),
                ),
                const SizedBox(height: 8),
                if (projects.isEmpty) const Text('ピン留めしたプロジェクトはありません。'),
                // 幅の狭い端末でも題名を読めるよう、題名を1行使い、操作のボタンはその下に置く。
                for (final (index, project) in projects.indexed)
                  Padding(
                    key: Key('pin-row-${project.id}'),
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          project.title,
                          key: Key('pin-title-${project.id}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (project.lifecycle != 'active')
                          Text(
                            '${project.lifecycleLabel}（「次の一手」には出ません）',
                            style: noteStyle(context),
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              key: Key('pin-up-${project.id}'),
                              tooltip: '前へ',
                              onPressed: index == 0
                                  ? null
                                  : () => _run(
                                      context,
                                      () => controller.movePin(project.id, -1),
                                    ),
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              key: Key('pin-down-${project.id}'),
                              tooltip: '後ろへ',
                              onPressed: index == projects.length - 1
                                  ? null
                                  : () => _run(
                                      context,
                                      () => controller.movePin(project.id, 1),
                                    ),
                              icon: const Icon(Icons.arrow_downward, size: 18),
                            ),
                            IconButton(
                              key: Key('pin-remove-${project.id}'),
                              tooltip: 'ピン留めを外す',
                              onPressed: () => _run(
                                context,
                                () => controller.setPinned(project.id, false),
                              ),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('pin-order-close'),
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      );
    },
  );
}

/// 連絡待ちの印（相手・頼んだ日）と見直す日を入力する。相手は任意で、AIは推測しない。
/// 結果の見直す日（reviewAfter）がnullなら見直す日を外す。
class WaitDialog extends StatefulWidget {
  const WaitDialog({super.key, required this.item, this.suggestions = const []});
  final NowItemRef item;

  /// 相手の候補（いま連絡待ちにしている項目の相手）。
  final List<String> suggestions;
  @override
  State<WaitDialog> createState() => _WaitDialogState();
}

class _WaitDialogState extends State<WaitDialog> {
  late final who = TextEditingController(text: widget.item.waitingWho ?? ''),
      since = TextEditingController(
        text: widget.item.waitingSince ?? hubToday(),
      ),
      review = TextEditingController(text: widget.item.reviewAfter ?? '');

  @override
  void dispose() {
    who.dispose();
    since.dispose();
    review.dispose();
    super.dispose();
  }

  String? get whoValue => who.text.trim().isEmpty ? null : who.text.trim();
  String? get reviewValue =>
      review.text.trim().isEmpty ? null : review.text.trim();
  String? get whoProblem {
    final v = whoValue;
    return v == null || validWaitWho(v) ? null : '1行・$waitWhoChars文字以内で入力してください。';
  }

  String? get sinceProblem {
    final v = since.text.trim();
    if (!validScheduleDate(v)) return 'YYYY-MM-DDの実在する日で入力してください（2000〜2099年）。';
    return v.compareTo(hubToday()) > 0 ? '頼んだ日に先の日付は付けられません。' : null;
  }

  String? get reviewProblem {
    final v = reviewValue;
    return v == null || validScheduleDate(v)
        ? null
        : 'YYYY-MM-DDの実在する日で入力してください（2000〜2099年）。';
  }

  Widget dateChips(String key, TextEditingController c, List<(String, int)> choices) =>
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (label, days) in choices)
            ActionChip(
              key: Key('wait-$key-$days'),
              label: Text(label),
              onPressed: () =>
                  setState(() => c.text = addScheduleDays(hubToday(), days)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final valid =
            whoProblem == null && sinceProblem == null && reviewProblem == null,
        sinceValue = since.text.trim(),
        changed =
            !widget.item.waiting ||
            widget.item.waitingSince != sinceValue ||
            widget.item.waitingWho != whoValue ||
            widget.item.reviewAfter != reviewValue;
    return AlertDialog(
      key: const Key('wait-dialog'),
      title: Text(widget.item.waiting ? '連絡待ちを変える' : '連絡待ちにする'),
      content: SizedBox(
        width: 520,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.display,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('wait-who'),
                controller: who,
                maxLength: waitWhoChars,
                decoration: InputDecoration(
                  labelText: '相手（任意）',
                  helperText: '名前はVaultに残り、同期先の端末とバックアップにも入ります。気になる場合はイニシャルなどで書いてください。',
                  helperMaxLines: 3,
                  errorText: whoProblem,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (widget.suggestions.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final name in widget.suggestions)
                      ActionChip(
                        key: Key('wait-who-suggestion-$name'),
                        label: Text(name),
                        onPressed: () => setState(() => who.text = name),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                key: const Key('wait-since'),
                controller: since,
                decoration: InputDecoration(
                  labelText: '頼んだ日',
                  hintText: 'YYYY-MM-DD',
                  errorText: sinceProblem,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              dateChips('since', since, [('今日', 0), ('昨日', -1), ('3日前', -3), ('1週間前', -7)]),
              const SizedBox(height: 14),
              TextField(
                key: const Key('wait-review'),
                controller: review,
                decoration: InputDecoration(
                  labelText: '見直す日（任意）',
                  hintText: 'YYYY-MM-DD',
                  helperText: 'この日になると「次の一手」の先頭に、連絡待ちの確認として出ます。',
                  helperMaxLines: 2,
                  errorText: reviewProblem,
                  suffixIcon: review.text.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('wait-review-clear'),
                          tooltip: '外す',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(review.clear),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              dateChips('review', review, [('3日後', 3), ('1週間後', 7), ('2週間後', 14)]),
              const SizedBox(height: 12),
              Text(
                '連絡待ちにした項目は、「次の一手」の一覧と件数から外れ、「連絡待ち」にまとまります。返事が来たら印を外すか、完了にしてください。相手の名前は、ホーム画面のウィジェットと、別のAIへ渡す資料には出しません。',
                style: noteStyle(context),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('wait-submit'),
          onPressed: valid && changed
              ? () => Navigator.pop(context, (
                  who: whoValue,
                  since: sinceValue,
                  reviewAfter: reviewValue,
                ))
              : null,
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}

/// NOWの項目の手間の目安を選ぶ。目安は本人が選び、AIは推測しない。結果のeffortがnullなら外す。
class EffortDialog extends StatefulWidget {
  const EffortDialog({super.key, required this.item});
  final NowItemRef item;
  @override
  State<EffortDialog> createState() => _EffortDialogState();
}

class _EffortDialogState extends State<EffortDialog> {
  late String? effort = widget.item.effort;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('effort-dialog'),
    title: const Text('手間の目安'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.item.display,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in itemEfforts)
                  ChoiceChip(
                    key: Key('effort-choice-$e'),
                    label: Text(itemEffortLabels[e]!),
                    selected: effort == e,
                    onSelected: (_) => setState(() => effort = e),
                  ),
                if (widget.item.effort != null)
                  ChoiceChip(
                    key: const Key('effort-choice-none'),
                    label: const Text('目安を外す'),
                    selected: effort == null,
                    onSelected: (_) => setState(() => effort = null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '空いた時間に合う項目を「次の一手」で絞り込むための目安です。Mac miniで処理されると現状に反映され、同じ本文の項目には新しい報告が届いても引き継がれます。',
              style: noteStyle(context),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('やめる'),
      ),
      FilledButton(
        key: const Key('effort-submit'),
        onPressed: effort == widget.item.effort
            ? null
            : () => Navigator.pop(context, (effort: effort)),
        child: const Text('依頼する'),
      ),
    ],
  );
}

/// 札を選ぶチップの並び。[options]は語彙と、語彙にないが今付いている札（「一覧にない」と添える）。
class ContextChips extends StatelessWidget {
  const ContextChips({
    super.key,
    required this.options,
    required this.vocabulary,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'contexts-choice',
  });
  final List<String> options, vocabulary, selected;
  final ValueChanged<List<String>> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final t in options)
        FilterChip(
          key: Key('$keyPrefix-$t'),
          showCheckmark: true,
          label: Text(vocabulary.contains(t) ? t : '$t（一覧にない）'),
          selected: selected.contains(t),
          onSelected: (on) {
            // 選んだ札は、語彙の並び（一覧にない札はその後ろ）にそろえて送る。
            final next = on ? {...selected, t} : ({...selected}..remove(t));
            onChanged([
              for (final o in options)
                if (next.contains(o)) o,
            ]);
          },
        ),
    ],
  );
}

/// NOWの項目の場所・道具の札を選ぶ。札は本人が選び、AIは付けない。結果のcontextsがnullなら外す。
/// 語彙から外した札が付いている項目は、その札を表示したまま付け直せる。
class ContextsDialog extends StatefulWidget {
  const ContextsDialog({
    super.key,
    required this.item,
    required this.vocabulary,
    required this.editVocabulary,
  });
  final NowItemRef item;

  /// 今の語彙（一覧を変えた後に読み直すため、関数で受け取る）。
  final List<String> Function() vocabulary;

  /// 語彙を編集して依頼する。依頼したらtrue。
  final Future<bool> Function() editVocabulary;
  @override
  State<ContextsDialog> createState() => _ContextsDialogState();
}

class _ContextsDialogState extends State<ContextsDialog> {
  late List<String> selected = [...widget.item.contexts];
  late List<String> vocabulary = widget.vocabulary();

  List<String> get options => {
    ...vocabulary,
    for (final t in [...widget.item.contexts, ...selected])
      if (!vocabulary.contains(t)) t,
  }.toList();

  // 札の並びだけが違う（語彙の順に並べ直した）ときは、変えていないものとする。
  bool get unchanged =>
      selected.length == widget.item.contexts.length &&
      selected.toSet().containsAll(widget.item.contexts);

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('contexts-dialog'),
    title: const Text('場所・道具の札'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.item.display,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (options.isEmpty)
              const Text('札の一覧が空です。「札の一覧を編集」から足してください。')
            else
              ContextChips(
                options: options,
                vocabulary: vocabulary,
                selected: selected,
                onChanged: (next) => setState(() => selected = next),
              ),
            if (selected.length > contextTagsMax)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '札は1つの項目に$contextTagsMax個までです。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('contexts-edit-vocabulary'),
                onPressed: () async {
                  if (await widget.editVocabulary() && mounted) {
                    setState(() => vocabulary = widget.vocabulary());
                  }
                },
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('札の一覧を編集'),
              ),
            ),
            Text(
              '今いる場所や手元の道具でできる項目を「次の一手」で絞り込むための札です。いくつでも選べ、何も選ばなければ札を外します。Mac miniで処理されると現状に反映され、同じ本文の項目には新しい報告が届いても引き継がれます。',
              style: noteStyle(context),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('やめる'),
      ),
      FilledButton(
        key: const Key('contexts-submit'),
        onPressed: unchanged || selected.length > contextTagsMax
            ? null
            : () => Navigator.pop(context, (
                contexts: selected.isEmpty ? null : selected,
              )),
        child: Text(
          selected.isEmpty && widget.item.contexts.isNotEmpty
              ? '札を外す'
              : '依頼する',
        ),
      ),
    ],
  );
}

/// 場所・道具の札の一覧（語彙）を編集する。足す・外す・並べ替える。結果は変更後の全体。
/// 一覧はVaultに置き、同じVaultを使うすべての端末で同じものを使う。外した札は、付いている項目に残る。
class ContextVocabularyDialog extends StatefulWidget {
  const ContextVocabularyDialog({
    super.key,
    required this.current,
    this.pending = false,
  });
  final List<String> current;

  /// 前の変更がまだ反映されていない（その変更の一覧を見せている）。
  final bool pending;
  @override
  State<ContextVocabularyDialog> createState() =>
      _ContextVocabularyDialogState();
}

class _ContextVocabularyDialogState extends State<ContextVocabularyDialog> {
  late final List<String> items = [...widget.current];
  final input = TextEditingController();
  String? error;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void add() {
    final t = normalizeContextTag(input.text);
    setState(() {
      if (t.isEmpty) {
        error = null;
      } else if (!validContextTag(t)) {
        error = '札は$contextTagChars文字以内で、空白・「@・、,<>`」・括弧を使わずに入力してください。';
      } else if (items.contains(t)) {
        error = '同じ札が一覧にあります。';
      } else if (items.length >= contextVocabularyMax) {
        error = '札の一覧は$contextVocabularyMax個までです。';
      } else {
        items.add(t);
        input.clear();
        error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('context-vocabulary-dialog'),
    title: const Text('札の一覧'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.pending)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '前の変更がまだMac miniで処理されていません（その一覧を表示しています）。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            for (final (i, t) in items.indexed)
              Row(
                key: Key('vocabulary-row-$t'),
                children: [
                  Expanded(child: Text(t)),
                  IconButton(
                    key: Key('vocabulary-up-$t'),
                    tooltip: '上へ',
                    onPressed: i == 0
                        ? null
                        : () => setState(() {
                            items.removeAt(i);
                            items.insert(i - 1, t);
                          }),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                  IconButton(
                    key: Key('vocabulary-remove-$t'),
                    tooltip: '一覧から外す',
                    onPressed: () => setState(() => items.removeAt(i)),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('vocabulary-input'),
                    controller: input,
                    maxLength: contextTagChars,
                    decoration: InputDecoration(
                      labelText: '新しい札（例: 家・外出先・PC・電話・元気なとき）',
                      errorText: error,
                    ),
                    onSubmitted: (_) => add(),
                  ),
                ),
                IconButton(
                  key: const Key('vocabulary-add'),
                  tooltip: '足す',
                  onPressed: add,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Text(
              'この一覧は同じVaultを使うすべての端末で共有します。一覧から外しても、その札が付いている項目からは消えません（札を選ぶ画面に「一覧にない」と出ます）。',
              style: noteStyle(context),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('やめる'),
      ),
      FilledButton(
        key: const Key('vocabulary-submit'),
        onPressed: listEquals(items, widget.current)
            ? null
            : () => Navigator.pop(context, [...items]),
        child: const Text('依頼する'),
      ),
    ],
  );
}

/// NOWの項目を「誤り」として外す理由と一言を選ぶ。完了・解決とは別の報告にする。
class ExcludeDialog extends StatefulWidget {
  const ExcludeDialog({super.key, required this.item, required this.owned});
  final NowItemRef item;

  /// 元のメモが、本人がこのプロジェクトを指定して保存したものか。
  final bool owned;
  @override
  State<ExcludeDialog> createState() => _ExcludeDialogState();
}

class _ExcludeDialogState extends State<ExcludeDialog> {
  String? reason;
  final note = TextEditingController();

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  String effect(String reason) => switch (reason) {
    'outdated' when widget.item.action => 'もうやらない。項目を外すだけです。完了には数えません。',
    'misread' => 'メモはそう言っていない。Mac miniが次のAI読み取りで、このメモを読み直します。',
    'wrong-project' =>
      widget.owned
          ? 'このプロジェクトの話ではない。プロジェクトを指定して保存したメモなので、関連付けは変えず、この項目だけを外します。'
          : 'このプロジェクトの話ではない。AIが推定した関連付けなので、このメモをこのプロジェクトから外し、読み直して関連先を見直します。このメモから出たほかの項目も、このプロジェクトから外れます。',
    _ => '読みは合っているが、今は当てはまらない。項目を外すだけで、読み直しません。',
  };

  @override
  Widget build(BuildContext context) {
    final text = note.text.trim(),
        valid = text.isEmpty || validExclusionNote(text);
    return AlertDialog(
      key: const Key('exclude-dialog'),
      title: const Text('誤りとして外す'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.display,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              // 本人が追加した行動はAIの読み取りではないため、「もう古い」だけを選べる（本体も同じ）。
              for (final r
                  in widget.item.action ? const ['outdated'] : exclusionReasons)
                ListTile(
                  key: Key('exclude-reason-$r'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    reason == r
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(exclusionReasonLabels[r]!),
                  subtitle: Text(
                    effect(r),
                    style: noteStyle(context),
                  ),
                  onTap: () => setState(() => reason = r),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('exclude-note'),
                controller: note,
                maxLines: 1,
                decoration: InputDecoration(
                  labelText: '一言（任意）',
                  helperText: '例: 検討しただけで、まだ決めていない',
                  // 本体の検査と同じ数え方（UTF-16の単位。絵文字などは2文字と数える）で示す。
                  counterText: '${text.length} / $exclusionNoteChars',
                  errorText: valid
                      ? null
                      : '1行・$exclusionNoteChars文字以内で入力してください。',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Text(
                '完了・解決には数えません。原文は変わりません。外した項目の本文・理由・一言は、同じ読み違いを減らすために、次からのAI読み取りでAIへ渡します。Mac miniが処理すると現状に反映され、プロジェクトの画面から未解決に戻せます。',
                style: noteStyle(context),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('exclude-submit'),
          onPressed: reason == null || !valid
              ? null
              : () => Navigator.pop(context, (
                  reason: reason!,
                  note: text.isEmpty ? null : text,
                )),
          child: const Text('誤りとして外す'),
        ),
      ],
    );
  }
}

/// 本人が決めた行動を「次の一手」に追加する画面。AIの読み取り（提案など）を行動にするときは、元の行を初期値にする。
class ActionDialog extends StatefulWidget {
  const ActionDialog({
    super.key,
    required this.projects,
    this.from,
    this.allowUnassigned = false,
    this.unassigned = false,
    this.effortChoice = false,
    this.contextChoices,
  });

  /// 追加と一緒に手間の目安を選べる（対応した本体で、新しく足す行動のとき）。
  final bool effortChoice;

  /// 追加と一緒に選べる場所・道具の札（語彙）。nullなら札の欄を出さない。
  final List<String>? contextChoices;

  /// 追加先に選べるプロジェクト。1件で[allowUnassigned]でなければ、そのプロジェクトに決まっている。
  final List<HubProject> projects;

  /// 追加先に「プロジェクト未定」も選べる（本体が対応しているとき）。
  final bool allowUnassigned;

  /// 最初から「プロジェクト未定」を選んでおく（[allowUnassigned]のときだけ効く）。
  final bool unassigned;

  /// AIが読み取った行を行動にするときの元の行。
  final ActionSource? from;
  @override
  State<ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<ActionDialog> {
  late final text = TextEditingController(
    text: widget.from?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '',
  );
  late String project =
      widget.allowUnassigned && (widget.unassigned || widget.projects.isEmpty)
      ? unassignedScope
      : widget.projects.first.id;
  String? effort;
  List<String> contexts = const [];

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = text.text.trim(),
        valid = validActionText(value) && contexts.length <= contextTagsMax;
    return AlertDialog(
      key: const Key('action-dialog'),
      title: Text(widget.from == null ? '次の一手を追加' : '自分の行動にする'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.projects.length + (widget.allowUnassigned ? 1 : 0) ==
                  1)
                Text(
                  widget.projects.firstOrNull?.title ?? 'プロジェクト未定',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                )
              else
                DropdownButtonFormField<String>(
                  key: const Key('action-project'),
                  style: fieldTextStyle(context),
                  initialValue: project,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'プロジェクト'),
                  items: [
                    for (final p in widget.projects)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(p.title, overflow: TextOverflow.ellipsis),
                      ),
                    if (widget.allowUnassigned)
                      const DropdownMenuItem(
                        key: Key('action-project-unassigned'),
                        value: unassignedScope,
                        child: Text('プロジェクト未定'),
                      ),
                  ],
                  onChanged: (v) => setState(() => project = v ?? project),
                ),
              if (widget.from case final from?) ...[
                const SizedBox(height: 16),
                Text(
                  '元の行（AIの読み取り）: ${from.text}',
                  key: const Key('action-from'),
                  style: noteStyle(context),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const Key('action-text'),
                controller: text,
                autofocus: true,
                maxLines: 1,
                decoration: InputDecoration(
                  labelText: '次にやること（1行）',
                  helperText: '自分の言葉で書いてください。AIは書き換えません。',
                  // 本体の検査と同じ数え方（UTF-16の単位。絵文字などは2文字と数える）で示す。
                  counterText: '${value.length} / $actionTextChars',
                  errorText: value.isEmpty || valid
                      ? null
                      : '1行・$actionTextChars文字以内で入力してください。',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (widget.effortChoice) ...[
                const SizedBox(height: 16),
                fieldLabel(context, '手間の目安（任意）'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in itemEfforts)
                      ChoiceChip(
                        key: Key('action-effort-$e'),
                        label: Text(itemEffortLabels[e]!),
                        selected: effort == e,
                        onSelected: (on) =>
                            setState(() => effort = on ? e : null),
                      ),
                  ],
                ),
              ],
              if (widget.contextChoices case final choices?
                  when choices.isNotEmpty) ...[
                const SizedBox(height: 16),
                fieldLabel(context, '場所・道具の札（任意・いくつでも）'),
                ContextChips(
                  keyPrefix: 'action-context',
                  options: choices,
                  vocabulary: choices,
                  selected: contexts,
                  onChanged: (next) => setState(() => contexts = next),
                ),
                if (contexts.length > contextTagsMax)
                  Text(
                    '札は1つの項目に$contextTagsMax個までです。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              Text(
                project == unassignedScope
                    ? widget.from == null
                          ? '本人が追加した行動として、プロジェクト未定の次の一手に載ります。AIは書き換えず、完了か却下するまで残ります（期日は付けられません。後からプロジェクトへは移せません）。'
                          : '本人が追加した行動としてプロジェクト未定の次の一手に載り、元の行はAIの読み取りの欄から外れます。完了か却下するまで残ります（期日は付けられません）。'
                    : widget.from == null
                    ? '本人が追加した行動として、そのまま次の一手に載ります。AIは書き換えず、完了か誤りとして外すと報告するまで、新しい作業要約が届いても残ります。Mac miniで処理されると現状に反映されます。'
                    : '本人が追加した行動として次の一手に載り、元の行はAIの読み取りの欄から外れます。完了か誤りとして外すと報告するまで、新しい作業要約が届いても残ります。Mac miniで処理されると現状に反映されます。',
                style: noteStyle(context),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('action-submit'),
          onPressed: valid
              ? () => Navigator.pop(context, (
                  projectId: project,
                  text: value,
                  effort: widget.effortChoice ? effort : null,
                  contexts: widget.contextChoices != null && contexts.isNotEmpty
                      ? contexts
                      : null,
                ))
              : null,
          child: const Text('追加する'),
        ),
      ],
    );
  }
}

/// NOWの項目に期日と次に見直す日を付ける画面。日付は本人が選び、AIは推測しない。
class ScheduleDialog extends StatefulWidget {
  const ScheduleDialog({
    super.key,
    required this.item,
    this.repeatSupported = false,
  });
  final NowItemRef item;

  /// 本体が繰り返し（定例）に対応している。対応していなければ選ばせない。
  final bool repeatSupported;
  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  late final due = TextEditingController(text: widget.item.due ?? ''),
      review = TextEditingController(text: widget.item.reviewAfter ?? '');
  late RepeatRule? repeat = widget.item.repeat;

  @override
  void dispose() {
    due.dispose();
    review.dispose();
    super.dispose();
  }

  String? value(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();
  String? problem(TextEditingController c) {
    final v = value(c);
    return v == null || validScheduleDate(v)
        ? null
        : 'YYYY-MM-DDの実在する日で入力してください（2000〜2099年）。';
  }

  Widget field(String key, String label, String help, TextEditingController c) {
    final today = hubToday();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: Key('schedule-$key'),
          controller: c,
          decoration: InputDecoration(
            labelText: label,
            hintText: 'YYYY-MM-DD',
            helperText: help,
            helperMaxLines: 2,
            errorText: problem(c),
            suffixIcon: c.text.isEmpty
                ? null
                : IconButton(
                    key: Key('schedule-$key-clear'),
                    tooltip: '外す',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(c.clear),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, days) in [
              ('今日', 0),
              ('明日', 1),
              ('3日後', 3),
              ('1週間後', 7),
              ('2週間後', 14),
              ('30日後', 30),
            ])
              ActionChip(
                key: Key('schedule-$key-$days'),
                label: Text(label),
                onPressed: () =>
                    setState(() => c.text = addScheduleDays(today, days)),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final nextDue = value(due), nextReview = value(review);
    // 繰り返しは期日があるときだけ付く。期日を外すと繰り返しも外れる。
    final nextRepeat = nextDue == null
        ? null
        : widget.repeatSupported
        ? repeat
        : widget.item.repeat;
    final valid = problem(due) == null && problem(review) == null,
        changed =
            nextDue != widget.item.due ||
            nextReview != widget.item.reviewAfter ||
            nextRepeat != widget.item.repeat,
        clearing = nextDue == null && nextReview == null;
    final choices = {...RepeatRule.choices, ?widget.item.repeat}.toList();
    return AlertDialog(
      title: const Text('期日と次に見直す日'),
      content: SizedBox(
        width: 520,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.display,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              field('due', '期日（任意）', '過ぎた・今日・7日以内になると「次の一手」の先頭に出ます。', due),
              if (widget.repeatSupported) ...[
                const SizedBox(height: 14),
                const Text('繰り返し（定例）', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      key: const Key('schedule-repeat-none'),
                      label: const Text('なし'),
                      selected: nextRepeat == null,
                      onSelected: (_) => setState(() => repeat = null),
                    ),
                    for (final r in choices)
                      ChoiceChip(
                        key: Key('schedule-repeat-${r.unit}-${r.every}'),
                        label: Text(r.label),
                        selected: nextRepeat == r,
                        // 期日がなければ繰り返しは付けられない。
                        onSelected: nextDue == null
                            ? null
                            : (_) => setState(() => repeat = r),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  nextDue == null
                      ? '繰り返しは期日を入れると選べます。'
                      : '繰り返しを付けると、「今回を完了」「今回は見送る」で期日が次の回へ進み、項目は欄に残ります。毎月は期日の日を覚えます（短い月は月末）。',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              field(
                'review',
                '次に見直す日（任意）',
                'その日までは「次の一手」の末尾にたたみます。期日が近ければたたみません。',
                review,
              ),
              const SizedBox(height: 14),
              const Text(
                '日付はMac miniが処理すると現状とHOMEに反映されます。原文とAIの読み取り結果は変わりません。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('schedule-save'),
          onPressed: valid && changed
              ? () => Navigator.pop(context, (
                  due: nextDue,
                  reviewAfter: nextReview,
                  repeat: widget.repeatSupported ? nextRepeat : null,
                ))
              : null,
          child: Text(clearing ? '日付を外す' : '依頼する'),
        ),
      ],
    );
  }
}

class ProjectStatusDialog extends StatefulWidget {
  const ProjectStatusDialog({
    super.key,
    required this.project,
    this.outcomeSupported = true,
  });
  final HubProject project;

  /// 本体が望む結果に対応しているか。対応前の本体では書けないため、未記入の案内を出さない。
  final bool outcomeSupported;
  @override
  State<ProjectStatusDialog> createState() => _ProjectStatusDialogState();
}

class _ProjectStatusDialogState extends State<ProjectStatusDialog> {
  String? selected;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.project.title}の状態'),
    content: DialogScroll(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('現在: ${widget.project.lifecycleLabel}'),
          const SizedBox(height: 12),
          for (final status in projectLifecycles)
            if (status != widget.project.lifecycle)
              ListTile(
                key: Key('project-status-$status'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  selected == status
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(projectLifecycleLabels[status]!),
                onTap: () => setState(() => selected = status),
              ),
          // 完了・休止の判断の基準として、本人が書いた望む結果を添える。
          if (selected != null &&
              selected != 'active' &&
              (widget.outcomeSupported ||
                  widget.project.outcomeLines.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: NoticeBox(
                widget.project.outcomeLines.isEmpty
                    ? '望む結果は書かれていません。'
                    : '望む結果:\n${widget.project.outcomeLines.join('\n')}${selected == 'done' ? '\nこれを満たしたかを確かめてから完了にしてください。' : ''}',
                key: const Key('project-status-outcome'),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '休止・完了にすると、ホームの後ろにまとめて表示し、AIの帰属候補から外します。メモで明示したプロジェクトは引き続き使えます。依頼は保存され、Mac miniで処理されると反映されます。',
            style: noteStyle(context),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        key: const Key('project-status-submit'),
        onPressed: selected == null
            ? null
            : () => Navigator.pop(context, selected),
        child: const Text('変更を依頼'),
      ),
    ],
  );
}

/// 同じものを指すプロジェクトを、ほかのプロジェクトへ統合する確認画面。統合先を選ぶ。
class ProjectMergeDialog extends StatefulWidget {
  const ProjectMergeDialog({
    super.key,
    required this.project,
    required this.candidates,
  });

  /// 統合元（いま開いているプロジェクト）。
  final HubProject project;

  /// 統合先にできるプロジェクト（統合済みを除く）。
  final List<HubProject> candidates;
  @override
  State<ProjectMergeDialog> createState() => _ProjectMergeDialogState();
}

class _ProjectMergeDialogState extends State<ProjectMergeDialog> {
  HubProject? selected;
  bool confirmed = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('「${widget.project.title}」を統合'),
    content: SizedBox(
      width: 520,
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '同じものを指すプロジェクトが2つできたときに、このプロジェクトをもう一方へまとめます。',
              style: TextStyle(height: 1.6),
            ),
            const SizedBox(height: 12),
            if (widget.candidates.isEmpty)
              const NoticeBox('統合先にできるプロジェクトがありません。')
            else
              DropdownButtonFormField<String>(
                key: const Key('project-merge-into'),
                style: fieldTextStyle(context),
                initialValue: selected?.id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '統合先'),
                items: [
                  for (final p in widget.candidates)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        '${p.title}（${p.lifecycleLabel}）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) => setState(() {
                  selected = widget.candidates
                      .where((p) => p.id == id)
                      .firstOrNull;
                  confirmed = false;
                }),
              ),
            if (selected case final into?) ...[
              const SizedBox(height: 12),
              Text(
                [
                  '・「${widget.project.title}」は「統合済み」になり、ホームの後ろにまとめて表示します。定義とファイルは残ります。',
                  '・「${widget.project.title}」を指定したメモ・完了報告・日付は、「${into.title}」のものとして読みます。原文と記録は書き換えません。',
                  '・「${widget.project.title}」の名前・別名・キーワードを、「${into.title}」の別名・キーワードに足します。',
                  '・「${widget.project.title}」だけの方針は移しません。必要なものは統合先へ採用し直してください。',
                  '・あとで取り消せます。',
                ].join('\n'),
                key: const Key('project-merge-effects'),
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              CheckboxListTile(
                key: const Key('project-merge-confirm'),
                visualDensity: formTileDensity,
                horizontalTitleGap: formTileGap,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: confirmed,
                onChanged: (v) => setState(() => confirmed = v ?? false),
                title: Text(
                  '「${widget.project.title}」と「${into.title}」は同じものを指している',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
            Text(
              '依頼は保存され、Mac miniで処理されると反映されます。',
              style: noteStyle(context),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        key: const Key('project-merge-submit'),
        onPressed: selected == null || !confirmed
            ? null
            : () => Navigator.pop(context, selected),
        child: const Text('統合を依頼'),
      ),
    ],
  );
}

/// プロジェクトの名前・別名・キーワード（と望む結果）を編集する。別名とキーワードは1行に1つ。
/// 望む結果の欄は、本体が対応しているとき（[outcomeLimits]があるとき）だけ出す。
class ProjectDefinitionDialog extends StatefulWidget {
  const ProjectDefinitionDialog({
    super.key,
    required this.project,
    this.outcomeLimits,
  });
  final HubProject project;
  final ({int maxChars, int maxLines})? outcomeLimits;
  @override
  State<ProjectDefinitionDialog> createState() =>
      _ProjectDefinitionDialogState();
}

class _ProjectDefinitionDialogState extends State<ProjectDefinitionDialog> {
  late final title = TextEditingController(text: widget.project.title),
      aliases = TextEditingController(text: widget.project.aliases.join('\n')),
      keywords = TextEditingController(
        text: widget.project.keywords.join('\n'),
      ),
      outcome = TextEditingController(text: widget.project.outcome ?? '');

  /// 望む結果は、欄を書き換えたときだけ送る（手で書いた文を、ほかの変更のついでに整えて書き換えない）。
  ProjectDefinitionDraft get draft => ProjectDefinitionDraft(
    title: title.text,
    aliases: aliases.text.split('\n'),
    keywords: keywords.text.split('\n'),
    outcome:
        widget.outcomeLimits == null ||
            outcome.text == (widget.project.outcome ?? '')
        ? null
        : outcome.text,
    outcomeLimits: widget.outcomeLimits,
  );

  @override
  void initState() {
    super.initState();
    for (final t in [title, aliases, keywords, outcome]) {
      t.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    title.dispose();
    aliases.dispose();
    keywords.dispose();
    outcome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = draft,
        problem = next.problem,
        unchanged = next.sameAs(widget.project);
    final limits = widget.outcomeLimits;
    return AlertDialog(
      title: Text(
        limits == null
            ? '${widget.project.title}の呼び名とキーワード'
            : '${widget.project.title}の定義',
      ),
      content: SizedBox(
        width: 560,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'AIはメモをどのプロジェクトに結び付けるかを、名前・別名・キーワードから判断します。メモでよく使う呼び方や、このプロジェクトに特有の言葉を加えてください。',
                style: noteStyle(context),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('definition-title'),
                controller: title,
                maxLength: ProjectDefinitionDraft.maxTitleChars,
                decoration: const InputDecoration(labelText: '名前'),
              ),
              TextField(
                key: const Key('definition-aliases'),
                controller: aliases,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: '別名（1行に1つ）',
                  helperText:
                      '${next.aliases.length}/${ProjectDefinitionDraft.maxTerms}件',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('definition-keywords'),
                controller: keywords,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'キーワード（1行に1つ）',
                  helperText:
                      '${next.keywords.length}/${ProjectDefinitionDraft.maxTerms}件',
                ),
              ),
              if (limits != null) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const Key('definition-outcome'),
                  controller: outcome,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: '望む結果（任意）',
                    hintText: 'どうなればこのプロジェクトを完了にできるか',
                    helperText:
                        '${normalizeProjectOutcome(outcome.text).length}/${limits.maxChars}文字・${limits.maxLines}行まで。空にすると外します',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (problem != null)
                NoticeBox(problem, error: true)
              else
                Text(
                  '依頼は保存され、Mac miniで処理されると反映されます。プロジェクトを指定せずに保存したメモのうち、まだどのプロジェクトにも結び付いていないものは、次のAI読み取りで新しい定義に合わせて見直されます（AIを使います）。${limits == null ? '' : '望む結果もAIへ渡し、メモの結び付けと次の一手を読む手がかりにします。'}',
                  style: noteStyle(context),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('definition-submit'),
          onPressed: problem != null || unchanged
              ? null
              : () => Navigator.pop(context, next),
          child: const Text('変更を依頼'),
        ),
      ],
    );
  }
}

Future<void> showProjectCreate(BuildContext context, HubController c) async {
  if (c.composing) return;
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProjectCreateDialog(controller: c),
    );
  } finally {
    c.composing = false;
  }
}

/// 新しいプロジェクトの作成を依頼するフォーム。IDと操作IDはフォームを開いたときに決め、
/// 保存結果が不明なときは同じ操作IDで確認する。
class ProjectCreateDialog extends StatefulWidget {
  const ProjectCreateDialog({super.key, required this.controller});
  final HubController controller;
  @override
  State<ProjectCreateDialog> createState() => _ProjectCreateDialogState();
}

class _ProjectCreateDialogState extends State<ProjectCreateDialog> {
  final title = TextEditingController(),
      aliases = TextEditingController(),
      keywords = TextEditingController(),
      outcome = TextEditingController(),
      area = TextEditingController(),
      memo = TextEditingController();
  final operation = const Uuid().v4(), projectId = newProjectId();

  /// 本体が領域に対応していれば、選べる領域（語彙と、今のプロジェクトに付いている領域）。対応前の本体ではnull（欄を出さない）。
  List<String>? get areaChoices {
    final repo = widget.controller.repository;
    return repo != null && repo.intakeFeatures.areas ? repo.areasInUse : null;
  }

  /// 本体が望む結果に対応していれば、その上限。対応前の本体ではnull（欄を出さない）。
  ({int maxChars, int maxLines})? get outcomeLimits =>
      widget.controller.repository?.intakeFeatures.projectOutcome;
  String? error;
  CaptureResult? result;
  bool busy = false, locked = false;

  @override
  void dispose() {
    for (final c in [title, aliases, keywords, outcome, area, memo]) {
      c.dispose();
    }
    super.dispose();
  }

  NewProjectRequest get request => NewProjectRequest(
    operationId: operation,
    projectId: projectId,
    title: title.text.trim(),
    aliases: NewProjectRequest.splitNames(aliases.text),
    keywords: NewProjectRequest.splitNames(keywords.text),
    firstMemo: memo.text.trim().isEmpty ? '' : memo.text,
    outcome: outcomeLimits == null ? '' : outcome.text,
    outcomeLimits: outcomeLimits,
    area: areaChoices == null || area.text.trim().isEmpty
        ? null
        : normalizeArea(area.text),
  );

  Future<void> submit() async {
    if (busy) return;
    if (memo.text.trim().isNotEmpty) {
      final checked = await checkSecretsBeforeSave(
        context,
        memo.text,
        secrets: widget.controller.repository?.secretPolicy,
      );
      if (checked == null || !mounted) return;
      if (checked != memo.text) memo.text = checked;
    }
    final r = request, repo = widget.controller.repository;
    final problem =
        r.formatError ??
        (repo == null
            ? null
            : r.overlapError(
                repo.projects.values,
                repo.pendingProjectCreations,
              ));
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    setState(() {
      busy = true;
      locked = true;
      error = null;
    });
    try {
      final saved = await widget.controller.requestProjectCreate(r);
      if (mounted) setState(() => result = saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = HubController.message(e);
          // 依頼の記録（journal）を作る前に止まった場合（重なり・形式・状態）だけ、直して送り直せるようにする。
          // 記録後に結果が不明になった場合は、同じ内容・同じ操作IDで確認する。
          final journaled = widget.controller.pending.any(
            (p) => p.operationId == operation,
          );
          if (result == null && !journaled) locked = false;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    String key,
    TextEditingController controller,
    String label, {
    String? hint,
    int lines = 1,
    int? max,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: Key(key),
      controller: controller,
      readOnly: locked,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 4,
      maxLength: max,
      // 書き方の手がかりは、入力を始める前から読めるよう欄の下に出す（欄の中の薄い文字は、名前に隠れて見えない）。
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        alignLabelWithHint: lines > 1,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('新しいプロジェクト'),
      content: SizedBox(
        width: 620,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              fieldNote(
                context,
                '保存先: ${widget.controller.location?.name ?? ''}',
                top: 0,
              ),
              const SizedBox(height: 16),
              field('project-create-title', title, '名前', max: 200),
              field(
                'project-create-aliases',
                aliases,
                '別名（任意）',
                hint: 'カンマ・読点区切り。AIがメモを結び付ける手がかりになります',
              ),
              field(
                'project-create-keywords',
                keywords,
                'キーワード（任意）',
                hint: 'カンマ・読点区切り',
              ),
              if (outcomeLimits case final limits?)
                field(
                  'project-create-outcome',
                  outcome,
                  '望む結果（任意）',
                  // 上限は整えた後の文で数える（本体と同じ）。入力欄では切らず、送るときに確かめる。
                  hint:
                      'どうなればこのプロジェクトを完了にできるか（${limits.maxChars}文字・${limits.maxLines}行まで）',
                  lines: 2,
                ),
              if (areaChoices case final choices?) ...[
                field(
                  'project-create-area',
                  area,
                  '領域（任意）',
                  hint: '仕事・家・健康のような、責任を持つ範囲（$areaChars文字まで）',
                  max: areaChars,
                ),
                if (choices.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final a in choices)
                          ActionChip(
                            key: Key('project-create-area-$a'),
                            label: Text(a),
                            onPressed: locked
                                ? null
                                : () => setState(() => area.text = a),
                          ),
                      ],
                    ),
                  ),
              ],
              field(
                'project-create-memo',
                memo,
                '最初のメモ（任意）',
                hint: 'このプロジェクトのメモとして保存します',
                lines: 4,
                max: 8000,
              ),
              Text(
                '作成の依頼を保存します。Mac miniで処理されるとプロジェクト一覧に表示されます。名前・別名が既存のプロジェクトと重なる場合は作成されません。',
                style: noteStyle(context),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: NoticeBox(error!, error: true),
                ),
              if (result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: NoticeBox(
                    result!.saved
                        ? 'この端末に作成の依頼を保存しました'
                        : '保存確認待ちです。再送せず同じ操作を確認してください。',
                  ),
                ),
              if (locked && result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    '操作ID: $operation',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(result?.saved == true ? '閉じる' : 'フォームを閉じる'),
        ),
        if (result == null)
          FilledButton(
            key: const Key('project-create-submit'),
            onPressed: busy ? null : submit,
            child: const Text('作成を依頼'),
          ),
        if (result != null && !result!.saved)
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      final r = await widget.controller.confirm(operation);
                      if (mounted) setState(() => result = r);
                    } catch (e) {
                      if (mounted) {
                        setState(() => error = HubController.message(e));
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('同じ操作を確認'),
          ),
        if (busy)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    ),
  );
}

/// 次の一手を手順に分ける・直す・外す。1行に1つの手順を書く（2〜10個）。AIは手順を作らない。
/// 直すときは、先頭から変えていない手順の分だけ、終えた数を保つ。
class StepsDialog extends StatefulWidget {
  const StepsDialog({super.key, required this.item});
  final NowItemRef item;
  @override
  State<StepsDialog> createState() => _StepsDialogState();
}

class _StepsDialogState extends State<StepsDialog> {
  late final text = TextEditingController(
    text: widget.item.steps?.items.join('\n') ?? '',
  );

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  List<String> get lines => [
    for (final l in text.text.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];

  /// 送る手順の全体。規則に合わなければnull。
  ItemSteps? get next {
    final items = lines, old = widget.item.steps;
    if (!validStepItems(items)) return null;
    var kept = 0;
    while (old != null &&
        kept < old.done &&
        kept < items.length &&
        kept < old.items.length &&
        old.items[kept] == items[kept]) {
      kept++;
    }
    return ItemSteps(items, kept);
  }

  String? get problem {
    final items = lines;
    if (items.isEmpty) return null;
    if (items.length < itemStepsMin) return '手順は$itemStepsMinつ以上にしてください。';
    if (items.length > itemStepsMax) return '手順は$itemStepsMax個までです。';
    if (!items.every(validActionText)) {
      return '手順は1つ$actionTextChars文字以内にしてください。';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final steps = next, old = widget.item.steps;
    return AlertDialog(
      key: const Key('steps-dialog'),
      title: Text(old == null ? '手順に分ける' : '手順を直す'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.item.display, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                key: const Key('steps-input'),
                controller: text,
                minLines: 4,
                maxLines: 12,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '手順（1行に1つ、$itemStepsMin〜$itemStepsMax個）',
                  hintText: '医療費の領収書を集める\nふるさと納税の受領証を探す\ne-Taxで下書きする\n提出する',
                  alignLabelWithHint: true,
                  errorText: problem,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                steps == null
                    ? '次の一手の一覧には、今の1歩だけが出ます。'
                    : '次の一手の一覧には「${steps.label}」と出ます。${old != null && steps.done > 0 ? '（変えていない先頭の${steps.done}つは終えたままにします）' : ''}',
                style: noteStyle(context),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (old != null)
          TextButton(
            key: const Key('steps-clear'),
            onPressed: () => Navigator.pop(context, (steps: null)),
            child: const Text('手順を外す'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('steps-submit'),
          onPressed: steps == null || steps == old
              ? null
              : () => Navigator.pop(context, (steps: steps)),
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}

/// プロジェクトの領域を選ぶ（語彙から選ぶか、新しく書く）。外すこともできる。語彙の一覧はここから編集できる。
class AreaDialog extends StatefulWidget {
  const AreaDialog({
    super.key,
    required this.current,
    required this.choices,
    required this.editVocabulary,
  });
  final String? current;

  /// 選べる領域（語彙と、今のプロジェクトに付いている領域）。語彙を編集した後に読み直す。
  final List<String> Function() choices;
  final Future<bool> Function() editVocabulary;
  @override
  State<AreaDialog> createState() => _AreaDialogState();
}

class _AreaDialogState extends State<AreaDialog> {
  late final input = TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  String get value => normalizeArea(input.text);

  @override
  Widget build(BuildContext context) {
    final v = value,
        valid = validArea(v),
        choices = widget.choices();
    return AlertDialog(
      key: const Key('area-dialog'),
      title: const Text('領域'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (choices.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in choices)
                      ChoiceChip(
                        key: Key('area-choice-$a'),
                        label: Text(a),
                        selected: v == a,
                        onSelected: (_) => setState(() => input.text = a),
                      ),
                  ],
                ),
              TextField(
                key: const Key('area-input'),
                controller: input,
                maxLength: areaChars,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '領域（例: 仕事・家・健康・お金）',
                  errorText: v.isEmpty || valid
                      ? null
                      : '1行・$areaChars文字までで、「$noAreaLabel」は使えません。',
                ),
              ),
              TextButton(
                key: const Key('area-vocabulary-edit'),
                onPressed: () async {
                  if (await widget.editVocabulary() && mounted) setState(() {});
                },
                child: const Text('領域の一覧と並びを編集'),
              ),
              Text(
                '領域は、プロジェクトをまとめる責任の範囲です。ホームと週次レビューで領域ごとにまとまります。AIは領域を付けません。',
                style: noteStyle(context),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            key: const Key('area-clear'),
            onPressed: () => Navigator.pop(context, (area: null)),
            child: const Text('領域を外す'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('area-submit'),
          onPressed: !valid || v == widget.current
              ? null
              : () => Navigator.pop(context, (area: v)),
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}

/// 領域の一覧（語彙）と並びを編集する。並びはホームと週次レビューの領域の順になる。
class AreaVocabularyDialog extends StatefulWidget {
  const AreaVocabularyDialog({
    super.key,
    required this.current,
    this.pending = false,
  });
  final List<String> current;
  final bool pending;
  @override
  State<AreaVocabularyDialog> createState() => _AreaVocabularyDialogState();
}

class _AreaVocabularyDialogState extends State<AreaVocabularyDialog> {
  late final List<String> items = [...widget.current];
  final input = TextEditingController();
  String? error;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void add() {
    final a = normalizeArea(input.text);
    setState(() {
      if (a.isEmpty) {
        error = null;
      } else if (!validArea(a)) {
        error = '領域は1行・$areaChars文字までで、「$noAreaLabel」は使えません。';
      } else if (items.contains(a)) {
        error = '同じ領域が一覧にあります。';
      } else if (items.length >= areaVocabularyMax) {
        error = '領域の一覧は$areaVocabularyMax個までです。';
      } else {
        items.add(a);
        input.clear();
        error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('area-vocabulary-dialog'),
    title: const Text('領域の一覧'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.pending)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '前の変更がまだMac miniで処理されていません（その一覧を表示しています）。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            for (final (i, a) in items.indexed)
              Row(
                key: Key('area-vocabulary-row-$a'),
                children: [
                  Expanded(child: Text(a)),
                  IconButton(
                    key: Key('area-vocabulary-up-$a'),
                    tooltip: '上へ',
                    onPressed: i == 0
                        ? null
                        : () => setState(() {
                            items.removeAt(i);
                            items.insert(i - 1, a);
                          }),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                  IconButton(
                    key: Key('area-vocabulary-remove-$a'),
                    tooltip: '一覧から外す',
                    onPressed: () => setState(() => items.removeAt(i)),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('area-vocabulary-input'),
                    controller: input,
                    maxLength: areaChars,
                    decoration: InputDecoration(
                      labelText: '新しい領域（例: 仕事・家・健康・お金）',
                      errorText: error,
                    ),
                    onSubmitted: (_) => add(),
                  ),
                ),
                IconButton(
                  key: const Key('area-vocabulary-add'),
                  tooltip: '足す',
                  onPressed: add,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Text(
              'この一覧と並びは同じVaultを使うすべての端末で共有し、ホームと週次レビューの領域の順になります。一覧から外しても、その領域が付いているプロジェクトからは消えません。',
              style: noteStyle(context),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('やめる'),
      ),
      FilledButton(
        key: const Key('area-vocabulary-submit'),
        onPressed: listEquals(items, widget.current)
            ? null
            : () => Navigator.pop(context, [...items]),
        child: const Text('依頼する'),
      ),
    ],
  );
}
