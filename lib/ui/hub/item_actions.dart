import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/calendar.dart';
import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../dialogs/action_dialog.dart';
import '../dialogs/blocks_dialog.dart';
import '../dialogs/contexts_dialog.dart';
import '../dialogs/effort_dialog.dart';
import '../dialogs/exclude_dialog.dart';
import '../dialogs/schedule_dialog.dart';
import '../dialogs/steps_dialog.dart';
import '../dialogs/wait_dialog.dart';
import '../notice.dart';
import '../parts.dart';
import '../save_checks.dart';
import 'hub_common.dart';
import 'hub_view.dart';

/// 次の一手・未解決の項目への操作（完了・外す・期日・手間・札・手順・連絡待ち・先に済ませること・行動の追加と移動）。
extension HubItemActions on HubViewState {
  Future<void> reportItem(
    HubProject project,
    NowItemRef item,
    String action,
  ) async {
    final resolve = action == 'resolve',
        verb = item.section == 'next' ? '完了' : '解決',
        resolveLabel = item.repeating ? '定例をやめる' : '$verbにする';
    // 外したときに起きたこと（読み直し・関連の変更）だけを、元に戻ると伝える。
    final undo = switch (item.exclusionReason) {
      'misread' => '誤りとして外したときのメモの読み直しも元に戻ります。',
      'wrong-project' when !repo.itemOwnedByProject(project.id, item) =>
        '誤りとして外したときのメモの読み直しと、このプロジェクトとの関連の変更も元に戻ります。',
      _ => '',
    };
    if (!await confirmAction(
          resolve ? resolveLabel : '未解決に戻す',
          '${item.display}\n\n${resolve ? 'この項目を現状の「解決済み・完了」へ移すよう依頼します。原文とAIの読み取り結果は変わりません。' : 'この項目を現状の元の欄へ戻すよう依頼します。$undo'}',
          resolve ? resolveLabel : '戻す',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestItemResolution(
        project.id,
        item.key,
        action,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '報告を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 手間の目安を選んで依頼する。目安は本人が選び、AIは推測しない。[projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> effortItem(String projectId, NowItemRef item) async {
    final choice = await showDialog<({String? effort})>(
      context: context,
      builder: (_) => EffortDialog(item: item),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestItemEffort(
        projectId,
        item.key,
        choice.effort,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '手間の目安を依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 場所・道具の札を選んで依頼する。札は本人が選び、AIは付けない。語彙の一覧もここから変えられる。
  /// [projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> contextsItem(String projectId, NowItemRef item) async {
    final choice = await showDialog<({List<String>? contexts})>(
      context: context,
      builder: (_) => ContextsDialog(
        item: item,
        vocabulary: () => repo.contextVocabulary,
        editVocabulary: editContextVocabulary,
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestItemContexts(
        projectId,
        item.key,
        choice.contexts,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '場所・道具の札を依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 場所・道具の札の一覧（語彙）を編集して、Vaultの好みとして依頼する。依頼したらtrue。
  Future<bool> editContextVocabulary() async {
    final next = await showDialog<List<String>>(
      context: context,
      builder: (_) => ContextVocabularyDialog(
        current: repo.contextVocabulary,
        pending: repo.contextVocabularyPending,
      ),
    );
    if (next == null || !mounted) return false;
    try {
      final result = await c.requestContextVocabulary(next);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '札の一覧を依頼しました。Mac miniで処理されると、ほかの端末にも同じ一覧が出ます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// 次の一手を手順に分ける・直す・外す依頼。手順は本人が書き、AIは作らない。
  Future<void> stepsItem(String projectId, NowItemRef item) async {
    final choice = await showDialog<({ItemSteps? steps})>(
      context: context,
      builder: (_) => StepsDialog(item: item),
    );
    if (choice == null || !mounted) return;
    await sendSteps(
      projectId,
      item,
      choice.steps,
      choice.steps == null ? '手順を外す依頼をしました' : '手順を依頼しました',
    );
  }

  /// 今の手順を終えた（[delta]が1）・1つ戻す（-1）依頼。手順の全体を送る。
  Future<void> moveStep(String projectId, NowItemRef item, int delta) async {
    final steps = item.steps;
    if (steps == null) return;
    final done = steps.done + delta;
    if (done < 0 || done > steps.items.length) return;
    await sendSteps(
      projectId,
      item,
      ItemSteps(steps.items, done),
      delta > 0 ? '手順を進める依頼をしました' : '手順を1つ戻す依頼をしました',
    );
  }

  Future<void> sendSteps(
    String projectId,
    NowItemRef item,
    ItemSteps? steps,
    String done,
  ) async {
    try {
      final result = await c.requestItemSteps(
        projectId,
        item.key,
        steps,
        seen: item.steps,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '$done。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 連絡待ちの印（相手・頼んだ日）を依頼する。見直す日を変えたときは、続けて日付も依頼する（見直す日は期日と同じ記録）。
  /// [projectId]は項目の置き場（プロジェクト未定もある）。
  Future<void> waitItem(String projectId, NowItemRef item) async {
    final choice =
        await showDialog<({String? who, String since, String? reviewAfter})>(
          context: context,
          builder: (_) =>
              WaitDialog(item: item, suggestions: waitingWhoSuggestions()),
        );
    if (choice == null || !mounted) return;
    final changed =
        !item.waiting ||
        item.waitingSince != choice.since ||
        item.waitingWho != choice.who;
    var sent = false;
    try {
      var saved = true;
      if (changed) {
        saved = (await c.requestItemWait(
          projectId,
          item.key,
          who: choice.who,
          since: choice.since,
        )).saved;
        sent = true;
      }
      // 見直す日は今の日付の記録に重ねる（期日と繰り返しは保つ）。日付の依頼が反映待ちなら送らない。
      // 期日は、ダイアログを開いている間に別の端末で変わっていることがあるため、読み直した項目のものを使う。
      final current = currentItem(projectId, item.key) ?? item;
      final review = choice.reviewAfter != current.reviewAfter;
      if (saved && review && mounted) {
        if (repo.scheduleRequestIdFor(item.key) != null) {
          notice(
            context,
            '${sent ? '連絡待ちを依頼しました。' : ''}日付の依頼が反映待ちのため、見直す日は送りませんでした。反映後に「期日を変える」から付けてください。',
          );
          return;
        }
        saved = (await c.requestItemSchedule(
          projectId,
          item.key,
          current.due,
          choice.reviewAfter,
        )).saved;
      }
      if (mounted) {
        notice(
          context,
          !saved
              ? '保存結果を確認できません。保存と反映から同じ操作を確認してください。'
              : sent
              ? '連絡待ちを依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '見直す日を依頼しました。Mac miniで処理されると現状と一覧に反映されます。',
        );
      }
    } catch (e) {
      if (mounted) {
        // 連絡待ちを保存した後に見直す日の依頼が断られたときは、連絡待ちは保存したことも示す。
        notice(
          context,
          sent
              ? '連絡待ちは依頼しましたが、見直す日は送れませんでした: ${HubController.message(e)}'
              : HubController.message(e),
        );
      }
    }
  }

  /// 本人が追加した行動を、別の置き場（進行中のプロジェクト・プロジェクト未定）へ移すよう依頼する。
  /// [fromScope]は今の置き場。移す先は本人が選び、付けていた日付・手間の目安などは移した先へ引き継ぐ。
  Future<void> moveAction(String fromScope, NowItemRef item) async {
    final unassigned = repo.intakeFeatures.unassignedActions;
    final targets = [
      for (final p in repo.actionableProjects)
        if (!p.merged &&
            p.id != fromScope &&
            repo.projectMergeRequestIdFor(p.id) == null)
          (id: p.id, title: p.title),
      if (fromScope != unassignedScope && unassigned)
        (id: unassignedScope, title: 'プロジェクト未定'),
    ];
    if (targets.isEmpty) {
      notice(context, '移せる進行中のプロジェクトがありません。');
      return;
    }
    final to = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        key: const Key('move-action-dialog'),
        titlePadding: closableTitlePadding,
        title: closableTitle(
          Text(fromScope == unassignedScope ? 'プロジェクトへ移す' : '別の置き場へ移す'),
          () => Navigator.of(dialog).pop(),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '${item.display}\n\n移す先を選んでください。期日・見直す日・繰り返し・手間の目安・連絡待ち・「いつかやる」は、移した先の行動に引き継ぎます。元に戻すときは、移した先でもう一度移します。「今日の3つ」に選んでいたときは外すので、移した後に選び直してください。',
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
          ),
          for (final t in targets)
            SimpleDialogOption(
              key: Key('move-action-to-${t.id}'),
              onPressed: () => Navigator.of(dialog).pop(t.id),
              child: Text(t.title),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: TextButton(
                key: const Key('move-action-cancel'),
                onPressed: () => Navigator.of(dialog).pop(),
                child: const Text('キャンセル'),
              ),
            ),
          ),
        ],
      ),
    );
    if (to == null || !mounted) return;
    try {
      final result = await c.requestMoveAction(fromScope, item.key, to);
      // 移すと項目キーが変わり、元の選択は見つからなくなるため、今日の3つ・持ち越しから外す。
      final today = c.today;
      if (result.saved &&
          (today.picked(item.key) ||
              today.carry.any((p) => p.itemKey == item.key))) {
        try {
          await c.setToday(fromScope, item.key, false);
        } catch (_) {
          // 外せなくても、移す依頼は保存済み。
        }
      }
      if (mounted) {
        notice(
          context,
          result.saved
              ? '行動を移す依頼を保存しました。Mac miniで処理されると移した先に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 項目に付けた先の項目の、今の状態（先に済ませる順）。付けていなければ空。
  List<PrerequisiteState> prerequisiteStates(NowItemRef item) => [
    for (final a in item.after?.items ?? const <ItemAfterRef>[])
      repo.prerequisiteState(a),
  ];

  /// 先の項目が残っている（先待ち）。片付いた項目には付かない。
  bool blockedNow(NowItemRef item) =>
      item.after != null &&
      !item.resolved &&
      !blockSettled(prerequisiteStates(item));

  /// 先の項目がすべて片付き、取りかかれるようになった。
  bool readyNow(NowItemRef item) =>
      item.after != null &&
      !item.resolved &&
      blockSettled(prerequisiteStates(item));

  /// 先に済ませることを選んで依頼する（1〜3件、プロジェクトをまたいでよい）。[projectId]はプロジェクトの項目の置き場。
  Future<void> blocksItem(String projectId, NowItemRef item) async {
    final choices = [
      for (final (scope, i) in HubController.prerequisiteChoices(
        repo,
        projectId,
        item,
      ))
        (scope: scope, title: scopeTitle(scope), item: i),
    ];
    final max = repo.intakeFeatures.blocksMax ?? itemBlocksMax;
    final choice =
        await showDialog<({List<({String scope, String key})>? after})>(
          context: context,
          builder: (_) => BlocksDialog(
            item: item,
            choices: choices,
            max: max < itemBlocksMax ? max : itemBlocksMax,
            current: [
              for (final a in item.after?.items ?? const <ItemAfterRef>[])
                if (repo.findPrerequisite(a) case final found?
                    when !found.resolved &&
                        choices.any((c) => c.item.key == found.key))
                  (scope: a.projectId, key: found.key),
            ],
          ),
        );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestItemBlocks(
        projectId,
        item.key,
        choice.after,
        seen: item.after?.id,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? choice.after == null
                    ? '先に済ませることを外す依頼を保存しました。Mac miniで処理されると現状に反映されます。'
                    : '先に済ませることを依頼しました。Mac miniで処理されると、先の項目が片付くまで「先待ち」にまとまります。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<void> unwaitItem(String projectId, NowItemRef item) async {
    if (!await confirmAction(
          '連絡待ちを外す',
          '${item.display}\n\n連絡待ちの印を外し、項目を元の欄へ戻すよう依頼します。返事が来て終わった場合は、外さずに「${item.section == 'next' ? '完了にする' : '解決にする'}」も使えます。',
          '外す',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestItemWait(projectId, item.key);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '連絡待ちを外す依頼を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 連絡待ちの相手の候補。いま連絡待ちにしている項目の相手から作る（端末には保存しない）。
  List<String> waitingWhoSuggestions() {
    final names = <String>{};
    for (final p in repo.projects.values) {
      for (final i in p.nowItems) {
        if (i.waiting && i.waitingWho != null) names.add(i.waitingWho!);
      }
    }
    for (final i in repo.unassignedWaitingActions) {
      if (i.waitingWho != null) names.add(i.waitingWho!);
    }
    return (names.toList()..sort()).take(8).toList();
  }

  /// AIの読み違いなどを、理由を選んで「誤り」として外すよう依頼する。完了・解決には数えない。
  Future<void> excludeItem(HubProject project, NowItemRef item) async {
    final choice = await showDialog<({String reason, String? note})>(
      context: context,
      builder: (_) => ExcludeDialog(
        item: item,
        owned: repo.itemOwnedByProject(project.id, item),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestItemResolution(
        project.id,
        item.key,
        'exclude',
        reason: choice.reason,
        note: choice.note,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '報告を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 本人が決めた行動を次の一手に追加する。[project]を渡すとそのプロジェクトに決まり、渡さないと進行中のプロジェクトから選ぶ。
  /// 本体が対応していれば、プロジェクトを決めない「プロジェクト未定」も選べる（[unassigned]なら最初からそれを選ぶ）。
  /// [from]はAIが読み取った行（提案・作業要約の次の一手・プロジェクト未定の行）を行動にするときの元の行。
  /// AIの行を行動にするときは、元の行のプロジェクトのほかに「プロジェクト未定」も選べる。
  Future<void> addAction({
    HubProject? project,
    ActionSource? from,
    bool unassigned = false,
  }) async {
    final choices = project != null
        ? [project]
        : repo.actionableProjects.where((p) => !p.merged).toList();
    final allowUnassigned =
        repo.intakeFeatures.unassignedActions &&
        (project == null || from != null);
    if (choices.isEmpty && !allowUnassigned) {
      notice(context, '追加できる進行中のプロジェクトがありません。');
      return;
    }
    // 新しく足す行動には、対応した本体なら手間の目安と札を一緒に付けられる（AIの行を引き取るときは、元の行の札と目安を本体が写す）。
    final features = repo.intakeFeatures;
    final value =
        await showDialog<
          ({
            String projectId,
            String text,
            String? effort,
            List<String>? contexts,
          })
        >(
          context: context,
          builder: (_) => ActionDialog(
            projects: choices,
            from: from,
            allowUnassigned: allowUnassigned,
            unassigned: unassigned || choices.isEmpty,
            effortChoice: from == null && features.actionEffort,
            contextChoices: from == null && features.actionContexts
                ? repo.contextVocabulary
                : null,
          ),
        );
    if (value == null || !mounted) return;
    final checked = await checkSecretsBeforeSave(
      context,
      value.text,
      secrets: repo.secretPolicy,
    );
    if (checked == null || !mounted) return;
    if (!validActionText(checked)) {
      notice(context, '伏せ字にすると$actionTextChars文字を超えます。文面を短くしてください。');
      return;
    }
    try {
      final result = await c.requestAction(
        value.projectId,
        checked,
        from: from,
        effort: value.effort,
        contexts: value.contexts,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? value.projectId == unassignedScope
                    ? '次の一手への追加を保存しました。Mac miniで処理されるとプロジェクト未定の一覧に反映されます。'
                    : '次の一手への追加を保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 期日・見直す日（と繰り返し）を依頼する。依頼を保存できたらtrue。[projectId]は項目の置き場（プロジェクト未定もある）。
  Future<bool> scheduleItem(String projectId, NowItemRef item) async {
    // 繰り返しに対応した本体にだけ、繰り返しを選ばせて送る（古い本体は知らない欄を断るため）。
    final repeatable = repo.intakeFeatures.repeat;
    final value =
        await showDialog<
          ({String? due, String? reviewAfter, RepeatRule? repeat})
        >(
          context: context,
          builder: (_) =>
              ScheduleDialog(item: item, repeatSupported: repeatable),
        );
    if (value == null || !mounted) return false;
    try {
      final result = await c.requestItemSchedule(
        projectId,
        item.key,
        value.due,
        value.reviewAfter,
        withRepeat: repeatable,
        repeat: value.repeat,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '日付を依頼しました。Mac miniで処理されると現状と一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// 定例の今の回を完了にする・見送る。本体が次の回の期日を付け、項目は欄に残る。
  Future<void> completeRound(
    String projectId,
    NowItemRef item,
    String action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => HubAlertDialog(
        title: Text(occurrenceActionLabels[action]!),
        onClose: () => Navigator.pop(dialog),
        content: SizedBox(
          width: 480,
          child: Text(
            '${item.display}\n\n期日 ${item.due}（${item.repeat!.label}）の回を${action == 'done' ? '完了にします' : '見送ります'}。'
            '項目は欄に残り、Mac miniで処理されると期日が次の回へ進みます。定例をやめるときは「…」の「定例をやめる」を使ってください。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('やめる'),
          ),
          FilledButton(
            key: Key('round-$action-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(occurrenceActionLabels[action]!),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await c.requestItemOccurrence(projectId, item.key, action);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '${occurrenceActionLabels[action]}を依頼しました。Mac miniで処理されると、次の回の期日が現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 「片付いたかも」が違うときに、そのメモからの候補を見送る。項目は未解決のまま残る。
  Future<void> dismissHint(
    HubProject project,
    NowItemRef item,
    NowItemHint hint,
  ) async {
    if (!await confirmAction(
          '「片付いたかも」を見送る',
          '${item.display}\n\n根拠のメモ: 「${hint.quote}」\n\nこのメモからの候補を見送るよう依頼します。項目は${item.section == 'next' ? '次の一手' : '未解決'}に残ります。',
          '見送る',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestHintDismiss(
        project.id,
        item.key,
        hint.inputId,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '見送りを保存しました。Mac miniで処理されると現状に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 行動にできるAIの読み取りの行なら、その元の行。作業要約の次の一手（キー付きの未完了の項目）と「提案」の行が対象。
  ActionSource? actionSourceOf(
    HubProject project,
    String section,
    NowEntry entry,
  ) {
    if (section == 'proposals') return repo.proposalSource(entry);
    if (section != 'next' || entry.itemKey == null) return null;
    // 完了などの報告・日付や定例の回の依頼が反映待ちの項目は、行動にしない（受付の順で依頼が断られるため）。
    if (repo.itemRequestIdFor(entry.itemKey!) != null ||
        repo.scheduleRequestIdFor(entry.itemKey!) != null) {
      return null;
    }
    final item = project.nowItems
        .where((i) => i.key == entry.itemKey)
        .firstOrNull;
    if (item == null || item.action || item.resolved) return null;
    return ActionSource(inputId: item.inputId, text: item.text, key: item.key);
  }

  /// 期日を端末のカレンダーへ渡す。カレンダーはクラウドへ同期されることが多いため、伏せ字の規則を確かめられないときは渡さない。
  /// [projectId]と[projectTitle]は項目の置き場（プロジェクト未定の行動は[unassignedScope]と「プロジェクト未定」）。
  Future<void> addToCalendar(
    String projectId,
    String projectTitle,
    NowItemRef item,
  ) async {
    final secrets = repo.secretPolicy;
    if (secrets.problem case final problem?) {
      notice(context, problem);
      return;
    }
    final event = dueEvent(
      projectId,
      projectTitle,
      item,
      hide: secrets.redact,
      withText: repo.intakeFeatures.calendarTitles == 'item',
    );
    if (event == null || calendarOpening) return;
    // 続けて押しても作成画面を重ねて開かない。
    calendarOpening = true;
    try {
      await c.access.addToCalendar(event);
    } catch (_) {
      if (mounted) notice(context, 'カレンダーを開けませんでした。端末にカレンダーのアプリがあるか確かめてください。');
    } finally {
      calendarOpening = false;
    }
  }
}
