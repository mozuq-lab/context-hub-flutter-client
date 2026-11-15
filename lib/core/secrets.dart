import 'dart:math' as math;

/// メモに紛れたAPIキー・トークン・パスワード・秘密鍵らしい文字列を見つけて伏せる。
///
/// 本体（packages/core/src/secrets.ts）と同じ規則で、同じ結果になることを
/// 本体の試験データ（test/fixtures/secret-cases.json）で確かめる。
/// アプリでは、保存の前に知らせることと、「選んで深掘り」でClaude APIへ送る内容を伏せることに使う。
class SecretRule {
  const SecretRule(this.id, this.label, this.pattern, {this.group});
  final String id, label;
  final RegExp pattern;

  /// 値だけを伏せる場合の捕捉グループ番号。値は一致の末尾に置く。
  final int? group;
}

class SecretFinding {
  const SecretFinding(this.rule, this.label, this.start, this.end);
  final String rule, label;
  final int start, end;
}

String secretPlaceholder(String label) => '[伏せ字:$label]';
const _placeholderHead = '[伏せ字:';

/// 代入の形で値を伏せる鍵の名前。DB_PASSWORDのように前に語が付いた環境変数名も含める。
const _keys =
    r'(?:(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-])*(?:password|passwd|pwd|passphrase|secret|client[_-]?secret|api[_-]?key|access[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|token|signature|sig)(?![A-Za-z0-9])|パスワード|暗証番号|合言葉)';

final List<SecretRule> secretRules = [
  SecretRule(
    'private-key',
    '秘密鍵',
    RegExp(
      r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|$)',
    ),
  ),
  SecretRule('anthropic', 'APIキー', RegExp(r'\bsk-ant-[A-Za-z0-9_-]{20,}')),
  SecretRule(
    'openai',
    'APIキー',
    RegExp(r'\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}'),
  ),
  SecretRule(
    'github',
    'トークン',
    RegExp(r'\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})'),
  ),
  SecretRule('gitlab', 'トークン', RegExp(r'\bglpat-[A-Za-z0-9_-]{20,}')),
  SecretRule(
    'aws-access-key',
    'アクセスキー',
    RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'),
  ),
  SecretRule('google-api-key', 'APIキー', RegExp(r'\bAIza[0-9A-Za-z_-]{35}')),
  SecretRule('slack', 'トークン', RegExp(r'\bxox[abposr]-[A-Za-z0-9-]{10,}')),
  SecretRule(
    'stripe',
    'APIキー',
    RegExp(r'\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}'),
  ),
  SecretRule(
    'jwt',
    'トークン',
    RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
  ),
  SecretRule(
    'bearer',
    'トークン',
    RegExp(r'\bBearer[ \t]+([A-Za-z0-9._~+/=-]{20,})'),
    group: 1,
  ),
  SecretRule(
    'url-credential',
    'パスワード',
    RegExp(
      r'(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s:/@]+:([^\s@/]+)(?=@)',
    ),
    group: 1,
  ),
  SecretRule(
    'assignment-quoted',
    'パスワード等',
    RegExp(
      '$_keys'
      r'''[ \t]*["']?[ \t]*[:=：][ \t]*["'](?!\[伏せ字)([^"'\r\n]{4,})(?=["'])''',
      caseSensitive: false,
    ),
    group: 1,
  ),
  SecretRule(
    'assignment',
    'パスワード等',
    RegExp(
      '$_keys'
      r'''[ \t]*["']?[ \t]*[:=：][ \t]*["']?(?!\[伏せ字)([^\s"'`,;、。，；）」』]{6,})''',
      caseSensitive: false,
    ),
    group: 1,
  ),
];

final _highEntropy = RegExp(
  r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])',
);
const _minEntropyBits = 4.0;
final _vaultId = RegExp(r'^[A-Z]{2,6}-[A-Za-z0-9]+$');

double _entropy(String value) {
  final counts = <int, int>{};
  for (final c in value.codeUnits) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  var bits = 0.0;
  for (final n in counts.values) {
    final p = n / value.length;
    bits -= p * math.log(p) / math.ln2;
  }
  return bits;
}

/// 重ならない一致を、開始位置の順に返す。
List<SecretFinding> findSecrets(String text) {
  if (text.isEmpty) return const [];
  final all = <(SecretFinding, int)>[];
  var order = 0;
  for (final rule in secretRules) {
    for (final m in rule.pattern.allMatches(text)) {
      final whole = m.group(0)!;
      if (whole.isEmpty) continue;
      var start = m.start;
      final end = m.end;
      if (rule.group != null) {
        final value = m.group(rule.group!);
        if (value == null || value.isEmpty || !whole.endsWith(value)) continue;
        start = end - value.length;
      }
      all.add((SecretFinding(rule.id, rule.label, start, end), order++));
    }
  }
  for (final m in _highEntropy.allMatches(text)) {
    final value = m.group(0)!, start = m.start;
    // URLのパスの一部は伏せない（クエリの値は伏せる）。ContextHubの記録IDも伏せない。
    if (start > 0 && text[start - 1] == '/') continue;
    if (_vaultId.hasMatch(value)) continue;
    if (!value.contains(RegExp('[A-Z]')) ||
        !value.contains(RegExp('[a-z]')) ||
        !value.contains(RegExp('[0-9]'))) {
      continue;
    }
    if (_entropy(value) < _minEntropyBits) continue;
    all.add((
      SecretFinding('high-entropy', '秘密情報らしい文字列', start, m.end),
      order++,
    ));
  }
  // 開始位置が早い順、同じなら長い順、さらに同じなら規則の順（本体の安定ソートと同じ）。
  all.sort((a, b) {
    final x = a.$1, y = b.$1;
    if (x.start != y.start) return x.start - y.start;
    final len = (y.end - y.start) - (x.end - x.start);
    return len != 0 ? len : a.$2 - b.$2;
  });
  final result = <SecretFinding>[];
  var last = -1;
  for (final (f, _) in all) {
    if (f.start < last) {
      // 重なった一致は、先に採った箇所を後ろへ広げて1つの伏せ字にする。
      if (result.isNotEmpty && f.end > result.last.end) {
        final prev = result.removeLast();
        result.add(SecretFinding(prev.rule, prev.label, prev.start, f.end));
        last = f.end;
      }
      continue;
    }
    if (text.startsWith(_placeholderHead, f.start)) continue;
    result.add(f);
    last = f.end;
  }
  return result;
}

/// 種類ごとの件数（例: 「APIキー、パスワード等×2」）。
String describeSecrets(List<SecretFinding> findings) {
  final counts = <String, int>{};
  for (final f in findings) {
    counts[f.label] = (counts[f.label] ?? 0) + 1;
  }
  return counts.entries
      .map((e) => e.value > 1 ? '${e.key}×${e.value}' : e.key)
      .join('、');
}

/// 見つかった箇所を伏せ字に置き換える。
String redactSecrets(String text) {
  final findings = findSecrets(text);
  if (findings.isEmpty) return text;
  final out = StringBuffer();
  var at = 0;
  for (final f in findings) {
    out
      ..write(text.substring(at, f.start))
      ..write(secretPlaceholder(f.label));
    at = f.end;
  }
  out.write(text.substring(at));
  return out.toString();
}
