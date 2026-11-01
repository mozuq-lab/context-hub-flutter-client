import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 読取テストが使うfixtureは本体の生成物をコミットしたもの。submodule更新時に古い形式のまま残らないよう、
  // 固定参照の本体で再生成した出力とキー構造・記録の種類を比較する。
  test('読取fixtureの形式が固定参照の本体の出力と一致する', () async {
    final result = await Process.run('node', [
      'scripts/check_fixture_drift.mjs',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
