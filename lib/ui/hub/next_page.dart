import 'package:flutter/material.dart';

import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../labels.dart';
import '../parts.dart';
import '../theme.dart';
import 'home_page.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'item_actions.dart';
import 'item_rows.dart';
import 'today_section.dart';
import 'unassigned_section.dart';

/// 「次の一手」画面と、項目の行・ボタン。
extension HubNext on HubViewState {
  /// 進行中のプロジェクトの「次の一手」（または未解決）を、ピン留めしたものから順に、残りは最新の根拠が新しい順にまとめる。
  /// 本人が付けた期日が過ぎた・今日・7日以内の項目はプロジェクトをまたいで先頭に出し、見直す日が先の項目はたたむ。
  List<Widget> nextView() {
    // 期日の通知から開いたら、通知で数えた項目が隠れないよう、次の一手の欄に戻して絞り込みを外す。
    if (c.dueOpened != dueOpenedShown) {
      dueOpenedShown = c.dueOpened;
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
            ownListed =
            <NowItemRef>[],
            // 本人が連絡待ちの印を付けた項目。一覧・件数・期日の欄から外し、「連絡待ち」にまとめる。
            // 見直す日が来たものは、先頭の「連絡待ちの確認」にも出す。
            waits =
            <(HubProject?, NowEntry?, NowItemRef, int)>[],
            // 先の項目が残っている項目（先待ち）と、先の項目が片付いて取りかかれるようになった項目。
            // 先待ちは一覧から外して下にまとめ（件数には含める）、取りかかれるようになった項目は先頭に出す。
            blocked =
            <(HubProject?, NowEntry?, NowItemRef, int)>[],
        ready = <(HubProject?, NowEntry?, NowItemRef, int)>[],
            // 次の一手の画面に出す、未解決の欄の連絡待ち（HOMEと同じく、次の一手の画面でもまとめて示す）。
            openWaits =
            Set<NowEntry>.identity();
    // 手間の目安での絞り込み。目安に対応した本体のときだけ使う。
    final efforts = repo.intakeFeatures.effort,
        filter = efforts ? effortFilter : null;
    // 場所・道具の札での絞り込み。札に対応した本体のときだけ使う。手間の目安と両方選ぶと、両方に合う項目だけを出す。
    final contextsOn = repo.intakeFeatures.contexts,
        tags = contextsOn ? repo.contextTagsInUse : const <String>[],
        contextChoice = contextsOn && contextFilter != null
            ? (contextFilter == contextFilterNone ||
                      tags.contains(contextFilter)
                  ? contextFilter
                  : null)
            : null,
        filtering = filter != null || contextChoice != null;
    // 選んでいた札が選択肢から消えたら、絞り込みを外したことにする（後で札が戻っても、黙って絞り込み直さない）。
    if (contextFilter != null && contextChoice == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && contextFilter != null) {
          refresh(() => contextFilter = null);
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
        if (item != null && blockedNow(item)) {
          blocked.add((project, entry, item, order));
          continue;
        }
        if (item != null && readyNow(item) && !filtering) {
          ready.add((project, entry, item, order));
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
            onSelectionChanged: (v) => refresh(() => nextSection = v.single),
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
                      onSelected: (_) => refresh(() => effortFilter = value),
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
                      onSelected: (_) => refresh(() => contextFilter = value),
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
      if (ready.isNotEmpty) ...[
        sectionHeading(
          '動けるようになった項目（${ready.length}件）',
          key: const Key('next-ready'),
          note: '先に済ませることがすべて片付いた項目です。取りかかるか、「先に済ませることを変える・外す」で印を外してください。',
        ),
        entryCard([for (final e in ready) crossEntry(e)]),
      ],
      if (checks.isNotEmpty) ...[
        sectionHeading(
          '連絡待ちの確認（${checks.length}件）',
          key: const Key('next-waiting-checks'),
          note: '見直す日が来た連絡待ちです。返事が来ていれば「連絡待ちを外す」か完了に、まだなら催促して見直す日を付け直してください。',
        ),
        entryCard([for (final e in checks) crossEntry(e)]),
      ],
      if (projects.isEmpty &&
          front.isEmpty &&
          resting.isEmpty &&
          waits.isEmpty &&
          blocked.isEmpty &&
          ready.isEmpty)
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
      // 先待ちのまとまり。絞り込み中は出さない（先の項目が片付くまで取りかかれないため）。
      if (blocked.isNotEmpty && !filtering) ...[
        sectionHeading(
          '先待ち（${blocked.length}件）',
          key: const Key('next-blocked'),
          note:
              '先に済ませることが残っている項目です。${sectionLabels[section]}の件数には含みます。先の項目が片付くと、先頭の「動けるようになった項目」に出ます。',
        ),
        entryCard([for (final e in blocked) crossEntry(e)]),
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
}
