import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../app/controller.dart';
import 'mermaid_block.dart';
import 'notice.dart';

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
    // 「```mermaid」のコードブロックは図にする。
    blockSyntaxes: const [MermaidBlockSyntax()],
    builders: {mermaidTag: MermaidElementBuilder()},
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
    styleSheet: _styleSheet(Theme.of(context)),
  );

  /// 本文の文字の大きさと見出しの段差。見出しは画面の見出しより小さくし、本文の中で目立ちすぎないようにする。
  static MarkdownStyleSheet _styleSheet(ThemeData theme) {
    final scheme = theme.colorScheme;
    const body = TextStyle(fontSize: 15, height: 1.8);
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      listBullet: body,
      h1: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, height: 1.5),
      h2: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.5),
      h3: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.5),
      h4: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.5),
      h1Padding: const EdgeInsets.only(top: 8, bottom: 4),
      h2Padding: const EdgeInsets.only(top: 12, bottom: 2),
      h3Padding: const EdgeInsets.only(top: 8),
      blockSpacing: 10,
      code: TextStyle(
        fontSize: 13.5,
        color: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerHigh,
      ),
      codeblockDecoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      a: TextStyle(color: scheme.primary, fontWeight: FontWeight.w500),
    );
  }
  void _message(BuildContext context, String text) => notice(context, text);
}
