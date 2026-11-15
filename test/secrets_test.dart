import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/secrets.dart';

void main() {
  test('本体の試験データと同じように検出して伏せる', () {
    final fixture =
        jsonDecode(
              File(
                'vendor/context-hub/packages/core/test/fixtures/secret-cases.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, greaterThan(15));
    for (final c in cases) {
      final text = c['text'] as String;
      expect(redactSecrets(text), c['redacted'], reason: c['name'] as String);
      expect(
        findSecrets(text).map((f) => f.label).toList(),
        List<String>.from(c['labels'] as List),
        reason: c['name'] as String,
      );
      final once = redactSecrets(text);
      expect(redactSecrets(once), once, reason: c['name'] as String);
    }
  });

  test('種類ごとの件数を短く示す', () {
    final findings = findSecrets(
      'password=hunter2pass と token: abcdefgh と sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123',
    );
    expect(describeSecrets(findings), 'パスワード等×2、APIキー');
    expect(findSecrets('普通のメモ'), isEmpty);
  });
}
