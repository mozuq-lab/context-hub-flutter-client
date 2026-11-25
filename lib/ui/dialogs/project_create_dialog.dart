import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../../storage/capture_service.dart';
import '../parts.dart';
import '../save_checks.dart';

Future<void> showProjectCreate(BuildContext context, HubController c) async {
  if (c.composing) return;
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProjectCreateDialog(controller: c),
    );
  } finally {
    c.composing = false;
  }
}

/// 新しいプロジェクトの作成を依頼するフォーム。IDと操作IDはフォームを開いたときに決め、
/// 保存結果が不明なときは同じ操作IDで確認する。
class ProjectCreateDialog extends StatefulWidget {
  const ProjectCreateDialog({super.key, required this.controller});
  final HubController controller;
  @override
  State<ProjectCreateDialog> createState() => _ProjectCreateDialogState();
}

class _ProjectCreateDialogState extends State<ProjectCreateDialog> {
  final title = TextEditingController(),
      aliases = TextEditingController(),
      keywords = TextEditingController(),
      outcome = TextEditingController(),
      area = TextEditingController(),
      memo = TextEditingController();
  final operation = const Uuid().v4(), projectId = newProjectId();

  /// 本体が領域に対応していれば、選べる領域（語彙と、今のプロジェクトに付いている領域）。対応前の本体ではnull（欄を出さない）。
  List<String>? get areaChoices {
    final repo = widget.controller.repository;
    return repo != null && repo.intakeFeatures.areas ? repo.areasInUse : null;
  }

  /// 本体が望む結果に対応していれば、その上限。対応前の本体ではnull（欄を出さない）。
  ({int maxChars, int maxLines})? get outcomeLimits =>
      widget.controller.repository?.intakeFeatures.projectOutcome;
  String? error;
  CaptureResult? result;
  bool busy = false, locked = false;

  @override
  void dispose() {
    for (final c in [title, aliases, keywords, outcome, area, memo]) {
      c.dispose();
    }
    super.dispose();
  }

  NewProjectRequest get request => NewProjectRequest(
    operationId: operation,
    projectId: projectId,
    title: title.text.trim(),
    aliases: NewProjectRequest.splitNames(aliases.text),
    keywords: NewProjectRequest.splitNames(keywords.text),
    firstMemo: memo.text.trim().isEmpty ? '' : memo.text,
    outcome: outcomeLimits == null ? '' : outcome.text,
    outcomeLimits: outcomeLimits,
    area: areaChoices == null || area.text.trim().isEmpty
        ? null
        : normalizeArea(area.text),
  );

  Future<void> submit() async {
    if (busy) return;
    if (memo.text.trim().isNotEmpty) {
      final checked = await checkSecretsBeforeSave(
        context,
        memo.text,
        secrets: widget.controller.repository?.secretPolicy,
      );
      if (checked == null || !mounted) return;
      if (checked != memo.text) memo.text = checked;
    }
    final r = request, repo = widget.controller.repository;
    final problem =
        r.formatError ??
        (repo == null
            ? null
            : r.overlapError(
                repo.projects.values,
                repo.pendingProjectCreations,
              ));
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    setState(() {
      busy = true;
      locked = true;
      error = null;
    });
    try {
      final saved = await widget.controller.requestProjectCreate(r);
      if (mounted) setState(() => result = saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = HubController.message(e);
          // 依頼の記録（journal）を作る前に止まった場合（重なり・形式・状態）だけ、直して送り直せるようにする。
          // 記録後に結果が不明になった場合は、同じ内容・同じ操作IDで確認する。
          final journaled = widget.controller.pending.any(
            (p) => p.operationId == operation,
          );
          if (result == null && !journaled) locked = false;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    String key,
    TextEditingController controller,
    String label, {
    String? hint,
    int lines = 1,
    int? max,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: Key(key),
      controller: controller,
      readOnly: locked,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 4,
      maxLength: max,
      // 書き方の手がかりは、入力を始める前から読めるよう欄の下に出す（欄の中の薄い文字は、名前に隠れて見えない）。
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        alignLabelWithHint: lines > 1,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: HubAlertDialog(
      title: const Text('新しいプロジェクト'),
      onClose: busy ? null : () => Navigator.pop(context),
      content: SizedBox(
        width: 620,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              fieldNote(
                context,
                '保存先: ${widget.controller.location?.name ?? ''}',
                top: 0,
              ),
              const SizedBox(height: 16),
              field('project-create-title', title, '名前', max: 200),
              field(
                'project-create-aliases',
                aliases,
                '別名（任意）',
                hint: 'カンマ・読点区切り。AIがメモを結び付ける手がかりになります',
              ),
              field(
                'project-create-keywords',
                keywords,
                'キーワード（任意）',
                hint: 'カンマ・読点区切り',
              ),
              if (outcomeLimits case final limits?)
                field(
                  'project-create-outcome',
                  outcome,
                  '望む結果（任意）',
                  // 上限は整えた後の文で数える（本体と同じ）。入力欄では切らず、送るときに確かめる。
                  hint:
                      'どうなればこのプロジェクトを完了にできるか（${limits.maxChars}文字・${limits.maxLines}行まで）',
                  lines: 2,
                ),
              if (areaChoices case final choices?) ...[
                field(
                  'project-create-area',
                  area,
                  '領域（任意）',
                  hint: '仕事・家・健康のような、責任を持つ範囲（$areaChars文字まで）',
                  max: areaChars,
                ),
                if (choices.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final a in choices)
                          ActionChip(
                            key: Key('project-create-area-$a'),
                            label: Text(a),
                            onPressed: locked
                                ? null
                                : () => setState(() => area.text = a),
                          ),
                      ],
                    ),
                  ),
              ],
              field(
                'project-create-memo',
                memo,
                '最初のメモ（任意）',
                hint: 'このプロジェクトのメモとして保存します',
                lines: 4,
                max: 8000,
              ),
              Text(
                '作成の依頼を保存します。Mac miniで処理されるとプロジェクト一覧に表示されます。名前・別名が既存のプロジェクトと重なる場合は作成されません。',
                style: noteStyle(context),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: NoticeBox(error!, error: true),
                ),
              if (result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: NoticeBox(
                    result!.saved
                        ? 'この端末に作成の依頼を保存しました'
                        : '保存確認待ちです。再送せず同じ操作を確認してください。',
                  ),
                ),
              if (locked && result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    '操作ID: $operation',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(result?.saved == true ? '閉じる' : 'フォームを閉じる'),
        ),
        if (result == null)
          FilledButton(
            key: const Key('project-create-submit'),
            onPressed: busy ? null : submit,
            child: const Text('作成を依頼'),
          ),
        if (result != null && !result!.saved)
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      final r = await widget.controller.confirm(operation);
                      if (mounted) setState(() => result = r);
                    } catch (e) {
                      if (mounted) {
                        setState(() => error = HubController.message(e));
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('同じ操作を確認'),
          ),
        if (busy)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    ),
  );
}
