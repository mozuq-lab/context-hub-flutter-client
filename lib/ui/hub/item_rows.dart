import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../../core/parser.dart' show clip;
import '../labels.dart';
import '../markdown_view.dart';
import '../parts.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'item_actions.dart';
import 'progress_section.dart';
import 'someday_page.dart';
import 'today_section.dart';

/// 次の一手・未解決の行と、行ごとの操作のボタン・メニュー（「次の一手」画面・プロジェクト・ホームで共通）。
extension HubItemRows on HubViewState {
  /// 項目の下に添える、先に済ませることの説明（先の項目と今の状態）。
  Widget afterNote(NowItemRef item) {
    final after = item.after!, states = prerequisiteStates(item);
    final ready = blockSettled(states);
    final tag = item.key.substring(0, 12);
    return Padding(
      key: Key('after-note-$tag'),
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ready
                ? '先に済ませることが片付きました。取りかかれます。'
                : '先に済ませること（残り${states.where((s) => s == PrerequisiteState.open).length}件）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: ready ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          for (final (i, a) in after.items.indexed)
            Text(
              '${i + 1}. ${clip((repo.findPrerequisite(a)?.text ?? a.text).trim(), 60)}（${scopeTitle(repo.prerequisiteScope(a))}・${prerequisiteStateLabels[states[i]]}）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (states.contains(PrerequisiteState.missing))
            Text(
              '見当たらない項目は待ちません。本文が変わった場合は、選び直してください。',
              style: noteStyle(context),
            ),
        ],
      ),
    );
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
            contextsPending =
            repo.contextsRequestIdFor(key) != null,
        contexts = repo.intakeFeatures.contexts && !project.merged,
            // 手順（次の一手だけ）。依頼が反映待ちの間は出さない。
            stepsPending =
            repo.stepsRequestIdFor(key) != null,
        steps =
            repo.intakeFeatures.steps &&
            !project.merged &&
            section == 'next' &&
            !item.resolved,
            // 連絡待ちの印。依頼が反映待ちの間は出さない。
            waitPending =
            repo.waitRequestIdFor(key) != null,
        wait = repo.intakeFeatures.wait && !project.merged,
            // 先に済ませること（プロジェクトの項目だけ）。依頼が反映待ちの間は出さない。
            blocksPending =
            repo.blocksRequestIdFor(key) != null,
        blocks = repo.intakeFeatures.blocks && !project.merged,
            // 取りかかり中（次の一手だけ）。依頼が反映待ちの間は出さない。
            progressPending =
            repo.progressRequestIdFor(key) != null,
        progress = progressAvailable(item, merged: project.merged),
            // 「いつかやる」へ移す・戻す。依頼が反映待ちの間は出さない。連絡待ちの項目には出さない。
            somedayPending =
            repo.somedayRequestIdFor(key) != null,
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
            !progressPending &&
            !somedayPending &&
            !blocksPending,
        calendar = c.access.calendarSupported && validScheduleDate(item.due) && !item.resolved;
    final more = <PopupMenuEntry<VoidCallback>>[
      ...progressMenu(
        project.id,
        item,
        tag,
        enabled: progress && !progressPending,
      ),
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
      if (blocks && !blocksPending)
        PopupMenuItem(
          key: Key('blocks-$tag'),
          value: () => blocksItem(project.id, item),
          child: Text(item.after == null ? '先に済ませることを選ぶ' : '先に済ませることを変える・外す'),
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
      if (progressPending) progressPendingNote(),
      if (blocksPending)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('先に済ませることを依頼済み（反映待ち）', style: noteStyle(context)),
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
        // 取りかかり中の日数とひとこと（NOWの本文には始めた日だけを書くため、ここで示す）。
        if (project.itemOf(entry) case final item? when item.progressing)
          progressLine(item),
        // 先に済ませること（NOWの本文には件数だけを書くため、先の項目と状態をここで示す）。
        if (project.itemOf(entry) case final item?
            when item.after != null && !item.resolved)
          afterNote(item),
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
}
