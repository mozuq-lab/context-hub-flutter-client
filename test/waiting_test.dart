import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';

import 'capture_test.dart' show TempAccess, location;
import 'fixtures.dart';
import 'unassigned_actions_test.dart' show fixturePath;
import 'unassigned_records_test.dart' show writeFixture;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'recurring_ask_preferences_test.dart' show openMore;

/// 本体が書く形で、項目一覧の項目に連絡待ちの印を付ける。
Map<String, String> withWaiting(
  Map<String, String> files,
  int index, {
  String since = '2026-10-20',
  String? who,
  String? reviewAfter,
  String project = projectId,
}) {
  final path = '90_system/now-items/$project.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  item['waiting'] = {
    'id': 'WAIT-${'0' * 24}${index.toString().padLeft(2, '0')}',
    'since': since,
    'who': ?who,
  };
  if (reviewAfter != null) {
    item['schedule'] = {
      'id': 'SCH-${'0' * 24}${index.toString().padLeft(2, '0')}',
      'due': null,
      'review_after': reviewAfter,
    };
  }
  return {...files, path: jsonEncode(items)};
}

/// 対応表から連絡待ちの依頼を外す（対応前の本体）。
Map<String, String> withoutWait(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (o != 'item-wait') o,
  ];
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

void main() {
  test('項目一覧の連絡待ちを読み、次の一手の件数・ウィジェットから外す（相手の名前は出さない）', () {
    final plain = HubRepository(fixture());
    expect(plain.intakeFeatures.wait, isTrue);
    expect(HubRepository(fixture(withoutWait(fixtureFiles()))).intakeFeatures.wait, isFalse);
    final before = plain.projects[projectId]!.nextCount;
    expect(before, 1);
    final repo = HubRepository(fixture(withWaiting(fixtureFiles(), 0, who: '山田さん')));
    expect(repo.warnings, isEmpty);
    final project = repo.projects[projectId]!, item = project.nowItems.first;
    expect((item.waiting, item.waitingSince, item.waitingWho), (true, '2026-10-20', '山田さん'));
    expect(project.nextCount, 0);
    expect(project.waitingEntries('next'), hasLength(1));
    expect(project.activeEntries('next'), isEmpty);
    expect(waitingLabel(item, '2026-10-30'), '連絡待ち・相手: 山田さん・頼んでから10日');
    // 未解決の項目も連絡待ちにでき、未解決の件数から外れる。
    final open = HubRepository(fixture(withWaiting(fixtureFiles(), 1))).projects[projectId]!;
    expect(open.activeEntries('open'), hasLength(1));
    expect(open.waitingEntries('open'), hasLength(1));
    // ウィジェットには連絡待ちの行も相手の名前も出さない。
    final content = homeWidgetContent(repo, settings: const HomeWidgetSettings(showText: true));
    expect(content['counts'], startsWith('次の一手 0件'));
    expect(jsonEncode(content), isNot(contains('山田')));
    expect(content['lines'], isEmpty);
    // 片付いた項目の印は効かない。不正な印は壊れた一覧として扱う。
    final bad = withWaiting(fixtureFiles(), 0, who: ' 山田');
    expect(HubRepository(fixture(bad)).projects[projectId]!.nowItems, isEmpty);
    expect(HubRepository(fixture(bad)).warnings, isNotEmpty);
    expect(validWaitWho('山田さん'), isTrue);
    expect(validWaitWho('山田\nさん'), isFalse);
    expect(validWaitWho('あ' * 41), isFalse);
    expect(waitingDays('2026-10-31', '2026-10-30'), 0);
  });

  test('見直す日が来た連絡待ちを、確認の対象として判定する', () {
    final repo = HubRepository(
      fixture(withWaiting(fixtureFiles(), 0, reviewAfter: '2026-10-30')),
    );
    final item = repo.projects[projectId]!.nowItems.first;
    expect(waitingCheckDue(item, '2026-10-29'), isFalse);
    expect(waitingCheckDue(item, '2026-10-30'), isTrue);
    expect(itemRecordLabel(item), '見直す日 2026-10-30');
  });

  test('Dartの連絡待ちの依頼を本体が受理し、NOWには相手を載せず、項目一覧に相手が届く', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          item = HubRepository(fixture(files)).projects[projectId]!.nowItems.first;
      final service = CaptureService(access, location);
      // 付いていない印は外せず、不正な相手は送らない。
      await expectLater(
        service.saveItemWait('a1111111-2222-4333-8444-555555555555', projectId, item, null),
        throwsFormatException,
      );
      await expectLater(
        service.saveItemWait('a1111111-2222-4333-8444-555555555555', projectId, item, (who: ' 山田', since: '2026-10-20')),
        throwsFormatException,
      );
      final saved = await service.saveItemWait(
        'a1111111-2222-4333-8444-555555555555',
        projectId,
        item,
        (who: '山田さん', since: '2026-10-20'),
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(parseMarkdown(raw).meta, allOf(containsPair('operation', 'item-wait'), containsPair('waiting', {'who': '山田さん', 'since': '2026-10-20'})));
      final waiting = HubRepository(fixture({...files, 'Input/${saved.requestId}.md': raw}));
      expect(waiting.warnings, isEmpty);
      expect(waiting.waitRequestIdFor(item.key), saved.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('連絡待ちの依頼（相手: 山田さん・頼んだ日 2026-10-20）'),
      );
      final synced = HubRepository(
        fixture(await protocol(access, saved.requestId, 'assets/sample.json', 'wait')),
      );
      expect(synced.warnings, isEmpty);
      final project = synced.projects[projectId]!,
          now = project.nowItems.firstWhere((i) => i.key == item.key);
      expect((now.waitingSince, now.waitingWho), ('2026-10-20', '山田さん'));
      expect(synced.waitRequestIdFor(item.key), isNull);
      expect(synced.latestWaitIdFor(item.key), startsWith('WAIT-'));
      // NOWの行末には印と頼んだ日だけが付き、相手の名前は載らない。行は項目に結び付いたまま。
      final line = project.sections['next']!.single;
      expect(line.text, contains('連絡待ち 2026-10-20から'));
      expect(line.text, isNot(contains('山田')));
      expect(line.itemKey, item.key);
      expect(project.nextCount, 0);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('プロジェクト未定の行動の連絡待ちを本体が受理し、行動の件数から外れる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      final added = await service.saveAction('61111111-2222-4333-8444-666666666666', unassignedScope, '見積もりの返事を待つ');
      var files = await protocol(access, added.requestId, fixturePath, 'add');
      var repo = HubRepository(VaultSnapshot(files));
      final item = repo.unassignedOwnActions.single;
      expect(repo.unassignedActionCount, 1);
      final wait = await service.saveItemWait('62111111-2222-4333-8444-666666666666', unassignedScope, item, (who: null, since: hubToday()));
      expect(parseMarkdown((await access.readRequest(location, wait.requestId))!).meta['waiting'], {'since': hubToday()});
      files = await protocol(access, wait.requestId, await writeFixture(access, files), 'wait');
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.unassignedOwnActions, isEmpty);
      expect(repo.unassignedActionCount, 0);
      expect(repo.unassignedWaitingActions.single.waitingSince, hubToday());
      expect(repo.unassignedWaitingActions.single.waitingWho, isNull);
      expect(homeWidgetContent(repo, settings: const HomeWidgetSettings(showText: true))['lines'], isNot(contains(startsWith('本人が追加: 見積もり'))));
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('対応していない本体と、変わらない印は依頼しない', () async {
    final files = withoutWait(fixtureFiles());
    final a = MemoryUIAccess()..current = fixture(files);
    final c = HubController(a, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final key = c.repository!.projects[projectId]!.nowItems.first.key;
    await expectLater(c.requestItemWait(projectId, key, since: '2026-10-20'), throwsA(isA<StateError>()));
    expect(() => c.requestItemWait(projectId, key, who: '山田', since: '2026-02-30'), throwsA(isA<StateError>()));
    final waiting = withWaiting(fixtureFiles(), 0, who: '山田さん');
    final b = MemoryUIAccess()..current = fixture(waiting);
    final d = HubController(b, sampleLoader: () async => waiting);
    addTearDown(d.dispose);
    await d.useSample();
    await expectLater(d.requestItemWait(projectId, key, who: '山田さん', since: '2026-10-20'), throwsA(isA<StateError>()));
    expect(a.requests, isEmpty);
    expect(b.requests, isEmpty);
  });

  testWidgets('項目の「…」から連絡待ちにし、次の一手の画面で「連絡待ち」にまとまり、見直す日が来ると先頭に出る', (tester) async {
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
    await tester.tap(find.byKey(const Key('project-$projectId')).first);
    await tester.pumpAndSettle();
    final item = c.repository!.projects[projectId]!.nowItems.first,
        short = item.key.substring(0, 12);
    await openMore(tester, short);
    expect(find.byKey(Key('unwait-$short')), findsNothing);
    await tester.tap(find.byKey(Key('wait-$short')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wait-dialog')), findsOneWidget);
    // 頼んだ日は今日が入っていて、先の日付は付けられない。
    expect(tester.widget<TextField>(find.byKey(const Key('wait-since'))).controller!.text, hubToday());
    await tester.enterText(find.byKey(const Key('wait-since')), '2099-01-01');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('wait-submit'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('wait-since')), '2026-10-20');
    await tester.enterText(find.byKey(const Key('wait-who')), '山田さん');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wait-submit')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-wait');
    expect(request['item_key'], item.key);
    expect(request['waiting'], {'who': '山田さん', 'since': '2026-10-20'});

    // 依頼が同期されて反映待ちの間は、連絡待ちの操作を重ねて出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('連絡待ちを依頼済み（反映待ち）'), findsOneWidget);
    await openMore(tester, short);
    expect(find.byKey(Key('wait-$short')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 反映後は、次の一手の画面で「連絡待ち」にまとまり、件数から外れる。相手と日数は画面にだけ出る。
    access.current = fixture(withWaiting(files, 0, who: '山田さん'));
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    expect(find.text('次の一手 0件'), findsOneWidget);
    expect(find.byKey(const Key('next-waiting')), findsOneWidget);
    expect(find.byKey(const Key('next-waiting-checks')), findsNothing);
    expect(find.textContaining('相手: 山田さん'), findsOneWidget);
    await openMore(tester, short);
    expect(find.byKey(Key('unwait-$short')), findsOneWidget);
    await tester.tap(find.byKey(Key('unwait-$short')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('外す').last);
    await tester.pumpAndSettle();
    final removal = parseMarkdown(
      access.requests.values.firstWhere((r) => parseMarkdown(r).meta['waiting'] == null),
    ).meta;
    expect(removal['operation'], 'item-wait');

    // 見直す日が来ると、先頭の「連絡待ちの確認」に出て、下の「連絡待ち」には重ねない。
    access.current = fixture(withWaiting(files, 0, who: '山田さん', reviewAfter: '2026-10-01'));
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('next-waiting-checks')), findsOneWidget);
    expect(find.byKey(const Key('next-waiting')), findsNothing);
  });

  testWidgets('未解決の連絡待ちも次の一手の画面にまとまり、見直す日が来た確認は目安で絞り込んでも先頭に出る', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = withWaiting(fixtureFiles(), 1, who: '佐藤さん');
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
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    // 次の一手の件数は変わらず、未解決の件数から外れる。未解決の連絡待ちも次の一手の画面の「連絡待ち」に出る。
    expect(find.text('次の一手 1件'), findsOneWidget);
    expect(find.text('未解決 1件'), findsOneWidget);
    expect(find.byKey(const Key('next-waiting')), findsOneWidget);
    expect(find.text('AI Context Hub・未解決'), findsOneWidget);
    expect(find.textContaining('相手: 佐藤さん'), findsOneWidget);

    // 見直す日が来ると先頭の確認に出て、手間の目安で絞り込んでも消えない。
    access.current = fixture(
      withWaiting(fixtureFiles(), 1, who: '佐藤さん', reviewAfter: '2026-10-01'),
    );
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('next-waiting-checks')), findsOneWidget);
    await tester.tap(find.byKey(const Key('effort-filter-quick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('next-waiting-checks')), findsOneWidget);
    expect(find.byKey(const Key('next-waiting')), findsNothing);
  });
}
