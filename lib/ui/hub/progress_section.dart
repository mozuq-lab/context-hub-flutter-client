import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../dialogs/progress_dialog.dart';
import '../notice.dart';
import '../parts.dart';
import '../save_checks.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'item_actions.dart';

/// 次の一手の「取りかかり中」の印（始めた日と、どこまで進んだかのひとこと）。行の操作・表示と、ホームの欄。
extension HubProgress on HubViewState {
  /// 項目に今付いている印（本体へ送る形）。付いていなければnull。
  ({String since, String? note})? progressOf(NowItemRef item) =>
      item.progressing
      ? (since: item.progressSince!, note: item.progressNote)
      : null;

  /// 印もひとことも更新しないまま、この日数が過ぎたら「止まった」と示す（本体の`item_progress.stale_days`）。
  int get progressStaleDays =>
      repo.intakeFeatures.progressLimits?.staleDays ?? progressStaleDaysDefault;

  /// 取りかかり中の印を付けられる（または付いている）次の一手か。統合済みのプロジェクトと片付いた項目には出さない。
  bool progressAvailable(NowItemRef item, {bool merged = false}) =>
      repo.intakeFeatures.progress &&
      !merged &&
      item.section == 'next' &&
      !item.resolved;

  /// 「…」の操作に並べる、取りかかり中の操作。[enabled]がfalse（ほかの依頼が反映待ち）なら出さない。
  /// 連絡待ち・「いつかやる」・先待ちの項目には新しく付けない（付いている印のひとことの書き直しと、外すのは出す）。
  List<PopupMenuEntry<VoidCallback>> progressMenu(
    String scope,
    NowItemRef item,
    String tag, {
    required bool enabled,
  }) {
    if (!enabled) return const [];
    if (!item.progressing) {
      if (item.waiting ||
          item.someday ||
          blockedNow(item) ||
          repo.waitRequestIdFor(item.key) != null ||
          repo.blocksRequestIdFor(item.key) != null ||
          repo.somedayRequestIdFor(item.key) != null) {
        return const [];
      }
      return [
        PopupMenuItem(
          key: Key('progress-start-$tag'),
          value: () => startProgress(scope, item),
          child: const Text('取りかかる'),
        ),
      ];
    }
    return [
      PopupMenuItem(
        key: Key('progress-note-$tag'),
        value: () => editProgress(scope, item),
        child: const Text('どこまで進んだか書く'),
      ),
      PopupMenuItem(
        key: Key('progress-stop-$tag'),
        value: () => stopProgress(scope, item),
        child: const Text('取りかかり中をやめる'),
      ),
    ];
  }

  /// 取りかかり中の依頼が反映待ちのときに、操作の代わりに示す文。
  Widget progressPendingNote() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text('取りかかり中を依頼済み（反映待ち）', style: noteStyle(context)),
  );

  /// 行の下に添える、始めてからの日数・止まっている日数・ひとこと（NOWの本文には始めた日だけが載るため）。
  Widget progressLine(NowItemRef item) {
    final stale = progressStale(item, hubToday(), progressStaleDays);
    return Text(
      progressDetail(item, hubToday(), progressStaleDays),
      key: Key('progress-label-${item.key.substring(0, 12)}'),
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: stale ? Theme.of(context).colorScheme.error : null),
    );
  }

  /// 今日から取りかかり中にする（ひとことは後から「どこまで進んだか書く」で足す）。
  Future<void> startProgress(String scope, NowItemRef item) => _sendProgress(
    scope,
    item,
    (since: hubToday(), note: null),
    saved: '取りかかり中にする依頼を保存しました。Mac miniで処理されるとホームと次の一手の先頭に出ます。',
  );

  /// どこまで進んだかのひとこと（と始めた日）を書き直す。ひとことは保存の前に秘密情報らしい文字列を確かめる。
  Future<void> editProgress(String scope, NowItemRef item) async {
    final max =
        repo.intakeFeatures.progressLimits?.noteMaxChars ?? progressNoteChars;
    final value = await showDialog<({String since, String? note})>(
      context: context,
      builder: (_) => ProgressDialog(item: item, noteMaxChars: max),
    );
    if (value == null || !mounted) return;
    var note = value.note;
    if (note != null) {
      note = await checkSecretsBeforeSave(
        context,
        note,
        secrets: repo.secretPolicy,
      );
      if (note == null || !mounted) return;
      if (!validProgressNote(note, max)) {
        notice(context, '伏せ字にすると$max文字を超えます。ひとことを短くしてください。');
        return;
      }
    }
    await _sendProgress(scope, item, (
      since: value.since,
      note: note,
    ), saved: '取りかかり中の依頼を保存しました。Mac miniで処理されると現状と一覧に反映されます。');
  }

  /// 取りかかり中の印を外す（項目は次の一手に残る）。
  Future<void> stopProgress(String scope, NowItemRef item) async {
    if (!await confirmAction(
          '取りかかり中をやめる',
          '${item.display}\n\n取りかかり中の印とひとことを外し、ふつうの次の一手に戻すよう依頼します。終えた場合は、外さずに「完了にする」を使ってください。',
          '印を外す',
        ) ||
        !mounted) {
      return;
    }
    await _sendProgress(
      scope,
      item,
      null,
      saved: '取りかかり中をやめる依頼を保存しました。Mac miniで処理されると現状に反映されます。',
    );
  }

  Future<void> _sendProgress(
    String scope,
    NowItemRef item,
    ({String since, String? note})? progress, {
    required String saved,
  }) async {
    try {
      final result = await c.requestItemProgress(
        scope,
        item.key,
        progress: progress,
        expected: progressOf(item),
      );
      if (mounted) {
        notice(
          context,
          result.saved ? saved : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// ホームに出す、取りかかり中の項目（印を更新した新しい順）。本体の上限を超えたら、絞るよう添える。
  /// 連絡待ち・「いつかやる」・先待ちの項目は、それぞれの欄で示すので含めない（本体のHOME・「次の一手」画面と同じ）。
  List<Widget> progressHome() {
    if (!repo.intakeFeatures.progress) return const [];
    final items = [
      for (final e in repo.progressingItems)
        if (!e.item.waiting && !e.item.someday && !blockedNow(e.item)) e,
    ];
    if (items.isEmpty) return const [];
    final limit = repo.intakeFeatures.progressLimits!.limit;
    void openNext() {
      nextSection = 'next';
      widget.onNavigate('next');
    }

    return [
      sectionHeading(
        '取りかかり中（${items.length}件）',
        key: const Key('home-progress'),
        note: items.length > limit
            ? '取りかかり中が$limit件を超えています。終えたものは完了に、手を止めているものは「取りかかり中をやめる」にすると、今の仕事が見えやすくなります。'
            : null,
      ),
      groupCard([
        for (final e in items.take(HubViewState.homeUnassigned))
          ListTile(
            key: Key('home-progress-${e.item.key.substring(0, 12)}'),
            dense: true,
            title: Text(
              e.item.display,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${e.project?.title ?? 'プロジェクト未定'}・${progressDetail(e.item, hubToday(), progressStaleDays)}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: openNext,
          ),
      ]),
      if (items.length > HubViewState.homeUnassigned)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'ほかに${items.length - HubViewState.homeUnassigned}件あります（「次の一手」の先頭にすべて並びます）。',
            style: noteStyle(context),
          ),
        ),
      const SizedBox(height: 12),
    ];
  }
}
