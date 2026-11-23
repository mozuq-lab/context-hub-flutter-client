import 'package:flutter/material.dart';

/// 画面の共通の部品。どの画面も同じ見出し・余白・面の作法で並べるために使う。

/// 本文の一覧の余白。狭い画面では、右下の「メモを追加」に最後の行が隠れないよう下を空ける。
EdgeInsets pagePadding(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width < 600
      ? const EdgeInsets.fromLTRB(16, 20, 16, 96)
      : width < 820
      ? const EdgeInsets.fromLTRB(28, 28, 28, 96)
      : const EdgeInsets.fromLTRB(40, 32, 40, 48);
}

/// 本文の一覧の最大幅。広い画面でも行が長くなりすぎないようにする。
const pageMaxWidth = 1000.0;

/// 画面の見出し。[label]は状態など見出しの上に添える短い語、[subtitle]は1〜2行の説明（どちらも任意）。
Widget pageTitle(
  BuildContext context,
  String text, {
  String? subtitle,
  String? label,
  List<Widget> trailing = const [],
}) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(text, style: theme.textTheme.headlineSmall),
            ),
            ...trailing,
          ],
        ),
        if (subtitle != null && subtitle.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.65,
            ),
          ),
        ],
      ],
    ),
  );
}

/// 欄の見出し。[note]は見出しの下に添える短い説明、[trailing]は見出しの右に置く小さな操作。
Widget sectionTitle(
  BuildContext context,
  String text, {
  Key? key,
  String? note,
  Color? color,
  double top = 28,
  List<Widget> trailing = const [],
}) {
  final theme = Theme.of(context);
  return Padding(
    padding: EdgeInsets.only(top: top, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                text,
                key: key,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
            ...trailing,
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(note, style: theme.textTheme.bodySmall),
          ),
      ],
    ),
  );
}

/// 行を1枚の面にまとめる。行の間には細い線を引く。
Widget groupCard(List<Widget> rows, {Key? key}) => Card(
  key: key,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, row) in rows.indexed) ...[
        if (i > 0) const Divider(indent: 16, endIndent: 16),
        row,
      ],
    ],
  ),
);

/// 項目（次の一手・未解決など）の行を1枚の面にまとめる。行の間に細い線を引き、行そのものの余白は各行が持つ。
Widget entryCard(List<Widget> rows, {Key? key}) => Card(
  key: key,
  child: Padding(
    padding: const EdgeInsets.fromLTRB(18, 2, 10, 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) const Divider(endIndent: 8),
          row,
        ],
      ],
    ),
  ),
);

/// 項目に添える小さな注記（AI自己報告・未検証など）。[problem]は確かめが要る問題で、赤で示す。
Widget entryNote(BuildContext context, String text, {bool problem = false}) {
  final scheme = Theme.of(context).colorScheme;
  final color = problem ? scheme.error : scheme.onSurfaceVariant;
  return Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          problem ? Icons.error_outline : Icons.info_outline,
          size: 13,
          color: color,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    ),
  );
}

/// 注記のうち、確かめが要る問題ではなく、性質を示すだけのもの（控えめに出す）。
const softEntryNotes = {'AI自己報告・未検証', 'プロジェクトとの関連は候補です'};

/// 行の小さな状態（「反映待ち」など）。
Widget statusText(BuildContext context, String text, {Key? key}) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
  child: Text(
    text,
    key: key,
    style: Theme.of(context).textTheme.bodySmall,
  ),
);

/// 見出しの下や記録の下に置く枠付きボタンの、一回り小さい形。
ButtonStyle compactOutlinedStyle(BuildContext context) => OutlinedButton.styleFrom(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  minimumSize: const Size(0, 38),
  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
  ),
);

/// 出典・根拠のメモへの小さなリンク。本文の下に、本文より控えめに並べる。
Widget sourceLink(
  BuildContext context, {
  Key? key,
  IconData icon = Icons.article_outlined,
  required String label,
  required VoidCallback? onPressed,
}) {
  final theme = Theme.of(context);
  return TextButton.icon(
    key: key,
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      minimumSize: const Size(0, 32),
      textStyle: theme.textTheme.bodySmall,
      foregroundColor: theme.colorScheme.onSurfaceVariant,
      iconColor: theme.colorScheme.onSurfaceVariant,
    ),
    onPressed: onPressed,
    icon: Icon(icon, size: 14),
    label: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}

/// 項目の行に並べる操作（完了・今日やる・却下など）。文字を本文の色にし、印だけを藍にして、行が続いても目立ちすぎないようにする。
Widget rowActions(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  final base = TextButtonTheme.of(context).style ?? const ButtonStyle();
  return TextButtonTheme(
    data: TextButtonThemeData(
      style: base.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? theme.colorScheme.onSurface.withValues(alpha: .38)
              : theme.colorScheme.onSurface,
        ),
      ),
    ),
    child: child,
  );
}
