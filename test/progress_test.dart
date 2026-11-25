import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'recurring_ask_preferences_test.dart' show openMore;
import 'waiting_test.dart' show withWaiting;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;

const progressId = 'PROG-01KAXQZ0000000000000000000';

/// 本体が書く形で、項目一覧の[index]番目の項目に取りかかり中の印を付ける。
Map<String, String> withProgress(
  Map<String, String> files,
  int index, {
  String since = '2026-11-20',
  String? updated,
  String? note,
}) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  item['progress'] = {
    'id': progressId,
    'since': since,
    'updated': updated ?? since,
    'note': ?note,
  };
  return {...files, path: jsonEncode(items)};
}

/// 対応表から取りかかり中の依頼を外す（対応前の本体）。
Map<String, String> withoutProgress(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (o != 'item-progress') o,
  ];
  features.remove('item_progress');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

void main() {
  test('対応表と項目一覧の取りかかり中を読み、不正な印は本体と同じく扱う', () {
    final repo = HubRepository(fixture());
    expect(repo.intakeFeatures.progress, isTrue);
    expect(repo.intakeFeatures.progressLimits, (
      noteMaxChars: 80,
      limit: 3,
      staleDays: 14,
    ));
    expect(
      HubRepository(fixture(withoutProgress(fixtureFiles())))
          .intakeFeatures
          .progress,
      isFalse,
    );

    final files = withProgress(
      fixtureFiles(),
      0,
      since: '2026-11-01',
      updated: '2026-11-03',
      note: '見積もりの表は半分まで',
    );
    final r = HubRepository(fixture(files)),
        item = r.projects[projectId]!.nowItems[0];
    expect(r.warnings, isEmpty);
    expect(
      (
        item.progressId,
        item.progressSince,
        item.progressUpdated,
        item.progressNote,
      ),
      (progressId, '2026-11-01', '2026-11-03', '見積もりの表は半分まで'),
    );
    expect(item.progressing, isTrue);
    expect(r.progressingItems.single.item.key, item.key);
    expect(progressLabel(item), '取りかかり中 2026-11-01から');
    expect(
      progressDetail(item, '2026-11-20', 14),
      '取りかかり中 2026-11-01から19日・17日更新なし・どこまで: 見積もりの表は半分まで',
    );
    expect(
      progressDetail(item, '2026-11-10', 14),
      startsWith('取りかかり中 2026-11-01から9日・どこまで'),
    );
    expect(progressStale(item, '2026-11-17', 14), isTrue);
    expect(progressStale(item, '2026-11-16', 14), isFalse);
    // 連絡待ちの項目も、印は付いたまま一覧に含める（ホームと次の一手では連絡待ちとして分ける）。
    expect(
      HubRepository(fixture(withWaiting(files, 0)))
          .progressingItems
          .single
          .item
          .waiting,
      isTrue,
    );

    // 形の合わない印を持つ一覧は読まない（ほかの項目一覧と同じく、問題として示す）。
    for (final bad in [
      {'id': 'PROG-x', 'since': '2026-11-01', 'updated': '2026-11-01'},
      {'id': progressId, 'since': '2026-13-01', 'updated': '2026-11-01'},
      {'id': progressId, 'since': '2026-11-01'},
      {
        'id': progressId,
        'since': '2026-11-01',
        'updated': '2026-11-01',
        'note': '',
      },
      {
        'id': progressId,
        'since': '2026-11-01',
        'updated': '2026-11-01',
        'who': 'x',
      },
    ]) {
      final path = '90_system/now-items/$projectId.json',
          items = jsonDecode(fixtureFiles()[path]!) as Map<String, dynamic>;
      ((items['items'] as List)[0] as Map)['progress'] = bad;
      final broken = HubRepository(
        fixture({...fixtureFiles(), path: jsonEncode(items)}),
      );
      expect(broken.projects[projectId]!.nowItems, isEmpty, reason: '$bad');
    }

    // ひとことの規則（本体のprogressNoteSchemaと同じ）。
    expect(validProgressNote('半分まで'), isTrue);
    expect(validProgressNote('x' * 80), isTrue);
    for (final bad in ['', ' 前に空白', '後に空白 ', '2行\n目', 'x' * 81, 'a b']) {
      expect(validProgressNote(bad), isFalse, reason: bad);
    }
  });

  group('protocol', () {
    late TempAccess access;
    setUp(() async {
      access = TempAccess();
      await access.init();
    });
    tearDown(() => access.directory.delete(recursive: true));

    test('取りかかり中の印・ひとことの書き直し・外す依頼を本体が受け付け、項目一覧に反映する', () async {
      final service = CaptureService(access, location),
          repo = HubRepository(fixture()),
          item = repo.projects[projectId]!.nowItems[0],
          open = repo.projects[projectId]!.nowItems[1];
      for (final (target, progress, expected) in [
        // 未解決の項目には付けない。
        (open, (since: '2026-11-20', note: null), null),
        // 2行のひとこと・長すぎるひとこと・不正な日付。
        (item, (since: '2026-11-20', note: '1行\n2行'), null),
        (item, (since: '2026-11-20', note: 'x' * 81), null),
        (item, (since: '2026-11-31', note: null), null),
        // 変わらない依頼。
        (item, null, null),
      ]) {
        await expectLater(
          service.saveItemProgress(
            'd1111111-2222-4333-8444-555555555555',
            projectId,
            target,
            progress,
            expected: expected,
          ),
          throwsFormatException,
          reason: '$progress',
        );
      }
      final today = hubToday();
      final started = await service.saveItemProgress(
        'd1111111-2222-4333-8444-555555555555',
        projectId,
        item,
        (since: today, note: null),
        expected: null,
      );
      final raw = (await access.readRequest(location, started.requestId))!;
      expect(
        parseMarkdown(raw).meta,
        allOf(
          containsPair('operation', 'item-progress'),
          containsPair('progress', {'since': today}),
          containsPair('expected', null),
        ),
      );
      final waiting = HubRepository(
        fixture({...fixtureFiles(), 'Input/${started.requestId}.md': raw}),
      );
      expect(waiting.progressRequestIdFor(item.key), started.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == started.requestId).title,
        startsWith('取りかかり中にする依頼'),
      );

      final synced = await protocol(
        access,
        started.requestId,
        'assets/sample.json',
        'prog1',
      );
      final r1 = HubRepository(fixture(synced)),
          marked = r1.projects[projectId]!.nowItems.firstWhere(
            (i) => i.key == item.key,
          );
      expect(r1.warnings, isEmpty);
      expect(r1.progressRequestIdFor(item.key), isNull);
      expect(r1.latestProgressIdFor(item.key), marked.progressId);
      expect((marked.progressSince, marked.progressNote), (today, null));
      expect(
        r1.projects[projectId]!.sections['next']!.single.text,
        contains('取りかかり中 $todayから'),
      );

      // ひとことの書き直しは、見た印（expected）を添えて送る。ひとことはNOWの本文に載らない。
      final fixtureOut = File('${access.directory.path}/prog1-fixture.json');
      await fixtureOut.writeAsString(jsonEncode(synced));
      final noted = await service.saveItemProgress(
        'd2222222-2222-4333-8444-555555555555',
        projectId,
        marked,
        (since: today, note: '見積もりの表は半分まで'),
        expected: (since: today, note: null),
      );
      final r2 = HubRepository(
        fixture(
          await protocol(access, noted.requestId, fixtureOut.path, 'prog2'),
        ),
      );
      final written = r2.projects[projectId]!.nowItems.firstWhere(
        (i) => i.key == item.key,
      );
      expect(written.progressNote, '見積もりの表は半分まで');
      expect(r2.latestProgressIdFor(item.key), written.progressId);
      expect(written.progressId, isNot(marked.progressId));
    });
  });

  test('画面で見た印と読み直した印が違えば送らず、手を動かせない項目には新しく付けない', () async {
    final access = MemoryUIAccess();
    await access.init();
    final c = HubController(access, sampleLoader: () async => fixtureFiles());
    addTearDown(c.dispose);
    access.current = fixture(
      withProgress(fixtureFiles(), 0, since: '2026-11-20', note: '半分まで'),
    );
    await c.useSample();
    final key = c.repository!.projects[projectId]!.nowItems[0].key;
    // 別の端末でひとことが書き直された後の、古い表示からの書き直し。
    await expectLater(
      c.requestItemProgress(
        projectId,
        key,
        progress: (since: '2026-11-20', note: '全部終わった'),
        expected: (since: '2026-11-20', note: null),
      ),
      throwsA(isA<StateError>()),
    );
    expect(access.requests, isEmpty);
    // 先の日付は付けられない。
    await expectLater(
      c.requestItemProgress(
        projectId,
        key,
        progress: (since: '2099-01-01', note: '半分まで'),
        expected: (since: '2026-11-20', note: '半分まで'),
      ),
      throwsA(isA<StateError>()),
    );
    // 連絡待ちの項目には新しく付けない。
    access.current = fixture(withWaiting(fixtureFiles(), 0));
    await c.reload();
    await expectLater(
      c.requestItemProgress(
        projectId,
        key,
        progress: (since: hubToday(), note: null),
        expected: null,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('連絡待ち')),
      ),
    );
    expect(access.requests, isEmpty);
    // 対応前の本体には送らない。
    access.current = fixture(withoutProgress(fixtureFiles()));
    await c.reload();
    await expectLater(
      c.requestItemProgress(
        projectId,
        key,
        progress: (since: hubToday(), note: null),
        expected: null,
      ),
      throwsA(isA<StateError>()),
    );
    expect(access.requests, isEmpty);
  });

  testWidgets('次の一手から取りかかり、ホームと次の一手の先頭に出て、どこまで進んだかを書ける', (tester) async {
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
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    final item = c.repository!.projects[projectId]!.nowItems.first,
        tag = item.key.substring(0, 12);
    await openMore(tester, tag);
    expect(find.byKey(Key('progress-note-$tag')), findsNothing);
    await tester.tap(find.byKey(Key('progress-start-$tag')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-progress');
    expect(request['item_key'], item.key);
    expect(request['progress'], {'since': hubToday()});
    expect(request['expected'], isNull);

    // 依頼が同期されて反映待ちの間は、取りかかり中の操作を重ねて出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('取りかかり中を依頼済み（反映待ち）'), findsOneWidget);
    await openMore(tester, tag);
    expect(find.byKey(Key('progress-start-$tag')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<VoidCallback>), findsNothing);

    // 反映後は、次の一手の先頭の「取りかかり中」に出て、件数は変わらない。止まっていれば日数を添える。
    access.requests.clear();
    final marked = withProgress(
      files,
      0,
      since: '2026-10-01',
      updated: '2026-10-02',
      note: '表は半分まで',
    );
    access.current = fixture(marked);
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('次の一手 1件'), findsOneWidget);
    expect(find.byKey(const Key('next-progress')), findsOneWidget);
    expect(find.byKey(Key('progress-label-$tag')), findsOneWidget);
    expect(find.textContaining('日更新なし・どこまで: 表は半分まで'), findsOneWidget);

    // ひとことの書き直しは、見た印を添えて送る。
    await openMore(tester, tag);
    expect(find.byKey(Key('progress-start-$tag')), findsNothing);
    await tester.tap(find.byKey(Key('progress-note-$tag')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-dialog')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('progress-note')))
          .controller!
          .text,
      '表は半分まで',
    );
    // 変えていないうちは送れない。始めた日に先の日付は付けられない。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('progress-submit')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('progress-since')),
      '2099-01-01',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('progress-submit')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('progress-since')),
      '2026-10-01',
    );
    await tester.enterText(
      find.byKey(const Key('progress-note')),
      '表は終わった。次は単価',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('progress-submit')));
    await tester.pumpAndSettle();
    final edit = parseMarkdown(access.requests.values.single).meta;
    expect(edit['progress'], {'since': '2026-10-01', 'note': '表は終わった。次は単価'});
    expect(edit['expected'], {'since': '2026-10-01', 'note': '表は半分まで'});

    // ホームでは今日の3つの次に出る。
    await tester.tap(find.byKey(const Key('nav-home')).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-progress')), findsOneWidget);
    expect(find.byKey(Key('home-progress-$tag')), findsOneWidget);

    // 取りかかり中をやめる。
    access.requests.clear();
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    await openMore(tester, tag);
    await tester.tap(find.byKey(Key('progress-stop-$tag')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('印を外す').last);
    await tester.pumpAndSettle();
    final stop = parseMarkdown(access.requests.values.single).meta;
    expect(stop['progress'], isNull);
    expect(stop['expected'], {'since': '2026-10-01', 'note': '表は半分まで'});

    // 対応前の本体では、取りかかり中の操作を出さない。
    access.current = fixture(withoutProgress(files));
    await c.reload();
    await tester.pumpAndSettle();
    await openMore(tester, tag);
    expect(find.byKey(Key('progress-start-$tag')), findsNothing);
  });
}
