import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/today.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';

import 'capture_test.dart' show TempAccess, location;
import 'fixtures.dart';
import 'unassigned_actions_test.dart' show fixturePath;
import 'unassigned_records_test.dart' show writeFixture;
import 'waiting_test.dart' show withWaiting;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'recurring_ask_preferences_test.dart' show openMore;

const ideaId = 'IDEA-01M2DSFVQMH65989604KSVE1PV';

/// 対応表から「いつかやる」の依頼を外す（対応前の本体）。
Map<String, String> withoutSomeday(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (o != 'item-someday' && o != 'someday-review') o,
  ];
  features.remove('someday_review_days');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

/// 本体が書く形で、項目一覧の項目を「いつかやる」へ移し、一覧に載せる。
Map<String, String> withSomeday(
  Map<String, String> files,
  int index, {
  String since = '2026-09-01',
  String? reviewed,
}) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  item['someday'] = {
    'id': 'SMD-${'0' * 24}${index.toString().padLeft(2, '0')}',
    'since': since,
    'reviewed': reviewed ?? since,
  };
  final list = {
    'schema_version': 1,
    'generated_at': '2026-11-02T00:00:00.000Z',
    'review_days': 30,
    'entries': [
      {
        'kind': 'item',
        'scope': projectId,
        'title': 'AI Context Hub',
        'item_key': item['key'],
        'section': item['section'],
        'label': item['section'] == 'next' ? '' : '未解決: ',
        'text': item['text'],
        'since': since,
        'reviewed': reviewed ?? since,
      },
    ],
  };
  return {
    ...files,
    path: jsonEncode(items),
    '90_system/someday.json': jsonEncode(list),
  };
}

void main() {
  // プロジェクト未定の行動を本体で「いつかやる」へ移したVault（画面のテストで使う）。
  late Map<String, String> unassignedSomeday;
  setUpAll(() async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location), today = hubToday();
      final added = await service.saveAction('e1111111-2222-4333-8444-666666666666', unassignedScope, '物置の棚を作る');
      final files = await protocol(access, added.requestId, fixturePath, 'add');
      final item = HubRepository(VaultSnapshot(files)).unassignedOwnActions.single;
      final moved = await service.saveItemSomeday('e2111111-2222-4333-8444-666666666666', unassignedScope, item, (since: today, reviewed: today));
      unassignedSomeday = await protocol(access, moved.requestId, await writeFixture(access, files), 'someday');
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('項目一覧の「いつかやる」を読み、次の一手の件数・ウィジェットから外し、見直していない行を数える', () {
    final plain = HubRepository(fixture());
    expect(plain.intakeFeatures.someday, isTrue);
    expect(plain.intakeFeatures.somedayReviewDays, 30);
    expect(plain.somedayEntries, isEmpty);
    expect(plain.somedayGeneratedAt, isNotNull);
    final old = HubRepository(fixture(withoutSomeday(fixtureFiles())));
    expect(old.intakeFeatures.someday, isFalse);
    expect(old.intakeFeatures.somedayReviewDays, somedayReviewDaysDefault);

    final repo = HubRepository(fixture(withSomeday(fixtureFiles(), 0)));
    expect(repo.warnings, isEmpty);
    final project = repo.projects[projectId]!, item = project.nowItems.first;
    expect((item.someday, item.waiting, item.somedaySince), (true, false, '2026-09-01'));
    expect(project.nextCount, 0);
    expect(project.activeEntries('next'), isEmpty);
    final entry = repo.somedayEntries.single;
    expect((entry.kind, entry.id, entry.place), ('item', item.key, 'AI Context Hub'));
    expect(entry.days('2026-10-01'), 30);
    expect(repo.staleSomedayEntries('2026-09-30'), isEmpty);
    expect(repo.staleSomedayEntries('2026-10-01'), hasLength(1));
    final content = homeWidgetContent(repo, settings: const HomeWidgetSettings(showText: true));
    expect(content['counts'], startsWith('次の一手 0件'));
    expect(content['lines'], isEmpty);
    // 今日の3つに選んでいた項目も、移した後は持ち越さない。
    final pick = TodayPick(projectId, item.key, item.text);
    expect(todayOpen(plain, pick), isTrue);
    expect(todayOpen(repo, pick), isFalse);
    // 連絡待ちの印と重なった項目は「いつかやる」として扱う（本体は重ねて付けない）。
    final both = HubRepository(fixture(withWaiting(withSomeday(fixtureFiles(), 0), 0)));
    expect(both.projects[projectId]!.nowItems.first.waiting, isFalse);
    // 壊れた一覧は使わず、警告を出す。
    final broken = HubRepository(
      fixture({...fixtureFiles(), '90_system/someday.json': '{"schema_version":1}'}),
    );
    expect(broken.somedayEntries, isEmpty);
    expect(broken.warnings, isNotEmpty);
  });

  test('Dartの「いつかやる」の依頼を本体が受理し、移す・見直す・戻すが項目一覧と一覧に反映される', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      var files = fixtureFiles();
      var repo = HubRepository(fixture(files));
      final item = repo.projects[projectId]!.nowItems.first, today = hubToday();
      // 移していない項目は戻せず、移した日より前の見直しは送らない。
      await expectLater(
        service.saveItemSomeday('b1111111-2222-4333-8444-555555555555', projectId, item, null),
        throwsFormatException,
      );
      await expectLater(
        service.saveItemSomeday('b1111111-2222-4333-8444-555555555555', projectId, item, (since: today, reviewed: '2026-01-01')),
        throwsFormatException,
      );
      final moved = await service.saveItemSomeday(
        'b1111111-2222-4333-8444-555555555555',
        projectId,
        item,
        (since: today, reviewed: today),
      );
      final raw = (await access.readRequest(location, moved.requestId))!;
      expect(parseMarkdown(raw).meta, allOf(containsPair('operation', 'item-someday'), containsPair('someday', {'since': today})));
      final pending = HubRepository(fixture({...files, 'Input/${moved.requestId}.md': raw}));
      expect(pending.warnings, isEmpty);
      expect(pending.somedayRequestIdFor(item.key), moved.requestId);
      expect(pending.intake.firstWhere((i) => i.id == moved.requestId).title, contains('「いつかやる」'));

      files = await protocol(access, moved.requestId, 'assets/sample.json', 'move');
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      final now = repo.projects[projectId]!.nowItems.firstWhere((i) => i.key == item.key);
      expect((now.someday, now.somedaySince, now.somedayReviewed), (true, today, today));
      expect(repo.somedayRequestIdFor(item.key), isNull);
      expect(repo.latestSomedayIdFor(item.key), startsWith('SMD-'));
      expect(repo.projects[projectId]!.nextCount, 0);
      expect(repo.somedayEntries.single.id, item.key);
      // NOWの行は項目に結び付いたまま、行末に「いつかやる」が付く。
      final line = repo.projects[projectId]!.sections['next']!.single;
      expect(line.itemKey, item.key);
      expect(line.text, contains('いつかやる'));

      // 戻すと元の欄へ戻り、一覧から外れる。
      final back = await service.saveItemSomeday('b2111111-2222-4333-8444-555555555555', projectId, now, null);
      files = await protocol(access, back.requestId, await writeFixture(access, files), 'back');
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.projects[projectId]!.nowItems.firstWhere((i) => i.key == item.key).someday, isFalse);
      expect(repo.projects[projectId]!.nextCount, 1);
      expect(repo.somedayEntries, isEmpty);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('アイデアを置く・やめる依頼を本体が受理し、一覧の書き直しで反映を確かめる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location), today = hubToday();
      expect(HubRepository(fixture()).ideaRecord(ideaId), isNotNull);
      await expectLater(
        service.saveSomedayReview('c1111111-2222-4333-8444-555555555555', 'project', projectId, 'drop', today),
        throwsFormatException,
      );
      final added = await service.saveSomedayReview('c1111111-2222-4333-8444-555555555555', 'idea', ideaId, 'add', today);
      final raw = (await access.readRequest(location, added.requestId))!;
      final pending = HubRepository(fixture({...fixtureFiles(), 'Input/${added.requestId}.md': raw}));
      expect(pending.warnings, isEmpty);
      expect(pending.somedayReviewRequestIdFor('idea', ideaId), added.requestId);
      var files = await protocol(access, added.requestId, 'assets/sample.json', 'idea-add');
      var repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.somedayReviewRequestIdFor('idea', ideaId), isNull);
      expect(repo.somedayIdea(ideaId), isTrue);
      expect(repo.somedayEntries.single.kind, 'idea');

      final dropped = await service.saveSomedayReview('c2111111-2222-4333-8444-555555555555', 'idea', ideaId, 'drop', today);
      files = await protocol(access, dropped.requestId, await writeFixture(access, files), 'idea-drop');
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.somedayIdea(ideaId), isFalse);
      expect(repo.somedayEntries, isEmpty);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('プロジェクト未定の行動も移せて、行動の件数から外れる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location), today = hubToday();
      final added = await service.saveAction('d1111111-2222-4333-8444-666666666666', unassignedScope, '庭の物置を片付ける');
      var files = await protocol(access, added.requestId, fixturePath, 'add');
      var repo = HubRepository(VaultSnapshot(files));
      final item = repo.unassignedOwnActions.single;
      final moved = await service.saveItemSomeday('d2111111-2222-4333-8444-666666666666', unassignedScope, item, (since: today, reviewed: today));
      files = await protocol(access, moved.requestId, await writeFixture(access, files), 'someday');
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.unassignedOwnActions, isEmpty);
      expect(repo.unassignedActionCount, 0);
      expect(repo.unassignedSomedayCount, 1);
      final entry = repo.somedayEntries.single;
      expect((entry.kind, entry.scope, entry.id), ('item', unassignedScope, item.key));
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('対応していない本体・連絡待ちの項目・今日見直した項目には依頼しない', () async {
    final files = withoutSomeday(fixtureFiles());
    final a = MemoryUIAccess()..current = fixture(files);
    final c = HubController(a, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final key = c.repository!.projects[projectId]!.nowItems.first.key;
    await expectLater(c.requestItemSomeday(projectId, key, 'move'), throwsA(isA<StateError>()));
    await expectLater(c.requestSomedayReview('idea', ideaId, 'add'), throwsA(isA<StateError>()));
    expect(() => c.requestSomedayReview('project', projectId, 'drop'), throwsA(isA<StateError>()));

    final waiting = withWaiting(fixtureFiles(), 0);
    final b = MemoryUIAccess()..current = fixture(waiting);
    final d = HubController(b, sampleLoader: () async => waiting);
    addTearDown(d.dispose);
    await d.useSample();
    await expectLater(d.requestItemSomeday(projectId, key, 'move'), throwsA(isA<StateError>()));
    // 移していない項目は見直せず、戻せない。進行中のプロジェクトは見直さない。
    await expectLater(d.requestItemSomeday(projectId, key, 'back'), throwsA(isA<StateError>()));
    await expectLater(d.requestSomedayReview('project', projectId, 'keep'), throwsA(isA<StateError>()));

    final today = hubToday(), moved = withSomeday(fixtureFiles(), 0, since: today);
    final e = MemoryUIAccess()..current = fixture(moved);
    final f = HubController(e, sampleLoader: () async => moved);
    addTearDown(f.dispose);
    await f.useSample();
    await expectLater(f.requestItemSomeday(projectId, key, 'keep'), throwsA(isA<StateError>()));
    await expectLater(f.requestItemSomeday(projectId, key, 'move'), throwsA(isA<StateError>()));
    // 「いつかやる」の項目には連絡待ちの印を付けない。
    await expectLater(f.requestItemWait(projectId, key, since: today), throwsA(isA<StateError>()));
    expect(a.requests, isEmpty);
    expect(b.requests, isEmpty);
    expect(e.requests, isEmpty);
  });

  testWidgets('項目の「…」から「いつかやる」へ移し、ホームと「いつかやる」の画面で見直して戻せる', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
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
    expect(find.byKey(const Key('home-someday')), findsNothing);
    await tester.tap(find.byKey(const Key('project-$projectId')).first);
    await tester.pumpAndSettle();
    final item = c.repository!.projects[projectId]!.nowItems.first,
        short = item.key.substring(0, 12);
    await openMore(tester, short);
    await tester.tap(find.byKey(Key('someday-$short')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移す').last);
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-someday');
    expect(request['item_key'], item.key);
    expect(request['someday'], {'since': hubToday()});

    // 依頼が同期されて反映待ちの間は、操作を重ねて出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('「いつかやる」を依頼済み（反映待ち）'), findsOneWidget);
    await openMore(tester, short);
    expect(find.byKey(Key('someday-$short')), findsNothing);
    expect(find.byKey(Key('wait-$short')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 反映後は次の一手から外れ、ホームに件数と見直していない件数が出る。
    access.current = fixture(withSomeday(files, 0));
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    expect(find.text('次の一手 0件'), findsOneWidget);
    expect(find.byKey(const Key('next-someday')), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-home')).last);
    await tester.pumpAndSettle();
    expect(find.text('いつかやる 1件'), findsOneWidget);
    expect(find.textContaining('30日以上見直していないもの1件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-someday')));
    await tester.pumpAndSettle();
    final tag = digest(c.repository!.somedayEntries.single.ref).substring(0, 12);
    expect(find.byKey(Key('someday-$tag')), findsOneWidget);
    expect(find.textContaining('移した日 2026-09-01'), findsOneWidget);

    // そのまま: 見直した日だけを今日にする。
    await tester.tap(find.byKey(Key('someday-keep-$tag')));
    await tester.pumpAndSettle();
    final keep = parseMarkdown(access.requests.values.last).meta;
    expect(keep['operation'], 'item-someday');
    expect(keep['someday'], {'since': '2026-09-01', 'reviewed': hubToday()});

    // 始める: 元の欄へ戻す（見直しが反映待ちの間は操作を出さないため、反映後の状態で試す）。
    access.current = fixture(withSomeday(files, 0, reviewed: '2026-10-01'));
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('someday-start-$tag')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('戻す').last);
    await tester.pumpAndSettle();
    final back = parseMarkdown(access.requests.values.last).meta;
    expect((back['operation'], back['someday']), ('item-someday', null));
  });

  testWidgets('アイデアの画面から「いつかやる」に置ける', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
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
    await tester.tap(find.byKey(const Key('nav-ideas')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(c.repository!.ideaRecord(ideaId)!.title).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('idea-someday')));
    await tester.tap(find.byKey(const Key('idea-someday')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('idea-someday-confirm')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(
      (request['operation'], request['target'], request['target_id'], request['action']),
      ('someday-review', 'idea', ideaId, 'add'),
    );
  });

  testWidgets('プロジェクト未定の行動も「いつかやる」の画面から戻せる', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = unassignedSomeday;
    access.current = VaultSnapshot(files);
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
    await tester.tap(find.byKey(const Key('nav-someday')).last);
    await tester.pumpAndSettle();
    final entry = c.repository!.somedayEntries.single,
        tag = digest(entry.ref).substring(0, 12);
    expect(entry.scope, unassignedScope);
    // 今日移したので「そのまま」は押せない。始める・やめるは出る。
    expect(tester.widget<TextButton>(find.byKey(Key('someday-keep-$tag'))).onPressed, isNull);
    expect(find.byKey(Key('someday-drop-$tag')), findsOneWidget);
    await tester.tap(find.byKey(Key('someday-start-$tag')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('戻す').last);
    await tester.pumpAndSettle();
    final back = parseMarkdown(access.requests.values.single).meta;
    expect((back['operation'], back['project_id'], back['item_key'], back['someday']), ('item-someday', unassignedScope, entry.id, null));
  });
}
