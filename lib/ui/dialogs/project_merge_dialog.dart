import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';
import '../save_checks.dart';

/// 同じものを指すプロジェクトを、ほかのプロジェクトへ統合する確認画面。統合先を選ぶ。
class ProjectMergeDialog extends StatefulWidget {
  const ProjectMergeDialog({
    super.key,
    required this.project,
    required this.candidates,
  });

  /// 統合元（いま開いているプロジェクト）。
  final HubProject project;

  /// 統合先にできるプロジェクト（統合済みを除く）。
  final List<HubProject> candidates;
  @override
  State<ProjectMergeDialog> createState() => _ProjectMergeDialogState();
}

class _ProjectMergeDialogState extends State<ProjectMergeDialog> {
  HubProject? selected;
  bool confirmed = false;
  @override
  Widget build(BuildContext context) => HubAlertDialog(
    title: Text('「${widget.project.title}」を統合'),
    onClose: () => Navigator.pop(context),
    content: SizedBox(
      width: 520,
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '同じものを指すプロジェクトが2つできたときに、このプロジェクトをもう一方へまとめます。',
              style: TextStyle(height: 1.6),
            ),
            const SizedBox(height: 12),
            if (widget.candidates.isEmpty)
              const NoticeBox('統合先にできるプロジェクトがありません。')
            else
              DropdownButtonFormField<String>(
                key: const Key('project-merge-into'),
                style: fieldTextStyle(context),
                initialValue: selected?.id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '統合先'),
                items: [
                  for (final p in widget.candidates)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        '${p.title}（${p.lifecycleLabel}）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) => setState(() {
                  selected = widget.candidates
                      .where((p) => p.id == id)
                      .firstOrNull;
                  confirmed = false;
                }),
              ),
            if (selected case final into?) ...[
              const SizedBox(height: 12),
              Text(
                [
                  '・「${widget.project.title}」は「統合済み」になり、ホームの後ろにまとめて表示します。定義とファイルは残ります。',
                  '・「${widget.project.title}」を指定したメモ・完了報告・日付は、「${into.title}」のものとして読みます。原文と記録は書き換えません。',
                  '・「${widget.project.title}」の名前・別名・キーワードを、「${into.title}」の別名・キーワードに足します。',
                  '・「${widget.project.title}」だけの方針は移しません。必要なものは統合先へ採用し直してください。',
                  '・あとで取り消せます。',
                ].join('\n'),
                key: const Key('project-merge-effects'),
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              CheckboxListTile(
                key: const Key('project-merge-confirm'),
                visualDensity: formTileDensity,
                horizontalTitleGap: formTileGap,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: confirmed,
                onChanged: (v) => setState(() => confirmed = v ?? false),
                title: Text(
                  '「${widget.project.title}」と「${into.title}」は同じものを指している',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
            Text('依頼は保存され、Mac miniで処理されると反映されます。', style: noteStyle(context)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        key: const Key('project-merge-submit'),
        onPressed: selected == null || !confirmed
            ? null
            : () => Navigator.pop(context, selected),
        child: const Text('統合を依頼'),
      ),
    ],
  );
}
