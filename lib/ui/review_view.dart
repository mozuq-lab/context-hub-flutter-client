import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../core/review_candidates.dart';
import '../core/parser.dart';
import 'views.dart';

String reviewState(ReviewCandidate i) => switch (i.status) {
  'pending' => '未承認',
  'approved' =>
    i.retired
        ? '承認済み・適用停止'
        : i.reflected
        ? '承認済み・反映済み'
        : '承認済み・反映待ち',
  'rejected' => '却下済み',
  'stale' => '根拠の再確認が必要',
  _ => '同期・形式の確認が必要',
};

class ReviewView extends StatelessWidget {
  const ReviewView({super.key, required this.controller});
  final HubController controller;
  @override
  Widget build(BuildContext context) {
    final r = controller.review!;
    Widget section(String title, List<ReviewCandidate> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text(
            '$title（${items.length}件）',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
        if (items.isEmpty) const Text('該当する候補はありません。'),
        for (final i in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              child: ListTile(
                key: Key('review-${i.id}'),
                title: Text(i.title),
                subtitle: Text(
                  '${i.label} · ${reviewState(i)}${r.requestIdFor(i.id) != null ? '\n依頼保存済み・Miniの判断待ち' : ''}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReviewDetail(
                      controller: controller,
                      id: i.id,
                      identity: controller.location!.identity,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '候補を確認する',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              '内容と元のメモを確認し、採用・却下を選べます。保留は閉じるだけです。依頼保存後、Miniが最新状態を再検証します。',
            ),
            for (final w in r.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: NoticeBox(w, error: true),
              ),
            section('確認待ち', r.pending),
            section('要確認', r.attention),
            section('判断履歴', r.history),
          ],
        ),
      ),
    );
  }
}

class ReviewDetail extends StatefulWidget {
  const ReviewDetail({
    super.key,
    required this.controller,
    required this.id,
    required this.identity,
  });
  final HubController controller;
  final String id, identity;
  @override
  State<ReviewDetail> createState() => _ReviewDetailState();
}

class _ReviewDetailState extends State<ReviewDetail> {
  HubController get c => widget.controller;
  String? result, error;
  bool busy = false;
  AdoptionTarget? selectedTarget;
  bool targetInitialized = false;
  Future<void> decide(String action) async {
    if (busy || c.composing) return;
    setState(() {
      busy = true;
      error = null;
    });
    c.composing = true;
    try {
      if (c.location?.identity != widget.identity) {
        throw StateError('Vaultが切り替わりました。一覧へ戻ってください。');
      }
      final ticket = await c.prepareReview(
        widget.id,
        target: action == 'approve' ? selectedTarget : null,
        retiring: action == 'retire',
      );
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action == 'retire'
                ? 'この採用済み記録を適用停止しますか？'
                : action == 'approve'
                ? 'この内容を採用しますか？'
                : 'この候補を却下しますか？',
          ),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (ticket.target != null)
                    Text(
                      '採用先: ${ticket.target!.label}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  if (action == 'retire')
                    const Text('自動適用を止めます。本文と採用履歴は保持します。'),
                  ReviewContent(
                    controller: c,
                    item: ticket.candidate,
                    links: false,
                  ),
                  const SizedBox(height: 20),
                  const Text('これは依頼の保存です。Miniで判断が確定し反映されるまで、正式データは変わりません。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('confirm-review'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                action == 'retire'
                    ? '適用停止を依頼'
                    : action == 'approve'
                    ? '採用を依頼'
                    : '却下を依頼',
              ),
            ),
          ],
        ),
      );
      if (yes != true) return;
      final saved = await c.submitReview(ticket, action);
      if (mounted) {
        setState(
          () => result = saved.saved
              ? '依頼をこの端末に保存しました。同期・Miniの判断待ちです。'
              : '保存結果が不明です。再送せず、受付状況から同じ操作の保存確認をしてください。',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    } finally {
      c.composing = false;
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _targetPicker(ReviewCandidate item) {
    final projects = [...c.review!.projects]
      ..sort(
        (a, b) =>
            ((item.projectSuggestions.any((s) => s['projectId'] == a['id'])
                ? 0
                : 1) -
            (item.projectSuggestions.any((s) => s['projectId'] == b['id'])
                ? 0
                : 1)),
      );
    final targets = <String, AdoptionTarget>{
      for (final p in projects)
        'project:${p['id']}:${p['hash']}': AdoptionTarget.project(
          p['id'] as String,
          p['hash'] as String,
        ),
      'global': AdoptionTarget.global(),
    };
    String keyFor(AdoptionTarget t) => t.scope == 'global'
        ? 'global'
        : 'project:${t.projectId}:${t.projectHash}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.kind == 'knowledge'
              ? '採用先（参考知識として必要時に参照）'
              : '採用先（有効な方針としてAI作業へ適用）',
        ),
        const SizedBox(height: 8),
        DropdownMenu<String>(
          key: const Key('review-target'),
          width: MediaQuery.sizeOf(context).width < 700
              ? MediaQuery.sizeOf(context).width - 64
              : 620,
          initialSelection: selectedTarget == null
              ? null
              : keyFor(selectedTarget!),
          hintText: '採用先を選択してください。未定なら保留できます。',
          enableFilter: true,
          enableSearch: true,
          enabled: !busy,
          onSelected: (value) => setState(
            () => selectedTarget = value == null ? null : targets[value],
          ),
          dropdownMenuEntries: targets.entries.map((e) {
            final t = e.value,
                p = projects.where((p) => p['id'] == t.projectId).firstOrNull,
                s = item.projectSuggestions
                    .where((s) => s['projectId'] == t.projectId)
                    .firstOrNull;
            return DropdownMenuEntry(
              value: e.key,
              label: t.scope == 'global'
                  ? '全ての作業に共通（明示選択）'
                  : '${p?['title'] ?? t.projectId}${s == null
                        ? ''
                        : s['source'] == 'explicit'
                        ? ' / 元メモで指定'
                        : ' / AIの推定・確認が必要'}',
            );
          }).toList(),
        ),
        if (selectedTarget == null) const Text('採用先は未定です。却下・保留はそのまま行えます。'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final item = c.location?.identity == widget.identity
          ? c.review?.byId(widget.id)
          : null;
      if (!targetInitialized && item != null) {
        targetInitialized = true;
        if (item.suggestedTarget?.scope == 'project') {
          selectedTarget = item.suggestedTarget;
        }
      }
      return Scaffold(
        appBar: AppBar(title: const Text('候補の詳細')),
        body: item == null
            ? const Center(child: Text('候補を再取得してください。一覧へ戻ってください。'))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(
                        item.title,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text('${item.label} · ${reviewState(item)}'),
                      if (item.status == 'pending')
                        Text(item.inputIds.isEmpty ? '利用者の提案・未承認' : 'AI候補・未承認'),
                      const SizedBox(height: 16),
                      for (final warning in item.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(warning),
                        ),
                      if (error != null) NoticeBox(error!, error: true),
                      if (result != null) NoticeBox(result!),
                      if (item.actionable &&
                          c.review!.requestIdFor(item.id) != null)
                        const NoticeBox('依頼保存済み・Miniの判断待ちです。受付状況で結果を確認してください。'),
                      const SizedBox(height: 20),
                      ReviewContent(controller: c, item: item),
                      const SizedBox(height: 24),
                      if (item.actionable && item.kind != 'project') ...[
                        _targetPicker(item),
                        const SizedBox(height: 16),
                      ],
                      if (item.retirable)
                        FilledButton(
                          key: const Key('review-retire'),
                          onPressed:
                              busy ||
                                  result != null ||
                                  c.captureWarning != null ||
                                  c.review!.retirementRequestIdFor(item.id) !=
                                      null
                              ? null
                              : () => decide('retire'),
                          child: const Text('適用停止する'),
                        ),
                      if (item.status == 'approved' &&
                          c.review!.retirementRequestIdFor(item.id) != null)
                        const NoticeBox('適用停止の依頼保存済み・Miniの判断待ちです。'),
                      if (item.actionable)
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            FilledButton(
                              key: const Key('review-approve'),
                              onPressed:
                                  busy ||
                                      (item.kind != 'project' &&
                                          selectedTarget == null) ||
                                      result != null ||
                                      c.review!.requestIdFor(item.id) != null ||
                                      c.captureWarning != null
                                  ? null
                                  : () => decide('approve'),
                              child: const Text('採用する'),
                            ),
                            OutlinedButton(
                              key: const Key('review-reject'),
                              onPressed:
                                  busy ||
                                      result != null ||
                                      c.review!.requestIdFor(item.id) != null ||
                                      c.captureWarning != null
                                  ? null
                                  : () => decide('reject'),
                              child: const Text('却下する'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => Navigator.pop(context),
                              child: const Text('保留して閉じる'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}

class ReviewContent extends StatelessWidget {
  const ReviewContent({
    super.key,
    required this.controller,
    required this.item,
    this.links = true,
  });
  final HubController controller;
  final ReviewCandidate item;
  final bool links;
  @override
  Widget build(BuildContext context) {
    final repo = controller.repository!;
    Widget source(String id) {
      final record = repo.records.values
          .where((r) => r.sourceId == id)
          .firstOrNull;
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (links && record != null)
              TextButton(
                key: const Key('review-source'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        RecordView(controller: controller, record: record),
                  ),
                ),
                child: Text('元のメモを開く: $id'),
              )
            else
              SelectableText(id, style: const TextStyle(fontSize: 12)),
            SelectableText(
              record?.body ?? '元のメモが未同期です。',
              style: const TextStyle(height: 1.7),
            ),
          ],
        ),
      );
    }

    final projectDetails = item.kind == 'project'
        ? '別名: ${item.aliases.join('、')}\n検索語: ${item.keywords.join('、')}'
        : null;
    final previous = item.supersedes == null
        ? null
        : repo.snapshot.files.entries
              .where((e) => e.key.endsWith('/${item.supersedes}.md'))
              .firstOrNull
              ?.value;
    String? previousBody;
    if (previous != null) {
      try {
        previousBody = parseMarkdown(previous).body;
      } catch (_) {
        previousBody = '置き換え元の形式を確認できません。';
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.adoptedTarget != null)
          Text('採用先: ${item.adoptedTarget!.label}'),
        if (item.retired) Text('適用停止: ${item.retiredAt ?? "記録あり"}（本文と履歴を保持）'),
        const Text(
          '主張・内容',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        SelectableText(
          item.claim,
          style: const TextStyle(fontSize: 17, height: 1.7),
        ),
        if (projectDetails != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(projectDetails),
          ),
        const SizedBox(height: 20),
        const Text('候補になった理由', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SelectableText(
          item.rationale.isEmpty ? '理由の記載はありません。' : item.rationale,
        ),
        const SizedBox(height: 20),
        SelectableText(
          '候補: ${item.id}\n生成: ${item.generatedAt ?? '未取得'}${item.decisionId == null ? '' : '\n判断: ${item.decisionId}'}',
          style: const TextStyle(fontSize: 12, height: 1.8),
        ),
        const SizedBox(height: 20),
        const Text(
          '元のメモ・訂正履歴',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        if (item.inputIds.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('利用者の提案（原文なし）'),
          ),
        for (final id in item.inputIds) source(id),
        if (item.supersedes != null) ...[
          const SizedBox(height: 20),
          const Text('置き換え元', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(item.supersedes!),
          SelectableText(previousBody ?? '未同期です。'),
        ],
      ],
    );
  }
}
