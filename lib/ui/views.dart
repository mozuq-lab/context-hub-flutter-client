import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'package:uuid/uuid.dart';
import '../app/controller.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../core/secrets.dart';
import '../core/templates.dart';
import '../core/today.dart';
import '../storage/capture_service.dart';
import '../storage/basket_store.dart';
import '../storage/draft_store.dart';
import 'markdown_view.dart';
import 'template_view.dart';
import 'review_view.dart';
import 'guided_view.dart';
import 'shortcuts.dart';
import 'notice.dart';
import 'shell_scope.dart';

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
          'Inputへ保存したメモは、同期先のすべての端末とバックアップに残り、後から消せません（訂正しても元のメモは残ります）。'
          '整理用のAIへは伏せ字にして渡しますが、本当に秘密の値なら「伏せ字にして保存」を選んでください。',
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
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    color: error
        ? Theme.of(context).colorScheme.errorContainer
        : Theme.of(context).colorScheme.secondaryContainer,
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: error ? Theme.of(context).colorScheme.onErrorContainer : null,
      ),
    ),
  );
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

  Widget title(String eyebrow, String text, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.4,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          text,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -.6,
          ),
        ),
        const SizedBox(height: 10),
        Text(subtitle, style: const TextStyle(height: 1.7)),
      ],
    ),
  );

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

  Widget recordCard(
    HubRecord r, {
    Key? key,
    List<String>? words,
    String? badge,
  }) => Card(
    key: key,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${words == null ? '' : '${searchKindLabels[HubRepository.searchKindOf(r)] ?? r.kind} · '}${originLabel(r.origin)} · ${stateLabel(r.status)}\n${timeLabel(r.at ?? r.generatedAt)}',
              style: const TextStyle(fontSize: 12, height: 1.7),
            ),
            if (badge != null)
              Text(
                badge,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.7,
                  color: Theme.of(context).colorScheme.tertiary,
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
                      Theme.of(context).colorScheme.primaryContainer,
                    ),
                  ),
                  style: const TextStyle(fontSize: 13, height: 1.6),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (HubRepository.bundleKinds.contains(r.kind))
            BasketToggle(controller: c, record: r),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => open(r.id),
    ),
  );
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
            'Vaultの記録が多く、アプリが一度に読める上限に達しました。一部の記録を読めていないため、整理済みのメモが「未整理」に見えたり、確認待ちの候補や方針が欠けたりすることがあります。文脈のコピーは止まります。Vaultの記録そのものは失われていません。',
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
    } else if (page == 'digest') {
      children.addAll(digestView());
    } else if (page == 'next') {
      children.addAll(nextView());
    } else if (page == 'home') {
      children.add(
        title(
          'YOUR CONTEXT',
          '今日、どこから始める？',
          '${repo.projects.length}プロジェクト · ${repo.recent.length}件のメモ\n読込: ${timeLabel(repo.snapshot.loadedAt)}（同期完了の確認ではありません）',
        ),
      );
      final backupNow = DateTime.now();
      for (final (index, warning) in repo.backup.warnings(backupNow).indexed) {
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
      if (repo.backup.line(backupNow) case final line?) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              line,
              key: const Key('home-backup'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      }
      // 本人が今日やると決めたものを、いちばん上に置く。
      children.addAll(todaySection(compact: true));
      // 今週の気づきは、行動につながる欄（次の一手）より前に置く。
      children.addAll(insightsHome());
      final actionable = repo.actionableProjects,
          nextCount = actionable.fold<int>(0, (n, p) => n + p.nextCount),
          nextProjects = actionable.where((p) => p.nextCount > 0).length;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Card(
            child: ListTile(
              key: const Key('home-next'),
              leading: const Icon(Icons.checklist_outlined),
              title: Text('次の一手 $nextCount件'),
              subtitle: Text(
                nextCount == 0
                    ? '進行中のプロジェクトに次の一手はありません'
                    : '進行中の$nextProjectsプロジェクトから · 終わったらその場で完了を報告',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onNavigate('next'),
            ),
          ),
        ),
      );
      if (repo.unassignedMemos.isNotEmpty) {
        // プロジェクトに結び付いていないメモの行動は、どのプロジェクトの次の一手にも出ない。ここで拾う。
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    key: const Key('home-unassigned'),
                    leading: const Icon(Icons.lightbulb_outline),
                    title: Text('プロジェクト未定の次の一手 メモ${repo.unassignedTotal}件'),
                    subtitle: const Text(
                      'プロジェクトに結び付いていないメモの、タスク候補とAIの提案（未検証） · 完了の報告はできません',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      nextSection = 'next';
                      widget.onNavigate('next');
                    },
                  ),
                  for (final memo in repo.unassignedMemos.take(homeUnassigned))
                    ListTile(
                      key: Key('home-unassigned-${memo.inputId}'),
                      dense: true,
                      contentPadding: const EdgeInsets.fromLTRB(72, 0, 16, 0),
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
                ],
              ),
            ),
          ),
        );
      }
      final now = DateTime.now();
      if (repo.projects.isEmpty) {
        children.add(const Text('プロジェクトはまだありません。メモはproject未指定でも追加できます。'));
      }
      // 統合済みのプロジェクトは変化の印を出さないので、件数にも数えない。
      final changed = repo.projects.values
          .where((p) => !p.merged && c.changesSince(p)?.isEmpty == false)
          .length;
      if (changed > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '前回見てから変化のあったプロジェクト $changed件',
                    key: const Key('home-changes'),
                  ),
                ),
                TextButton(
                  key: const Key('mark-all-seen'),
                  onPressed: markAllSeen,
                  child: const Text('すべて既読にする'),
                ),
              ],
            ),
          ),
        );
      }
      final mergedProjects = repo.projects.values
          .where((p) => p.merged)
          .toList();
      // 統合済みのプロジェクトは後ろの「統合済み」にまとめるので、ピン留めの先頭には数えない。
      final pinnedCount = repo.pinnedProjects.where((p) => !p.merged).length;
      if (pinnedCount > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'ピン留め $pinnedCount件を先頭に表示（この端末だけの並び）',
                    key: const Key('home-pins'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  key: const Key('reorder-pins'),
                  onPressed: reorderPins,
                  child: const Text('並び替え'),
                ),
              ],
            ),
          ),
        );
      }
      for (final project in repo.orderedProjects.where((p) => !p.merged)) {
        final pinned = repo.isPinned(project.id);
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                key: Key('project-${project.id}'),
                contentPadding: const EdgeInsets.fromLTRB(24, 24, 12, 24),
                title: Text(
                  project.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // 本人が追加して反映待ちの行動は、本体と同じく作業要約の次の一手より前に示す。
                        project.pendingActions.firstOrNull?.text != null
                            ? '$actionLabel${project.pendingActions.first.text}（反映待ち）'
                            : project.sections['next']?.firstOrNull?.text ??
                                  '次の一手はまだ整理されていません。',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        projectStatusLine(project, now),
                        key: Key('project-status-${project.id}'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (changeLabel(c.changesSince(project))
                          case final label?)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            label,
                            key: Key('project-changes-${project.id}'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      if (project.drafts.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '作業記録の下書き ${project.drafts.length}件',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('pin-${project.id}'),
                      tooltip: pinned ? 'ピン留めを外す' : 'ピン留めして先頭に表示',
                      isSelected: pinned,
                      onPressed: () => togglePin(project),
                      icon: const Icon(Icons.push_pin_outlined, size: 20),
                      selectedIcon: const Icon(Icons.push_pin, size: 20),
                    ),
                    const Icon(Icons.arrow_forward),
                  ],
                ),
                onTap: () => widget.onNavigate('project:${project.id}'),
              ),
            ),
          ),
        );
      }
      if (mergedProjects.isNotEmpty) {
        // 統合済みのプロジェクトは入力を統合先のものとして読むため、小さくまとめて統合先を示す。
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                      child: Text(
                        '統合済み（${mergedProjects.length}件）',
                        key: const Key('merged-projects'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    for (final project in mergedProjects)
                      ListTile(
                        key: Key('project-${project.id}'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                        ),
                        title: Text(project.title),
                        subtitle: Text(
                          projectStatusLine(project, now),
                          key: Key('project-status-${project.id}'),
                        ),
                        trailing: const Icon(Icons.arrow_forward, size: 18),
                        onTap: () => widget.onNavigate('project:${project.id}'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      // 確認待ちは、同じ対象を指すプロジェクト案を1件と数える。
      // プロジェクト案は、根拠のメモが多いものから数件をここに出す（依頼を保存済みのものは除く）。
      final review = c.review!,
          proposals = [
            for (final (index, item) in review.pendingRows.indexed)
              if (item.kind == 'project' &&
                  review.requestIdFor(item.id) == null)
                (index, item, review.groupMembers(item).length + 1),
          ]..sort((a, b) => b.$3 != a.$3 ? b.$3 - a.$3 : a.$1.compareTo(b.$1));
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 20),
          child: Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  key: const Key('home-review'),
                  leading: const Icon(Icons.fact_check_outlined),
                  title: Text('確認待ち ${review.pendingRows.length}件'),
                  subtitle: Text(
                    '要確認 ${review.attention.length}件 · 採用前に内容と元のメモを確認',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onNavigate('review'),
                ),
                for (final (_, item, memos) in proposals.take(homeProposals))
                  ListTile(
                    key: Key('home-proposal-${item.id}'),
                    dense: true,
                    contentPadding: const EdgeInsets.fromLTRB(72, 0, 16, 0),
                    title: Text(
                      '「${item.title}」をプロジェクトにしますか？',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('AIのプロジェクト案・未承認 · 根拠のメモ$memos件'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
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
              ],
            ),
          ),
        ),
      );
      final stale = repo.projects.values.where((p) => p.stale(now)).length;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Card(
            child: ListTile(
              key: const Key('home-digest'),
              leading: const Icon(Icons.event_note_outlined),
              title: Text(
                repo.digestDocument == null
                    ? 'ふりかえり（未生成）'
                    : '直近${repo.digestDocument!.periodDays ?? 7}日のふりかえり',
              ),
              subtitle: Text(
                stale == 0
                    ? '動いたプロジェクトと現在地の変化を確認'
                    : '停滞しているプロジェクト $stale件 · 再開か休止・完了かを判断',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onNavigate('digest'),
            ),
          ),
        ),
      );
      children.add(const SizedBox(height: 8));
      children.add(
        const Text(
          '最近のメモ',
          key: Key('home-recent'),
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      );
      children.add(const SizedBox(height: 12));
      children.addAll(
        repo.recent
            .take(5)
            .map(
              (r) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: recordCard(r),
              ),
            ),
      );
      // 受付と整理の状況は1行にまとめ、詳細は「受付状況」で見る。
      if (repo.intake.isNotEmpty || c.pending.isNotEmpty) {
        final waiting = repo.intake.where((s) => s.state == 'waiting').length,
            failing = repo.intake
                .where(
                  (s) => const [
                    'failed',
                    'rejected',
                    'conflict',
                  ].contains(s.state),
                )
                .length;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InkWell(
              key: const Key('home-status'),
              onTap: () => widget.onNavigate('intake'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '受付状況: Mini受領待ち $waiting件 · 失敗・競合 $failing件 · 保存確認待ち ${c.pending.length}件（詳細は「受付状況」）',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        );
      }
    } else if (page == 'search') {
      children.addAll(searchView());
    } else if (page == 'basket') {
      children.addAll(basketView());
    } else if (page == 'intake') {
      children.add(
        title(
          'CAPTURE STATUS',
          '受付状況',
          'Input保存、Mini受領、整理はそれぞれ別の段階です。同期後に再読込してください。',
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
                                  ? 'この端末のInputに保存されています'
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
        children.add(const Text('この端末に受付ファイルはありません。'));
      }
      for (final status in repo.intake) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                title: Text(stateLabel(status.state)),
                subtitle: Text(
                  '${status.title}\n${timeLabel(status.at)}\n${status.detail}',
                  style: const TextStyle(height: 1.7),
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: Text(stateLabel(status.state)),
                      content: SelectableText('${status.id}\n${status.detail}'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('閉じる'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      }
    } else {
      final ideas = page == 'ideas';
      final records = ideas ? repo.ideas : repo.recent;
      children.add(
        title(
          ideas ? 'IDEAS' : 'RECENT NOTES',
          ideas ? 'アイデア' : '最近のメモ',
          ideas ? '原文に戻りながら、育てたいアイデアを探します。' : '雑な思いつきも、作業の記録も、そのまま残せます。',
        ),
      );
      if (records.isEmpty) {
        children.add(const Text('まだ記録がありません。'));
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '${records.length}件（新しい順）',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      }
      children.addAll(
        records
            .take(shown)
            .map(
              (r) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: recordCard(r, badge: ideas ? ideaBadge(r) : null),
              ),
            ),
      );
      children.add(moreButton(records.length));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          key: ValueKey('${c.location?.handle}:$page'),
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 20 : 40,
          ),
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
        'CONTEXT BASKET',
        '文脈かご',
        '別のAIに渡したい記録を、検索・最近のメモ・アイデア・記録の詳細から入れます。プロジェクトをまたいで選べます。まとめてコピーすると、選んだ順に、出典・訂正の注意・AI推定の区別と、関わるプロジェクトの方針を付けた1つの文章になります。かごの中身はこの端末だけに残し、Vaultには書きません。',
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
        style: const TextStyle(fontSize: 12, height: 1.7),
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
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i], record = repo.records[id];
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            key: Key('basket-item-$i'),
            child: ListTile(
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
                      '${searchKindLabels[HubRepository.searchKindOf(record)] ?? record.kind} · ${originLabel(record.origin)} · ${timeLabel(record.at ?? record.generatedAt)}'
                      '${(repo.correctionChainOf(id)?.length ?? 1) > 1 ? '\n訂正あり（最新の訂正の本文を渡します）' : ''}',
                      style: const TextStyle(fontSize: 12, height: 1.7),
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
          ),
        ),
      );
    }
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
    final out = <Widget>[
      title(
        'FIND A THOUGHT',
        '検索',
        'タイトルと本文を検索します。複数の語は空白で区切ります。プロジェクト・種類・期間で絞り込むと、語を入れなくても一覧できます。',
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
    out.add(Text('${results.length}件', key: const Key('search-count')));
    out.add(const SizedBox(height: 12));
    for (final r in results.take(shown)) {
      final estimated =
          searchProject != null &&
          repo.projectRelation(r, searchProject!) == 'estimated';
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: recordCard(
            r,
            key: const Key('search-result'),
            words: words,
            badge: estimated ? 'AI推定の関連（帰属未確定）' : null,
          ),
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

  List<Widget> digestView() {
    final digest = repo.digestDocument;
    if (digest == null) {
      return [
        title(
          'REVIEW',
          'ふりかえり',
          '本体のcycleまたはdigestがVaultのREVIEW.mdを生成すると、ここに表示されます。',
        ),
        const Text('ふりかえりはまだ生成されていません。'),
      ];
    }
    return [
      title(
        'REVIEW',
        '直近${digest.periodDays ?? 7}日のふりかえり',
        '生成: ${timeLabel(digest.generatedAt)}\n読込: ${timeLabel(repo.snapshot.loadedAt)}（同期完了の確認ではありません）',
      ),
      for (final warning in digest.warnings)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(warning),
        ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
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
                'NOWの更新が止まっています',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'NOWの自動で作られる部分が手で書き換えられているため、${timeLabel(project.generatedAt)}の生成から更新されていません。'
                '下の内容は止まった時点のものです${conflict.count > 1 ? '（新しい版の退避${conflict.count}件）' : ''}。',
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 10),
              Text(
                lines.isEmpty
                    ? '手で変えた行は見つかりませんでした（行の削除や並べ替えだけの可能性があります）。'
                    : '手で変えた行${conflict.comparedWithGenerated ? '' : '（最新の生成版との違い。生成側の変化も含みます）'}:',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final line in lines.take(shown))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
              if (lines.length > shown)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'ほか${lines.length - shown}行',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              if (requested)
                const NoticeBox(
                  '生成版に戻す依頼を送りました。Miniで受け付けられ、同期されると最新のNOWが表示されます。',
                )
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
      'NOWを生成版に戻す',
      '${conflict.manualLines.isEmpty ? '' : '手で変えた${conflict.manualLines.length}行を、このプロジェクトのメモとして保存してから、'}'
          'Miniが最新の入力からNOWを作り直します。NOWの自動で作られる部分の外に書いたメモは残ります。'
          '置き換える前のNOWの全文は本体の記録に残ります。',
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
              ? '生成版に戻す依頼を保存しました。Miniで受け付けられると反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
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
      builder: (_) => ProjectStatusDialog(project: project),
    );
    if (status == null || !mounted) return;
    try {
      final result = await c.requestProjectStatus(project.id, hash, status);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '状態の変更を依頼しました。Miniで受け付けられると反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
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
      builder: (_) => ProjectDefinitionDialog(project: project),
    );
    if (next == null || !mounted) return;
    try {
      final result = await c.requestProjectDefinition(project.id, hash, next);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '呼び名とキーワードの変更を依頼しました。Miniで受け付けられると反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
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
              ? '統合を依頼しました。Miniで受け付けられると反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
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
              ? '統合の取り消しを依頼しました。Miniで受け付けられると反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
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
        verb = item.section == 'next' ? '完了' : '解決';
    // 外したときに起きたこと（読み直し・関連の変更）だけを、元に戻ると伝える。
    final undo = switch (item.exclusionReason) {
      'misread' => '誤りとして外したときのメモの読み直しも元に戻ります。',
      'wrong-project' when !repo.itemOwnedByProject(project.id, item) =>
        '誤りとして外したときのメモの読み直しと、このプロジェクトとの関連の変更も元に戻ります。',
      _ => '',
    };
    if (!await confirmAction(
          resolve ? '$verbにする' : '未解決に戻す',
          '${item.display}\n\n${resolve ? 'この項目をNOWの「解決済み・完了」へ移すよう依頼します。原文と整理結果は変わりません。' : 'この項目をNOWの元の欄へ戻すよう依頼します。$undo'}',
          resolve ? '$verbにする' : '戻す',
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
              ? '報告を保存しました。Miniで受け付けられるとNOWに反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
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
              ? '報告を保存しました。Miniで受け付けられるとNOWに反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 本人が決めた行動を次の一手に追加する。[project]を渡すとそのプロジェクトに決まり、渡さないと進行中のプロジェクトから選ぶ。
  /// [from]はAIが読み取った行（提案・作業要約の次の一手）を行動にするときの元の行。
  Future<void> addAction({HubProject? project, ActionSource? from}) async {
    final choices = project != null
        ? [project]
        : repo.actionableProjects.where((p) => !p.merged).toList();
    if (choices.isEmpty) {
      notice(context, '追加できる進行中のプロジェクトがありません。');
      return;
    }
    final value = await showDialog<({String projectId, String text})>(
      context: context,
      builder: (_) => ActionDialog(projects: choices, from: from),
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
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '次の一手への追加を保存しました。Miniで受け付けられるとNOWに反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 反映待ちの行動の1行。
  Widget pendingActionRow(PendingAction action) => Padding(
    key: Key('pending-action-${action.requestId}'),
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$actionLabel${action.text}',
          style: const TextStyle(fontSize: 15),
        ),
        Text(
          '反映待ち（${stateLabel(action.state)}）',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
  );

  /// 期日・見直す日を依頼する。依頼を保存できたらtrue。
  Future<bool> scheduleItem(HubProject project, NowItemRef item) async {
    final value = await showDialog<({String? due, String? reviewAfter})>(
      context: context,
      builder: (_) => ScheduleDialog(item: item),
    );
    if (value == null || !mounted) return false;
    try {
      final result = await c.requestItemSchedule(
        project.id,
        item.key,
        value.due,
        value.reviewAfter,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '日付を依頼しました。Miniで受け付けられるとNOWと一覧に反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// 本体が生成するプロジェクトの経緯（HISTORY.md）を開く。
  void showHistory(HubProject project) =>
      showGenerated(project, project.history, '経緯', 'HISTORY.md', 'history');

  /// 本体が生成するプロジェクトの資料（REFERENCES.md）を開く。
  /// URLは本文のリンクとして示し、押したときだけ外部のブラウザで開く（http・httpsだけ）。
  void showShelf(HubProject project) =>
      showGenerated(project, project.shelf, '資料', 'REFERENCES.md', 'shelf');

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
          appBar: AppBar(
            title: Text('${project.title}の$label'),
            actions: const [HubMenuButton()],
          ),
          body: ListView(
            key: Key('$keyName-view'),
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '生成: ${timeLabel(history.generatedAt)}\n読込: ${timeLabel(loadedAt)}（同期完了の確認ではありません）',
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 12),
              for (final warning in history.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: NoticeBox(warning),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
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
              ? '見送りを保存しました。Miniで受け付けられるとNOWに反映されます。'
              : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
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
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text('見送り済み（反映待ち）', style: TextStyle(fontSize: 12)),
                )
              else
                TextButton.icon(
                  key: Key('dismiss-hint-${item.key.substring(0, 12)}'),
                  onPressed: busy
                      ? null
                      : () => dismissHint(project, item, hint),
                  icon: const Icon(Icons.close, size: 15),
                  label: const Text('違う'),
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
          result.saved ? '見送りを依頼しました。' : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  bool get busy => c.loading || c.saving || c.captureWarning != null;

  /// 「今日やる」「今日から外す」。選んだ項目はこの端末だけに残し、Vaultには書かない。
  Widget todayToggle(HubProject project, String key) {
    final focus = c.today, on = focus.picked(key);
    return TextButton.icon(
      key: Key('today-${key.substring(0, 12)}'),
      // 3つ埋まっている間は、外す操作だけを受け付ける。
      onPressed: !on && focus.full
          ? null
          : () => setToday(project.id, key, !on),
      icon: Icon(on ? Icons.wb_sunny : Icons.wb_sunny_outlined, size: 15),
      label: Text(on ? '今日から外す' : '今日やる'),
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
    if (!await scheduleItem(entry.project!, entry.item!)) return;
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
        e.project?.title ?? e.pick.projectId,
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
          finished = e.done || reported;
      return Padding(
        key: Key('today-pick-${key.substring(0, 12)}'),
        padding: const EdgeInsets.only(bottom: 10),
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
                'NOWから見つかりません。言い換えられたか、片付いた可能性があります。',
                style: TextStyle(fontSize: 12, color: scheme.error),
              )
            else if (e.done)
              Text(
                e.item!.excluded ? '誤りとして外しました' : '片付きました',
                style: const TextStyle(fontSize: 12),
              )
            else if (reported)
              const Text('報告済み（反映待ち）', style: TextStyle(fontSize: 12)),
            Wrap(
              spacing: 8,
              children: [
                if (!finished && !e.missing)
                  TextButton.icon(
                    key: Key('today-resolve-${key.substring(0, 12)}'),
                    onPressed: busy
                        ? null
                        : () => reportItem(e.project!, e.item!, 'resolve'),
                    icon: const Icon(Icons.check_circle_outline, size: 15),
                    label: Text(e.item!.section == 'next' ? '完了にする' : '解決にする'),
                  ),
                TextButton.icon(
                  key: Key('today-remove-${key.substring(0, 12)}'),
                  onPressed: () => setToday(e.pick.projectId, key, false),
                  icon: const Icon(Icons.close, size: 15),
                  label: const Text('今日から外す'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    Widget carryRow(TodayEntry e) {
      final key = e.pick.itemKey,
              // 日付が変わった後に片付いた・報告した項目は、続けたり日付を付けたりできない。
              closed =
              e.missing || e.done || repo.itemRequestIdFor(key) != null;
      return Padding(
        key: Key('today-carry-${key.substring(0, 12)}'),
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            projectLink(e),
            Text(e.text),
            if (e.missing)
              Text(
                'NOWから見つかりません。言い換えられたか、片付いた可能性があります。',
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
            Wrap(
              spacing: 8,
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
                if (!closed && repo.scheduleRequestIdFor(key) == null)
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
                  label: const Text('外す'),
                ),
              ],
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
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '前の日から持ち越した項目（${carry.length}件）',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    focus.full
                        ? '今日の3つは埋まっています。続けるなら、先に今日の3つから外してください。'
                        : '今日も続けるか、期日を付けるか、外すかを選んでください。',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  for (final e in carry) carryRow(e),
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
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '今日の3つ（${picks.length}/$todayMax）',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final e in picks) pickRow(e),
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
            style: const TextStyle(fontSize: 12),
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
    if (repo.itemRequestIdFor(entry.itemKey!) != null) return null;
    final item = project.nowItems
        .where((i) => i.key == entry.itemKey)
        .firstOrNull;
    if (item == null || item.action || item.resolved) return null;
    return ActionSource(inputId: item.inputId, text: item.text, key: item.key);
  }

  /// NOWの1行。プロジェクト画面と「次の一手」画面で共通に使う。
  Widget nowEntry(
    HubProject project,
    String section,
    NowEntry entry,
    Set<String> added,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
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
          Text(
            warning,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        if (entry.itemKey case final key?)
          if (project.nowItems.where((i) => i.key == key).firstOrNull
              case final item?)
            for (final hint in item.hints) hintBox(project, item, hint),
        Wrap(
          spacing: 8,
          children: [
            if (entry.itemKey case final key?)
              repo.itemRequestIdFor(key) != null
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('報告済み（反映待ち）', style: TextStyle(fontSize: 12)),
                    )
                  : TextButton.icon(
                      key: Key('resolve-${key.substring(0, 12)}'),
                      onPressed: busy
                          ? null
                          : () => reportItem(
                              project,
                              project.nowItems.firstWhere((i) => i.key == key),
                              'resolve',
                            ),
                      icon: const Icon(Icons.check_circle_outline, size: 15),
                      label: Text(section == 'next' ? '完了にする' : '解決にする'),
                    ),
            // 完了・解決の報告が反映待ちの間は、日付を依頼させない（本体が断るため）。
            if (entry.itemKey case final key?
                when repo.itemRequestIdFor(key) == null)
              repo.scheduleRequestIdFor(key) != null
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        '日付を依頼済み（反映待ち）',
                        style: TextStyle(fontSize: 12),
                      ),
                    )
                  : TextButton.icon(
                      key: Key('schedule-${key.substring(0, 12)}'),
                      onPressed: busy
                          ? null
                          : () => scheduleItem(
                              project,
                              project.nowItems.firstWhere((i) => i.key == key),
                            ),
                      icon: const Icon(Icons.event_outlined, size: 15),
                      label: Text(
                        project.nowItems
                                    .where((i) => i.key == key)
                                    .firstOrNull
                                    ?.scheduled ==
                                true
                            ? '日付を変える'
                            : '日付を付ける',
                      ),
                    ),
            // 今日の3つ（この端末だけ）。報告が反映待ちの項目は選ばせない。
            if (entry.itemKey case final key?
                when repo.itemRequestIdFor(key) == null)
              todayToggle(project, key),
            // 報告が反映待ちの間は、重ねて依頼させない。
            if (entry.itemKey case final key?
                when repo.itemRequestIdFor(key) == null)
              TextButton.icon(
                key: Key('exclude-${key.substring(0, 12)}'),
                onPressed: busy
                    ? null
                    : () => excludeItem(
                        project,
                        project.nowItems.firstWhere((i) => i.key == key),
                      ),
                icon: const Icon(Icons.report_gmailerrorred_outlined, size: 15),
                label: const Text('誤りとして外す'),
              ),
            // AIが読み取った次の一手・提案を、本人の行動として引き取る（統合済みのプロジェクトでは本体が断る）。
            if (!project.merged)
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
              TextButton.icon(
                key: const Key('source-record'),
                onPressed: () => open(id),
                icon: const Icon(Icons.article_outlined, size: 15),
                label: Text(
                  repo.records[id]?.title ?? '出典を確認',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ],
    ),
  );

  /// 進行中のプロジェクトの「次の一手」（または未解決）を、ピン留めしたものから順に、残りは最新の根拠が新しい順にまとめる。
  /// 本人が付けた期日が過ぎた・今日・7日以内の項目はプロジェクトをまたいで先頭に出し、見直す日が先の項目はたたむ。
  List<Widget> nextView() {
    final now = DateTime.now(),
        today = hubToday(now),
        projects = repo.actionableProjects,
        section = nextSection,
        // 次の一手には、本人が追加して反映待ちの行動も数える。
        count = {
          'next': projects.fold<int>(0, (n, p) => n + p.nextCount),
          'open': projects.fold<int>(
            0,
            (n, p) => n + p.entriesWithSource('open').length,
          ),
        },
        empty = projects
            .where(
              (p) => section == 'next'
                  ? p.nextCount == 0
                  : p.entriesWithSource(section).isEmpty,
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
    final front =
            <ScheduleBucket, List<(HubProject, NowEntry, NowItemRef, int)>>{},
        resting = <(HubProject, NowEntry, NowItemRef, int)>[],
        listed = <String, List<NowEntry>>{};
    for (final project in projects) {
      final rest = <NowEntry>[];
      var order = 0;
      for (final entry in project.entriesWithSource(section)) {
        order++;
        final item = entry.itemKey == null
            ? null
            : project.nowItems.where((i) => i.key == entry.itemKey).firstOrNull;
        if (item == null || !item.scheduled) {
          rest.add(entry);
          continue;
        }
        final b = scheduleBucket(item.due, item.reviewAfter, today);
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
    }
    for (final list in front.values) {
      list.sort(
        (a, b) => a.$3.due!.compareTo(b.$3.due!) != 0
            ? a.$3.due!.compareTo(b.$3.due!)
            : a.$1.id.compareTo(b.$1.id) != 0
            ? a.$1.id.compareTo(b.$1.id)
            : a.$4.compareTo(b.$4),
      );
    }
    Widget crossEntry((HubProject, NowEntry, NowItemRef, int) e) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => widget.onNavigate('project:${e.$1.id}'),
          child: Text(
            e.$1.title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        nowEntry(e.$1, section, e.$2, added[e.$1.id]!),
      ],
    );
    return [
      title(
        'NEXT ACTIONS',
        '次の一手',
        '進行中のプロジェクトの「次の一手」と「未解決」を、ピン留めしたプロジェクトから順に、残りは最新の根拠が新しい順にまとめます。休止・完了のプロジェクトは含みません。期日が過ぎた・今日・7日以内の項目は先頭に、見直す日が先の項目は末尾にたたみます（日付は本体と同じ日本時間の暦日で判断します）。どのプロジェクトにも結び付いていないメモのタスク候補とAIの提案は、「次の一手」の後ろの「プロジェクト未定」に並べます。\n読込: ${timeLabel(repo.snapshot.loadedAt)}（同期完了の確認ではありません）',
      ),
      ...todaySection(),
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<String>(
          key: const Key('next-section'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'next', label: Text('次の一手 ${count['next']}件')),
            ButtonSegment(value: 'open', label: Text('未解決 ${count['open']}件')),
          ],
          selected: {section},
          onSelectionChanged: (v) => setState(() => nextSection = v.single),
        ),
      ),
      if (section == 'next' && projects.any((p) => !p.merged))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('next-add-action'),
              onPressed: busy || c.composing ? null : () => addAction(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('次の一手を追加'),
            ),
          ),
        ),
      const SizedBox(height: 20),
      if (projects.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 24),
          child: Text('進行中のプロジェクトはありません。'),
        )
      else if (count[section] == 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Text(
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
          Text(
            '${scheduleBucketLabels[bucket]}（${entries.length}件）',
            key: Key('next-bucket-${bucket.name}'),
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: bucket == ScheduleBucket.overdue
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final e in entries) crossEntry(e)],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      for (final project in projects)
        if (listed[project.id]! case final entries
            when entries.isNotEmpty ||
                (section == 'next' && project.pendingActions.isNotEmpty)) ...[
          InkWell(
            key: Key('next-project-${project.id}'),
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
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          projectStatusLine(project, now),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (section == 'next')
                    for (final action in project.pendingActions)
                      pendingActionRow(action),
                  for (final entry in entries)
                    nowEntry(project, section, entry, added[project.id]!),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      if (section == 'next' && repo.unassignedMemos.isNotEmpty)
        ...unassignedGroup(),
      if (resting.isNotEmpty)
        Card(
          child: ExpansionTile(
            key: const Key('next-resting'),
            title: Text('見直す日まで休ませている項目（${resting.length}件）'),
            subtitle: const Text(
              '見直す日が来ると元の一覧に戻ります。',
              style: TextStyle(fontSize: 12),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final e in resting) crossEntry(e)],
          ),
        ),
      if (empty.isNotEmpty && count[section] != 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            '${sectionLabels[section]}がないプロジェクト: ${empty.map((p) => p.title).join('、')}',
            key: const Key('next-empty-projects'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
    ];
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
                    '根拠のメモを開いて確かめられます',
                    if (insights.waiting > 0)
                      '根拠のメモが届いていない${insights.waiting}件は、届いてから表示',
                  ].join(' · '),
                ),
              ),
              for (final section in insightSectionLabels.keys)
                if (items.any(
                  (i) => i.section == section && shownKeys.contains(i.key),
                )) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(72, 6, 16, 2),
                    child: Text(
                      insightSectionLabels[section]!,
                      key: Key('home-insights-$section'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  for (final item in items)
                    if (item.section == section && shownKeys.contains(item.key))
                      insightEntry(item),
                ],
              if (hidden > 0 || insightsExpanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(60, 0, 16, 8),
                  child: TextButton(
                    key: const Key('home-insights-more'),
                    onPressed: () =>
                        setState(() => insightsExpanded = !insightsExpanded),
                    child: Text(insightsExpanded ? 'たたむ' : 'ほか$hidden件を表示'),
                  ),
                )
              else
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
        notice(context, '保存結果を確認できません。受付状況から同じ操作を確認してください。');
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 今週の気づきの1件。本文はAIが書いたもので、そのまま文字として出す（Markdownとして解釈しない）。
  /// 反応（役に立った・的外れ）を付けられ、問いと止まっている意図には答えられる。
  Widget insightEntry(InsightItem item) {
    // 反応と答えに対応していない本体には、依頼を出さない。
    final runId = repo.insights?.feedback == true ? repo.insights?.runId : null;
    final (:reaction, :pending) = repo.insightReactionOf(item);
    return Padding(
      key: Key('home-insight-${item.key}'),
      padding: const EdgeInsets.fromLTRB(72, 4, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.text, style: const TextStyle(height: 1.6)),
          if (item.firstStep != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '最初の一歩: ${item.firstStep}',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('根拠', style: TextStyle(fontSize: 12)),
              for (final source in item.sources)
                TextButton.icon(
                  key: Key('home-insight-source-${item.key}-${source.inputId}'),
                  onPressed: () {
                    final record = repo.inputRecord(source.inputId);
                    if (record != null) open(record.id);
                  },
                  icon: const Icon(Icons.article_outlined, size: 15),
                  label: Text(
                    '${hubToday(source.at)}のメモ${source.corrected ? '（訂正あり）' : ''}',
                  ),
                ),
            ],
          ),
          if (item.answers.isNotEmpty)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('答え', style: TextStyle(fontSize: 12)),
                for (final answer in item.answers)
                  TextButton.icon(
                    key: Key(
                      'home-insight-answered-${item.key}-${answer.inputId}',
                    ),
                    onPressed: () {
                      final record = repo.inputRecord(answer.inputId);
                      if (record != null) open(record.id);
                    },
                    icon: const Icon(Icons.chat_bubble_outline, size: 15),
                    label: Text('${hubToday(answer.at)}のメモ'),
                  ),
              ],
            ),
          if (runId != null)
            Wrap(
              spacing: 8,
              runSpacing: 4,
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
                      size: 16,
                    ),
                    showCheckmark: false,
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
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 「次の一手」画面の「プロジェクト未定」。どのプロジェクトにも結び付いていないメモの、
  /// AIによるタスクの分類と次の一手の提案を新しい順に並べる。
  List<Widget> unassignedGroup() {
    final memos = repo.unassignedMemos,
        listed = memos.take(unassignedShown).toList(),
        rest = repo.unassignedTotal - memos.length;
    return [
      Text(
        'プロジェクト未定（メモ${repo.unassignedTotal}件）',
        key: const Key('next-unassigned'),
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'どのプロジェクトにも結び付いていないメモから、AIが「タスク」と分類したものと、AIが挙げた次の一手の提案を新しい順に集めています。AI生成・未検証で、完了の報告や期日の対象にはなりません。メモがプロジェクトに結び付くと、そのプロジェクトの次の一手へ移ります。',
        style: TextStyle(fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final memo in listed) unassignedEntry(memo)],
          ),
        ),
      ),
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
            style: const TextStyle(fontSize: 12),
          ),
        ),
      const SizedBox(height: 24),
    ];
  }

  /// プロジェクト未定のメモ1件。完了の報告や期日の対象ではないので、できる操作は元のメモを開くことだけ。
  Widget unassignedEntry(UnassignedMemo memo) {
    final record = repo.inputRecord(memo.inputId);
    return Padding(
      key: Key('unassigned-${memo.inputId}'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${hubToday(memo.at)} · ${memo.ownWords ? '本人のメモ' : 'AIの要約・未検証'}${memo.task ? ' · AIがタスクと分類' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            memo.text,
            style: const TextStyle(fontWeight: FontWeight.w600, height: 1.5),
          ),
          for (final suggestion in memo.suggestions)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 12),
              child: Text(
                'AI提案: $suggestion',
                style: const TextStyle(height: 1.5),
              ),
            ),
          if (record != null)
            TextButton.icon(
              key: Key('unassigned-open-${memo.inputId}'),
              onPressed: () => open(record.id),
              icon: const Icon(Icons.article_outlined, size: 15),
              label: const Text('元のメモを開く'),
            ),
        ],
      ),
    );
  }

  List<Widget> projectView(HubProject project) {
    final now = DateTime.now(),
        requested = repo.projectStatusRequestIdFor(project.id) != null,
        defining = repo.projectDefinitionRequestIdFor(project.id) != null,
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
    return [
      title(
        'PROJECT / ${project.lifecycleLabel}',
        project.title,
        '要約の生成: ${timeLabel(project.generatedAt)}\n最新の根拠: ${timeLabel(project.lastEvidenceAt)}\n${projectStatusLine(project, now)}',
      ),
      if (project.stale(now))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '最終根拠から$projectStaleDays日を超えて新しい入力がありません。再開するか、休止・完了にするかを判断してください。',
          ),
        ),
      if (requested)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox('状態の変更を依頼済みです。Miniで受け付けられ、同期されると反映されます。'),
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
            '統合（または取り消し）を依頼済みです。Miniで受け付けられ、同期されると反映されます。',
            key: Key('project-merge-requested'),
          ),
        ),
      if (defining)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '呼び名とキーワードの変更を依頼済みです。Miniで受け付けられ、同期されると反映されます。',
            key: Key('project-definition-requested'),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SelectableText(
          '別名: ${project.aliases.isEmpty ? 'なし' : project.aliases.join('・')}\nキーワード: ${project.keywords.isEmpty ? 'なし' : project.keywords.join('・')}',
          key: const Key('project-terms'),
          style: const TextStyle(fontSize: 12, height: 1.7),
        ),
      ),
      for (final warning in project.warnings)
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
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton.icon(
            key: const Key('project-status'),
            onPressed: editable ? () => changeStatus(project) : null,
            icon: const Icon(Icons.flag_outlined, size: 18),
            label: const Text('状態を変更'),
          ),
          OutlinedButton.icon(
            key: const Key('project-definition'),
            onPressed: editable ? () => changeDefinition(project) : null,
            icon: const Icon(Icons.label_outline, size: 18),
            label: const Text('呼び名とキーワード'),
          ),
          OutlinedButton.icon(
            key: const Key('project-pin'),
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
            onPressed: project.history == null
                ? null
                : () => showHistory(project),
            icon: const Icon(Icons.timeline, size: 18),
            label: Text(project.history == null ? '経緯（未生成）' : 'これまでの経緯'),
          ),
          // 資料は、参考資料に分類されたメモがあるプロジェクトにだけ本体が作る。
          // 統合済みのプロジェクトの資料は統合先にまとまるので、統合先の資料を開く。
          if ((mergeTarget ?? project).shelf != null)
            OutlinedButton.icon(
              key: const Key('project-shelf'),
              onPressed: () => showShelf(mergeTarget ?? project),
              icon: const Icon(Icons.bookmarks_outlined, size: 18),
              label: Text(mergeTarget == null ? '資料' : '資料（統合先）'),
            ),
          // 手で書いた統合先が見つからない・循環している定義は、直すまで統合を依頼できない（本体が断る）。
          if (!project.merged && project.mergedInto == null)
            OutlinedButton.icon(
              key: const Key('project-merge'),
              // ほかのプロジェクトの統合先になっているプロジェクトは、統合元にできない（本体と同じ）。
              onPressed: mergeable && sources.isEmpty
                  ? () => mergeProject(project)
                  : null,
              icon: const Icon(Icons.merge, size: 18),
              label: const Text('ほかのプロジェクトへ統合'),
            ),
          OutlinedButton.icon(
            key: const Key('project-guided'),
            onPressed: c.loading || c.captureWarning != null
                ? null
                : () => showGuided(context, c, project: project.id),
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('このプロジェクトで深掘り'),
          ),
          OutlinedButton.icon(
            key: const Key('copy-context'),
            onPressed: c.loading
                ? null
                : () async {
                    try {
                      final text = await c.context(project.id);
                      await Clipboard.setData(ClipboardData(text: text));
                      if (mounted) {
                        notice(context, '出典付きcontextをコピーしました');
                      }
                    } catch (e) {
                      if (mounted) {
                        notice(context, HubController.message(e));
                      }
                    }
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('出典付きcontextをコピー'),
          ),
        ],
      ),
      const SizedBox(height: 28),
      for (final section in [
        ('current', '現在地'),
        ('next', '次の一手'),
        ('open', '未解決'),
        ('proposals', '提案'),
      ]) ...[
        Row(
          children: [
            Expanded(
              child: Text(
                section.$2,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // 本人が決めた行動を、AIの整理を待たずに次の一手へ載せる。統合済みのプロジェクトには追加しない。
            if (section.$1 == 'next' && !project.merged)
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
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (section.$1 == 'next')
                  for (final action in project.pendingActions)
                    pendingActionRow(action),
                if (project.sections[section.$1]!.isEmpty &&
                    (section.$1 != 'next' || project.pendingActions.isEmpty))
                  const Text('まだ整理されていません。'),
                for (final entry in project.sections[section.$1]!)
                  nowEntry(project, section.$1, entry, added),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
      ],
      if (project.resolvedItems.isNotEmpty) ...[
        const Text(
          '解決済み・完了（本人報告）',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          key: const Key('resolved-items'),
          child: Padding(
            padding: const EdgeInsets.all(22),
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
        const SizedBox(height: 28),
      ],
      if (project.excludedItems.isNotEmpty) ...[
        const Text(
          '誤りとして外した項目（本人報告）',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          '完了・解決には数えません。理由と一言は、次からの整理でAIへ渡します。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        Card(
          key: const Key('excluded-items'),
          child: Padding(
            padding: const EdgeInsets.all(22),
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
        const SizedBox(height: 28),
      ],
      if (project.drafts.isNotEmpty) ...[
        const Text(
          '作業記録の下書き',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          '設定したリポジトリのコミット件名から作った下書きです。本文を確認・編集して入力にするか、見送ってください。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        for (final draft in project.drafts)
          Card(
            key: Key('draft-${draft.id}'),
            child: Padding(
              padding: const EdgeInsets.all(22),
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
                    const Text('操作済み（反映待ち）', style: TextStyle(fontSize: 12))
                  else
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonal(
                          key: Key('draft-use-${draft.id}'),
                          onPressed: busy || c.composing
                              ? null
                              : () => showCapture(context, c, draft: draft),
                          child: const Text('入力にする'),
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
        const SizedBox(height: 28),
      ],
      if (project.notes.trim().isNotEmpty) ...[
        const Text(
          '手動メモ',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
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
          child: const Text('NOW本文と出典・日時を開く'),
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
        icon: Icon(inside ? Icons.check_circle : Icons.add_circle_outline),
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
      padding: const EdgeInsets.only(top: 24),
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
                    ? '行動の文面の訂正を送りました。Miniに届くまで、NOWの次の一手は直す前の文面のままです（$requestId）。'
                    : '訂正を送りました。Miniに届いて整理されるまで、要約は訂正前の内容のままです（$requestId）。',
              ),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('write-correction'),
                icon: const Icon(Icons.edit_note),
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

  /// 似ているアイデアと束ねたアイデア。束ねる・別の話にする判断を依頼できる。
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
          '依頼済み（$requestId）。Miniで受け付けられると反映されます。',
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
            Text(
              '束ねたアイデア（${group.ideas.length}件）',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              '本人が同じ話と判断したアイデアです。検索では1件にまとめて表示します（本体の検索）。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
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
            Text(
              '似ているアイデア（${similar.length}件）',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              '文字の重なりから見つけた候補です（AIは使っていません）。同じ話なら束ねると、どこまで考えたかを1か所で追えます。違う話なら「別の話」を選ぶと、次から候補に出しません。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
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
        const HubMenuButton(),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              record.title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              '${originLabel(record.origin)} · ${stateLabel(record.status)}',
            ),
            const SizedBox(height: 20),
            for (final warning in record.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NoticeBox(warning),
              ),
            SafeMarkdown(
              text: record.body,
              sourcePath: record.path,
              controller: controller,
              onRecord: (id) => open(context, id),
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
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              '出典・日時',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 12),
            SelectableText(
              '${record.sourceId}\n${record.path}\n入力元: ${record.source}\n発生: ${timeLabel(record.at)}\n受領: ${timeLabel(record.receivedAt)}\n生成: ${timeLabel(record.generatedAt)}',
              style: const TextStyle(fontSize: 12, height: 1.9),
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
      content: Text('$body依頼はInputへ保存され、Miniで受け付けられると反映されます。'),
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
            ? '依頼を保存しました。Miniで受け付けられると反映されます。'
            : '保存結果を確認できません。受付状況から同じ操作を確認してください。',
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
String originLabel(String origin) => switch (origin) {
  'user-note' => '本人のメモ',
  'ai-self-report' => 'AIの作業自己報告・未検証',
  'ai-generated' => 'AI生成・未検証',
  _ => origin,
};
String stateLabel(String state) => switch (state) {
  'waiting' => 'Mini受領待ち',
  'accepted' => 'Mini受領',
  'organized' => '整理済み',
  'failed' => '整理失敗',
  'rejected' => '受付失敗',
  'conflict' => '競合',
  'uncertain' => '保存確認待ち',
  'unknown' => '整合性未確認',
  'action' => '本人が追加した行動（整理しません）',
  _ => state,
};

Future<void> showCapture(
  BuildContext context,
  HubController c, {
  GitDraft? draft,
  InsightAnswerTarget? answer,
}) async {
  if (c.composing) {
    return;
  }
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          CaptureDialog(controller: c, draft: draft, answer: answer),
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
              child: SingleChildScrollView(
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
                          ? '直した後の文面を1行で書いてください。元の文面は原文に残ります。Miniで受け付けられるとNOWの次の一手が直した文面になります。付けた日付は直した後の行動に引き継がれます。'
                          : '訂正後の全文を書いてください。元のメモは残り、訂正として追加されます。Miniで整理されるまで、要約やNOWは訂正前の内容のままです。',
                      style: const TextStyle(fontSize: 12, height: 1.6),
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
                              ? 'この端末のInputに訂正を保存しました'
                              : '保存確認待ちです。再送せず同じ操作を確認してください。',
                        ),
                      ),
                    if (locked)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          '操作ID: $operation',
                          style: const TextStyle(fontSize: 10),
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
  });
  final HubController controller;

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
    );
    text.addListener(_schedulePersist);
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
    project = draft?.projectId;
  }

  /// 前回の書きかけを戻す。保存済みの操作の書きかけは消し、保存結果が不明なものは確認へ戻す。
  Future<void> _restore() async {
    final key = _draftKey;
    try {
      _templates = await widget.controller.templates.list();
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
    text.dispose();
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
    final body = stripEmptyTemplateHeadings(
      text.text,
      templateHeadings(_templates),
    );
    if (body.trim().isEmpty && text.text.trim().isNotEmpty) {
      setState(() => error = 'ひな形の見出しだけで、中身がありません。見出しの下に書いてから保存してください。');
      return;
    }
    if (body.trim().isEmpty || body.length > 8000) {
      setState(() => error = '本文は1〜8000文字で入力してください。');
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
        ),
      );
      await _settled(r);
      if (mounted) {
        setState(() => result = r);
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
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '保存先: ${widget.controller.location?.name ?? ''}',
                          style: const TextStyle(fontSize: 12),
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
                                const Text(
                                  '今週の気づきの問い（AIの推定・未検証）',
                                  style: TextStyle(fontSize: 12),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  answer.question,
                                  style: const TextStyle(height: 1.6),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '答えはふつうのメモとして保存し、この問いへの答えだと分かるように記録します。次の週の読み直しで使われます。',
                            style: TextStyle(fontSize: 12, height: 1.5),
                          ),
                        ],
                        const SizedBox(height: 8),
                        if (!locked && widget.answer == null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: PopupMenuButton<String>(
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
                                    child: Text(
                                      t.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                if (_templates.isNotEmpty)
                                  const PopupMenuDivider(),
                                const PopupMenuItem(
                                  key: Key('template-manage'),
                                  value: _editTemplates,
                                  child: Text('ひな形を編集…'),
                                ),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                  horizontal: 4,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.playlist_add,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'ひな形',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 4),
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
                        // 問いへの答えは本人のメモとして残すので、種類を選ばせない。
                        if (widget.answer == null) ...[
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: ValueKey('memo-kind-$_formGeneration'),
                            initialValue: kind,
                            decoration: const InputDecoration(labelText: '種類'),
                            items: const [
                              DropdownMenuItem(
                                value: 'memo',
                                child: Text('メモ'),
                              ),
                              DropdownMenuItem(
                                value: 'work-summary',
                                child: Text('AIの作業要約・未検証'),
                              ),
                            ],
                            onChanged: locked
                                ? null
                                : (v) {
                                    setState(() => kind = v!);
                                    _schedulePersist();
                                  },
                          ),
                        ],
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: ValueKey('memo-project-$_formGeneration'),
                          initialValue: project ?? '',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'プロジェクト（任意）',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('指定しない'),
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
                                },
                        ),
                        if (widget.draft != null && kind == 'work-summary')
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: NoticeBox(
                              '作業要約として保存すると、NOWの現在地・次の一手はこの本文から作られます。次の一手を書き足してください。',
                            ),
                          ),
                        const SizedBox(height: 16),
                        const Text(
                          'Inputへ追加します。同期後のMini受領・整理は受付状況で確認できます。',
                          style: TextStyle(fontSize: 12, height: 1.6),
                        ),
                        if (_draftKey != null)
                          CheckboxListTile(
                            key: const Key('keep-drafts'),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            dense: true,
                            value: _keepDrafts,
                            onChanged: (v) => _setKeepDrafts(v ?? true),
                            title: const Text(
                              '書きかけをこの端末に残す',
                              style: TextStyle(fontSize: 12),
                            ),
                            subtitle: const Text(
                              'フォームを閉じたりアプリが終了したりしても、次に開いたときに続きから書けます。保存が確かめられたら消します。Vaultには書きません。',
                              style: TextStyle(fontSize: 11, height: 1.5),
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
                                  ? 'この端末のInputに保存しました'
                                  : '保存確認待ちです。再送せず同じ操作を確認してください。',
                            ),
                          ),
                        if (locked)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: SelectableText(
                              '操作ID: $operation',
                              style: const TextStyle(fontSize: 10),
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
                child: const Text('Inputへ保存'),
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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ピン留めしたプロジェクトは、メニュー・ホーム・「次の一手」の先頭にこの順で並びます。並びはこの端末にだけ保存し、Vaultやほかの端末には伝わりません。',
                  style: TextStyle(fontSize: 12, height: 1.7),
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
                            style: const TextStyle(fontSize: 12, height: 1.6),
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
    'misread' => 'メモはそう言っていない。Miniが次の整理で、このメモを読み直します。',
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
        child: SingleChildScrollView(
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
                    style: const TextStyle(fontSize: 12, height: 1.6),
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
              const Text(
                '完了・解決には数えません。原文は変わりません。外した項目の本文・理由・一言は、同じ読み違いを減らすために、次からの整理でAIへ渡します。Miniが受け付けるとNOWに反映され、プロジェクトの画面から未解決に戻せます。',
                style: TextStyle(fontSize: 12, height: 1.6),
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
  const ActionDialog({super.key, required this.projects, this.from});

  /// 追加先に選べるプロジェクト。1件ならそのプロジェクトに決まっている。
  final List<HubProject> projects;

  /// AIが読み取った行を行動にするときの元の行。
  final ActionSource? from;
  @override
  State<ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<ActionDialog> {
  late final text = TextEditingController(
    text: widget.from?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '',
  );
  late String project = widget.projects.first.id;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = text.text.trim(), valid = validActionText(value);
    return AlertDialog(
      key: const Key('action-dialog'),
      title: Text(widget.from == null ? '次の一手を追加' : '自分の行動にする'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.projects.length == 1)
                Text(
                  widget.projects.single.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                )
              else
                DropdownButtonFormField<String>(
                  key: const Key('action-project'),
                  initialValue: project,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'プロジェクト'),
                  items: [
                    for (final p in widget.projects)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(p.title, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => project = v ?? project),
                ),
              if (widget.from case final from?) ...[
                const SizedBox(height: 12),
                Text(
                  '元の行（AIの読み取り）: ${from.text}',
                  key: const Key('action-from'),
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
              const SizedBox(height: 12),
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
              const SizedBox(height: 8),
              Text(
                widget.from == null
                    ? '本人が追加した行動として、そのまま次の一手に載ります。AIは整理せず、完了か誤りとして外すと報告するまで、新しい作業要約が届いても残ります。Miniで受け付けられ、同期されるとNOWに反映されます。'
                    : '本人が追加した行動として次の一手に載り、元の行はAIの読み取りの欄から外れます。完了か誤りとして外すと報告するまで、新しい作業要約が届いても残ります。Miniで受け付けられ、同期されるとNOWに反映されます。',
                style: const TextStyle(fontSize: 12, height: 1.6),
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
              ? () => Navigator.pop(context, (projectId: project, text: value))
              : null,
          child: const Text('追加する'),
        ),
      ],
    );
  }
}

/// NOWの項目に期日と次に見直す日を付ける画面。日付は本人が選び、AIは推測しない。
class ScheduleDialog extends StatefulWidget {
  const ScheduleDialog({super.key, required this.item});
  final NowItemRef item;
  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  late final due = TextEditingController(text: widget.item.due ?? ''),
      review = TextEditingController(text: widget.item.reviewAfter ?? '');

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
    final valid = problem(due) == null && problem(review) == null,
        changed =
            nextDue != widget.item.due || nextReview != widget.item.reviewAfter,
        clearing = nextDue == null && nextReview == null;
    return AlertDialog(
      title: const Text('期日と次に見直す日'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
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
              const SizedBox(height: 18),
              field(
                'review',
                '次に見直す日（任意）',
                'その日までは「次の一手」の末尾にたたみます。期日が近ければたたみません。',
                review,
              ),
              const SizedBox(height: 14),
              const Text(
                '日付はMiniが受け付けるとNOWとHOMEに反映されます。原文と整理結果は変わりません。',
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
                ))
              : null,
          child: Text(clearing ? '日付を外す' : '依頼する'),
        ),
      ],
    );
  }
}

class ProjectStatusDialog extends StatefulWidget {
  const ProjectStatusDialog({super.key, required this.project});
  final HubProject project;
  @override
  State<ProjectStatusDialog> createState() => _ProjectStatusDialogState();
}

class _ProjectStatusDialogState extends State<ProjectStatusDialog> {
  String? selected;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.project.title}の状態'),
    content: SingleChildScrollView(
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
          const SizedBox(height: 8),
          const Text(
            '休止・完了にすると、ホームの後ろにまとめて表示し、AIの帰属候補から外します。メモで明示したプロジェクトは引き続き使えます。依頼はInputへ保存され、Miniで受け付けられると反映されます。',
            style: TextStyle(fontSize: 12, height: 1.6),
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
      child: SingleChildScrollView(
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
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
              CheckboxListTile(
                key: const Key('project-merge-confirm'),
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
            const Text(
              '依頼はInputへ保存され、Miniで受け付けられると反映されます。',
              style: TextStyle(fontSize: 12, height: 1.6),
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

/// プロジェクトの名前・別名・キーワードを編集する。別名とキーワードは1行に1つ。
class ProjectDefinitionDialog extends StatefulWidget {
  const ProjectDefinitionDialog({super.key, required this.project});
  final HubProject project;
  @override
  State<ProjectDefinitionDialog> createState() =>
      _ProjectDefinitionDialogState();
}

class _ProjectDefinitionDialogState extends State<ProjectDefinitionDialog> {
  late final title = TextEditingController(text: widget.project.title),
      aliases = TextEditingController(text: widget.project.aliases.join('\n')),
      keywords = TextEditingController(
        text: widget.project.keywords.join('\n'),
      );

  ProjectDefinitionDraft get draft => ProjectDefinitionDraft(
    title: title.text,
    aliases: aliases.text.split('\n'),
    keywords: keywords.text.split('\n'),
  );

  @override
  void initState() {
    super.initState();
    for (final t in [title, aliases, keywords]) {
      t.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    title.dispose();
    aliases.dispose();
    keywords.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = draft,
        problem = next.problem,
        unchanged = next.sameAs(widget.project);
    return AlertDialog(
      title: Text('${widget.project.title}の呼び名とキーワード'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'AIはメモをどのプロジェクトに結び付けるかを、名前・別名・キーワードから判断します。メモでよく使う呼び方や、このプロジェクトに特有の言葉を加えてください。',
                style: TextStyle(fontSize: 12, height: 1.6),
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
              const SizedBox(height: 12),
              if (problem != null)
                NoticeBox(problem, error: true)
              else
                const Text(
                  '依頼はInputへ保存され、Miniで受け付けられると反映されます。プロジェクトを指定せずに保存したメモのうち、まだどのプロジェクトにも結び付いていないものは、次の整理で新しい定義に合わせて見直されます（AIを使います）。',
                  style: TextStyle(fontSize: 12, height: 1.6),
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
      memo = TextEditingController();
  final operation = const Uuid().v4(), projectId = newProjectId();
  String? error;
  CaptureResult? result;
  bool busy = false, locked = false;

  @override
  void dispose() {
    for (final c in [title, aliases, keywords, memo]) {
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
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key(key),
      controller: controller,
      readOnly: locked,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 4,
      maxLength: max,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '保存先: ${widget.controller.location?.name ?? ''}',
                style: const TextStyle(fontSize: 12),
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
              field(
                'project-create-memo',
                memo,
                '最初のメモ（任意）',
                hint: 'このプロジェクトのメモとして保存します',
                lines: 4,
                max: 8000,
              ),
              const Text(
                '作成の依頼をInputへ追加します。Miniで受け付けられ、同期されるとプロジェクト一覧に表示されます。名前・別名が既存のプロジェクトと重なる場合は作成されません。',
                style: TextStyle(fontSize: 12, height: 1.6),
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
                        ? 'この端末のInputに作成の依頼を保存しました'
                        : '保存確認待ちです。再送せず同じ操作を確認してください。',
                  ),
                ),
              if (locked && result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    '操作ID: $operation',
                    style: const TextStyle(fontSize: 10),
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
