import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/ui/app.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

/// 本体の`ctx backup verify`が残す形の確認結果。
MapEntry<String, String> check(
  String suffix, {
  required String archivedAt,
  required String checkedAt,
  bool ok = true,
  int maxAgeDays = 7,
}) {
  final id = 'BKC-01M9${suffix * 22}';
  return MapEntry(
    '90_system/backup-checks/$id.json',
    jsonEncode({
      'schema_version': 1,
      'id': id,
      'archive': 'vault-20261101-033000.tar.gz',
      'archive_created_at': archivedAt,
      'archive_bytes': 1024,
      'checked_at': checkedAt,
      'status': ok ? 'ok' : 'failed',
      'restored': ok
          ? {'files': 10, 'inputs': 3, 'projects': 1, 'receipts': 3}
          : null,
      'live': {'inputs': 3, 'projects': 1},
      'verify_max_age_days': maxAgeDays,
      'issues': ok ? [] : ['アーカイブを最後まで読めません'],
      'notes': [],
    }),
  );
}

void main() {
  test('バックアップの確認結果から、最後に確かめた復元点と注意を本体と同じ決め方で示す', () {
    // 確認結果がなければ何も示さない。
    final none = HubRepository(fixture());
    expect(none.backup.isEmpty, isTrue);
    expect(none.backup.line(DateTime.utc(2026, 11, 4)), isNull);
    expect(none.backup.warnings(DateTime.utc(2026, 11, 4)), isEmpty);
    final ok = check(
      'A',
      archivedAt: '2026-10-31T18:30:00.000Z',
      checkedAt: '2026-11-03T19:30:00.000Z',
    );
    final repo = HubRepository(fixture({...fixtureFiles(), ok.key: ok.value}));
    expect(repo.warnings, isEmpty);
    // 日付は日本時間の暦日、日数は経過した24時間の数で示す。
    expect(
      repo.backup.line(DateTime.utc(2026, 11, 4)),
      '最後に確かめた復元点: 2026-11-01のバックアップ（3日前 / 今日復元できることを確認）',
    );
    expect(repo.backup.warnings(DateTime.utc(2026, 11, 4)), isEmpty);
    expect(
      repo.backup.line(DateTime.utc(2026, 11, 6)),
      contains('（5日前 / 2日前に復元できることを確認）'),
    );
    // 目安（確認したときの設定）より古い復元点は知らせる。
    expect(repo.backup.warnings(DateTime.utc(2026, 11, 7, 18)), isEmpty);
    expect(
      repo.backup.warnings(DateTime.utc(2026, 11, 8, 19)).single,
      contains('確かめた復元点が8日前のバックアップです（目安は7日以内）'),
    );
    // 最後の確認が失敗しても、復元できた復元点は残して示す。
    final failed = check(
      'B',
      archivedAt: '2026-11-02T18:30:00.000Z',
      checkedAt: '2026-11-03T20:00:00.000Z',
      ok: false,
    );
    final both = HubRepository(
      fixture({...fixtureFiles(), ok.key: ok.value, failed.key: failed.value}),
    );
    expect(both.backup.latest!.ok, isFalse);
    expect(both.backup.restorePoint!.ok, isTrue);
    expect(
      both.backup.warnings(DateTime.utc(2026, 11, 4)).single,
      contains('復元できませんでした（1件の問題）'),
    );
    expect(both.backup.line(DateTime.utc(2026, 11, 4)), contains('2026-11-01'));
    // 一度も復元できていなければ、復元点の行は出さない。
    final only = HubRepository(
      fixture({...fixtureFiles(), failed.key: failed.value}),
    );
    expect(only.backup.line(DateTime.utc(2026, 11, 4)), isNull);
    expect(only.backup.warnings(DateTime.utc(2026, 11, 4)), hasLength(1));
    // 壊れた確認記録は使わず、知らせる。
    final broken = HubRepository(
      fixture({
        ...fixtureFiles(),
        ok.key: ok.value.replaceFirst('"status":"ok"', '"status":"unknown"'),
      }),
    );
    expect(broken.backup.isEmpty, isTrue);
    expect(broken.warnings, isNotEmpty);
  });

  testWidgets('ホームに最後に確かめた復元点を示し、復元できなかったときは知らせる', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final now = DateTime.now().toUtc();
    final ok = check(
      'A',
      archivedAt: now.subtract(const Duration(days: 2)).toIso8601String(),
      checkedAt: now.subtract(const Duration(hours: 1)).toIso8601String(),
    );
    final files = {...fixtureFiles(), ok.key: ok.value};
    access.current = VaultSnapshot(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('home-backup'))).data,
      contains('のバックアップ（2日前 / 今日復元できることを確認）'),
    );
    expect(find.byKey(const Key('home-backup-warning-0')), findsNothing);
    final failed = check(
      'B',
      archivedAt: now.subtract(const Duration(days: 1)).toIso8601String(),
      checkedAt: now.toIso8601String(),
      ok: false,
    );
    access.current = VaultSnapshot({...files, failed.key: failed.value});
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-backup-warning-0')), findsOneWidget);
    expect(find.byKey(const Key('home-backup')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
