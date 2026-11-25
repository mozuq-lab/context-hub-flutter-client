import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../notice.dart';
import '../parts.dart';
import '../reference_shelf.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'item_actions.dart';
import 'item_rows.dart';
import 'progress_section.dart';
import 'someday_page.dart';
import 'today_section.dart';

/// プロジェクト未定の次の一手（本人の行動とメモから出た行）。
extension HubUnassigned on HubViewState {
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
            total =
            repo.unassignedActionCount,
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
              onPressed: () => refresh(
                () => unassignedShown += HubViewState.unassignedPageSize,
              ),
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
        progressPending = repo.progressRequestIdFor(item.key) != null,
        progress = records && progressAvailable(item),
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
            !progressPending &&
            !somedayPending;
    final more = <PopupMenuEntry<VoidCallback>>[
      ...progressMenu(
        unassignedScope,
        item,
        'unassigned-$tag',
        enabled: progress && !progressPending,
      ),
      ...stepsMenu(
        unassignedScope,
        item,
        'unassigned-$tag',
        steps && !stepsPending,
      ),
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
          if (progressPending && records)
            Text('取りかかり中を依頼済み（反映待ち）', style: noteStyle(context)),
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
        if (item.progressing) progressLine(item),
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
}
