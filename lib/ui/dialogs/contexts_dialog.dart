import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// 札を選ぶチップの並び。[options]は語彙と、語彙にないが今付いている札（「一覧にない」と添える）。
class ContextChips extends StatelessWidget {
  const ContextChips({
    super.key,
    required this.options,
    required this.vocabulary,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'contexts-choice',
  });
  final List<String> options, vocabulary, selected;
  final ValueChanged<List<String>> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final t in options)
        FilterChip(
          key: Key('$keyPrefix-$t'),
          showCheckmark: true,
          label: Text(vocabulary.contains(t) ? t : '$t（一覧にない）'),
          selected: selected.contains(t),
          onSelected: (on) {
            // 選んだ札は、語彙の並び（一覧にない札はその後ろ）にそろえて送る。
            final next = on ? {...selected, t} : ({...selected}..remove(t));
            onChanged([
              for (final o in options)
                if (next.contains(o)) o,
            ]);
          },
        ),
    ],
  );
}

/// NOWの項目の場所・道具の札を選ぶ。札は本人が選び、AIは付けない。結果のcontextsがnullなら外す。
/// 語彙から外した札が付いている項目は、その札を表示したまま付け直せる。
class ContextsDialog extends StatefulWidget {
  const ContextsDialog({
    super.key,
    required this.item,
    required this.vocabulary,
    required this.editVocabulary,
  });
  final NowItemRef item;

  /// 今の語彙（一覧を変えた後に読み直すため、関数で受け取る）。
  final List<String> Function() vocabulary;

  /// 語彙を編集して依頼する。依頼したらtrue。
  final Future<bool> Function() editVocabulary;
  @override
  State<ContextsDialog> createState() => _ContextsDialogState();
}

class _ContextsDialogState extends State<ContextsDialog> {
  late List<String> selected = [...widget.item.contexts];
  late List<String> vocabulary = widget.vocabulary();

  List<String> get options => {
    ...vocabulary,
    for (final t in [...widget.item.contexts, ...selected])
      if (!vocabulary.contains(t)) t,
  }.toList();

  // 札の並びだけが違う（語彙の順に並べ直した）ときは、変えていないものとする。
  bool get unchanged =>
      selected.length == widget.item.contexts.length &&
      selected.toSet().containsAll(widget.item.contexts);

  @override
  Widget build(BuildContext context) => HubAlertDialog(
    key: const Key('contexts-dialog'),
    title: const Text('場所・道具の札'),
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
            if (options.isEmpty)
              const Text('札の一覧が空です。「札の一覧を編集」から足してください。')
            else
              ContextChips(
                options: options,
                vocabulary: vocabulary,
                selected: selected,
                onChanged: (next) => setState(() => selected = next),
              ),
            if (selected.length > contextTagsMax)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '札は1つの項目に$contextTagsMax個までです。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('contexts-edit-vocabulary'),
                onPressed: () async {
                  if (await widget.editVocabulary() && mounted) {
                    setState(() => vocabulary = widget.vocabulary());
                  }
                },
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('札の一覧を編集'),
              ),
            ),
            Text(
              '今いる場所や手元の道具でできる項目を「次の一手」で絞り込むための札です。いくつでも選べ、何も選ばなければ札を外します。Mac miniで処理されると現状に反映され、同じ本文の項目には新しい報告が届いても引き継がれます。',
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
        key: const Key('contexts-submit'),
        onPressed: unchanged || selected.length > contextTagsMax
            ? null
            : () => Navigator.pop(context, (
                contexts: selected.isEmpty ? null : selected,
              )),
        child: Text(
          selected.isEmpty && widget.item.contexts.isNotEmpty ? '札を外す' : '依頼する',
        ),
      ),
    ],
  );
}

/// 場所・道具の札の一覧（語彙）を編集する。足す・外す・並べ替える。結果は変更後の全体。
/// 一覧はVaultに置き、同じVaultを使うすべての端末で同じものを使う。外した札は、付いている項目に残る。
class ContextVocabularyDialog extends StatefulWidget {
  const ContextVocabularyDialog({
    super.key,
    required this.current,
    this.pending = false,
  });
  final List<String> current;

  /// 前の変更がまだ反映されていない（その変更の一覧を見せている）。
  final bool pending;
  @override
  State<ContextVocabularyDialog> createState() =>
      _ContextVocabularyDialogState();
}

class _ContextVocabularyDialogState extends State<ContextVocabularyDialog> {
  late final List<String> items = [...widget.current];
  final input = TextEditingController();
  String? error;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void add() {
    final t = normalizeContextTag(input.text);
    setState(() {
      if (t.isEmpty) {
        error = null;
      } else if (!validContextTag(t)) {
        error = '札は$contextTagChars文字以内で、空白・「@・、,<>`」・括弧を使わずに入力してください。';
      } else if (items.contains(t)) {
        error = '同じ札が一覧にあります。';
      } else if (items.length >= contextVocabularyMax) {
        error = '札の一覧は$contextVocabularyMax個までです。';
      } else {
        items.add(t);
        input.clear();
        error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => HubAlertDialog(
    key: const Key('context-vocabulary-dialog'),
    title: const Text('札の一覧'),
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
            for (final (i, t) in items.indexed)
              Row(
                key: Key('vocabulary-row-$t'),
                children: [
                  Expanded(child: Text(t)),
                  IconButton(
                    key: Key('vocabulary-up-$t'),
                    tooltip: '上へ',
                    onPressed: i == 0
                        ? null
                        : () => setState(() {
                            items.removeAt(i);
                            items.insert(i - 1, t);
                          }),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                  IconButton(
                    key: Key('vocabulary-remove-$t'),
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
                    key: const Key('vocabulary-input'),
                    controller: input,
                    maxLength: contextTagChars,
                    decoration: InputDecoration(
                      labelText: '新しい札（例: 家・外出先・PC・電話・元気なとき）',
                      errorText: error,
                    ),
                    onSubmitted: (_) => add(),
                  ),
                ),
                IconButton(
                  key: const Key('vocabulary-add'),
                  tooltip: '足す',
                  onPressed: add,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Text(
              'この一覧は同じVaultを使うすべての端末で共有します。一覧から外しても、その札が付いている項目からは消えません（札を選ぶ画面に「一覧にない」と出ます）。',
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
        key: const Key('vocabulary-submit'),
        onPressed: listEquals(items, widget.current)
            ? null
            : () => Navigator.pop(context, [...items]),
        child: const Text('依頼する'),
      ),
    ],
  );
}
