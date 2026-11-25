import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../dialogs/capture_dialog.dart';
import '../guided_view.dart';
import '../labels.dart';
import '../markdown_view.dart';
import '../notice.dart';
import '../parts.dart';
import '../save_checks.dart';
import 'home_page.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'item_actions.dart';
import 'item_rows.dart';
import 'project_actions.dart';

/// プロジェクトの画面と、状態・定義・統合・領域・経緯・資料の操作。
extension HubProjectPage on HubViewState {
  /// 手で書き換えたため更新が止まったNOWの説明と、生成版に戻す操作。
  Widget conflictPanel(HubProject project, NowConflict conflict) {
    final requested = repo.conflictRequestIdFor(project.id) != null;
    const shown = 8;
    final lines = conflict.manualLines;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        key: const Key('now-conflict'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '現状の更新が止まっています',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '現状の自動で作られる部分が手で書き換えられているため、${timeLabel(project.generatedAt)}の生成から更新されていません。'
                '下の内容は止まった時点のものです${conflict.count > 1 ? '（新しい版の退避${conflict.count}件）' : ''}。',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 10),
              Text(
                lines.isEmpty
                    ? '手で変えた行は見つかりませんでした（行の削除や並べ替えだけの可能性があります）。'
                    : '手で変えた行${conflict.comparedWithGenerated ? '' : '（最新の生成版との違い。生成側の変化も含みます）'}:',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontSize: 13),
              ),
              for (final line in lines.take(shown))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(line, style: noteStyle(context)),
                ),
              if (lines.length > shown)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'ほか${lines.length - shown}行',
                    style: noteStyle(context),
                  ),
                ),
              const SizedBox(height: 12),
              if (requested)
                const NoticeBox('生成版に戻す依頼を送りました。Mac miniで処理されると最新の現状が表示されます。')
              else
                OutlinedButton.icon(
                  key: const Key('conflict-resolve'),
                  onPressed: c.loading || c.saving || c.captureWarning != null
                      ? null
                      : () => resolveConflict(project, conflict),
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('生成版に戻す'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// プロジェクトの画面の先頭に置く望む結果。書いていなければ、対応した本体のときだけ書く操作を出す。
  Widget projectOutcome(HubProject project, bool editable) {
    final lines = project.outcomeLines,
        supported = repo.intakeFeatures.projectOutcome != null;
    if (lines.isEmpty && !supported) return const SizedBox.shrink();
    final edit = supported
        ? TextButton.icon(
            key: const Key('project-outcome-edit'),
            onPressed: editable ? () => changeDefinition(project) : null,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: Text(lines.isEmpty ? '望む結果を書く' : '望む結果を直す'),
          )
        : null;
    // 書いていないときは1行だけにし、画面の先頭を大きく押し下げない。
    if (lines.isEmpty) {
      return Padding(
        key: const Key('project-outcome'),
        padding: const EdgeInsets.only(bottom: 6),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(
              '望む結果（何をもって完了か）: 未記入',
              key: const Key('project-outcome-empty'),
              style: inlineLabelStyle(context),
            ),
            ?edit,
          ],
        ),
      );
    }
    return Padding(
      key: const Key('project-outcome'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '望む結果（何をもって完了か）',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              SelectableText(
                lines.join('\n'),
                key: const Key('project-outcome-text'),
                style: const TextStyle(height: 1.6),
              ),
              if (edit != null)
                Align(alignment: Alignment.centerRight, child: edit),
            ],
          ),
        ),
      ),
    );
  }

  /// プロジェクトの領域（本人が付けた責任の範囲）と、付ける・変える操作。領域に対応していない本体では、付いていても示すだけ。
  Widget projectArea(HubProject project, bool editable) {
    final supported = repo.intakeFeatures.areas;
    if (project.area == null && !supported) return const SizedBox.shrink();
    return Padding(
      key: const Key('project-area'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(
            '領域: ${project.area ?? '未設定'}',
            key: const Key('project-area-label'),
            style: inlineLabelStyle(context),
          ),
          if (supported)
            TextButton.icon(
              key: const Key('project-area-edit'),
              onPressed: editable ? () => changeArea(project) : null,
              icon: const Icon(Icons.folder_outlined, size: 16),
              label: Text(project.area == null ? '領域を付ける' : '領域を変える'),
            ),
        ],
      ),
    );
  }

  List<Widget> projectView(HubProject project) {
    final now = DateTime.now(),
        requested = repo.projectStatusRequestIdFor(project.id) != null,
        defining =
            repo.projectDefinitionRequestIdFor(project.id) != null ||
            repo.projectAreaRequestIdFor(project.id) != null,
        merging = repo.projectMergeRequestIdFor(project.id) != null,
        mergeTarget = repo.projects[project.mergeTarget],
        sources = repo.mergedSources(project.id),
            // 統合と取り消しは、統合済みのプロジェクトでも依頼できる（取り消しのため）。
            mergeable =
            !c.loading &&
            !c.saving &&
            !requested &&
            !defining &&
            !merging &&
            c.captureWarning == null &&
            project.definitionHash != null,
        editable =
            !c.loading &&
            !c.saving &&
            !requested &&
            !defining &&
            !merging &&
            !project.merged &&
            c.captureWarning == null &&
            project.definitionHash != null,
        changes = c.changesSince(project, visit: true),
        added = changes?.added.map((i) => i.id).toSet() ?? const <String>{};
    final theme = Theme.of(context);
    // 見出しの下の操作は、行の操作より一回り大きいが、本文より目立たない大きさにそろえる。
    final actionStyle = compactOutlinedStyle(context);
    // 本体がいつも付ける「未検証の要約」の注意は、欄の見出しの下に小さく添える（毎回の大きな注意にしない）。
    final summaryNote = project.warnings.where(
          (w) => w == HubProject.summaryWarning,
        ),
        problems = project.warnings.where(
          (w) => w != HubProject.summaryWarning,
        );
    return [
      title(
        label: 'プロジェクト · ${project.lifecycleLabel}',
        project.title,
        '${projectStatusLine(project, now)}\n最新の根拠: ${timeLabel(project.lastEvidenceAt)} · 要約の生成: ${timeLabel(project.generatedAt)}',
      ),
      projectOutcome(project, editable),
      projectArea(project, editable),
      if (project.stale(now))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '最終根拠から$projectStaleDays日を超えて新しい入力がありません。再開するか、休止・完了にするかを判断してください。${project.outcomeLines.isEmpty ? '' : '\n望む結果: ${project.outcomeLines.join(' / ')}'}',
            key: const Key('project-stale'),
          ),
        ),
      if (requested)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox('状態の変更を依頼済みです。Mac miniで処理されると反映されます。'),
        ),
      if (project.nowConflict case final conflict?)
        conflictPanel(project, conflict),
      if (mergeTarget != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NoticeBox(
                'このプロジェクトは「${mergeTarget.title}」に統合済みです。このプロジェクトを指定したメモ・完了報告・日付は、統合先のものとして読みます。現在地と次の一手は統合先で確認してください。',
                key: const Key('project-merged'),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('project-merge-target'),
                    onPressed: () =>
                        widget.onNavigate('project:${mergeTarget.id}'),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: Text('統合先「${mergeTarget.title}」を開く'),
                  ),
                  // 取り消せるのは直接の統合先からだけ（本体と同じ）。
                  if (project.mergedInto == mergeTarget.id)
                    OutlinedButton.icon(
                      key: const Key('project-unmerge'),
                      onPressed: mergeable
                          ? () => unmergeProject(project)
                          : null,
                      icon: const Icon(Icons.call_split, size: 18),
                      label: const Text('統合を取り消す'),
                    ),
                ],
              ),
            ],
          ),
        ),
      if (sources.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '統合されたプロジェクト: ${sources.map((p) => p.title).join('、')}\nこれらを指定したメモ・完了報告・日付も、このプロジェクトのものとして読んでいます。',
            key: const Key('project-merge-sources'),
          ),
        ),
      if (merging)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '統合（または取り消し）を依頼済みです。Mac miniで処理されると反映されます。',
            key: Key('project-merge-requested'),
          ),
        ),
      if (defining)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            '呼び名とキーワード（または望む結果・領域）の変更を依頼済みです。Mac miniで処理されると反映されます。',
            key: Key('project-definition-requested'),
          ),
        ),
      // メモがどのプロジェクトのものかを見分ける手がかり。
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SelectableText(
          '呼び名: ${project.aliases.isEmpty ? 'なし' : project.aliases.join('・')} · キーワード: ${project.keywords.isEmpty ? 'なし' : project.keywords.join('・')}（メモを見分ける手がかり）',
          key: const Key('project-terms'),
          style: theme.textTheme.bodySmall,
        ),
      ),
      for (final warning in problems)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(warning),
        ),
      if (changes != null && !changes.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NoticeBox(
            [
              '前回見てから: 新しい項目${changes.added.length}件・外れた項目${changes.removed.length}件',
              for (final item in changes.removed.take(5))
                '外れた（${sectionLabels[item.section] ?? item.section}）: ${item.text.isEmpty ? '（本文は記録していません）' : item.text}',
              if (changes.removed.length > 5)
                'ほか${changes.removed.length - 5}件',
            ].join('\n'),
            key: const Key('project-changes'),
          ),
        ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            key: const Key('project-pin'),
            style: actionStyle,
            onPressed: () => togglePin(project),
            icon: Icon(
              repo.isPinned(project.id)
                  ? Icons.push_pin
                  : Icons.push_pin_outlined,
              size: 18,
            ),
            label: Text(repo.isPinned(project.id) ? 'ピン留めを外す' : 'ピン留め'),
          ),
          OutlinedButton.icon(
            key: const Key('project-history'),
            style: actionStyle,
            onPressed: project.history == null
                ? null
                : () => showHistory(project),
            icon: const Icon(Icons.timeline, size: 18),
            label: Text(project.history == null ? '経緯（未生成）' : '経緯'),
          ),
          // 資料のページは、資料のあるプロジェクトにだけ本体が作る。資料の一覧を書く本体なら、空の資料棚も開ける。
          // 統合済みのプロジェクトの資料は統合先にまとまるので、統合先の資料を開く。
          if ((mergeTarget ?? project).shelf != null ||
              repo.referenceIndex != null)
            OutlinedButton.icon(
              key: const Key('project-shelf'),
              style: actionStyle,
              onPressed: () => showShelf(mergeTarget ?? project),
              icon: const Icon(Icons.bookmarks_outlined, size: 18),
              label: Text(mergeTarget == null ? '資料' : '資料（統合先）'),
            ),
          OutlinedButton.icon(
            key: const Key('project-guided'),
            style: actionStyle,
            onPressed: c.loading || c.captureWarning != null
                ? null
                : () => showGuided(context, c, project: project.id),
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('質問に答える'),
          ),
          OutlinedButton.icon(
            key: const Key('copy-context'),
            style: actionStyle,
            onPressed: c.loading
                ? null
                : () async {
                    try {
                      final text = await c.context(project.id);
                      await Clipboard.setData(ClipboardData(text: text));
                      if (mounted) {
                        notice(context, '別のAIに渡す文章をコピーしました');
                      }
                    } catch (e) {
                      if (mounted) {
                        notice(context, HubController.message(e));
                      }
                    }
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('AIに渡す文章をコピー'),
          ),
          // ふだん使わない変更は「…」にまとめる。
          PopupMenuButton<VoidCallback>(
            key: const Key('project-more'),
            tooltip: 'ほかの操作',
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('project-status'),
                enabled: editable,
                value: () => changeStatus(project),
                child: const Text('状態を変える（休止・完了など）'),
              ),
              PopupMenuItem(
                key: const Key('project-definition'),
                enabled: editable,
                value: () => changeDefinition(project),
                child: Text(
                  repo.intakeFeatures.projectOutcome == null
                      ? '呼び名とキーワードを変える'
                      : '呼び名・キーワード・望む結果を変える',
                ),
              ),
              // 手で書いた統合先が見つからない・循環している定義は、直すまで統合を依頼できない（本体が断る）。
              if (!project.merged && project.mergedInto == null)
                PopupMenuItem(
                  key: const Key('project-merge'),
                  // ほかのプロジェクトの統合先になっているプロジェクトは、統合元にできない（本体と同じ）。
                  enabled: mergeable && sources.isEmpty,
                  value: () => mergeProject(project),
                  child: const Text('ほかのプロジェクトへ統合'),
                ),
            ],
          ),
        ],
      ),
      for (final section in [
        ('current', '現在地'),
        ('next', '次の一手'),
        ('open', '未解決'),
        ('proposals', '提案'),
      ]) ...[
        sectionHeading(
          section.$2,
          note: section.$1 == 'current' && summaryNote.isNotEmpty
              ? summaryNote.first
              : null,
          trailing: [
            // 本人が決めた行動を、AIの整理を待たずに次の一手へ載せる。統合済みのプロジェクトには追加しない。
            if (section.$1 == 'next' &&
                !project.merged &&
                c.repository?.intakeFeatures.actions == true)
              TextButton.icon(
                key: const Key('project-add-action'),
                onPressed: busy || c.composing
                    ? null
                    : () => addAction(project: project),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('次の一手を追加'),
              ),
          ],
        ),
        entryCard([
          if (section.$1 == 'next')
            for (final action in project.pendingActions)
              pendingActionRow(action),
          if (project.sections[section.$1]!.isEmpty &&
              (section.$1 != 'next' || project.pendingActions.isEmpty))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text('まだAIが読み取っていません。', style: theme.textTheme.bodySmall),
            ),
          for (final entry in project.sections[section.$1]!)
            nowEntry(project, section.$1, entry, added),
        ]),
      ],
      if (project.resolvedItems.isNotEmpty) ...[
        sectionHeading('解決済み・完了（本人報告）'),
        Card(
          key: const Key('resolved-items'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in project.resolvedItems)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${item.section == 'next' ? '完了' : '解決'}: ${item.display}（${timeLabel(item.resolvedAt)}）',
                        ),
                      ),
                      repo.itemRequestIdFor(item.key) != null
                          ? const Text(
                              '報告済み（反映待ち）',
                              style: TextStyle(fontSize: 12),
                            )
                          : TextButton(
                              key: Key('reopen-${item.key.substring(0, 12)}'),
                              onPressed: busy
                                  ? null
                                  : () => reportItem(project, item, 'reopen'),
                              child: const Text('未解決に戻す'),
                            ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
      if (project.excludedItems.isNotEmpty) ...[
        sectionHeading(
          '誤りとして外した項目（本人報告）',
          note: '完了・解決には数えません。理由と一言は、次からのAI読み取りでAIへ渡します。',
        ),
        Card(
          key: const Key('excluded-items'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in project.excludedItems)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${item.section == 'next' ? '次の一手' : '未解決'}: ${item.display}\n理由: ${exclusionReasonLabels[item.exclusionReason]}${item.exclusionNote == null ? '' : '（${item.exclusionNote}）'}（${timeLabel(item.resolvedAt)}）',
                        ),
                      ),
                      repo.itemRequestIdFor(item.key) != null
                          ? const Text(
                              '報告済み（反映待ち）',
                              style: TextStyle(fontSize: 12),
                            )
                          : TextButton(
                              key: Key('reopen-${item.key.substring(0, 12)}'),
                              onPressed: busy
                                  ? null
                                  : () => reportItem(project, item, 'reopen'),
                              child: const Text('未解決に戻す'),
                            ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
      if (project.drafts.isNotEmpty) ...[
        sectionHeading(
          '作業記録の下書き',
          note: '設定したリポジトリのコミット件名から作った下書きです。本文を確かめて直し、メモとして保存するか、見送ってください。',
        ),
        for (final draft in project.drafts)
          Card(
            key: Key('draft-${draft.id}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${draft.repo} · コミット${draft.commitCount}件 · 作成 ${timeLabel(draft.createdAt)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(draft.text),
                  const SizedBox(height: 8),
                  if (repo.draftRequestIdFor(draft.id) != null)
                    Text('操作済み（反映待ち）', style: noteStyle(context))
                  else
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonal(
                          key: Key('draft-use-${draft.id}'),
                          onPressed: busy || c.composing
                              ? null
                              : () => showCapture(context, c, draft: draft),
                          child: const Text('メモとして保存'),
                        ),
                        TextButton(
                          key: Key('draft-dismiss-${draft.id}'),
                          onPressed: busy ? null : () => dismissDraft(draft),
                          child: const Text('見送る'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
      if (project.notes.trim().isNotEmpty) ...[
        sectionHeading('手動メモ'),
        SafeMarkdown(
          text: project.notes,
          sourcePath: repo.records[project.nowRecordId]?.path ?? '',
          controller: c,
          onRecord: open,
        ),
        const SizedBox(height: 24),
      ],
      if (project.nowRecordId != null)
        TextButton(
          onPressed: () => open(project.nowRecordId!),
          child: const Text('現状の本文と出典・日時を開く'),
        ),
    ];
  }
}
