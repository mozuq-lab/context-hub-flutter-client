import 'dart:async';

import 'package:flutter/material.dart';

import '../core/secrets.dart';
import 'parts.dart';
import 'theme.dart';

/// 秘密情報らしい文字列があれば、保存の前に知らせる。
/// 保存する本文（伏せ字にしたもの、またはそのまま）を返す。戻って直すならnull。
///
/// [secrets]はVaultの伏せ字の規則で、本体の設定で追加した規則も同じく知らせる。
/// 追加規則を確かめられないときも保存は止めず、組み込み規則で知らせる（知らせるだけの補助のため）。
Future<String?> checkSecretsBeforeSave(
  BuildContext context,
  String text, {
  SecretPolicy? secrets,
}) async {
  final rules = secrets == null || !secrets.usable
      ? SecretPolicy.builtin
      : secrets;
  final findings = rules.find(text);
  if (findings.isEmpty) return text;
  final choice = await showDialog<String>(
    context: context,
    builder: (dialog) => HubAlertDialog(
      key: const Key('secret-warning'),
      title: const Text('秘密情報らしい文字列があります'),
      onClose: () => Navigator.pop(dialog),
      content: SizedBox(
        width: 480,
        child: Text(
          '${describeSecrets(findings)}に見える文字列があります。\n\n'
          '保存したメモは、同期先のすべての端末とバックアップに残り、後から消せません（訂正しても元のメモは残ります）。'
          '読み取り用のAIへは伏せ字にして渡しますが、本当に秘密の値なら「伏せ字にして保存」を選んでください。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('戻って直す'),
        ),
        TextButton(
          key: const Key('secret-keep'),
          onPressed: () => Navigator.pop(dialog, 'keep'),
          child: const Text('そのまま保存'),
        ),
        FilledButton(
          key: const Key('secret-redact'),
          onPressed: () => Navigator.pop(dialog, 'redact'),
          child: const Text('伏せ字にして保存'),
        ),
      ],
    ),
  );
  return switch (choice) {
    'redact' => rules.redact(text),
    'keep' => text,
    _ => null,
  };
}

class NoticeBox extends StatelessWidget {
  const NoticeBox(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tone = error ? scheme.error : scheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 16, 11),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: dark ? .14 : .07),
        borderRadius: BorderRadius.circular(hubRadiusSmall),
        border: Border.all(color: tone.withValues(alpha: dark ? .3 : .18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              error ? Icons.error_outline : Icons.info_outline,
              size: 17,
              color: tone,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.55,
                color: error ? scheme.error : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
