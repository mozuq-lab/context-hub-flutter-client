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
      "password=[伏せ字:パスワード等]",
      <String>["パスワード等"],
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
  ];
  test('本体と同じく、空白の多い代入・値の途中のカンマ・pass・「パスワードは」を伏せる', () {
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
    final text = 'password${' ' * 50000}x';
    final watch = Stopwatch()..start();
    findSecrets(text);
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });
}
