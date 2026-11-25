import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../../storage/capture_service.dart';
import '../labels.dart';
import '../notice.dart';
import '../parts.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'item_actions.dart';

/// 「いつかやる」の画面と、移す・始める・そのまま・やめる。
extension HubSomeday on HubViewState {
  /// 項目を「いつかやる」へ移す、または元の欄（次の一手・未解決）へ戻すよう依頼する。移すかは本人が決め、AIは移さない。
  /// [projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> somedayItem(String projectId, NowItemRef item) async {
    final back = item.someday;
    if (!await confirmAction(
          back ? '「いつかやる」から戻す' : '「いつかやる」へ移す',
          back
              ? '${item.display}\n\n項目を元の欄（${item.section == 'next' ? '次の一手' : '未解決'}）へ戻すよう依頼します。'
              : '${item.display}\n\n今は取り組まない項目として「いつかやる」へ移すよう依頼します。次の一手の件数やホーム画面の一覧からは外れ、「いつかやる」の画面でまとめて見直せます。いつでも戻せます。${item.action ? '' : '\n\nAIが書いた行は、次の作業要約で言い回しが変わると「いつかやる」から外れます（Mac miniのHOMEに示します）。長く置くなら、先に「自分の行動にする」で引き取ってください。'}',
          back ? '戻す' : '移す',
        ) ||
        !mounted) {
      return;
    }
    await somedayRequest(
      () => c.requestItemSomeday(projectId, item.key, back ? 'back' : 'move'),
      back ? '戻す依頼を保存しました。' : '「いつかやる」へ移す依頼を保存しました。',
    );
  }

  /// 「いつかやる」の依頼を送り、結果を知らせる。
  /// 保存できたかを返す。
  Future<bool> somedayRequest(
    Future<CaptureResult> Function() send,
    String done,
  ) async {
    try {
      final result = await send();
      if (mounted) {
        notice(
          context,
          result.saved
              ? '${done}Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// 「いつかやる」の画面。本人が移した項目・休止中のプロジェクト・置いたアイデアを、見直していない順に並べる。
  /// 行ごとに「始める・そのまま・やめる」を選ぶ。どれを移すか・始めるかは本人が決め、AIは決めない。
  List<Widget> somedayView() {
    final today = hubToday(),
        entries = repo.somedayEntries,
        days = repo.intakeFeatures.somedayReviewDays,
        stale = repo.staleSomedayEntries(today).length;
    if (!repo.intakeFeatures.someday && entries.isEmpty) {
      return [
        title('いつかやる', '今は取り組まないことの置き場です。'),
        const Text('Mac miniの本体が「いつかやる」に対応していません。本体を更新すると使えます。'),
      ];
    }
    return [
      title(
        'いつかやる',
        '今は取り組まない次の一手・未解決、休止中のプロジェクト、置いておくアイデアです。最後に見直した日の古い順です。'
            '\n$days日以上見直していないもの: $stale件 · 読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
      ),
      if (repo.somedayGeneratedAt == null)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            '本体がまだ一覧を作っていません。Mac miniで処理されると表示されます。',
            key: Key('someday-missing'),
          ),
        )
      else if (entries.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            '「いつかやる」は空です。次の一手・未解決の「…」の「「いつかやる」へ移す」や、アイデアの画面から置けます。',
            key: Key('someday-empty'),
          ),
        ),
      if (entries.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 14, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: dividedRows([
                for (final e in entries) somedayRow(e, today, days),
              ]),
            ),
          ),
        ),
      const SizedBox(height: 12),
      const Text(
        '始める: 項目は元の欄へ戻し、休止中のプロジェクトは進行中にします。アイデアは始めた記録を残し、続けて次の一手を追加できます。\n'
        'そのまま: 見直した日だけを今日にします（一覧の後ろへ回ります）。\n'
        'やめる: 項目は「誤り（古い情報）」として外し、プロジェクトは完了にし、アイデアは一覧から外します。原文のメモは残ります。',
        style: TextStyle(fontSize: 12),
      ),
    ];
  }

  /// 「いつかやる」の1行。種類ごとの依頼が反映待ちなら、操作の代わりにそう示す。
  Widget somedayRow(SomedayEntry e, String today, int reviewDays) {
    final tag = digest(e.ref).substring(0, 12),
        stale = e.stale(today, reviewDays),
        project = e.kind == 'project' ? repo.projects[e.id] : null,
        item = e.kind == 'item' ? currentItem(e.scope!, e.id) : null,
        pending = switch (e.kind) {
          'item' =>
            repo.somedayRequestIdFor(e.id) != null ||
                repo.itemRequestIdFor(e.id) != null ||
                repo.waitRequestIdFor(e.id) != null,
          'project' =>
            repo.somedayReviewRequestIdFor('project', e.id) != null ||
                repo.projectStatusRequestIdFor(e.id) != null,
          _ => repo.somedayReviewRequestIdFor('idea', e.id) != null,
        },
            // 操作に使う今の状態が読めない行（項目一覧やプロジェクトの定義が古い・欠けている）には操作を出さない。
            actionable =
            repo.intakeFeatures.someday &&
            switch (e.kind) {
              'item' => item != null && item.someday,
              'project' =>
                project != null &&
                    !project.merged &&
                    project.lifecycle == 'paused' &&
                    project.definitionHash != null,
              _ => repo.ideaRecord(e.id) != null,
            },
        kind = switch (e.kind) {
          'item' => e.place ?? '',
          'project' => '休止中のプロジェクト',
          _ => 'アイデア',
        },
        sinceLabel = switch (e.kind) {
          'item' => '移した日',
          'project' => '休止した日',
          _ => '置いた日',
        },
        age = e.days(today);
    return KeyedSubtree(
      key: Key('someday-$tag'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => openSomeday(e),
            child: Text(
              e.kind == 'item' ? '${e.label}${e.title}' : e.title,
              style: const TextStyle(fontSize: 15),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (kind.isNotEmpty) kind,
              if (e.since != null) '$sinceLabel ${e.since}',
              age == null
                  ? '見直した記録なし'
                  : e.reviewed == e.since
                  ? '置いてから$age日'
                  : '見直してから$age日',
            ].join(' · '),
            style: TextStyle(
              fontSize: 12,
              color: stale ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          if (pending)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('依頼済み（反映待ち）', style: noteStyle(context)),
            )
          else if (actionable)
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  key: Key('someday-start-$tag'),
                  onPressed: busy ? null : () => startSomeday(e, item, project),
                  icon: const Icon(Icons.play_arrow_outlined, size: 15),
                  label: const Text('始める'),
                ),
                TextButton.icon(
                  key: Key('someday-keep-$tag'),
                  onPressed: busy || e.reviewed == today
                      ? null
                      : () => keepSomeday(e),
                  icon: const Icon(Icons.schedule, size: 15),
                  label: Text(e.reviewed == today ? '今日見直し済み' : 'そのまま'),
                ),
                TextButton.icon(
                  key: Key('someday-drop-$tag'),
                  onPressed: busy ? null : () => dropSomeday(e, item, project),
                  icon: const Icon(Icons.close, size: 15),
                  label: const Text('やめる'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 「いつかやる」の行の元を開く。項目は置き場、プロジェクトはその画面、アイデアは記録。
  void openSomeday(SomedayEntry e) {
    switch (e.kind) {
      // プロジェクト未定の行動は、移している間はほかの一覧に出ない。この画面で始める・そのまま・やめるを選ぶ。
      case 'item' when e.scope == unassignedScope:
        notice(context, 'プロジェクト未定の行動です。この画面の「始める」で次の一手へ戻せます。');
      case 'item':
        widget.onNavigate('project:${e.scope}');
      case 'project':
        widget.onNavigate('project:${e.id}');
      default:
        if (repo.ideaRecord(e.id) case final record?) open(record.id);
    }
  }

  /// 始める。項目は元の欄へ戻し、プロジェクトは進行中にし、アイデアは始めた記録を残して次の一手の追加を開く。
  Future<void> startSomeday(
    SomedayEntry e,
    NowItemRef? item,
    HubProject? project,
  ) async {
    final (body, ok) = switch (e.kind) {
      'item' => (
        'この項目を元の欄（${e.section == 'open' ? '未解決' : '次の一手'}）へ戻すよう依頼します。',
        '戻す',
      ),
      'project' => ('このプロジェクトを進行中に戻すよう依頼します。', '進行中にする'),
      _ => (
        repo.intakeFeatures.actions
            ? 'このアイデアを始めたと記録し、「いつかやる」から外すよう依頼します。続けて最初の次の一手を追加できます（追加しなくても構いません）。'
            : 'このアイデアを始めたと記録し、「いつかやる」から外すよう依頼します。',
        '始める',
      ),
    };
    if (!await confirmAction('始める', '${e.title}\n\n$body', ok) || !mounted) {
      return;
    }
    switch (e.kind) {
      case 'item':
        await somedayRequest(
          () => c.requestItemSomeday(e.scope!, e.id, 'back'),
          '元の欄へ戻す依頼を保存しました。',
        );
      case 'project':
        await somedayRequest(
          () =>
              c.requestProjectStatus(e.id, project!.definitionHash!, 'active'),
          '進行中にする依頼を保存しました。',
        );
      default:
        final saved = await somedayRequest(
          () => c.requestSomedayReview('idea', e.id, 'start'),
          '始めた記録を依頼しました。',
        );
        if (saved && mounted && repo.intakeFeatures.actions) await addAction();
    }
  }

  /// そのまま（見直した日だけを今日にする）。
  Future<void> keepSomeday(SomedayEntry e) => somedayRequest(
    () => e.kind == 'item'
        ? c.requestItemSomeday(e.scope!, e.id, 'keep')
        : c.requestSomedayReview(e.kind, e.id, 'keep'),
    '見直した日を依頼しました。',
  );

  /// やめる。項目は「誤り（古い情報）」として外し、プロジェクトは完了にし、アイデアは一覧から外す。
  Future<void> dropSomeday(
    SomedayEntry e,
    NowItemRef? item,
    HubProject? project,
  ) async {
    final (body, ok) = switch (e.kind) {
      'item' => (
        'この項目はやらないものとして、「誤り（古い情報）」として外すよう依頼します。元のメモは残り、外した項目は元に戻せます。',
        '外す',
      ),
      'project' => (
        [
          'このプロジェクトを完了にするよう依頼します。記録は残り、あとで進行中に戻せます。',
          // 完了の判断の基準として、本人が書いた望む結果を添える（状態の変更と同じ）。
          if (project?.outcomeLines case final lines? when lines.isNotEmpty)
            '望む結果:\n${lines.join('\n')}\nこれを満たしたかを確かめてから完了にしてください。',
        ].join('\n\n'),
        '完了にする',
      ),
      _ => ('このアイデアをやめたと記録し、「いつかやる」から外すよう依頼します。アイデアの記録は残ります。', 'やめる'),
    };
    if (!await confirmAction('やめる', '${e.title}\n\n$body', ok) || !mounted) {
      return;
    }
    await somedayRequest(
      () => switch (e.kind) {
        'item' => c.requestItemResolution(
          e.scope!,
          e.id,
          'exclude',
          reason: 'outdated',
        ),
        'project' => c.requestProjectStatus(
          e.id,
          project!.definitionHash!,
          'done',
        ),
        _ => c.requestSomedayReview('idea', e.id, 'drop'),
      },
      'やめる依頼を保存しました。',
    );
  }
}
