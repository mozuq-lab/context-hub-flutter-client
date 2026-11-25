import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// NOWの項目に期日と次に見直す日を付ける画面。日付は本人が選び、AIは推測しない。
class ScheduleDialog extends StatefulWidget {
  const ScheduleDialog({
    super.key,
    required this.item,
    this.repeatSupported = false,
  });
  final NowItemRef item;

  /// 本体が繰り返し（定例）に対応している。対応していなければ選ばせない。
  final bool repeatSupported;
  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  late final due = TextEditingController(text: widget.item.due ?? ''),
      review = TextEditingController(text: widget.item.reviewAfter ?? '');
  late RepeatRule? repeat = widget.item.repeat;

  @override
  void dispose() {
    due.dispose();
    review.dispose();
    super.dispose();
  }

  String? value(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();
  String? problem(TextEditingController c) {
    final v = value(c);
    return v == null || validScheduleDate(v)
        ? null
        : 'YYYY-MM-DDの実在する日で入力してください（2000〜2099年）。';
  }

  Widget field(String key, String label, String help, TextEditingController c) {
    final today = hubToday();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: Key('schedule-$key'),
          controller: c,
          decoration: InputDecoration(
            labelText: label,
            hintText: 'YYYY-MM-DD',
            helperText: help,
            helperMaxLines: 2,
            errorText: problem(c),
            suffixIcon: c.text.isEmpty
                ? null
                : IconButton(
                    key: Key('schedule-$key-clear'),
                    tooltip: '外す',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(c.clear),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, days) in [
              ('今日', 0),
              ('明日', 1),
              ('3日後', 3),
              ('1週間後', 7),
              ('2週間後', 14),
              ('30日後', 30),
            ])
              ActionChip(
                key: Key('schedule-$key-$days'),
                label: Text(label),
                onPressed: () =>
                    setState(() => c.text = addScheduleDays(today, days)),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final nextDue = value(due), nextReview = value(review);
    // 繰り返しは期日があるときだけ付く。期日を外すと繰り返しも外れる。
    final nextRepeat = nextDue == null
        ? null
        : widget.repeatSupported
        ? repeat
        : widget.item.repeat;
    final valid = problem(due) == null && problem(review) == null,
        changed =
            nextDue != widget.item.due ||
            nextReview != widget.item.reviewAfter ||
            nextRepeat != widget.item.repeat,
        clearing = nextDue == null && nextReview == null;
    final choices = {...RepeatRule.choices, ?widget.item.repeat}.toList();
    return HubAlertDialog(
      title: const Text('期日と次に見直す日'),
      onClose: () => Navigator.pop(context),
      content: SizedBox(
        width: 520,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.display,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              field('due', '期日（任意）', '過ぎた・今日・7日以内になると「次の一手」の先頭に出ます。', due),
              if (widget.repeatSupported) ...[
                const SizedBox(height: 14),
                const Text('繰り返し（定例）', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      key: const Key('schedule-repeat-none'),
                      label: const Text('なし'),
                      selected: nextRepeat == null,
                      onSelected: (_) => setState(() => repeat = null),
                    ),
                    for (final r in choices)
                      ChoiceChip(
                        key: Key('schedule-repeat-${r.unit}-${r.every}'),
                        label: Text(r.label),
                        selected: nextRepeat == r,
                        // 期日がなければ繰り返しは付けられない。
                        onSelected: nextDue == null
                            ? null
                            : (_) => setState(() => repeat = r),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  nextDue == null ? '繰り返しは期日を入れると選べます。' : '繰り返しを付けると、「今回を完了」「今回は見送る」で期日が次の回へ進み、項目は欄に残ります。毎月は期日の日を覚えます（短い月は月末）。',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              field(
                'review',
                '次に見直す日（任意）',
                'その日までは「次の一手」の末尾にたたみます。期日が近ければたたみません。',
                review,
              ),
              const SizedBox(height: 14),
              const Text(
                '日付はMac miniが処理すると現状とHOMEに反映されます。原文とAIの読み取り結果は変わりません。',
                style: TextStyle(fontSize: 12),
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
          key: const Key('schedule-save'),
          onPressed: valid && changed
              ? () => Navigator.pop(context, (
                  due: nextDue,
                  reviewAfter: nextReview,
                  repeat: widget.repeatSupported ? nextRepeat : null,
                ))
              : null,
          child: Text(clearing ? '日付を外す' : '依頼する'),
        ),
      ],
    );
  }
}
