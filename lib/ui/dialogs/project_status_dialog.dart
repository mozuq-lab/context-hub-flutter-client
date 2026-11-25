import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';
import '../save_checks.dart';

class ProjectStatusDialog extends StatefulWidget {
  const ProjectStatusDialog({
    super.key,
    required this.project,
    this.outcomeSupported = true,
  });
  final HubProject project;

  /// 本体が望む結果に対応しているか。対応前の本体では書けないため、未記入の案内を出さない。
  final bool outcomeSupported;
  @override
  State<ProjectStatusDialog> createState() => _ProjectStatusDialogState();
}

class _ProjectStatusDialogState extends State<ProjectStatusDialog> {
  String? selected;
  @override
  Widget build(BuildContext context) => HubAlertDialog(
    title: Text('${widget.project.title}の状態'),
    onClose: () => Navigator.pop(context),
    content: DialogScroll(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('現在: ${widget.project.lifecycleLabel}'),
          const SizedBox(height: 12),
          for (final status in projectLifecycles)
            if (status != widget.project.lifecycle)
              ListTile(
                key: Key('project-status-$status'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  selected == status
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(projectLifecycleLabels[status]!),
                onTap: () => setState(() => selected = status),
              ),
          // 完了・休止の判断の基準として、本人が書いた望む結果を添える。
          if (selected != null &&
              selected != 'active' &&
              (widget.outcomeSupported ||
                  widget.project.outcomeLines.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: NoticeBox(
                widget.project.outcomeLines.isEmpty
                    ? '望む結果は書かれていません。'
                    : '望む結果:\n${widget.project.outcomeLines.join('\n')}${selected == 'done' ? '\nこれを満たしたかを確かめてから完了にしてください。' : ''}',
                key: const Key('project-status-outcome'),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '休止・完了にすると、ホームの後ろにまとめて表示し、AIの帰属候補から外します。メモで明示したプロジェクトは引き続き使えます。依頼は保存され、Mac miniで処理されると反映されます。',
            style: noteStyle(context),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        key: const Key('project-status-submit'),
        onPressed: selected == null
            ? null
            : () => Navigator.pop(context, selected),
        child: const Text('変更を依頼'),
      ),
    ],
  );
}
