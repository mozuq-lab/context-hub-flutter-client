import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'package:uuid/uuid.dart';
import '../app/controller.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../storage/capture_service.dart';
import 'markdown_view.dart';
import 'review_view.dart';

void notice(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

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
  });
  final HubController controller;
  final String page;
  final void Function(String) onNavigate;
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
      trailing: const Icon(Icons.chevron_right),
      onTap: () => open(r.id),
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (widget.page == 'review') return ReviewView(controller: c);
    final children = <Widget>[];
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
      final actionable = repo.actionableProjects,
          nextCount = actionable.fold<int>(
            0,
            (n, p) => n + p.entriesWithSource('next').length,
          ),
          nextProjects = actionable
              .where((p) => p.entriesWithSource('next').isNotEmpty)
              .length;
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
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Card(
            child: ListTile(
              key: const Key('home-review'),
              leading: const Icon(Icons.fact_check_outlined),
              title: Text('確認待ち ${c.review!.pending.length}件'),
              subtitle: Text(
                '要確認 ${c.review!.attention.length}件 · 採用前に内容と元のメモを確認',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onNavigate('review'),
            ),
          ),
        ),
      );
      final now = DateTime.now(),
          stale = repo.projects.values.where((p) => p.stale(now)).length;
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
      if (repo.projects.isEmpty) {
        children.add(const Text('プロジェクトはまだありません。メモはproject未指定でも追加できます。'));
      }
      final changed = repo.projects.values
          .where((p) => c.changesSince(p)?.isEmpty == false)
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
      for (final project in repo.orderedProjects) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                key: Key('project-${project.id}'),
                contentPadding: const EdgeInsets.all(24),
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
                        project.sections['next']?.firstOrNull?.text ??
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
                trailing: const Icon(Icons.arrow_forward),
                onTap: () => widget.onNavigate('project:${project.id}'),
              ),
            ),
          ),
        );
      }
      children.add(const SizedBox(height: 28));
      children.add(
        const Text(
          '最近のメモ',
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
    } else if (page == 'search') {
      children.addAll(searchView());
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
                child: recordCard(r),
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
    if (!await confirmAction(
          resolve ? '$verbにする' : '未解決に戻す',
          '${item.display}\n\n${resolve ? 'この項目をNOWの「解決済み・完了」へ移すよう依頼します。原文と整理結果は変わりません。' : 'この項目をNOWの元の欄へ戻すよう依頼します。'}',
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

  Future<void> markAllSeen() async {
    try {
      await c.markAllSeen();
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
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

  /// 進行中のプロジェクトの「次の一手」（または未解決）を、最新の根拠が新しい順にまとめる。
  List<Widget> nextView() {
    final now = DateTime.now(),
        projects = repo.actionableProjects,
        section = nextSection,
        count = {
          for (final s in ['next', 'open'])
            s: projects.fold<int>(
              0,
              (n, p) => n + p.entriesWithSource(s).length,
            ),
        },
        empty = projects
            .where((p) => p.entriesWithSource(section).isEmpty)
            .toList();
    // 前回見てから増えた行。この画面では既読にしない。
    final added = {
      for (final p in projects)
        p.id:
            c.changesSince(p)?.added.map((i) => i.id).toSet() ??
            const <String>{},
    };
    return [
      title(
        'NEXT ACTIONS',
        '次の一手',
        '進行中のプロジェクトの「次の一手」と「未解決」を、最新の根拠が新しい順にまとめます。休止・完了のプロジェクトは含みません。\n読込: ${timeLabel(repo.snapshot.loadedAt)}（同期完了の確認ではありません）',
      ),
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
      const SizedBox(height: 20),
      if (projects.isEmpty)
        const Text('進行中のプロジェクトはありません。')
      else if (count[section] == 0)
        Text(
          section == 'next'
              ? '進行中のプロジェクトに次の一手はありません。'
              : '進行中のプロジェクトに未解決はありません。',
        ),
      for (final project in projects)
        if (project.entriesWithSource(section) case final entries
            when entries.isNotEmpty) ...[
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
                  for (final entry in entries)
                    nowEntry(project, section, entry, added[project.id]!),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      if (empty.isNotEmpty && count[section] != 0)
        Text(
          '${sectionLabels[section]}がないプロジェクト: ${empty.map((p) => p.title).join('、')}',
          key: const Key('next-empty-projects'),
          style: const TextStyle(fontSize: 12),
        ),
    ];
  }

  List<Widget> projectView(HubProject project) {
    final now = DateTime.now(),
        requested = repo.projectStatusRequestIdFor(project.id) != null,
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
            onPressed:
                c.loading ||
                    c.saving ||
                    requested ||
                    c.captureWarning != null ||
                    project.definitionHash == null
                ? null
                : () => changeStatus(project),
            icon: const Icon(Icons.flag_outlined, size: 18),
            label: const Text('状態を変更'),
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
        Text(
          section.$2,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (project.sections[section.$1]!.isEmpty)
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
                '訂正を送りました。Miniに届いて整理されるまで、要約は訂正前の内容のままです（$requestId）。',
              ),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('write-correction'),
                icon: const Icon(Icons.edit_note),
                label: const Text('訂正を書く'),
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('記録の詳細')),
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
            if (const [
              'memo',
              'work-summary',
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
  _ => state,
};

Future<void> showCapture(
  BuildContext context,
  HubController c, {
  GitDraft? draft,
}) async {
  if (c.composing) {
    return;
  }
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CaptureDialog(controller: c, draft: draft),
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
    if (text.text.trim().isEmpty || text.text.length > 8000) {
      setState(() => error = '訂正文は1〜8000文字で入力してください。');
      return;
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
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('メモを訂正する'),
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
                const Text(
                  '訂正後の全文を書いてください。元のメモは残り、訂正として追加されます。Miniで整理されるまで、要約やNOWは訂正前の内容のままです。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('correction-text'),
                  controller: text,
                  readOnly: locked || busy,
                  minLines: 5,
                  maxLines: 12,
                  maxLength: 8000,
                  decoration: const InputDecoration(alignLabelWithHint: true),
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
    );
  }
}

class CaptureDialog extends StatefulWidget {
  const CaptureDialog({super.key, required this.controller, this.draft});
  final HubController controller;

  /// 作業記録の下書きから入力を作る場合の下書き。本文とプロジェクトを初期値にする。
  final GitDraft? draft;
  @override
  State<CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<CaptureDialog> {
  final text = TextEditingController();
  final operation = const Uuid().v4();
  String kind = 'memo';
  String? project, error;
  CaptureResult? result;
  bool busy = false, locked = false;
  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    if (draft != null) {
      text.text = draft.text;
      project = draft.projectId;
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (text.text.trim().isEmpty || text.text.length > 8000) {
      setState(() => error = '本文は1〜8000文字で入力してください。');
      return;
    }
    setState(() {
      busy = true;
      locked = true;
      error = null;
    });
    try {
      final r = await widget.controller.save(
        CaptureDraft(
          operationId: operation,
          text: text.text,
          kind: kind,
          project: project,
          gitDraftId: widget.draft?.id,
          gitDraftHash: widget.draft?.hash,
        ),
      );
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.draft == null ? '思いつきを、そのまま。' : '下書きから入力を作る'),
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
              TextField(
                key: const Key('memo-text'),
                controller: text,
                readOnly: locked,
                minLines: 5,
                maxLines: 10,
                maxLength: 8000,
                decoration: const InputDecoration(
                  hintText: '断片的なメモ、疑問、あとで考えたいこと…',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: '種類'),
                items: const [
                  DropdownMenuItem(value: 'memo', child: Text('メモ')),
                  DropdownMenuItem(
                    value: 'work-summary',
                    child: Text('AIの作業要約・未検証'),
                  ),
                ],
                onChanged: locked ? null : (v) => setState(() => kind = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: project ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'プロジェクト（任意）'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('指定しない')),
                  for (final p
                      in widget.controller.repository?.projects.values ??
                          const <HubProject>[])
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(p.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                // 下書きは同じプロジェクトの入力でだけ使用済みになるため、プロジェクトを固定する。
                onChanged: locked || widget.draft != null
                    ? null
                    : (v) => setState(() => project = v == '' ? null : v),
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
            onPressed: busy ? null : submit,
            child: const Text('Inputへ保存'),
          ),
        if (locked && result?.saved != true)
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      final r = await widget.controller.confirm(operation);
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
