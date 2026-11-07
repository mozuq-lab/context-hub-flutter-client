import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/ui/app.dart';
import 'controller_test.dart' show UIAccess;
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/policies.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/vault_access.dart';

/// 固定参照の本体で、端末からのメモを[count]件受け付けて整理したVaultを作る。
Future<Map<String, dynamic>> growthVault(int count) async {
  final dir = await Directory.systemTemp.createTemp('ctx-growth-test-');
  try {
    final out = File('${dir.path}/vault.json');
    final result = await Process.run('node', [
      'scripts/generate_growth_vault.mjs',
      '$count',
      out.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return jsonDecode(await out.readAsString()) as Map<String, dynamic>;
  } finally {
    await dir.delete(recursive: true);
  }
}

bool skipped(String path) =>
    snapshotSkippedPaths.any((p) => path == p || path.startsWith('$p/'));

/// 読取結果の比較に使う、画面に出る内容の要約。
Map<String, Object?> summary(HubRepository repo) => {
  'warnings': repo.warnings,
  'records': {
    for (final r in repo.records.values)
      r.id: [r.status, r.kind, r.warnings, r.references],
  },
  'intake': [for (final i in repo.intake) '${i.id}:${i.state}:${i.detail}'],
  'projects': {
    for (final p in repo.projects.values)
      p.id: [
        p.lifecycle,
        p.warnings,
        for (final s in p.sections.entries)
          '${s.key}:${s.value.map((e) => e.raw).join('|')}',
        p.nowItems.map((i) => '${i.key}:${i.resolved}').toList(),
      ],
  },
  'review': repo.review.pending.map((c) => c.id).toList(),
  'policy': PolicyReader(repo.snapshot).read('garden').text,
};

void main() {
  controllerTests();
  late Map<String, dynamic> vault;
  setUpAll(() async => vault = await growthVault(40));

  test('アプリが読まない記録を除いても、画面に出る内容は変わらない', () {
    final files = Map<String, String>.from(vault['files'] as Map);
    final at = DateTime.utc(2026, 11, 7);
    final full = HubRepository(VaultSnapshot(files, loadedAt: at));
    final filtered = HubRepository(
      VaultSnapshot({
        for (final e in files.entries)
          if (!skipped(e.key)) e.key: e.value,
      }, loadedAt: at),
    );
    expect(files.keys.where(skipped), isNotEmpty);
    expect(full.records, isNotEmpty);
    expect(full.intake.length, 40);
    expect(full.intake.every((i) => i.state == 'organized'), isTrue);
    expect(summary(filtered), summary(full));
    expect(filtered.context('garden'), full.context('garden'));
  });

  test('読み除く記録の分だけ、メモ1件あたりの読取件数が減る', () {
    final entries = List<String>.from(vault['entries'] as List);
    final count = vault['count'] as int;
    final perMemoBefore = entries.length / count;
    // ネイティブは除外したパスを数えず、.md/.jsonのファイルだけを件数の上限に数える。
    final read = entries
        .where((p) => !skipped(p.replaceFirst(RegExp(r'/$'), '')))
        .where((p) => !p.endsWith('/') && RegExp(r'\.(md|json)$').hasMatch(p))
        .length;
    final perMemoAfter = read / count;
    expect(perMemoBefore, greaterThan(7));
    expect(perMemoAfter, lessThanOrEqualTo(4.5));
    // 以前の上限（フォルダーを含む5000件）と、今の上限（読むファイル20000件）で読み切れるメモの件数。
    expect(5000 / perMemoBefore, lessThan(700));
    expect(20000 / perMemoAfter, greaterThan(4000));
  });

  test('変わっていないファイルは前回の本文を引き継ぎ、全体を読んだときと同じになる', () {
    final files = Map<String, String>.from(vault['files'] as Map);
    final changed = files.keys.firstWhere((p) => p.startsWith('00_inbox/'));
    final merged = mergeSnapshot(
      files: {changed: files[changed]!},
      unchanged: [
        for (final p in files.keys)
          if (p != changed) p,
      ],
      stamps: {for (final p in files.keys) p: '1:1'},
      warnings: const [],
      recognized: true,
      previous: files,
    );
    expect(merged.fingerprint, VaultSnapshot(files).fingerprint);
    expect(merged.reused, files.length - 1);
    expect(merged.stamps.length, files.length);
  });

  test('引き継ぐ本文がない場合は読み直しが必要として扱う', () {
    expect(
      () => mergeSnapshot(
        files: const {},
        unchanged: const ['00_inbox/x.md'],
        stamps: const {},
        warnings: const [],
        recognized: true,
        previous: const {},
      ),
      throwsFormatException,
    );
  });

  test('読取の上限に達した注意を区別する', () {
    expect(
      VaultSnapshot(
        const {},
        warnings: const [
          '読取の上限（ファイル20000件・合計64MB）に達したため、90_systemの一部を読めませんでした。',
        ],
      ).limitReached,
      isTrue,
    );
    expect(
      VaultSnapshot(const {}, warnings: const ['読取できないファイル: x']).limitReached,
      isFalse,
    );
  });
}

class RefreshAccess extends UIAccess {
  final previous = <VaultSnapshot>[];
  @override
  Future<VaultSnapshot> refreshSnapshot(
    VaultLocation location,
    VaultSnapshot previous,
  ) async {
    this.previous.add(previous);
    return readSnapshot(location);
  }
}

void controllerTests() {
  test('再読込は前回の読取結果を渡して差分だけを読む', () async {
    final access = RefreshAccess();
    await access.init();
    final c = HubController(access, sampleLoader: () async => fixture().files);
    try {
      await c.activate(const VaultLocation('a', '架空'));
      expect(access.previous, isEmpty);
      final first = c.repository!.snapshot;
      await c.reload();
      expect(access.previous.single, same(first));
    } finally {
      c.dispose();
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('読取の上限に達したら、表示が不完全になることを示す', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final access = MemoryUIAccess();
    access.current = VaultSnapshot(
      fixture().files,
      warnings: const ['読取の上限（ファイル20000件・合計64MB）に達したため、90_systemの一部を読めませんでした。'],
    );
    final c = HubController(access, sampleLoader: () async => fixture().files);
    addTearDown(c.dispose);
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await c.activate(const VaultLocation('a', '架空'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('snapshot-limit')), findsOneWidget);
  });
}
