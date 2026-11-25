import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../labels.dart';
import '../notice.dart';
import '../parts.dart';
import '../review_view.dart';
import 'home_page.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'insights_section.dart';
import 'item_actions.dart';
import 'item_rows.dart';
import 'progress_section.dart';
import 'project_actions.dart';
import 'someday_page.dart';
import 'unassigned_section.dart';

/// 週次レビューの画面。
extension HubWeekly on HubViewState {
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
        (i, _) => !i.waiting && !i.someday && !i.scheduled && !i.progressing,
      );

  /// 止まった取りかかり中（印を外した・ひとことを書き直して動き出した・片付けた項目は除く）。
  List<(WeeklyItem, HubProject?, NowEntry?, NowItemRef)>
  get weeklyStalledProgress => weeklyRows(
    repo.weeklyReview?.progressStale ?? const [],
    (i, _) => progressStale(i, hubToday(), progressStaleDays),
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
  List<HubProject> get weeklyStaleProjects =>
      [
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
    'projects' =>
      weeklyEmptyProjects.length +
          weeklyLingering.length +
          weeklyStalledProgress.length,
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
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
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
            stalled = weeklyStalledProgress,
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
                    '${a.area ?? noAreaLabel}: 進行中 ${a.active}件・休止 ${a.paused}件・完了 ${a.done}件${a.noActive
                        ? '（進行中なし）'
                        : a.quiet
                        ? '（30日以上動いていない）'
                        : ''}',
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
        if (empty.isEmpty &&
            lingering.isEmpty &&
            stalled.isEmpty &&
            hinted.isEmpty) {
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
        if (stalled.isNotEmpty) {
          body.add(
            weeklyHeading(
              '止まった取りかかり中（${stalled.length}件）',
              key: const Key('weekly-progress-stale'),
            ),
          );
          body.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '取りかかり中のまま$progressStaleDays日以上、印もひとことも更新していない項目です。続けるなら「どこまで進んだか書く」で書き直し、手を止めているなら「取りかかり中をやめる」か「いつかやる」へ移してください。',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          );
          body.add(
            weeklyCard([
              for (final r in stalled)
                weeklyRow(
                  r,
                  head: '${waitingDays(r.$4.progressUpdated!, today)}日更新なし',
                ),
            ]),
          );
          if (review.progressStaleTotal > review.progressStale.length) {
            body.add(
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'ほかに${review.progressStaleTotal - review.progressStale.length}件あります（更新の古い${review.progressStale.length}件だけを並べています）。',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            );
          }
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
}
