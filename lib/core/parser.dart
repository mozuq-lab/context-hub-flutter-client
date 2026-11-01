import 'dart:convert';
import 'package:yaml/yaml.dart';
import 'models.dart';

class MarkdownDocument {
  final Map<String, dynamic> meta;
  final String body;
  MarkdownDocument(this.meta, this.body);
}

MarkdownDocument parseMarkdown(String raw) {
  final match = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n').firstMatch(raw);
  if (match == null) throw const FormatException('frontmatterがありません。');
  final header = match[1]!;
  if (RegExp(r'(^|[\s:\[,])[*&][a-zA-Z_]', multiLine: true).hasMatch(header)) {
    throw const FormatException('YAMLのaliasは扱えません。');
  }
  try {
    var count = 0;
    dynamic plain(dynamic value, int depth) {
      if (++count > 10000 || depth > 30) {
        throw const FormatException('frontmatterが複雑すぎます。');
      }
      if (value is Map) {
        return value.map((key, v) {
          if (key is! String) throw const FormatException('メタデータのキーは文字列が必要です。');
          return MapEntry(key, plain(v, depth + 1));
        });
      }
      if (value is List) return value.map((v) => plain(v, depth + 1)).toList();
      return value;
    }

    final value = plain(loadYaml(header), 0);
    if (value is! Map) throw const FormatException('frontmatterが不正です。');
    return MarkdownDocument(
      Map<String, dynamic>.from(value),
      raw.substring(match.end),
    );
  } catch (_) {
    throw const FormatException('frontmatterを確認できません。');
  }
}

String encodePacket(Map<String, dynamic> meta, String body) =>
    '---\n${jsonEncode(meta)}\n---\n$body';
final inputIdPattern = RegExp(r'^IN-[0-9A-HJKMNP-TV-Z]{26}$');
final projectIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,40}$');
final requestIdPattern = RegExp(r'^REQ-[A-Za-z0-9]{32}$');
bool validPath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains('\\') &&
    !path.split('/').any((p) => p.isEmpty || p == '.' || p == '..');
DateTime? timestamp(dynamic value) =>
    value is String && RegExp(r'T.*(?:Z|[+-]\d\d:\d\d)$').hasMatch(value)
    ? DateTime.tryParse(value)
    : null;
String clip(String text, int size) {
  if (text.length <= size) return text;
  var end = size;
  if (end > 0 &&
      text.codeUnitAt(end - 1) >= 0xD800 &&
      text.codeUnitAt(end - 1) <= 0xDBFF) {
    end--;
  }
  return text.substring(0, end);
}

String readableTitle(String body) {
  final lines = body
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final generic = RegExp(r'^#{1,6}\s*(現在地|次の一手|未解決|提案|アイデア|知識)([（(].*|\s*)$');
  final line =
      lines
          .where((s) => !generic.hasMatch(s) && !s.startsWith('<!--'))
          .firstOrNull ??
      lines.firstOrNull ??
      '本文のない記録';
  return clip(
    line
        .replaceFirst(RegExp(r'^#+\s*|^[-*]\s+'), '')
        .replaceFirst(RegExp(r'^\[(確認済み|未確認|提案|未解決)\]\s*'), '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!),
    100,
  );
}

({String before, String auto, String after})? autoRegion(String text) {
  const start = '<!-- ctx:auto:start -->', end = '<!-- ctx:auto:end -->';
  final a = text.indexOf(start), b = text.indexOf(end);
  if (a < 0 ||
      b <= a ||
      text.indexOf(start, a + start.length) >= 0 ||
      text.indexOf(end, b + end.length) >= 0) {
    return null;
  }
  return (
    before: text.substring(0, a),
    auto: text.substring(a + start.length, b),
    after: text.substring(b + end.length),
  );
}

bool generatedIntact(String raw, Map<String, dynamic> meta) {
  final expected = meta['generated_hash'];
  if (expected is! String ||
      !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(expected)) {
    return false;
  }
  // 上流の通常のYAML出力と同じ表現を照合する。異なる表現は保守的に未確認とする。
  final without = raw.replaceFirst(
    RegExp(r'^generated_hash: sha256:[a-f0-9]{64}\r?\n', multiLine: true),
    '',
  );
  return without != raw && expected == 'sha256:${digest(without)}';
}
