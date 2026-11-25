import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// NOWの項目の手間の目安を選ぶ。目安は本人が選び、AIは推測しない。結果のeffortがnullなら外す。
class EffortDialog extends StatefulWidget {
  const EffortDialog({super.key, required this.item});
  final NowItemRef item;
  @override
  State<EffortDialog> createState() => _EffortDialogState();
}

class _EffortDialogState extends State<EffortDialog> {
  late String? effort = widget.item.effort;

  @override
  Widget build(BuildContext context) => HubAlertDialog(
    key: const Key('effort-dialog'),
    title: const Text('手間の目安'),
    onClose: () => Navigator.pop(context),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.item.display,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in itemEfforts)
                  ChoiceChip(
                    key: Key('effort-choice-$e'),
                    label: Text(itemEffortLabels[e]!),
                    selected: effort == e,
                    onSelected: (_) => setState(() => effort = e),
                  ),
                if (widget.item.effort != null)
                  ChoiceChip(
                    key: const Key('effort-choice-none'),
                    label: const Text('目安を外す'),
                    selected: effort == null,
                    onSelected: (_) => setState(() => effort = null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '空いた時間に合う項目を「次の一手」で絞り込むための目安です。Mac miniで処理されると現状に反映され、同じ本文の項目には新しい報告が届いても引き継がれます。',
              style: noteStyle(context),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('やめる'),
      ),
      FilledButton(
        key: const Key('effort-submit'),
        onPressed: effort == widget.item.effort
            ? null
            : () => Navigator.pop(context, (effort: effort)),
        child: const Text('依頼する'),
      ),
    ],
  );
}
