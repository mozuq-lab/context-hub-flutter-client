import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../app/controller.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../core/parser.dart' show clip;
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

class _HubViewState extends State<HubView> {
  String query = '';
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
    if (old.page != widget.page) _visit();
  }

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
  Widget recordCard(HubRecord r, {Key? key}) => Card(
    key: key,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '${originLabel(r.origin)} · ${stateLabel(r.status)}\n${timeLabel(r.at)}',
          style: const TextStyle(fontSize: 12, height: 1.7),
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
    } else if (page == 'home') {
      children.add(
        title(
          'YOUR CONTEXT',
          '今日、どこから始める？',
          '${repo.projects.length}プロジェクト · ${repo.recent.length}件のメモ\n読込: ${timeLabel(repo.snapshot.loadedAt)}（同期完了の確認ではありません）',
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
      children.add(
        title('FIND A THOUGHT', '検索', 'タイトルと本文を検索します。複数の語は空白で区切ります。'),
      );
      children.add(
        TextField(
          key: const Key('search-query'),
          decoration: const InputDecoration(
            hintText: '思い出したいことを入力',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => setState(() => query = v),
        ),
      );
      children.add(const SizedBox(height: 20));
      if (query.trim().isNotEmpty) {
        final results = repo.search(query);
        children.add(Text('${results.length}件（最大50件）'));
        children.add(const SizedBox(height: 12));
        children.addAll(
          results.map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: recordCard(r, key: const Key('search-result')),
            ),
          ),
        );
      }
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
      }
      children.addAll(
        records.map(
          (r) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: recordCard(r),
          ),
        ),
      );
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
                '外れた（${sectionLabels[item.section] ?? item.section}）: ${item.text}',
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
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (added.contains(
                          SeenItem(section.$1, clip(entry.text, 500)).id,
                        ))
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
                          sourcePath:
                              repo.records[project.nowRecordId]?.path ?? '',
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
                                      padding: EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                      child: Text(
                                        '報告済み（反映待ち）',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    )
                                  : TextButton.icon(
                                      key: Key(
                                        'resolve-${key.substring(0, 12)}',
                                      ),
                                      onPressed: busy
                                          ? null
                                          : () => reportItem(
                                              project,
                                              project.nowItems.firstWhere(
                                                (i) => i.key == key,
                                              ),
                                              'resolve',
                                            ),
                                      icon: const Icon(
                                        Icons.check_circle_outline,
                                        size: 15,
                                      ),
                                      label: Text(
                                        section.$1 == 'next'
                                            ? '完了にする'
                                            : '解決にする',
                                      ),
                                    ),
                            for (final id in entry.references)
                              TextButton.icon(
                                key: const Key('source-record'),
                                onPressed: () => open(id),
                                icon: const Icon(
                                  Icons.article_outlined,
                                  size: 15,
                                ),
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
                  ),
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
      project = widget.controller.repository?.projects[draft.projectId]?.id;
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
                onChanged: locked
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
