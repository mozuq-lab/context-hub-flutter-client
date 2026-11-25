import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../../storage/capture_service.dart';
import '../dialogs/area_dialog.dart';
import '../dialogs/project_definition_dialog.dart';
import '../dialogs/project_merge_dialog.dart';
import '../dialogs/project_status_dialog.dart';
import '../labels.dart';
import '../markdown_view.dart';
import '../notice.dart';
import '../parts.dart';
import '../reference_shelf.dart';
import '../save_checks.dart';
import 'hub_common.dart';
import 'hub_view.dart';

/// プロジェクトへの操作（NOWの競合の片付け・状態・名前と別名・統合・領域・作業記録の下書き）と、経緯・資料の画面を開く操作。
extension HubProjectActions on HubViewState {
  Future<void> resolveConflict(HubProject project, NowConflict conflict) async {
    if (!await confirmAction(
      '現状を生成版に戻す',
      '${conflict.manualLines.isEmpty ? '' : '手で変えた${conflict.manualLines.length}行を、このプロジェクトのメモとして保存してから、'}'
          'Mac miniが最新の入力から現状を作り直します。現状の自動で作られる部分の外に書いたメモは残ります。'
          '置き換える前の現状の全文は本体の記録に残ります。',
      '生成版に戻す',
    )) {
      return;
    }
    try {
      final result = await c.requestConflictResolve(
        project.id,
        conflict.nowHash,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '生成版に戻す依頼を保存しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<void> changeStatus(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final status = await showDialog<String>(
      context: context,
      builder: (_) => ProjectStatusDialog(
        project: project,
        outcomeSupported: repo.intakeFeatures.projectOutcome != null,
      ),
    );
    if (status == null || !mounted) return;
    try {
      final result = await c.requestProjectStatus(project.id, hash, status);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '状態の変更を依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  Future<void> changeDefinition(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final next = await showDialog<ProjectDefinitionDraft>(
      context: context,
      builder: (_) => ProjectDefinitionDialog(
        project: project,
        outcomeLimits: repo.intakeFeatures.projectOutcome,
      ),
    );
    if (next == null || !mounted) return;
    try {
      final result = await c.requestProjectDefinition(project.id, hash, next);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '${next.outcome == null ? '呼び名とキーワード' : '呼び名・キーワード・望む結果'}の変更を依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// ほかのプロジェクトへの統合を依頼する。統合先は本人が選び、両方の定義hashに結び付ける。
  Future<void> mergeProject(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final into = await showDialog<HubProject>(
      context: context,
      builder: (_) => ProjectMergeDialog(
        project: project,
        candidates: [
          for (final p in repo.orderedProjects)
            if (p.id != project.id && !p.merged && p.definitionHash != null) p,
        ],
      ),
    );
    final intoHash = into?.definitionHash;
    if (into == null || intoHash == null || !mounted) return;
    try {
      final result = await c.requestProjectMerge(
        project.id,
        hash,
        into.id,
        intoHash,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '統合を依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 統合の取り消しを依頼する。統合元は統合前の状態に戻る。
  Future<void> unmergeProject(HubProject project) async {
    final into = repo.projects[project.mergedInto];
    final hash = project.definitionHash, intoHash = into?.definitionHash;
    if (into == null || hash == null || intoHash == null) return;
    if (!await confirmAction(
          '統合を取り消す',
          '「${project.title}」を「${into.title}」から切り離し、統合前の状態に戻すよう依頼します。\n\n'
              '「${project.title}」を指定したメモ・完了報告・日付は、このプロジェクトのものとして読む形に戻ります。'
              '統合で「${into.title}」に足した呼び名とキーワードのうち、残っているものは外します。原文と記録は変わりません。',
          '取り消しを依頼',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestProjectMerge(
        project.id,
        hash,
        into.id,
        intoHash,
        unmerge: true,
      );
      if (mounted) {
        notice(
          context,
          result.saved
              ? '統合の取り消しを依頼しました。Mac miniで処理されると反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// プロジェクトの領域を選んで依頼する。語彙の一覧もここから変えられる。
  Future<void> changeArea(HubProject project) async {
    final hash = project.definitionHash;
    if (hash == null) return;
    final choice = await showDialog<({String? area})>(
      context: context,
      builder: (_) => AreaDialog(
        current: project.area,
        choices: () => repo.areasInUse,
        editVocabulary: editAreaVocabulary,
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final result = await c.requestProjectArea(project.id, hash, choice.area);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '領域を依頼しました。Mac miniで処理されるとプロジェクト一覧に反映されます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 領域の一覧（語彙と並び）を編集して、Vaultの好みとして依頼する。依頼したらtrue。
  Future<bool> editAreaVocabulary() async {
    final next = await showDialog<List<String>>(
      context: context,
      builder: (_) => AreaVocabularyDialog(
        current: repo.areaVocabulary,
        pending: repo.areaVocabularyPending,
      ),
    );
    if (next == null || !mounted) return false;
    try {
      final result = await c.requestAreaVocabulary(next);
      if (mounted) {
        notice(
          context,
          result.saved
              ? '領域の一覧を依頼しました。Mac miniで処理されると、ほかの端末にも同じ一覧と並びが出ます。'
              : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
      return result.saved;
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
      return false;
    }
  }

  /// 本体が生成するプロジェクトの経緯（HISTORY.md）を開く。
  void showHistory(HubProject project) =>
      showGenerated(project, project.history, '経緯', 'HISTORY.md', 'history');

  /// プロジェクトの資料棚を開く。本体が資料の一覧を書いていれば、名前を変える・外す・戻すができる画面にし、
  /// 一覧のない（古い）本体では、本体が生成する資料（REFERENCES.md）をそのまま示す。
  /// URLは押したときだけ外部のブラウザで開く（http・httpsだけ）。
  void showShelf(HubProject project) {
    if (repo.referenceIndex == null) {
      showGenerated(project, project.shelf, '資料', 'REFERENCES.md', 'shelf');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReferenceShelfPage(
          controller: c,
          projectId: project.id,
          title: project.title,
          onRecord: openRecordFrom,
          onGenerated: project.shelf == null
              ? null
              : () => showGenerated(
                  project,
                  project.shelf,
                  '資料',
                  'REFERENCES.md',
                  'shelf',
                ),
        ),
      ),
    );
  }

  /// プロジェクトごとの生成ビュー（経緯・資料）を開く。
  void showGenerated(
    HubProject project,
    HubDigest? history,
    String label,
    String fileName,
    String keyName,
  ) {
    if (history == null) return;
    // 本文と同じ読込の時刻を示す（開いたまま再読込しても、本文は開いたときのもの）。
    final loadedAt = repo.snapshot.loadedAt;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('${project.title}の$label')),
          body: ListView(
            key: Key('$keyName-view'),
            padding: pagePadding(context).copyWith(bottom: 48),
            children: [
              Text(
                '生成: ${timeLabel(history.generatedAt)} · 読み込み: ${timeLabel(loadedAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final warning in history.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: NoticeBox(warning),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  child: SafeMarkdown(
                    key: Key('$keyName-body'),
                    text: history.body,
                    sourcePath: '10_projects/${project.id}/$fileName',
                    controller: c,
                    onRecord: open,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> dismissDraft(GitDraft draft) async {
    if (!await confirmAction(
          '下書きを見送る',
          '${draft.repo}のコミット${draft.commitCount}件から作った下書きを見送ります。見送ったコミットは、以後の下書きに含まれません。',
          '見送る',
        ) ||
        !mounted) {
      return;
    }
    try {
      final result = await c.requestGitDraftDismiss(draft.id, draft.hash);
      if (mounted) {
        notice(
          context,
          result.saved ? '見送りを依頼しました。' : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }
}
