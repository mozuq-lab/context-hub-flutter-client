import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/parser.dart' show clip;
import '../../core/today.dart';
import '../parts.dart';

/// 今日を締める。今日できたこと（完了・解決にした項目と受け取ったメモの数）と、今日の3つの残りを確かめ、
/// 明日へのひとこと（任意・[dayNoteLines]行・[dayNoteChars]文字まで）を書く。結果のdropは今日の3つから外す項目のキー。
/// モデルは使わない。
class DayCloseDialog extends StatefulWidget {
  const DayCloseDialog({
    super.key,
    required this.today,
    required this.done,
    required this.memos,
    required this.remaining,
    this.initialNote,
  });
  final String today;
  final List<(String, NowItemRef)> done;
  final int memos;
  final List<TodayEntry> remaining;
  final String? initialNote;
  @override
  State<DayCloseDialog> createState() => _DayCloseDialogState();
}

class _DayCloseDialogState extends State<DayCloseDialog> {
  late final note = TextEditingController(text: widget.initialNote ?? '');
  final drop = <String>{};

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  String? get error {
    final text = normalizeDayNote(note.text);
    if (text == null || validDayNote(text)) return null;
    if (text.split('\n').length > dayNoteLines) {
      return '$dayNoteLines行以内にしてください。';
    }
    if (text.length > dayNoteChars) return '$dayNoteChars文字以内にしてください。';
    return '使えない文字が含まれています。';
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall,
        heading = Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w700);
    return HubAlertDialog(
      key: const Key('day-close-dialog'),
      title: Text('今日を締める（${widget.today}）'),
      onClose: () => Navigator.pop(context),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('今日できたこと', style: heading),
              const SizedBox(height: 4),
              if (widget.done.isEmpty)
                Text('今日、完了・解決にした項目はありません。', style: small)
              else
                for (final (where, item) in widget.done)
                  Padding(
                    key: Key('day-close-done-${item.key.substring(0, 12)}'),
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text('✓ ${clip(item.text.trim(), 60)}（$where）'),
                  ),
              if (widget.memos > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '今日Mac miniが受け取ったメモ ${widget.memos}件',
                    key: const Key('day-close-memos'),
                    style: small,
                  ),
                ),
              if (widget.remaining.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('今日の3つで残っているもの', style: heading),
                const SizedBox(height: 4),
                for (final e in widget.remaining)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(clip(e.text, 60)),
                        SegmentedButton<bool>(
                          key: Key(
                            'day-close-pick-${e.pick.itemKey.substring(0, 12)}',
                          ),
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(value: false, label: Text('明日も続ける')),
                            ButtonSegment(
                              value: true,
                              label: Text('今日の3つから外す'),
                            ),
                          ],
                          selected: {drop.contains(e.pick.itemKey)},
                          onSelectionChanged: (v) => setState(
                            () => v.single
                                ? drop.add(e.pick.itemKey)
                                : drop.remove(e.pick.itemKey),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  '続けるものは、明日開いたときに持ち越しとして確かめます。「いつかやる」へ移すときは、項目の「ほかの操作」から移してください。',
                  style: noteStyle(context),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const Key('day-close-note'),
                controller: note,
                minLines: 2,
                maxLines: dayNoteLines + 1,
                decoration: InputDecoration(
                  labelText: '明日へのひとこと（任意）',
                  helperText:
                      '明日は何から始めるか、どこまで進めたかなど。$dayNoteLines行・$dayNoteChars文字まで。次に締めるか消すまで、ホームの先頭に出ます。',
                  helperMaxLines: 3,
                  errorText: error,
                ),
                onChanged: (_) => setState(() {}),
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
          key: const Key('day-close-submit'),
          onPressed: error != null
              ? null
              : () => Navigator.pop(context, (
                  note: normalizeDayNote(note.text),
                  drop: {...drop},
                )),
          child: const Text('締める'),
        ),
      ],
    );
  }
}
