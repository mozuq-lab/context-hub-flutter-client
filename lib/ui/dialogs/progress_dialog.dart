import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// 取りかかり中の印の、どこまで進んだかのひとことと始めた日を入力する。
/// 結果のひとこと（note）がnullならひとことを外す。印を付けていない項目では、始めた日の既定は今日。
class ProgressDialog extends StatefulWidget {
  const ProgressDialog({
    super.key,
    required this.item,
    this.noteMaxChars = progressNoteChars,
  });
  final NowItemRef item;

  /// ひとことの文字数の上限（本体の`item_progress.note_max_chars`）。
  final int noteMaxChars;
  @override
  State<ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<ProgressDialog> {
  late final note = TextEditingController(text: widget.item.progressNote ?? ''),
      since = TextEditingController(
        text: widget.item.progressSince ?? hubToday(),
      );

  @override
  void dispose() {
    note.dispose();
    since.dispose();
    super.dispose();
  }

  String? get noteValue => note.text.trim().isEmpty ? null : note.text.trim();
  String? get noteProblem {
    final v = noteValue;
    return v == null || validProgressNote(v, widget.noteMaxChars)
        ? null
        : '1行・${widget.noteMaxChars}文字以内で入力してください。';
  }

  String? get sinceProblem {
    final v = since.text.trim();
    if (!validScheduleDate(v)) return 'YYYY-MM-DDの実在する日で入力してください（2000〜2099年）。';
    return v.compareTo(hubToday()) > 0 ? '始めた日に先の日付は付けられません。' : null;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item,
        valid = noteProblem == null && sinceProblem == null,
        sinceValue = since.text.trim(),
        changed =
            !item.progressing ||
            item.progressSince != sinceValue ||
            item.progressNote != noteValue;
    return HubAlertDialog(
      key: const Key('progress-dialog'),
      title: Text(item.progressing ? 'どこまで進んだかを書く' : '取りかかる'),
      onClose: () => Navigator.pop(context),
      content: SizedBox(
        width: 520,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.display,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('progress-note'),
                controller: note,
                autofocus: true,
                maxLength: widget.noteMaxChars,
                decoration: InputDecoration(
                  labelText: 'どこまで進んだか（任意）',
                  hintText: '例: 見積もりの表は半分まで。残りは単価の確認',
                  helperText: '次に手を付けるときの自分へのメモです。NOWの本文と、別のAIへ渡す資料には載りません。',
                  helperMaxLines: 3,
                  errorText: noteProblem,
                  suffixIcon: note.text.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('progress-note-clear'),
                          tooltip: '消す',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(note.clear),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('progress-since'),
                controller: since,
                decoration: InputDecoration(
                  labelText: '始めた日',
                  hintText: 'YYYY-MM-DD',
                  errorText: sinceProblem,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (label, days) in const [
                    ('今日', 0),
                    ('昨日', -1),
                    ('3日前', -3),
                    ('1週間前', -7),
                  ])
                    ActionChip(
                      key: Key('progress-since-$days'),
                      label: Text(label),
                      onPressed: () => setState(
                        () => since.text = addScheduleDays(hubToday(), days),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '取りかかり中の項目は、ホームと「次の一手」の先頭にまとまります。終えたら「完了にする」、手を止めるなら「取りかかり中をやめる」を選んでください。',
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
          key: const Key('progress-submit'),
          onPressed: valid && changed
              ? () =>
                    Navigator.pop(context, (since: sinceValue, note: noteValue))
              : null,
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}
