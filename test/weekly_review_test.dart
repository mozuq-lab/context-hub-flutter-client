import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';

import 'capture_test.dart' show TempAccess, location;
import 'fixtures.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;

const weeklyPath = '90_system/weekly-review.json';
const recordId = 'WRV-01M2DSFVQMH65989604KSVE1PV';

/// 本体が書く形で、見直した記録と、それを載せた点検の一覧を足す。
Map<String, String> withWeeklyReview(
  Map<String, String> files,
  String on, {
  String id = recordId,
}) {
  final list = jsonDecode(files[weeklyPath]!) as Map<String, dynamic>;
  final now = DateTime.now().toUtc();
  list['generated_at'] = now.toIso8601String();
  list['last_review'] = {
    'id': id,
    'on': on,
    'created_at': now.toIso8601String(),
  };
  return {
    ...files,
    weeklyPath: jsonEncode(list),
    '90_system/weekly-reviews/$id.json': jsonEncode({
      'schema_version': 1,
      'id': id,
      'on': on,
      'source': 'cli',
      'created_at': now.toIso8601String(),
    }),
  };
}

/// 対応表から週次レビューの依頼を外し、一覧も消す（対応前の本体）。
Map<String, String> withoutWeeklyReview(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (o != 'weekly-review') o,
  ];
  return {
    for (final e in files.entries)
      if (e.key != weeklyPath) e.key: e.value,
    intakeFeaturesPath: jsonEncode(features),
  };
}

void main() {
  test('本体の点検の一覧を読み、最後の見直しからの日数と促すかどうかを決める', () {
    final files = fixtureFiles();
    final repo = HubRepository(fixture(files));
    expect(repo.warnings, isEmpty);
    expect(repo.intakeFeatures.weeklyReview, isTrue);
    final review = repo.weeklyReview!;
    expect(review.intervalDays, 7);
    expect(review.lastReviewOn, isNull);
    expect(review.daysSinceReview('2026-11-22'), isNull);
    expect(review.due('2026-11-22'), isTrue);
    expect(review.projects.single.id, projectId);
    expect(review.projects.single.stale, isTrue);
    expect(review.lingering, hasLength(3));
    expect(review.lingeringTotal, 3);
    expect(review.lingering.first.section, 'next');

    final reviewed = HubRepository(fixture(withWeeklyReview(files, '2026-11-15'))).weeklyReview!;
    expect(reviewed.lastReviewId, recordId);
    expect(reviewed.daysSinceReview('2026-11-21'), 6);
    expect(reviewed.due('2026-11-21'), isFalse);
    expect(reviewed.daysSinceReview('2026-11-22'), 7);
    expect(reviewed.due('2026-11-22'), isTrue);

    // 壊れた一覧は読まずに問題として示し、新しい形式は更新を促す。
    final broken = HubRepository(fixture({...files, weeklyPath: '{"schema_version":1}'}));
    expect(broken.weeklyReview, isNull);
    expect(broken.warnings.join(), contains(weeklyPath));
    final newer = jsonDecode(files[weeklyPath]!) as Map<String, dynamic>
      ..['schema_version'] = 2;
    final future = HubRepository(fixture({...files, weeklyPath: jsonEncode(newer)}));
    expect(future.weeklyReview, isNull);
    expect(future.warnings.join(), contains('新しい形式'));

    // 対応前の本体では一覧も依頼もない。
    final old = HubRepository(fixture(withoutWeeklyReview(files)));
    expect(old.weeklyReview, isNull);
    expect(old.intakeFeatures.weeklyReview, isFalse);
  });

  test('Dartの「見直した」の依頼を本体が受理し、点検の一覧の最後の見直しに反映される', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location), today = hubToday();
      await expectLater(
        service.saveWeeklyReview('c1111111-2222-4333-8444-555555555555', '2026-13-01'),
        throwsFormatException,
      );
      final saved = await service.saveWeeklyReview('c1111111-2222-4333-8444-555555555555', today);
      final raw = (await access.readRequest(location, saved.requestId))!;
      final request = parseMarkdown(raw);
      expect(request.meta, allOf(containsPair('operation', 'weekly-review'), containsPair('on', today), containsPair('confirmed', true)));
      expect(request.body.trim(), isEmpty);

      final files = await protocol(access, saved.requestId, 'assets/sample.json', 'weekly');
      final repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.weeklyReview!.lastReviewOn, today);
      expect(repo.weeklyReview!.daysSinceReview(today), 0);
      expect(repo.weeklyReviewRequestId, isNull);
      final item = repo.intake.singleWhere((i) => i.id == saved.requestId);
      expect(item.title, '週次レビューを見直した（$today）');
      expect(item.detail, '週次レビューの見直しをMac miniが記録しました。');

      // 受理の後、一覧がまだ同期されていなければ反映待ちとして扱い、重ねて送らない。
      final stale = HubRepository(VaultSnapshot({...files, weeklyPath: fixtureFiles()[weeklyPath]!}));
      expect(stale.weeklyReviewRequestId, saved.requestId);
      expect(stale.intake.singleWhere((i) => i.id == saved.requestId).detail, 'Mac miniが受け取り済み。現状の同期を待っています。');
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('ふりかえりから週次レビューを順に進め、最後の段で見直したと報告する。途中の段は端末に残る', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();

    // ホーム: 記録がないので促す。
    expect(find.text('週次レビュー: まだ見直した記録がありません'), findsOneWidget);
    expect(find.textContaining('7日以上空いています'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-digest')).last);
    await tester.pumpAndSettle();
    expect(find.text('週次レビューを始める'), findsOneWidget);
    await tester.tap(find.byKey(const Key('digest-weekly')));
    await tester.pumpAndSettle();

    // 1段目は確認待ち。次へで進み、今いる段は端末に残る。
    expect(find.byKey(const Key('weekly-step-title')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('weekly-step-title'))).data, '確認待ち');
    await tester.tap(find.byKey(const Key('weekly-next')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('weekly-step-title'))).data, 'プロジェクト未定');
    await tester.tap(find.byKey(const Key('weekly-step-projects')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('weekly-step-title'))).data, '進行中のプロジェクト');
    expect(c.weeklyProgress?.step, 'projects');
    expect(c.weeklyProgress?.started, hubToday());
    expect(access.states['settings.json'], contains('weeklyReview'));
    // 長く残っている項目は、その場で判断できるよう行として並ぶ。
    expect(find.byKey(const Key('weekly-lingering')), findsOneWidget);
    await tester.tap(find.byKey(const Key('weekly-step-stale')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('weekly-project-$projectId')), findsOneWidget);
    expect(find.byKey(const Key('weekly-status-$projectId')), findsOneWidget);

    // 戻ってきても続きから再開できる。
    await tester.tap(find.byKey(const Key('nav-home')).last);
    await tester.pumpAndSettle();
    expect(find.text('続きから再開できます'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-digest')).last);
    await tester.pumpAndSettle();
    expect(find.text('週次レビューを続きから再開（停滞）'), findsOneWidget);
    // ホームの行からは、直接いまの段を開く。
    await tester.tap(find.byKey(const Key('nav-home')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-weekly')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('weekly-step-title'))).data, '停滞');

    // 最後の段で見直したと報告する。依頼は本人の操作だけで作る。
    await tester.tap(find.byKey(const Key('weekly-step-finish')));
    await tester.pumpAndSettle();
    expect(find.textContaining('残っているもの: '), findsOneWidget);
    expect(access.requests, isEmpty);
    await tester.tap(find.byKey(const Key('weekly-done')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'weekly-review');
    expect(request['on'], hubToday());
    // 報告の後も最後の段に残り、反映待ちを見せる。
    expect(c.weeklyProgress?.step, 'finish');
    expect(tester.widget<Text>(find.byKey(const Key('weekly-step-title'))).data, '見直した');

    // 同期されて反映待ちの間は重ねて送らない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-home')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-weekly')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('weekly-step-finish')));
    await tester.pumpAndSettle();
    expect(find.text('見直したことを報告済み（反映待ち）'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('weekly-done'))).onPressed, isNull);
    await expectLater(c.requestWeeklyReview(), throwsStateError);

    // 反映後はホームに今日見直したと出て、促さない。
    access.current = fixture(withWeeklyReview(files, hubToday()));
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-home')).last);
    await tester.pumpAndSettle();
    expect(find.text('週次レビュー: 今日見直しました'), findsOneWidget);
    expect(find.textContaining('7日以上空いています'), findsNothing);
    // 反映されると最後の見直しが変わり、途中の進み具合は使わない。
    expect(c.weeklyProgress, isNull);
    await expectLater(c.requestWeeklyReview(), throwsStateError);
  });

  testWidgets('別の端末で見直しを報告したら、この端末の途中の進み具合は使わない', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    await c.setWeeklyStep('waiting');
    expect(c.weeklyProgress?.step, 'waiting');

    // アプリを開き直しても続きから再開できる。
    final reopened = HubController(access, sampleLoader: () async => files);
    addTearDown(reopened.dispose);
    await reopened.useSample();
    expect(reopened.weeklyProgress?.step, 'waiting');

    // 始めてから7日以上たった進み具合は使わない。
    final settings = jsonDecode(access.states['settings.json']!) as Map<String, dynamic>;
    final stored = settings['weeklyReview'] as Map<String, dynamic>;
    final identity = stored.keys.single;
    stored[identity] = {
      ...stored[identity] as Map<String, dynamic>,
      'started': hubToday(DateTime.now().subtract(const Duration(days: 7))),
    };
    access.states['settings.json'] = jsonEncode(settings);
    final again = HubController(access, sampleLoader: () async => files);
    addTearDown(again.dispose);
    await again.useSample();
    expect(again.weeklyProgress, isNull);

    access.current = fixture(withWeeklyReview(files, hubToday(DateTime.now().subtract(const Duration(days: 1)))));
    await c.reload();
    await tester.pumpAndSettle();
    expect(c.weeklyProgress, isNull);
    expect(find.text('週次レビュー: 前回から1日'), findsOneWidget);
  });

  testWidgets('対応前の本体では、ふりかえりに週次レビューの入口を出さない', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = withoutWeeklyReview(fixtureFiles());
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-weekly')), findsNothing);
    await tester.tap(find.byKey(const Key('nav-digest')).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('digest-weekly')), findsNothing);
    await expectLater(c.requestWeeklyReview(), throwsStateError);
  });
}
