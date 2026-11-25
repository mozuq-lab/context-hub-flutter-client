import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../parts.dart';

/// NOWの項目を「誤り」として外す理由と一言を選ぶ。完了・解決とは別の報告にする。
class ExcludeDialog extends StatefulWidget {
  const ExcludeDialog({super.key, required this.item, required this.owned});
  final NowItemRef item;

  /// 元のメモが、本人がこのプロジェクトを指定して保存したものか。
  final bool owned;
  @override
  State<ExcludeDialog> createState() => _ExcludeDialogState();
}

class _ExcludeDialogState extends State<ExcludeDialog> {
  String? reason;
  final note = TextEditingController();

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  String effect(String reason) => switch (reason) {
    'outdated' when widget.item.action => 'もうやらない。項目を外すだけです。完了には数えません。',
    'misread' => 'メモはそう言っていない。Mac miniが次のAI読み取りで、このメモを読み直します。',
    'wrong-project' =>
      widget.owned
          ? 'このプロジェクトの話ではない。プロジェクトを指定して保存したメモなので、関連付けは変えず、この項目だけを外します。'
          : 'このプロジェクトの話ではない。AIが推定した関連付けなので、このメモをこのプロジェクトから外し、読み直して関連先を見直します。このメモから出たほかの項目も、このプロジェクトから外れます。',
    _ => '読みは合っているが、今は当てはまらない。項目を外すだけで、読み直しません。',
  };

  @override
  Widget build(BuildContext context) {
    final text = note.text.trim(),
        valid = text.isEmpty || validExclusionNote(text);
    return HubAlertDialog(
      key: const Key('exclude-dialog'),
      title: const Text('誤りとして外す'),
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
              const SizedBox(height: 12),
              // 本人が追加した行動はAIの読み取りではないため、「もう古い」だけを選べる（本体も同じ）。
              for (final r
                  in widget.item.action ? const ['outdated'] : exclusionReasons)
                ListTile(
                  key: Key('exclude-reason-$r'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    reason == r
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(exclusionReasonLabels[r]!),
                  subtitle: Text(effect(r), style: noteStyle(context)),
                  onTap: () => setState(() => reason = r),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('exclude-note'),
                controller: note,
                maxLines: 1,
                decoration: InputDecoration(
                  labelText: '一言（任意）',
                  helperText: '例: 検討しただけで、まだ決めていない',
                  // 本体の検査と同じ数え方（UTF-16の単位。絵文字などは2文字と数える）で示す。
                  counterText: '${text.length} / $exclusionNoteChars',
                  errorText: valid
                      ? null
                      : '1行・$exclusionNoteChars文字以内で入力してください。',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Text(
                '完了・解決には数えません。原文は変わりません。外した項目の本文・理由・一言は、同じ読み違いを減らすために、次からのAI読み取りでAIへ渡します。Mac miniが処理すると現状に反映され、プロジェクトの画面から未解決に戻せます。',
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
          key: const Key('exclude-submit'),
          onPressed: reason == null || !valid
              ? null
              : () => Navigator.pop(context, (
                  reason: reason!,
                  note: text.isEmpty ? null : text,
                )),
          child: const Text('誤りとして外す'),
        ),
      ],
    );
  }
}
