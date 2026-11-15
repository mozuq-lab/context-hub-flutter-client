import 'dart:convert';
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

/// 代入の形で値を伏せる鍵の名前。英数字に続く位置では始めないため、DB_PASSWORDのように
/// 前に語が付いた環境変数名にも当たり、passwordlessのような語の途中には当たらない。
const _keys =
    r'(?:(?<![A-Za-z0-9])(?:password|passwd|pwd|passphrase|secret|client[_-]?secret|api[_-]?key|access[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|token|signature|sig|pass)(?![A-Za-z0-9])|パスワード|暗証番号|合言葉)';

/// 鍵の名前と区切り（: = ：）の間。空白、引用符1つ、空白の順だけを認める。
/// 「空白*・引用符?・空白*」と書くと引用符がないときに空白の分け方が二乗に増えて後戻りするため、
/// 引用符の後の空白を引用符と組にする（本体のKEY_GAPと同じ）。
const _keyGap = r'''[ \t]*(?:["'][ \t]*)?[:=：]''';

/// 代入の値。読点や句点・括弧で終わる。半角のカンマ・セミコロンは、直後に空白や区切りが続かない
/// 値の途中（ab,cdef）だけ値に含める（本体のVALUE_CHARと同じ）。
const _valueChar = r'''[^\s"'`,;、。，；）」』]''';

/// 日本語の「パスワードは …」。語の続きと区別するため、英数字・記号の6文字以上で、
/// 数字か記号を含む値だけを伏せる（本体のPARTICLE_VALUEと同じ）。
const _particleValue =
    r'(?=[A-Za-z]*[0-9!#$%&*+?@^_~-])[A-Za-z0-9!#$%&*+.?@^_~-]{6,}';

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
      '$_keys$_keyGap'
      r'''[ \t]*["'](?!\[伏せ字)([^"'\r\n]{4,})(?=["'])''',
      caseSensitive: false,
    ),
    group: 1,
  ),
  SecretRule(
    'assignment',
    'パスワード等',
    RegExp(
      '$_keys$_keyGap'
      r'''[ \t]*["']?(?!\[伏せ字)((?:'''
      '$_valueChar|[,;](?=$_valueChar)){6,})',
      caseSensitive: false,
    ),
    group: 1,
  ),
  // パスワードは hunter2… のように、日本語の鍵の後に「は」で値を続ける書き方。
  SecretRule(
    'assignment-particle',
    'パスワード等',
    RegExp('(?:パスワード|暗証番号|合言葉)は[ \\t]*(?!\\[伏せ字)($_particleValue)'),
    group: 1,
  ),
];

/// 本体が設定の追加規則（`privacy.patterns`）を書き出すファイル。形式は本体と共有する取り決めで、
/// `{"schema_version":1,"redact_secrets":<bool>,"patterns":[{"label":"…","pattern":"…"}]}`。
/// patternはJavaScriptの正規表現で、本体は`gu`フラグで評価する。
const privacyPatternsPath = '90_system/privacy/patterns.json';

/// 本体の設定の上限（packages/core/src/config.tsのprivacy.patterns）。
const _maxPatterns = 50, _maxLabel = 40, _maxPattern = 500;

/// 伏せ字に使う規則。組み込み規則に、本体の設定で追加した規則を足す。
///
/// 追加規則のファイルが壊れている・形式の版が未知・Dartで解釈できない規則がある・読取の上限で
/// 確かめられないときは[problem]を持つ。その場合、選んで深掘りやcontextのコピーでVaultの内容を
/// 外へ渡さない（取りこぼしを避けるため）。保存の前に知らせるだけの検査は組み込み規則で続ける。
///
/// 本体は`redact_secrets: false`のとき伏せ字そのものを止めるが、アプリはClaude APIへ送る内容と
/// 別AI向けのコピーを常に伏せる（組み込み規則と同じく、追加規則も設定に関わらず当てる）。
class SecretPolicy {
  const SecretPolicy._(this.extra, this.problem);

  /// 追加規則のファイルがない（本体が古い・設定がない）とき。組み込み規則だけを使う。
  static const builtin = SecretPolicy._([], null);

  /// 規則を確かめる前（Vaultを読み込めていないなど）。
  factory SecretPolicy.unavailable(String reason) =>
      SecretPolicy._(const [], _failed(reason));

  /// 本体の設定で追加した規則。
  final List<SecretRule> extra;

  /// 追加規則を確かめられない理由。
  final String? problem;
  bool get usable => problem == null;

  static String _failed(String reason) =>
      '本体の伏せ字の追加規則（$privacyPatternsPath）を確かめられません（$reason）。'
      '取りこぼしを避けるため、Vaultの内容を外へ送りません。本体の設定と同期を確かめてください。';

  /// ファイルの本文を読む。
  static SecretPolicy parse(String raw) {
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return SecretPolicy._(const [], _failed('JSONとして読めません'));
    }
    if (value is! Map) return SecretPolicy._(const [], _failed('形式が不正です'));
    final version = value['schema_version'];
    if (version is int && version > 1) {
      return SecretPolicy._(
        const [],
        _failed('本体が新しい形式（版$version）で書いています。アプリを更新してください'),
      );
    }
    final patterns = value['patterns'];
    if (version != 1 ||
        value['redact_secrets'] is! bool ||
        patterns is! List ||
        patterns.length > _maxPatterns) {
      return SecretPolicy._(const [], _failed('形式が不正です'));
    }
    final rules = <SecretRule>[];
    for (final (i, item) in patterns.indexed) {
      final label = item is Map ? item['label'] : null;
      final pattern = item is Map ? item['pattern'] : null;
      // 知らない項目（フラグなど）は解釈を変えうるので、読めないものとして扱う。
      if (item is! Map ||
          item.length != 2 ||
          label is! String ||
          label.isEmpty ||
          label.length > _maxLabel ||
          label.contains(RegExp(r'[\]\r\n]')) ||
          pattern is! String ||
          pattern.isEmpty ||
          pattern.length > _maxPattern) {
        return SecretPolicy._(const [], _failed('${i + 1}件目の規則の形式が不正です'));
      }
      final RegExp compiled;
      try {
        // 本体は`gu`で評価する。Dartの正規表現はJavaScriptと同じ構文で、unicodeで`u`に合わせる。
        compiled = RegExp(pattern, unicode: true);
      } on FormatException {
        // 規則の本文は秘密の形のヒントになるので画面に出さず、ラベルと直し方だけを示す。
        return SecretPolicy._(
          const [],
          _failed(
            '${i + 1}件目の規則「$label」をこのアプリで解釈できません。'
            'Nodeでは使える書き方でも、(?i:…) のような一部だけの修飾子や、同じ名前の捕捉グループは'
            'アプリでは使えません。本体の設定（privacy.patterns）でこの規則を書き換えてください',
          ),
        );
      }
      // 利用者の正規表現は、本文ごとに端末の画面のスレッドで当てる。入れ子の繰り返しは
      // 一致しない入力で後戻りが爆発し、アプリが固まるおそれがあるので使わない。
      if (nestedRepeat(pattern)) {
        return SecretPolicy._(
          const [],
          _failed(
            '${i + 1}件目の規則「$label」は、(a+)+ のような入れ子の繰り返しを含み、'
            '端末が固まるおそれがあるため使えません。本体の設定（privacy.patterns）でこの規則を書き換えてください',
          ),
        );
      }
      rules.add(SecretRule('custom-${i + 1}', label, compiled));
    }
    return SecretPolicy._(List.unmodifiable(rules), null);
  }

  /// Vaultのsnapshotから読む。ファイルがなければ組み込み規則だけを使う。
  /// ただし読取の注意（上限・読めないファイル・中断したフォルダー）でファイルが欠けた可能性があれば確かめられない。
  static SecretPolicy fromSnapshot(
    Map<String, String> files,
    List<String> warnings,
  ) {
    final raw = files[privacyPatternsPath];
    if (raw != null) return parse(raw);
    for (final w in warnings) {
      final at = w.indexOf(': ');
      final path = at < 0 ? '' : w.substring(at + 2).trim();
      if (w.contains('90_system/privacy') ||
          w.startsWith('読取の上限') ||
          w.startsWith('深さの上限') ||
          (path.isNotEmpty &&
              (privacyPatternsPath == path ||
                  privacyPatternsPath.startsWith('$path/')))) {
        return SecretPolicy._(const [], _failed('Vaultの読取が途中で止まりました'));
      }
    }
    return builtin;
  }

  List<SecretFinding> find(String text) => findSecrets(text, extra: extra);
  String redact(String text) => redactSecrets(text, extra: extra);
  String redactLines(String text) => redactSecretLines(text, extra: extra);
  String redactHead(String text, int size) =>
      redactSecretsHead(text, size, extra: extra);
}

/// 回数に上限のない繰り返し（+・*・{n,}）を含むグループが、さらに上限のない繰り返しで
/// 囲まれているか（(a+)+、(?:\w+\s?)*、(x{2,})* など）。文字クラスとエスケープの中は数えない。
/// 後戻りが爆発する形の代表で、すべての危険な形を見つけるものではない。
bool nestedRepeat(String pattern) {
  final frames = <bool>[false];
  bool unboundedAt(int i) {
    if (i >= pattern.length) return false;
    final c = pattern[i];
    if (c == '+' || c == '*') return true;
    return c == '{' && RegExp(r'^\{\d+,\}').hasMatch(pattern.substring(i));
  }

  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == r'\') {
      i++;
    } else if (c == '[') {
      for (i++; i < pattern.length && pattern[i] != ']'; i++) {
        if (pattern[i] == r'\') i++;
      }
    } else if (c == '(') {
      frames.add(false);
    } else if (c == ')') {
      if (frames.length < 2) continue;
      final inner = frames.removeLast();
      final repeated = unboundedAt(i + 1);
      if (inner && repeated) return true;
      frames[frames.length - 1] = frames.last || inner || repeated;
    } else if (unboundedAt(i)) {
      frames[frames.length - 1] = true;
    }
  }
  return false;
}

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

/// 検査できなかった文字列に付ける種類名。
const secretUnscannedLabel = '検査できない長い文字列';

/// 重ならない一致を、開始位置の順に返す。
///
/// 空白のない数万文字の並びでは、端末向けビルドの正規表現が後戻りの上限に達して失敗する。
/// その場合は値を出さない側に倒し、全体を1つの検出として返す（本体のJavaScriptでは起きない）。
///
/// [extra]は本体の設定で追加した規則（[SecretPolicy.extra]）。組み込み規則のあとに当てる（本体と同じ順）。
List<SecretFinding> findSecrets(
  String text, {
  List<SecretRule> extra = const [],
}) {
  try {
    return _findSecrets(text, extra);
  } on StackOverflowError {
    return [SecretFinding('unscanned', secretUnscannedLabel, 0, text.length)];
  }
}

List<SecretFinding> _findSecrets(String text, List<SecretRule> extra) {
  if (text.isEmpty) return const [];
  final all = <(SecretFinding, int)>[];
  var order = 0;
  for (final rule in [...secretRules, ...extra]) {
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
String redactSecrets(String text, {List<SecretRule> extra = const []}) {
  final findings = findSecrets(text, extra: extra);
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

/// 組み立てた文書を1行ずつ伏せる。
///
/// 各部分は組み立てる前に伏せておき、これは1行に収まる値の取りこぼしを防ぐために使う。
/// 文書全体を一度に伏せると、終わりのない秘密鍵の見出しがその後ろの内容をすべて消してしまう。
String redactSecretLines(String text, {List<SecretRule> extra = const []}) =>
    text.split('\n').map((l) => redactSecrets(l, extra: extra)).join('\n');

/// 先頭[size]文字だけを使う場面で、切る前に伏せる。
///
/// 切る位置をまたぐ値を伏せ残さないよう、余裕を持たせた範囲を検査してから切る。
/// 全文を検査しないため、長い記録でも時間がかからない。
String redactSecretsHead(
  String text,
  int size, {
  List<SecretRule> extra = const [],
}) {
  const margin = 4096;
  var end = text.length > size + margin ? size + margin : text.length;
  // サロゲートペアの途中で切らない。
  if (end < text.length &&
      end > 0 &&
      text.codeUnitAt(end - 1) >= 0xD800 &&
      text.codeUnitAt(end - 1) <= 0xDBFF) {
    end--;
  }
  return redactSecrets(text.substring(0, end), extra: extra);
}
