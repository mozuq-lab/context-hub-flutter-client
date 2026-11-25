import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../../core/today.dart';
import '../dialogs/day_close_dialog.dart';
import '../notice.dart';
import '../parts.dart';
import 'hub_common.dart';
import 'hub_view.dart';

/// 1日の締めと、明日へのひとこと。
extension HubDayClose on HubViewState {
  /// 連絡待ちの印を外すよう依頼する。項目は元の欄（次の一手・未解決）へ戻る。
  /// ホームの先頭に置く、前回の締めの明日へのひとこと。示すひとことがなければ空。
  List<Widget> dayNoteHome() {
    final note = repo.currentDayNote;
    if (note == null) return const [];
    final today = hubToday(),
        // 日付どうしの差はUTCで数える（夏時間の切り替えをまたいでも1日ずれない）。
        days = DateTime.parse('${today}T00:00:00Z')
            .difference(DateTime.parse('${note.on}T00:00:00Z'))
            .inDays,
        when = days <= 0
            ? '今日'
            : days == 1
            ? '昨日'
            : '$days日前',
        pending = repo.dayCloseRequestId != null;
    return [
      Card(
        key: const Key('home-day-note'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '前回の締め（${note.on}・$when）',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text('明日へのひとこと', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 2),
              SelectableText(note.note!, key: const Key('home-day-note-text')),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      pending ? '締め・消す依頼を保存済み（反映待ち）' : '次に締めると置き換わります。',
                      style: noteStyle(context),
                    ),
                  ),
                  if (repo.intakeFeatures.dayClose && !pending)
                    TextButton(
                      key: const Key('home-day-note-dismiss'),
                      onPressed: busy ? null : () => dismissDayNote(note),
                      child: const Text('消す'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
    ];
  }

  /// 今日を締める入口（本体が1日の締めに対応しているときだけ）。
  List<Widget> dayCloseHome() {
    if (!repo.intakeFeatures.dayClose) return const [];
    final pending = repo.dayCloseRequestId != null,
        closed = repo.dayCloseOn(hubToday()) != null;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const Key('home-day-close'),
              onPressed: busy || pending ? null : closeDay,
              icon: const Icon(Icons.nightlight_outlined, size: 18),
              label: Text(closed ? '今日の締めを書き直す' : '今日を締める'),
            ),
            if (pending)
              Text('締めを依頼済み（反映待ち）', style: noteStyle(context))
            else if (closed)
              Text('今日は締めてあります', style: noteStyle(context)),
          ],
        ),
      ),
    ];
  }

  /// 今日、完了・解決にした項目（誤りとして外したものは除く）。置き場の名前と項目。
  List<(String, NowItemRef)> doneToday(String today) => [
    for (final p in repo.orderedProjects)
      if (!p.merged)
        for (final i in p.nowItems)
          if (i.resolved &&
              !i.excluded &&
              i.resolvedAt != null &&
              hubToday(i.resolvedAt) == today)
            (p.title, i),
    for (final i in repo.unassignedItems)
      if (i.resolved &&
          !i.excluded &&
          i.resolvedAt != null &&
          hubToday(i.resolvedAt) == today)
        ('プロジェクト未定', i),
  ];

  /// 今日を締める。今日できたことと今日の3つの残りを確かめ、明日へのひとことを残す。
  Future<void> closeDay() async {
    final today = hubToday(), limits = repo.intakeFeatures.dayCloseLimits;
    if (limits == null) return;
    final memos = repo.recent
        .where(
          (r) =>
              r.kind == 'memo' &&
              r.receivedAt != null &&
              hubToday(r.receivedAt) == today,
        )
        .length;
    final remaining = [
      for (final p in c.today.picks)
        if (todayOpen(repo, p)) todayEntry(repo, p),
    ];
    final result = await showDialog<({String? note, Set<String> drop})>(
      context: context,
      builder: (_) => DayCloseDialog(
        today: today,
        done: doneToday(today),
        memos: memos,
        remaining: remaining,
        initialNote: repo.dayCloseOn(today)?.note,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final saved = await c.requestDayClose(today, result.note);
      // 今日の3つから外すのは、締めを保存できた後（断られたときは選んだままにする）。
      if (saved.saved) {
        for (final key in result.drop) {
          await c.setToday(unassignedScope, key, false);
        }
      }
      if (mounted) {
        notice(
          context,
          saved.saved
              ? result.note == null
                    ? '今日を締めました。Mac miniで処理されると記録に残ります。'
                    : '今日を締めました。明日へのひとことは、Mac miniで処理されると次に締めるまでホームの先頭に出ます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 表示中の明日へのひとことを消す（締めの記録は残る）。
  Future<void> dismissDayNote(DayClose note) async {
    try {
      final result = await c.requestDayDismiss(note.id);
      if (mounted) {
        notice(
          context,
          result.saved
              ? 'ひとことを消す依頼を保存しました。Mac miniで処理されると表示から外れます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }
}
