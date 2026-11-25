import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// プロジェクトの領域を選ぶ（語彙から選ぶか、新しく書く）。外すこともできる。語彙の一覧はここから編集できる。
class AreaDialog extends StatefulWidget {
  const AreaDialog({
    super.key,
    required this.current,
    required this.choices,
    required this.editVocabulary,
  });
  final String? current;

  /// 選べる領域（語彙と、今のプロジェクトに付いている領域）。語彙を編集した後に読み直す。
  final List<String> Function() choices;
  final Future<bool> Function() editVocabulary;
  @override
  State<AreaDialog> createState() => _AreaDialogState();
}

class _AreaDialogState extends State<AreaDialog> {
  late final input = TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  String get value => normalizeArea(input.text);

  @override
  Widget build(BuildContext context) {
    final v = value, valid = validArea(v), choices = widget.choices();
    return HubAlertDialog(
      key: const Key('area-dialog'),
      title: const Text('領域'),
      onClose: () => Navigator.pop(context),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (choices.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in choices)
                      ChoiceChip(
                        key: Key('area-choice-$a'),
                        label: Text(a),
                        selected: v == a,
                        onSelected: (_) => setState(() => input.text = a),
                      ),
                  ],
                ),
              TextField(
                key: const Key('area-input'),
                controller: input,
                maxLength: areaChars,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '領域（例: 仕事・家・健康・お金）',
                  errorText: v.isEmpty || valid
                      ? null
                      : '1行・$areaChars文字までで、「$noAreaLabel」は使えません。',
                ),
              ),
              TextButton(
                key: const Key('area-vocabulary-edit'),
                onPressed: () async {
                  if (await widget.editVocabulary() && mounted) setState(() {});
                },
                child: const Text('領域の一覧と並びを編集'),
              ),
              Text(
                '領域は、プロジェクトをまとめる責任の範囲です。ホームと週次レビューで領域ごとにまとまります。AIは領域を付けません。',
                style: noteStyle(context),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            key: const Key('area-clear'),
            onPressed: () => Navigator.pop(context, (area: null)),
            child: const Text('領域を外す'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('area-submit'),
          onPressed: !valid || v == widget.current
              ? null
              : () => Navigator.pop(context, (area: v)),
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}

/// 領域の一覧（語彙）と並びを編集する。並びはホームと週次レビューの領域の順になる。
class AreaVocabularyDialog extends StatefulWidget {
  const AreaVocabularyDialog({
    super.key,
    required this.current,
    this.pending = false,
  });
  final List<String> current;
  final bool pending;
  @override
  State<AreaVocabularyDialog> createState() => _AreaVocabularyDialogState();
}

class _AreaVocabularyDialogState extends State<AreaVocabularyDialog> {
  late final List<String> items = [...widget.current];
  final input = TextEditingController();
  String? error;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void add() {
    final a = normalizeArea(input.text);
    setState(() {
      if (a.isEmpty) {
        error = null;
      } else if (!validArea(a)) {
        error = '領域は1行・$areaChars文字までで、「$noAreaLabel」は使えません。';
      } else if (items.contains(a)) {
        error = '同じ領域が一覧にあります。';
      } else if (items.length >= areaVocabularyMax) {
        error = '領域の一覧は$areaVocabularyMax個までです。';
      } else {
        items.add(a);
        input.clear();
        error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => HubAlertDialog(
    key: const Key('area-vocabulary-dialog'),
    title: const Text('領域の一覧'),
    onClose: () => Navigator.pop(context),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.pending)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '前の変更がまだMac miniで処理されていません（その一覧を表示しています）。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            for (final (i, a) in items.indexed)
              Row(
                key: Key('area-vocabulary-row-$a'),
                children: [
                  Expanded(child: Text(a)),
                  IconButton(
                    key: Key('area-vocabulary-up-$a'),
                    tooltip: '上へ',
                    onPressed: i == 0
                        ? null
                        : () => setState(() {
                            items.removeAt(i);
                            items.insert(i - 1, a);
                          }),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                  IconButton(
                    key: Key('area-vocabulary-remove-$a'),
                    tooltip: '一覧から外す',
                    onPressed: () => setState(() => items.removeAt(i)),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('area-vocabulary-input'),
                    controller: input,
                    maxLength: areaChars,
                    decoration: InputDecoration(
                      labelText: '新しい領域（例: 仕事・家・健康・お金）',
                      errorText: error,
                    ),
                    onSubmitted: (_) => add(),
                  ),
                ),
                IconButton(
                  key: const Key('area-vocabulary-add'),
                  tooltip: '足す',
                  onPressed: add,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Text(
              'この一覧と並びは同じVaultを使うすべての端末で共有し、ホームと週次レビューの領域の順になります。一覧から外しても、その領域が付いているプロジェクトからは消えません。',
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
        key: const Key('area-vocabulary-submit'),
        onPressed: listEquals(items, widget.current)
            ? null
            : () => Navigator.pop(context, [...items]),
        child: const Text('依頼する'),
      ),
    ],
  );
}
