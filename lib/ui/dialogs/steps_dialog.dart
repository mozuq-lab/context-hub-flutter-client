import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// 次の一手を手順に分ける・直す・外す。1行に1つの手順を書く（2〜10個）。AIは手順を作らない。
/// 直すときは、先頭から変えていない手順の分だけ、終えた数を保つ。
class StepsDialog extends StatefulWidget {
  const StepsDialog({super.key, required this.item});
  final NowItemRef item;
  @override
  State<StepsDialog> createState() => _StepsDialogState();
}

class _StepsDialogState extends State<StepsDialog> {
  late final text = TextEditingController(
    text: widget.item.steps?.items.join('\n') ?? '',
  );

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  List<String> get lines => [
    for (final l in text.text.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];

  /// 送る手順の全体。規則に合わなければnull。
  ItemSteps? get next {
    final items = lines, old = widget.item.steps;
    if (!validStepItems(items)) return null;
    var kept = 0;
    while (old != null &&
        kept < old.done &&
        kept < items.length &&
        kept < old.items.length &&
        old.items[kept] == items[kept]) {
      kept++;
    }
    return ItemSteps(items, kept);
  }

  String? get problem {
    final items = lines;
    if (items.isEmpty) return null;
    if (items.length < itemStepsMin) return '手順は$itemStepsMinつ以上にしてください。';
    if (items.length > itemStepsMax) return '手順は$itemStepsMax個までです。';
    if (!items.every(validActionText)) {
      return '手順は1つ$actionTextChars文字以内にしてください。';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final steps = next, old = widget.item.steps;
    return HubAlertDialog(
      key: const Key('steps-dialog'),
      title: Text(old == null ? '手順に分ける' : '手順を直す'),
      onClose: () => Navigator.pop(context),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.item.display, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                key: const Key('steps-input'),
                controller: text,
                minLines: 4,
                maxLines: 12,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '手順（1行に1つ、$itemStepsMin〜$itemStepsMax個）',
                  hintText: '医療費の領収書を集める\nふるさと納税の受領証を探す\ne-Taxで下書きする\n提出する',
                  alignLabelWithHint: true,
                  errorText: problem,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                steps == null
                    ? '次の一手の一覧には、今の1歩だけが出ます。'
                    : '次の一手の一覧には「${steps.label}」と出ます。${old != null && steps.done > 0 ? '（変えていない先頭の${steps.done}つは終えたままにします）' : ''}',
                style: noteStyle(context),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (old != null)
          TextButton(
            key: const Key('steps-clear'),
            onPressed: () => Navigator.pop(context, (steps: null)),
            child: const Text('手順を外す'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('steps-submit'),
          onPressed: steps == null || steps == old
              ? null
              : () => Navigator.pop(context, (steps: steps)),
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}
