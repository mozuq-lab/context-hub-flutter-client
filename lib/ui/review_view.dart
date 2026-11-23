import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../core/review_candidates.dart';
import '../core/parser.dart';
import '../core/repository.dart' show displayTime;
import 'parts.dart';
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
  'stale' => '古い候補・採用できません',
  _ => '同期・形式の確認が必要',
};

/// 同じ対象を指すプロジェクト案のまとめを、一覧の行に添える。
/// 代表の案には根拠のメモの件数（まとめた案の数＋1）を、まとめて判断された案には代表の案の名前を示す。
String groupNote(ReviewRepository r, ReviewCandidate i) {
  final members = r.groupMembers(i).length;
  if (members > 0) return ' · 根拠のメモ${members + 1}件（同じ対象の案をまとめて表示）';
  if (i.coveredBy case final lead?) {
    return ' · 「${r.byId(lead)?.title ?? lead}」とまとめて判断';
  }
  return '';
}

/// 採用した方針の見直しの状態を、一覧の行に添える。見直す時期の方針と、「まだ有効」の依頼を保存済みの方針だけ。
String policyNote(ReviewRepository r, ReviewCandidate i) {
  final review = i.policyReview;
  if (!i.keepable || review == null) return '';
  if (r.policyKeepRequestIdFor(i.id) != null) {
    return '\n「まだ有効」を依頼済み・Mac miniの記録待ち';
  }
  return review.due
      ? '\n見直す時期（${review.confirmedAt == null ? '採用' : '前回確かめて'}から${review.days}日）'
      : '';
}

/// 採用・却下の依頼の状況を、一覧の行に添える。
String requestNote(ReviewRepository r, ReviewCandidate i) => !i.rejectable
    ? ''
    : r.requestIdFor(i.id) != null
    ? '\n依頼保存済み・Mac miniの判断待ち'
    : r.failedRequestIdFor(i.id) != null
    ? '\n前の依頼は受け付けられませんでした'
    : r.groupMembers(i).any((m) => r.failedRequestIdFor(m.id) != null)
    ? '\nまとめた案の前の依頼は受け付けられませんでした'
    : '';

/// まとめた判断を止めている理由と、どの案を外せば判断できるかの説明。
/// [clashes]は、採用を依頼済みの[blocker]と名前か別名が同じ、判断する案（代表の案[lead]とまとめる案）。
String groupBlockedNote(
  ReviewCandidate blocker,
  ReviewCandidate lead,
  List<ReviewCandidate> clashes,
) {
  String names(Iterable<ReviewCandidate> items) =>
      items.map((c) => '「${c.title}」').join();
  return '「${blocker.title}」の採用を依頼済みです。採用が反映されると、名前か別名が同じ${names(clashes)}は古い案になり、その案を含むまとめた依頼は全体が受け付けられなくなります。反映されるまで、まとめた判断は依頼できません。${clashes.any((c) => c.id == lead.id) ? '同期して、採用の反映を確かめてから判断してください（すべてのチェックを外すと、この案だけの判断はできます）。' : '${names(clashes)}のチェックを外すと、残りの案を判断できます。'}';
}

class ReviewView extends StatelessWidget {
  const ReviewView({super.key, required this.controller});
  final HubController controller;
  @override
  Widget build(BuildContext context) {
    final r = controller.review!;
    Widget section(String title, List<ReviewCandidate> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sectionTitle(context, '$title（${items.length}件）'),
        if (items.isEmpty)
          Text(
            '該当する候補はありません。',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          groupCard([
            for (final i in items)
              ListTile(
                key: Key('review-${i.id}'),
                title: Text(i.title),
                subtitle: Text(
                  '${i.label} · ${reviewState(i)}${groupNote(r, i)}${requestNote(r, i)}${policyNote(r, i)}',
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
          ]),
      ],
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: pageMaxWidth),
        child: ListView(
          padding: pagePadding(context),
          children: [
            pageTitle(
              context,
              '候補を確認する',
              subtitle:
                  'AIが見つけた方針・知識・プロジェクト案です。採用すると、AIが以後の作業で使います。内容と元のメモを見て決めてください。',
            ),
            for (final w in r.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NoticeBox(w, error: true),
              ),
            section('確認待ち', r.pendingRows),
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

  /// この画面で保存した依頼のREQ ID。本体が受け付けられなかったら、保存済みの表示をやめる。
  String? savedId;
  bool busy = false;
  AdoptionTarget? selectedTarget;
  bool targetInitialized = false;

  /// まとめた案のうち、本人がこの判断から外した案。
  final excluded = <String>{};
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
        exclude: {...excluded},
      );
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action == 'retire'
                ? 'この採用済み記録を適用停止しますか？'
                : ticket.covers.isNotEmpty
                ? 'まとめた${ticket.covers.length + 1}件の案を${action == 'approve' ? '採用' : '却下'}しますか？'
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
                      '使う場所: ${ticket.target!.label}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  if (action == 'retire')
                    const Text('自動適用を止めます。本文と採用履歴は保持します。'),
                  if (ticket.covers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        action == 'approve'
                            ? '「${ticket.candidate.title}」の名前・別名・検索語でプロジェクトを作ります。同じ対象を指す案${ticket.covers.length}件にも、同じ採用を記録します。'
                            : '同じ対象を指す案${ticket.covers.length}件にも、同じ却下を記録します。',
                        key: const Key('review-covers-note'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ReviewContent(
                    controller: c,
                    item: ticket.candidate,
                    links: false,
                  ),
                  for (final cover in ticket.covers) ...[
                    const Divider(height: 40),
                    Text(
                      '同じ判断にまとめる案: ${cover.title}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ReviewContent(controller: c, item: cover, links: false),
                  ],
                  const SizedBox(height: 20),
                  const Text('これは依頼の保存です。Mac miniで判断が確定し反映されるまで、正式データは変わりません。'),
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
        setState(() {
          savedId = saved.requestId;
          result = saved.saved
              ? '依頼をこの端末に保存しました。同期・Mac miniの判断待ちです。'
              : '保存結果が不明です。再送せず、保存と反映から同じ操作の保存確認をしてください。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    } finally {
      c.composing = false;
      if (mounted) setState(() => busy = false);
    }
  }

  /// 採用した方針を「まだ有効」と確かめる。確かめた内容のhashに結び付けて依頼し、内容が変わっていれば本体が断る。
  Future<void> keep(ReviewCandidate item) async {
    if (busy || c.composing) return;
    final hash = item.dependencies[item.targetPath];
    if (hash is! String) return;
    setState(() {
      busy = true;
      error = null;
    });
    c.composing = true;
    try {
      if (c.location?.identity != widget.identity) {
        throw StateError('Vaultが切り替わりました。一覧へ戻ってください。');
      }
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('この方針はまだ有効ですか？'),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    item.claim,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '今の内容のまま続けることを記録し、見直しの日数をここから数え直します。方針の本文は変わりません。'
                    '変えたいときは適用停止するか、置き換える候補を作ってください。',
                  ),
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
              key: const Key('confirm-policy-keep'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('まだ有効と記録'),
            ),
          ],
        ),
      );
      if (yes != true) return;
      final saved = await c.requestPolicyKeep(item.id, hash);
      if (mounted) {
        setState(() {
          savedId = saved.requestId;
          result = saved.saved
              ? '「まだ有効」をこの端末に保存しました。同期・Mac miniの記録待ちです。'
              : '保存結果が不明です。再送せず、保存と反映から同じ操作の保存確認をしてください。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    } finally {
      c.composing = false;
      if (mounted) setState(() => busy = false);
    }
  }

  /// 採用した方針の見直しの状態と、「まだ有効」のボタン。古い本体は依頼を受け付けないので、対応を書き出している本体のときだけボタンを出す。
  Widget _policyReview(ReviewCandidate item) {
    final review = item.policyReview!,
        requested = c.review!.policyKeepRequestIdFor(item.id) != null,
        supported = c.repository?.intakeFeatures.policyKeep == true;
    final since = review.confirmedAt == null
        ? '採用から${review.days}日'
        : '前回「まだ有効」と確かめてから${review.days}日（${displayTime(review.confirmedAt!)}）';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NoticeBox(
            review.due
                ? '見直す時期です（$since）。今も同じ考えか確かめてください。続けるなら「まだ有効」、やめるなら適用停止します。'
                : '$since。${review.reviewDays}日を過ぎるとHOMEの「見直す方針」に出ます。',
            key: const Key('policy-review-state'),
          ),
          const SizedBox(height: 8),
          if (requested)
            const NoticeBox('「まだ有効」の依頼保存済み・Mac miniの記録待ちです。')
          else if (supported)
            OutlinedButton(
              key: const Key('policy-keep'),
              onPressed:
                  busy ||
                      c.captureWarning != null ||
                      c.review!.retirementRequestIdFor(item.id) != null
                  ? null
                  : () => keep(item),
              child: const Text('まだ有効'),
            ),
        ],
      ),
    );
  }

  Widget _targetPicker(ReviewCandidate item) {
    // 統合済みのプロジェクトは採用先にできない（本体が受け付けない）ので、選択肢から外す。
    final projects =
        [
          for (final p in c.review!.projects)
            if (c.repository?.projects[p['id']]?.merged != true) p,
        ]..sort(
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
              ? 'どこで使うか（必要なときにAIが参照します）'
              : 'どこで使うか（AIが作業で守ります）',
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
          hintText: '使う場所を選んでください',
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
                  ? 'すべての作業（共通）'
                  : '${p?['title'] ?? t.projectId}${s == null
                        ? ''
                        : s['source'] == 'explicit'
                        ? ' · 元のメモで指定'
                        : ' · AIの推定'}',
            );
          }).toList(),
        ),
        if (selectedTarget == null)
          const Text(
            '使う場所は未定です。新しいプロジェクトはここでは作れないので、必要なら先に作ってください。却下は選ばずにできます。',
          ),
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
      // 同じ対象を指すプロジェクト案のまとめ。代表の案ならまとめた案を、まとめられた案なら代表の案を示す。
      final members = item == null
              ? const <ReviewCandidate>[]
              : c.review!.groupMembers(item),
          lead = item == null ? null : c.review!.groupLead(item);
      // 依頼の状況と、この判断にまとめる案（本人が外した案を除く）。依頼済みのときは、依頼に含めた案がそのまま対象になる。
      final requested = item != null && c.review!.requestIdFor(item.id) != null,
          included = requested
              ? members
              : [
                  for (final member in members)
                    if (!excluded.contains(member.id)) member,
                ],
          failed = item == null
              ? const <String>[]
              : c.review!.failedRequestIdsFor(item.id),
          // この画面で保存した依頼を本体が受け付けられなかったら、保存済みの表示をやめて、もう一度判断できるようにする。
          notice = failed.contains(savedId)
              ? null
              : result,
          blocker = item == null
              ? null
              : c.review!.groupBlocker(item, included),
          waiting = item == null ? null : c.review!.approveBlocker(item);
      if (!targetInitialized && item != null) {
        targetInitialized = true;
        if (item.suggestedTarget?.scope == 'project') {
          selectedTarget = item.suggestedTarget;
        }
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('候補の詳細'),
        ),
        body: item == null
            ? const Center(child: Text('候補を再取得してください。一覧へ戻ってください。'))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView(
                    padding: pagePadding(context).copyWith(bottom: 48),
                    children: [
                      Text(
                        item.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text('${item.label} · ${reviewState(item)}'),
                      if (item.status == 'pending')
                        Text(item.inputIds.isEmpty ? '利用者の提案・未承認' : 'AI候補・未承認'),
                      const SizedBox(height: 16),
                      for (final warning in item.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(warning),
                        ),
                      if (members.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(
                            '同じ対象を指す案${members.length}件をまとめています（根拠のメモ${members.length + 1}件）。採用・却下は、チェックを付けた案にも同じ判断として記録します。別の取り組みの案は、チェックを外すとこの判断から外れ、確認待ちに残ります。「この案だけを判断する」から1件ずつ判断することもできます。',
                            key: const Key('review-group'),
                          ),
                        ),
                      if (blocker != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(
                            groupBlockedNote(
                              blocker,
                              item,
                              c.review!.sameNamed(blocker, [item, ...included]),
                            ),
                            key: const Key('review-group-blocked'),
                          ),
                        ),
                      if (waiting != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(
                            '「${waiting.title}」をまとめた判断を依頼済みです。この案の採用が先に反映されると、名前か別名が同じ案が古い案になり、まとめた依頼の全体が受け付けられなくなります。まとめた判断が反映されるまで、この案の採用は依頼できません。却下はできます。',
                            key: const Key('review-approve-blocked'),
                          ),
                        ),
                      if (lead != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(
                            '「${lead.title}」と同じ対象の案としてまとめて表示しています。ここでの採用・却下は、この案だけに記録します。',
                            key: const Key('review-grouped'),
                          ),
                        ),
                      if (item.coveredBy case final by?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(
                            '「${c.review!.byId(by)?.title ?? by}」と同じ対象の案として、まとめて判断しました。',
                            key: const Key('review-covered'),
                          ),
                        ),
                      // 判断済みの案だけに示す（この端末で読めないだけの確認待ちの案には示さない）。
                      if (const [
                            'approved',
                            'rejected',
                          ].contains(item.data['status']) &&
                          item.duplicates.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NoticeBox(
                            '同じ判断にまとめた案: ${item.duplicates.map((id) => c.review!.byId(id)?.title ?? id).join('、')}',
                            key: const Key('review-covers'),
                          ),
                        ),
                      if (error != null) NoticeBox(error!, error: true),
                      if (notice != null) NoticeBox(notice),
                      if (item.rejectable && requested)
                        const NoticeBox(
                          '依頼保存済み・Mac miniの判断待ちです。保存と反映で結果を確認してください。',
                        ),
                      if (item.rejectable &&
                          notice == null &&
                          failed.isNotEmpty)
                        const NoticeBox(
                          '前の依頼は、Mac miniが受け付けませんでした。確認した後に、候補・採用先・まとめた案の状況が変わった可能性があります（保存と反映に理由が出ることがあります）。内容を確かめて、もう一度判断できます。',
                          key: Key('review-failed'),
                          error: true,
                        ),
                      const SizedBox(height: 20),
                      ReviewContent(controller: c, item: item),
                      for (final member in members) ...[
                        const Divider(height: 48),
                        Text(
                          'まとめた案: ${member.title}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        ReviewContent(controller: c, item: member),
                        if (c.review!.failedRequestIdFor(member.id) != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: NoticeBox(
                              'この案の前の依頼は、Mac miniが受け付けませんでした。',
                              key: Key('review-member-failed-${member.id}'),
                              error: true,
                            ),
                          ),
                        CheckboxListTile(
                          key: Key('review-include-${member.id}'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: included.contains(member),
                          // 依頼を保存した後は、まとめる案を選び直せない。
                          onChanged: busy || requested || notice != null
                              ? null
                              : (value) => setState(
                                  () => value == true
                                      ? excluded.remove(member.id)
                                      : excluded.add(member.id),
                                ),
                          title: const Text('この案にも同じ判断を記録する'),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: Key('review-member-${member.id}'),
                            onPressed: busy
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ReviewDetail(
                                        controller: c,
                                        id: member.id,
                                        identity: widget.identity,
                                      ),
                                    ),
                                  ),
                            child: const Text('この案だけを判断する'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (item.actionable && item.kind != 'project') ...[
                        _targetPicker(item),
                        const SizedBox(height: 16),
                      ],
                      if (item.keepable) _policyReview(item),
                      if (item.retirable)
                        FilledButton(
                          key: const Key('review-retire'),
                          onPressed:
                              busy ||
                                  notice != null ||
                                  c.captureWarning != null ||
                                  c.review!.retirementRequestIdFor(item.id) !=
                                      null
                              ? null
                              : () => decide('retire'),
                          child: const Text('適用停止する'),
                        ),
                      if (item.status == 'approved' &&
                          c.review!.retirementRequestIdFor(item.id) != null)
                        const NoticeBox('適用停止の依頼保存済み・Mac miniの判断待ちです。'),
                      // 古くなった候補は採用できない。不要なら却下して要確認から片付ける。
                      if (item.status == 'stale') ...[
                        NoticeBox(
                          item.rejectable
                              ? 'この候補は古くなったため採用できません。不要なら却下すると、判断履歴へ移ります。'
                              : item.staleReject
                              ? 'この候補は古くなったため採用できません。確認情報が同期されると、ここから却下できます。'
                              : 'この候補は古くなったため採用できません。Mac miniの本体を更新すると、ここから却下できます。',
                          key: const Key('review-stale'),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (item.status == 'stale' && item.rejectable) ...[
                        OutlinedButton(
                          key: const Key('review-reject-stale'),
                          onPressed:
                              busy ||
                                  notice != null ||
                                  requested ||
                                  c.captureWarning != null
                              ? null
                              : () => decide('reject'),
                          child: const Text('却下する'),
                        ),
                      ],
                      if (item.actionable)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            adoptMeaning(item.kind),
                            key: const Key('review-meaning'),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
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
                                      notice != null ||
                                      requested ||
                                      blocker != null ||
                                      waiting != null ||
                                      c.captureWarning != null
                                  ? null
                                  : () => decide('approve'),
                              child: Text(
                                included.isEmpty
                                    ? '採用する'
                                    : '${included.length + 1}件をまとめて採用する',
                              ),
                            ),
                            OutlinedButton(
                              key: const Key('review-reject'),
                              onPressed:
                                  busy ||
                                      notice != null ||
                                      requested ||
                                      blocker != null ||
                                      c.captureWarning != null
                                  ? null
                                  : () => decide('reject'),
                              child: Text(
                                included.isEmpty
                                    ? '却下する'
                                    : '${included.length + 1}件をまとめて却下する',
                              ),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => Navigator.pop(context),
                              child: const Text('今は決めない'),
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
          Text('使う場所: ${item.adoptedTarget!.label}'),
        if (item.retired) Text('適用停止: ${item.retiredAt ?? "記録あり"}（本文と履歴を保持）'),
        Text(
          '主張・内容',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          item.claim,
          style: const TextStyle(fontSize: 16, height: 1.7),
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
        Text(
          '元のメモ・訂正履歴',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
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

/// 採用したときに起きること（種類ごと）。
String adoptMeaning(String kind) => switch (kind) {
  'project' => '採用すると、このプロジェクトを作ります。',
  'knowledge' => '採用すると、参考の知識として、必要なときにAIが参照します。',
  _ => '採用すると、方針として、AIが作業で守ります。',
};
