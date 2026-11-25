import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../dialogs/pin_order_dialog.dart';
import '../labels.dart';
import '../markdown_view.dart';
import '../notice.dart';
import '../parts.dart';
import '../review_view.dart';
import '../save_checks.dart';
import '../theme.dart';
import 'day_close_section.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'insights_section.dart';
import 'item_actions.dart';
import 'today_section.dart';
import 'weekly_page.dart';

/// ホーム画面と、プロジェクトのカード・ピン留め・ふりかえりへの入口。
extension HubHome on HubViewState {
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

  /// ホーム。今日の入口・次の一手・判断待ち・プロジェクト・最近のメモ・保存の状況を並べる。
  List<Widget> homeView() {
    final children = <Widget>[];
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
    // 前回の締めで残した明日へのひとことは、今日の3つより前に置く（次に締めるか消すまで出す）。
    children.addAll(dayNoteHome());
    // 本人が今日やると決めたものを、いちばん上に置く。
    children.addAll(todaySection(compact: true));
    children.addAll(dayCloseHome());
    children.addAll(readyHome());
    // 今週の気づきは、行動につながる欄（次の一手）より前に置く。
    children.addAll(insightsHome());
    // 件数の札。毎日開く画面への入口を横に並べ、件数と要点だけを示す。
    // プロジェクトを決めずに本人が追加した行動も、次の一手として数える。
    final actionable = repo.actionableProjects,
        ownUnassigned = repo.unassignedActionCount,
        nextCount =
            actionable.fold<int>(0, (n, p) => n + p.nextCount) + ownUnassigned,
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
            HubViewState.homeUnassigned,
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
            (HubViewState.homeUnassigned - repo.unassignedPendingActions.length)
                .clamp(0, HubViewState.homeUnassigned),
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
            (HubViewState.homeUnassigned - ownUnassigned).clamp(
              0,
              HubViewState.homeUnassigned,
            ),
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
    final mergedProjects = repo.projects.values.where((p) => p.merged).toList();
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
      final filter =
          areas.contains(areaFilter) ||
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
                onSelected: (_) => refresh(() => areaFilter = null),
              ),
              for (final a in areas)
                ChoiceChip(
                  key: Key('area-filter-${a ?? noAreaLabel}'),
                  label: Text(a ?? noAreaLabel),
                  selected: filter == (a ?? noAreaLabel),
                  onSelected: (_) =>
                      refresh(() => areaFilter = a ?? noAreaLabel),
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
      for (final (_, item, memos) in proposals.take(HubViewState.homeProposals))
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
              (s) => const ['failed', 'rejected', 'conflict'].contains(s.state),
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
    return children;
  }

  /// ホームに出す、先に済ませることが片付いて取りかかれるようになった項目。
  List<Widget> readyHome() {
    final items = [
      for (final p in repo.actionableProjects)
        for (final i in p.nowItems)
          if (readyNow(i) && !i.someday && !i.waiting) (p, i),
    ];
    if (items.isEmpty) return const [];
    void openNext() {
      nextSection = 'next';
      widget.onNavigate('next');
    }

    return [
      sectionHeading('動けるようになった項目（${items.length}件）'),
      groupCard([
        for (final (p, i) in items.take(HubViewState.homeUnassigned))
          ListTile(
            key: Key('home-ready-${i.key.substring(0, 12)}'),
            dense: true,
            title: Text(
              i.display,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${p.title}・先に済ませることが片付きました'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: openNext,
          ),
      ]),
      const SizedBox(height: 12),
    ];
  }
}
