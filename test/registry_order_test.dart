import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/parser.dart';

void main() {
  // 登録簿hash（関連の見直しの照合に使う）は、本体がプロジェクトIDをlocaleCompareで、
  // アプリがcompareToで並べてから計算する。IDに使える文字（英小文字・数字・ハイフン）の範囲で
  // 並びが一致することを、本体と同じNodeで確かめる（ロケールが変わっても同じ）。
  test('プロジェクトIDの並びは、本体のlocaleCompareとアプリのcompareToで一致する', () async {
    final ids = [
      'ab',
      'a-b',
      'a1',
      'a-1',
      'ab-',
      'a--b',
      '0a',
      '9-z',
      'z9',
      'context-hub',
      'context-hub-2',
      'contexthub',
      'context1',
      'aa',
      'a0',
      'a9',
      'a-z',
      'bb',
      '10',
      '1-0',
    ];
    expect(ids.every(projectIdPattern.hasMatch), isTrue);
    final dart = [...ids]..sort((a, b) => a.compareTo(b));
    for (final lang in ['C.UTF-8', 'ja_JP.UTF-8', 'en_US.UTF-8']) {
      final result = await Process.run(
        'node',
        [
          '-e',
          'const ids=JSON.parse(process.argv[1]);'
              'process.stdout.write(JSON.stringify([...ids].sort((a,b)=>a.localeCompare(b))));',
          jsonEncode(ids),
        ],
        environment: {'LANG': lang, 'LC_ALL': lang},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(jsonDecode(result.stdout as String), dart, reason: lang);
    }
  });
}
