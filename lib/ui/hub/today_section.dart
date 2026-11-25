import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/today.dart';
import '../notice.dart';
import '../parts.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'item_actions.dart';
import 'unassigned_section.dart';

/// 「今日の3つ」の選択と持ち越し。
extension HubToday on HubViewState {
  /// 「今日やる」「今日から外す」。選んだ項目はこの端末だけに残し、Vaultには書かない。
  Widget todayToggle(String projectId, String key) {
    final focus = c.today, on = focus.picked(key);
    return TextButton.icon(
      key: Key('today-${key.substring(0, 12)}'),
      // 3つ埋まっている間は、外す操作だけを受け付ける。
      onPressed: !on && focus.full ? null : () => setToday(projectId, key, !on),
      icon: Icon(on ? Icons.wb_sunny : Icons.wb_sunny_outlined, size: 15),
      label: Text(on ? '今日の3つから外す' : '今日やる'),
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
    if (!await scheduleItem(entry.pick.projectId, entry.item!)) return;
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
        e.unassigned ? 'プロジェクト未定' : e.project?.title ?? e.pick.projectId,
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
          finished = e.done || reported || e.someday;
      return KeyedSubtree(
        key: Key('today-pick-${key.substring(0, 12)}'),
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
                '見つかりません。言い換えられたか、片付いた可能性があります。',
                style: TextStyle(fontSize: 12, color: scheme.error),
              )
            else if (e.done)
              Text(
                e.item!.excluded
                    ? (e.unassigned ? '却下しました' : '誤りとして外しました')
                    : '片付きました',
                style: const TextStyle(fontSize: 12),
              )
            else if (reported)
              Text('報告済み（反映待ち）', style: noteStyle(context))
            else if (e.someday)
              const Text('「いつかやる」へ移しました', style: TextStyle(fontSize: 12)),
            rowActions(
              context,
              Wrap(
                spacing: 2,
                children: [
                  if (!finished && !e.missing)
                    TextButton.icon(
                      key: Key('today-resolve-${key.substring(0, 12)}'),
                      onPressed: busy
                          ? null
                          : () => e.unassigned
                                ? reportUnassigned(e.item!, 'resolve')
                                : reportItem(e.project!, e.item!, 'resolve'),
                      icon: const Icon(Icons.check_circle_outline, size: 15),
                      label: Text(
                        e.item!.section == 'next' ? '完了にする' : '解決にする',
                      ),
                    ),
                  TextButton.icon(
                    key: Key('today-remove-${key.substring(0, 12)}'),
                    onPressed: () => setToday(e.pick.projectId, key, false),
                    icon: const Icon(Icons.close, size: 15),
                    label: const Text('今日の3つから外す'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget carryRow(TodayEntry e) {
      final key = e.pick.itemKey,
              // 日付が変わった後に片付いた・報告した項目は、続けたり日付を付けたりできない。
              closed =
              e.missing ||
              e.done ||
              e.someday ||
              repo.itemRequestIdFor(key) != null;
      return KeyedSubtree(
        key: Key('today-carry-${key.substring(0, 12)}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            projectLink(e),
            Text(e.text),
            if (e.missing)
              Text(
                '見つかりません。言い換えられたか、片付いた可能性があります。',
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
            rowActions(
              context,
              Wrap(
                spacing: 2,
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
                  // プロジェクト未定の行には、本人が追加した行動にだけ、対応した本体のときに期日を付けられる。
                  if (!closed &&
                      e.item != null &&
                      (!e.unassigned ||
                          (e.item!.action &&
                              repo.intakeFeatures.unassignedRecords)) &&
                      repo.scheduleRequestIdFor(key) == null)
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
                    label: const Text('今日はやらない'),
                  ),
                ],
              ),
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
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '前の日から持ち越した項目（${carry.length}件）',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    focus.full
                        ? '今日の3つは埋まっています。続けるなら、先に今日の3つから外してください。'
                        : '今日も続けるか、期日を付けるか、今日はやらないかを選んでください。',
                    style: noteStyle(context),
                  ),
                  const SizedBox(height: 4),
                  ...dividedRows([for (final e in carry) carryRow(e)]),
                  // 最後の行の操作と見分けられるよう、線で区切る。
                  const Divider(height: 1),
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
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '今日の3つ（${picks.length}/$todayMax）',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  ...dividedRows([for (final e in picks) pickRow(e)]),
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
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ];
  }
}
