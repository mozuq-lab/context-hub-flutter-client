import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../app/controller.dart';

class SafeMarkdown extends StatelessWidget {
  const SafeMarkdown({
    super.key,
    required this.text,
    required this.sourcePath,
    required this.controller,
    required this.onRecord,
  });
  final String text, sourcePath;
  final HubController controller;
  final void Function(String) onRecord;
  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    selectable: true,
    imageBuilder: (uri, title, alt) => Text(
      '［画像は表示しません${alt == null ? '' : ': $alt'}］',
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    onTapLink: (label, href, title) async {
      if (href == null) {
        return;
      }
      final id = controller.resolveLink(sourcePath, href);
      if (id != null) {
        onRecord(id);
        return;
      }
      final uri = Uri.tryParse(href);
      if (uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty) {
        try {
          await controller.access.openExternal(href);
        } catch (_) {
          if (context.mounted) {
            _message(context, 'リンクを開けませんでした。');
          }
        }
      } else {
        if (context.mounted) {
          _message(context, 'このリンクは未取得、または対応していない形式です。');
        }
      }
    },
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(fontSize: 15, height: 1.8),
      h1: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
      h2: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
    ),
  );
  void _message(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
