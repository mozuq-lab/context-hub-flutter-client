import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// 連絡待ちの印（相手・頼んだ日）と見直す日を入力する。相手は任意で、AIは推測しない。
/// 結果の見直す日（reviewAfter）がnullなら見直す日を外す。
class WaitDialog extends StatefulWidget {
  const WaitDialog({
    super.key,
    required this.item,
    this.suggestions = const [],
  });
  final NowItemRef item;

  /// 相手の候補（いま連絡待ちにしている項目の相手）。
  final List<String> suggestions;
  @override
  State<WaitDialog> createState() => _WaitDialogState();
}

class _WaitDialogState extends State<WaitDialog> {
  late final who = TextEditingController(text: widget.item.waitingWho ?? ''),
      since = TextEditingController(
        text: widget.item.waitingSince ?? hubToday(),
      ),
      review = TextEditingController(text: widget.item.reviewAfter ?? '');

  @override
  void dispose() {
    who.dispose();
    since.dispose();
    review.dispose();
    super.dispose();
  }

  String? get whoValue => who.text.trim().isEmpty ? null : who.text.trim();
  String? get reviewValue =>
      review.text.trim().isEmpty ? null : review.text.trim();
  String? get whoProblem {
    final v = whoValue;
    return v == null || validWaitWho(v)
        ? null
        : '1行・$waitWhoChars文字以内で入力してください。';
  }

  String? get sinceProblem {
    final v = since.text.trim();
    if (!validScheduleDate(v)) return 'YYYY-MM-DDの実在する日で入力してください（2000〜2099年）。';
    return v.compareTo(hubToday()) > 0 ? '頼んだ日に先の日付は付けられません。' : null;
  }

  String? get reviewProblem {
    final v = reviewValue;
    return v == null || validScheduleDate(v)
        ? null
        : 'YYYY-MM-DDの実在する日で入力してください（2000〜2099年）。';
  }

  Widget dateChips(
    String key,
    TextEditingController c,
    List<(String, int)> choices,
  ) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final (label, days) in choices)
        ActionChip(
          key: Key('wait-$key-$days'),
          label: Text(label),
          onPressed: () =>
              setState(() => c.text = addScheduleDays(hubToday(), days)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final valid =
            whoProblem == null && sinceProblem == null && reviewProblem == null,
        sinceValue = since.text.trim(),
        changed =
            !widget.item.waiting ||
            widget.item.waitingSince != sinceValue ||
            widget.item.waitingWho != whoValue ||
            widget.item.reviewAfter != reviewValue;
    return HubAlertDialog(
      key: const Key('wait-dialog'),
      title: Text(widget.item.waiting ? '連絡待ちを変える' : '連絡待ちにする'),
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
              TextField(
                key: const Key('wait-who'),
                controller: who,
                maxLength: waitWhoChars,
                decoration: InputDecoration(
                  labelText: '相手（任意）',
                  helperText:
                      '名前はVaultに残り、同期先の端末とバックアップにも入ります。気になる場合はイニシャルなどで書いてください。',
                  helperMaxLines: 3,
                  errorText: whoProblem,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (widget.suggestions.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final name in widget.suggestions)
                      ActionChip(
                        key: Key('wait-who-suggestion-$name'),
                        label: Text(name),
                        onPressed: () => setState(() => who.text = name),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                key: const Key('wait-since'),
                controller: since,
                decoration: InputDecoration(
                  labelText: '頼んだ日',
                  hintText: 'YYYY-MM-DD',
                  errorText: sinceProblem,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              dateChips('since', since, [
                ('今日', 0),
                ('昨日', -1),
                ('3日前', -3),
                ('1週間前', -7),
              ]),
              const SizedBox(height: 14),
              TextField(
                key: const Key('wait-review'),
                controller: review,
                decoration: InputDecoration(
                  labelText: '見直す日（任意）',
                  hintText: 'YYYY-MM-DD',
                  helperText: 'この日になると「次の一手」の先頭に、連絡待ちの確認として出ます。',
                  helperMaxLines: 2,
                  errorText: reviewProblem,
                  suffixIcon: review.text.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('wait-review-clear'),
                          tooltip: '外す',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(review.clear),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              dateChips('review', review, [
                ('3日後', 3),
                ('1週間後', 7),
                ('2週間後', 14),
              ]),
              const SizedBox(height: 12),
              Text(
                '連絡待ちにした項目は、「次の一手」の一覧と件数から外れ、「連絡待ち」にまとまります。返事が来たら印を外すか、完了にしてください。相手の名前は、ホーム画面のウィジェットと、別のAIへ渡す資料には出しません。',
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
          key: const Key('wait-submit'),
          onPressed: valid && changed
              ? () => Navigator.pop(context, (
                  who: whoValue,
                  since: sinceValue,
                  reviewAfter: reviewValue,
                ))
              : null,
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}
