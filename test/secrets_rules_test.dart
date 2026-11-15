import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/secrets.dart';

/// 本体の試験データ（secret-cases.json）に足された規則の例。本体の変更がmergeされて
/// submoduleを進めると、同じ例は本体の試験データ側（secrets_test.dart）でも確かめられる。
void main() {
  const cases = <(String, String, String, List<String>)>[
    (
      "assignment-spaces",
      "password    =    hunter2pass",
      "password    =    [伏せ字:パスワード等]",
      <String>["パスワード等"],
    ),
    (
      "assignment-comma",
      "password=ab,cdefghij",
      "password=ab,cdefghij",
      <String>[],
    ),
    (
      "assignment-comma-list",
      "password=hunter22, user=bob",
      "password=[伏せ字:パスワード等], user=bob",
      <String>["パスワード等"],
    ),
    (
      "assignment-pass",
      "pass: S3cr3tValue!",
      "pass: [伏せ字:パスワード等]",
      <String>["パスワード等"],
    ),
    (
      "not-a-pass-key",
      "bypass: everything と passport: AB1234",
      "bypass: everything と passport: AB1234",
      <String>[],
    ),
    (
      "ja-particle",
      "パスワードは hunter2hunter2 です",
      "パスワードは [伏せ字:パスワード等] です",
      <String>["パスワード等"],
    ),
    (
      "ja-particle-words",
      "パスワードはGoogleDriveに置いた",
      "パスワードはGoogleDriveに置いた",
      <String>[],
    ),
    (
      "not-pass-sentence",
      "First pass: refactoring the parser",
      "First pass: refactoring the parser",
      <String>[],
    ),
    ("not-pass-status", "CI pass: succeeded", "CI pass: succeeded", <String>[]),
    (
      "not-token-count",
      "input token: 120,000",
      "input token: 120,000",
      <String>[],
    ),
    (
      "assignment-comma-nospace",
      "password=hunter22,user=bob",
      "password=[伏せ字:パスワード等],user=bob",
      <String>["パスワード等"],
    ),
    (
      "assignment-pass-short",
      "pass: hunter22",
      "pass: [伏せ字:パスワード等]",
      <String>["パスワード等"],
    ),
    (
      "assignment-pass-equals",
      "pass=s3cret!x",
      "pass=[伏せ字:パスワード等]",
      <String>["パスワード等"],
    ),
    (
      "ja-particle-fullwidth-space",
      "パスワードは　hunter22",
      "パスワードは　[伏せ字:パスワード等]",
      <String>["パスワード等"],
    ),
    (
      "ja-particle-bracket",
      "パスワードは「hunter22」",
      "パスワードは「[伏せ字:パスワード等]」",
      <String>["パスワード等"],
    ),
  ];
  test('本体と同じく、空白の多い代入・pass・「パスワードは」を伏せ、普通の英文や数の区切りは伏せない', () {
    for (final (name, text, redacted, labels) in cases) {
      expect(redactSecrets(text), redacted, reason: name);
      expect(
        findSecrets(text).map((f) => f.label).toList(),
        labels,
        reason: name,
      );
    }
  });

  test('鍵の名前の後に長い空白が続いても、伏せ字の検出に時間がかからない', () {
    // 後戻りが二乗に増えると5万字で数十秒かかる。混んだ環境でも誤って落ちないよう余裕を持たせる。
    final text = 'password${' ' * 50000}x';
    final watch = Stopwatch()..start();
    findSecrets(text);
    expect(watch.elapsedMilliseconds, lessThan(5000));
  });
}
