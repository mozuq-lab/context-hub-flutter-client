import 'dart:io';

import 'package:context_hub_client/app_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('画面に表示する版はpubspec.yamlの版と一致する', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final version = (pubspec['version'] as String).split('+').first;
    expect(appVersion, version);
  });
}
