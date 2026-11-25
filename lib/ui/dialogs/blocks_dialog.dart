import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/parser.dart' show clip;
import '../parts.dart';

/// 先に済ませること（別の項目1〜[max]件、先に済ませる順）を選ぶ。結果のafterがnullなら外す。
/// [choices]は選べる先の項目（置き場・置き場の名前・項目）。[current]は今付いていて、まだ残っている先の項目。
class BlocksDialog extends StatefulWidget {
  const BlocksDialog({
    super.key,
    required this.item,
    required this.choices,
    required this.current,
    this.max = itemBlocksMax,
  });
  final NowItemRef item;
  final List<({String scope, String title, NowItemRef item})> choices;
  final List<({String scope, String key})> current;
  final int max;
  @override
  State<BlocksDialog> createState() => _BlocksDialogState();
}

class _BlocksDialogState extends State<BlocksDialog> {
  late final selected = [...widget.current];
  final query = TextEditingController();
  static const shown = 20;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  ({String scope, String title, NowItemRef item})? choiceOf(String key) =>
      widget.choices.where((c) => c.item.key == key).firstOrNull;

  /// 今の記録（片付いた・見当たらない先の項目も含む）から変わったか。
  bool get changed {
    final before = [
      for (final a in widget.item.after?.items ?? const <ItemAfterRef>[])
        a.itemKey,
    ];
    return selected.length != before.length ||
        selected.indexed.any((e) => before[e.$1] != e.$2.key);
  }

  @override
  Widget build(BuildContext context) {
    final words = query.text.trim().toLowerCase();
    final matches = [
      for (final c in widget.choices)
        if (!selected.any((s) => s.key == c.item.key) &&
            (words.isEmpty ||
                c.item.text.toLowerCase().contains(words) ||
                c.title.toLowerCase().contains(words)))
          c,
    ];
    final full = selected.length >= widget.max;
    return HubAlertDialog(
      key: const Key('blocks-dialog'),
      title: const Text('先に済ませること'),
      onClose: () => Navigator.pop(context),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.item.display,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'この項目より先に済ませる項目を${widget.max}件まで、済ませる順に選びます。先の項目が残っている間は「先待ち」にまとまり、片付くと「動けるようになった項目」に出ます。',
                style: noteStyle(context),
              ),
              const SizedBox(height: 12),
              if (selected.isEmpty)
                Text('まだ選んでいません。', style: noteStyle(context))
              else
                for (final (i, s) in selected.indexed)
                  Row(
                    key: Key('blocks-selected-${s.key.substring(0, 12)}'),
                    children: [
                      Expanded(
                        child: Text(
                          '${i + 1}. ${clip(choiceOf(s.key)?.item.text.trim() ?? s.key, 60)}（${choiceOf(s.key)?.title ?? s.scope}）',
                        ),
                      ),
                      IconButton(
                        key: Key('blocks-remove-${s.key.substring(0, 12)}'),
                        tooltip: '外す',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => selected.removeAt(i)),
                      ),
                    ],
                  ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('blocks-search'),
                controller: query,
                decoration: const InputDecoration(
                  labelText: '項目を探す',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
              if (widget.choices.isEmpty)
                Text('選べる項目がありません。', style: noteStyle(context))
              else if (matches.isEmpty)
                Text('合う項目がありません。', style: noteStyle(context))
              else ...[
                for (final c in matches.take(shown))
                  ListTile(
                    key: Key('blocks-choice-${c.item.key.substring(0, 12)}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    enabled: !full,
                    title: Text(
                      c.item.display,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${c.title}・${c.item.section == 'next' ? '次の一手' : '未解決'}',
                    ),
                    onTap: () => setState(
                      () => selected.add((scope: c.scope, key: c.item.key)),
                    ),
                  ),
                if (matches.length > shown)
                  Text(
                    'ほか${matches.length - shown}件。語を入れて絞り込んでください。',
                    style: noteStyle(context),
                  ),
              ],
              if (full)
                Text('${widget.max}件まで選べます。', style: noteStyle(context)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        if (widget.item.after != null)
          TextButton(
            key: const Key('blocks-clear'),
            onPressed: () => Navigator.pop(context, (after: null)),
            child: const Text('すべて外す'),
          ),
        FilledButton(
          key: const Key('blocks-submit'),
          onPressed: selected.isEmpty || !changed
              ? null
              : () => Navigator.pop(context, (after: [...selected])),
          child: const Text('依頼する'),
        ),
      ],
    );
  }
}
