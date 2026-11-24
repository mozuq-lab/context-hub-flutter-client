import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'controller_test.dart' show UIAccess;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'recurring_ask_preferences_test.dart' show openMore;
import 'fixtures.dart';

const nextKey =
        '51e28c36b6a67de852103a7bc6c5a359c0f911784ce7692f495c5131f4b38167',
    openKey =
        'e2094bb522ac5dba10c3015d8ca2773e6681917be43b5082261a8624fcfdcb99',
    questionKey =
        'b46ddfa824fc94f36f17d2c124d7b71e886c0ee98e949d676874182940d288e4';
const blockId = 'BLK-01KAXQZ0000000000000000000';

/// 本体が書く形で、項目一覧の[index]番目の項目に「先に済ませること」を付ける。
Map<String, String> withAfter(
  Map<String, String> files,
  int index,
  List<(String, String)> after,
) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      list = items['items'] as List,
      item = list[index] as Map<String, dynamic>;
  item['after'] = {
    'id': blockId,
    'items': [
      for (final (scope, key) in after)
        {
          'project_id': scope,
          'item_key': key,
          'section': 'open',
          'text':
              (list.firstWhere((i) => (i as Map)['key'] == key) as Map)['text'],
        },
    ],
  };
  return {...files, path: jsonEncode(items)};
}

/// 項目一覧の[key]の項目を、本体が書く形で完了・解決（[exclude]なら誤りとして外した）にする。
Map<String, String> withResolved(
  Map<String, String> files,
  String key, {
  bool exclude = false,
}) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>;
  final item =
      (items['items'] as List).firstWhere((i) => (i as Map)['key'] == key)
          as Map<String, dynamic>;
  item['resolution'] = {
    'id': 'RES-01KAXQZ0000000000000000001',
    'at': '2026-11-24T03:00:00Z',
    if (exclude) ...{'action': 'exclude', 'reason': 'outdated', 'note': null},
  };
  return {...files, path: jsonEncode(items)};
}

/// 本体が書く1日の締めの記録。
Map<String, String> withDayClose(
  Map<String, String> files,
  String id,
  String on,
  String? note, {
  String? dismissedBy,
}) => {
  ...files,
  '90_system/day-closes/$id.json': jsonEncode({
    'schema_version': 1,
    'id': id,
    'action': 'close',
    'on': on,
    'note': note,
    'source': 'cli',
    'created_at': '${on}T12:00:00Z',
  }),
  if (dismissedBy != null)
    '90_system/day-closes/$dismissedBy.json': jsonEncode({
      'schema_version': 1,
      'id': dismissedBy,
      'action': 'dismiss',
      'close_id': id,
      'source': 'cli',
      'created_at': '${on}T13:00:00Z',
    }),
};

/// 対応表から、先に済ませること・1日の締めの対応を外す（対応前の本体）。
Map<String, String> withoutNewFeatures(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (!['item-blocks', 'day-close'].contains(o)) o,
  ];
  features.remove('item_blocks');
  features.remove('day_close');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

void main() {
  test('対応表・項目一覧のafter・締めの記録を読み、不正な値は本体と同じく扱う', () {
    final repo = HubRepository(fixture());
    expect(repo.intakeFeatures.blocks, isTrue);
    expect(repo.intakeFeatures.blocksMax, 3);
    expect(repo.intakeFeatures.dayClose, isTrue);
    expect(repo.intakeFeatures.dayCloseLimits, (
      maxChars: 300,
      maxLines: 3,
      backDays: 7,
    ));
    final old = HubRepository(fixture(withoutNewFeatures(fixtureFiles())));
    expect(old.intakeFeatures.blocks, isFalse);
    expect(old.intakeFeatures.dayClose, isFalse);

    // 先の項目の状態: 残っている・済み・外した・見当たらない。
    var files = withAfter(fixtureFiles(), 0, [
      (projectId, openKey),
      (projectId, questionKey),
    ]);
    var item = HubRepository(fixture(files)).projects[projectId]!.nowItems[0];
    expect(item.after!.id, blockId);
    expect(item.after!.label, '先に済ませること 2件');
    var r = HubRepository(fixture(files));
    expect(item.after!.items.map(r.prerequisiteState), [
      PrerequisiteState.open,
      PrerequisiteState.open,
    ]);
    files = withResolved(files, openKey);
    files = withResolved(files, questionKey, exclude: true);
    r = HubRepository(fixture(files));
    item = r.projects[projectId]!.nowItems[0];
    expect(item.after!.items.map(r.prerequisiteState), [
      PrerequisiteState.done,
      PrerequisiteState.dropped,
    ]);
    expect(blockSettled(item.after!.items.map(r.prerequisiteState)), isTrue);
    // 本文が同じで1件だけの項目は、キーが変わっても同じ先の項目として探す。見当たらなければ待たない。
    expect(
      r.findPrerequisite(
        ItemAfterRef(projectId, 'f' * 64, 'open', '同期とバックアップを分けるにはどうする？'),
      )?.key,
      questionKey,
    );
    expect(
      r.prerequisiteState(ItemAfterRef(projectId, 'e' * 64, 'open', '別の本文')),
      PrerequisiteState.missing,
    );
    expect(
      blockSettled([PrerequisiteState.missing, PrerequisiteState.done]),
      isTrue,
    );

    // 形の合わないafterは項目一覧ごと読めない（本体の検査と同じ）。
    for (final bad in [
      {'id': 'BLK-x', 'items': []},
      {
        'id': blockId,
        'items': [
          {'project_id': projectId, 'item_key': openKey, 'section': 'open'},
        ],
      },
      {
        'id': blockId,
        'items': List.filled(4, {
          'project_id': projectId,
          'item_key': openKey,
          'section': 'open',
          'text': 'a',
        }),
      },
    ]) {
      final path = '90_system/now-items/$projectId.json',
          items = jsonDecode(fixtureFiles()[path]!) as Map<String, dynamic>;
      ((items['items'] as List)[0] as Map)['after'] = bad;
      final broken = HubRepository(
        fixture({...fixtureFiles(), path: jsonEncode(items)}),
      );
      expect(broken.warnings.join('\n'), contains(path), reason: '$bad');
    }

    // 締めの記録: 日ごとに最後の締め、消したひとことは出さない、新しく締めると前のひとことは出さない。
    files = withDayClose(
      fixtureFiles(),
      'DAY-01KAXQZ0000000000000000001',
      '2026-11-23',
      '見積もりの返事を確かめる\n発注は午後',
    );
    r = HubRepository(fixture(files));
    expect(r.currentDayNote?.note, '見積もりの返事を確かめる\n発注は午後');
    expect(r.dayCloseOn('2026-11-23')?.id, 'DAY-01KAXQZ0000000000000000001');
    final redone = withDayClose(
      files,
      'DAY-01KAXQZ0000000000000000002',
      '2026-11-23',
      null,
    );
    expect(HubRepository(fixture(redone)).currentDayNote, isNull);
    expect(HubRepository(fixture(redone)).dayCloses, hasLength(1));
    final dismissed = withDayClose(
      fixtureFiles(),
      'DAY-01KAXQZ0000000000000000001',
      '2026-11-23',
      'メモ',
      dismissedBy: 'DAY-01KAXQZ0000000000000000003',
    );
    expect(HubRepository(fixture(dismissed)).currentDayNote, isNull);
    // 4行のひとことは本体の検査に合わないので、記録の不正として示す。
    final tooLong = withDayClose(
      fixtureFiles(),
      'DAY-01KAXQZ0000000000000000004',
      '2026-11-23',
      '1\n2\n3\n4',
    );
    expect(
      HubRepository(fixture(tooLong)).warnings.join('\n'),
      contains('DAY-01KAXQZ0000000000000000004'),
    );

    expect(normalizeDayNote('  \r\n  明日は\t\r\n\r\n'), '  明日は');
    expect(normalizeDayNote('\n \n'), isNull);
    expect(validDayNote('あ' * 300), isTrue);
    expect(validDayNote('あ' * 301), isFalse);
    expect(validDayNote('1\n2\n3'), isTrue);
    expect(validDayNote('1\n2\n3\n4'), isFalse);
    expect(validDayNote('タブ\tは不可'), isFalse);
    expect(validDayNote('行 区切り'), isFalse);
  });

  group('依頼の保存と、固定参照の本体での受付', () {
    late TempAccess access;
    setUp(() async {
      access = TempAccess();
      await access.init();
    });
    tearDown(() => access.directory.delete(recursive: true));

    test('先に済ませることの依頼を本体が受け付け、項目一覧とNOWに反映する', () async {
      final service = CaptureService(access, location),
          files = fixtureFiles(),
          repo = HubRepository(fixture(files)),
          item = repo.projects[projectId]!.nowItems[0],
          open = repo.projects[projectId]!.nowItems[1];
      for (final bad in [
        <ItemAfterRef>[],
        [ItemAfterRef(projectId, item.key, 'next', item.text)],
        List.filled(4, ItemAfterRef(projectId, open.key, 'open', open.text)),
        [
          ItemAfterRef(projectId, open.key, 'open', open.text),
          ItemAfterRef(projectId, open.key, 'open', open.text),
        ],
      ]) {
        await expectLater(
          service.saveItemBlocks(
            'b1111111-2222-4333-8444-555555555555',
            projectId,
            item,
            bad,
          ),
          throwsFormatException,
          reason: '$bad',
        );
      }
      // プロジェクト未定の項目には付けられない。外すのは付いている項目だけ。
      await expectLater(
        service.saveItemBlocks(
          'b1111111-2222-4333-8444-555555555555',
          unassignedScope,
          item,
          [ItemAfterRef(projectId, open.key, 'open', open.text)],
        ),
        throwsFormatException,
      );
      await expectLater(
        service.saveItemBlocks(
          'b1111111-2222-4333-8444-555555555555',
          projectId,
          item,
          null,
        ),
        throwsFormatException,
      );
      final saved = await service.saveItemBlocks(
        'b1111111-2222-4333-8444-555555555555',
        projectId,
        item,
        [ItemAfterRef(projectId, open.key, 'open', open.text)],
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(parseMarkdown(raw).meta['after'], [
        {'project_id': projectId, 'item_key': open.key},
      ]);
      final waiting = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(waiting.blocksRequestIdFor(item.key), saved.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('先に済ませることの依頼（1件）'),
      );
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'blk'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final blocked = synced.projects[projectId]!.nowItems.firstWhere(
        (i) => i.key == item.key,
      );
      expect(blocked.after!.items.single.itemKey, open.key);
      expect(blocked.after!.items.single.text, open.text);
      expect(synced.blocksRequestIdFor(item.key), isNull);
      expect(synced.latestBlocksIdFor(item.key), startsWith('BLK-'));
      expect(
        synced.projects[projectId]!.sections['next']!.single.text,
        contains('先に済ませること 1件'),
      );
      // 先の項目からは、この項目を待っている項目として、互いに待つ選択を出さない。
      expect(HubController.waitersOf(synced, open.key), {item.key});
      expect(
        HubController.prerequisiteChoices(
          synced,
          projectId,
          open,
        ).map((c) => c.$2.key),
        isNot(contains(item.key)),
      );
    });

    test('1日の締めと、ひとことを消す依頼を本体が受け付ける', () async {
      final service = CaptureService(access, location),
          today = hubToday();
      await expectLater(
        service.saveDayClose(
          'c1111111-2222-4333-8444-555555555555',
          today,
          '1\n2\n3\n4',
        ),
        throwsFormatException,
      );
      final closed = await service.saveDayClose(
        'c1111111-2222-4333-8444-555555555555',
        today,
        '\n明日は見積もりの返事から  \n発注は午後\n\n',
      );
      final raw = (await access.readRequest(location, closed.requestId))!;
      expect(parseMarkdown(raw).body.trim(), '明日は見積もりの返事から\n発注は午後');
      final waiting = HubRepository(
        fixture({...fixtureFiles(), 'Input/${closed.requestId}.md': raw}),
      );
      expect(waiting.dayCloseRequestId, closed.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == closed.requestId).title,
        '1日の締め（$today）: 明日は見積もりの返事から / 発注は午後',
      );
      final after = await protocol(
        access,
        closed.requestId,
        'assets/sample.json',
        'day',
      );
      final synced = HubRepository(fixture(after));
      expect(synced.warnings, isEmpty);
      expect(synced.dayCloseRequestId, isNull);
      final note = synced.currentDayNote!;
      expect((note.on, note.note), (today, '明日は見積もりの返事から\n発注は午後'));
      expect(
        synced.intake.firstWhere((i) => i.id == closed.requestId).detail,
        '締めをMac miniが記録しました。',
      );

      // 受け付けた後の状態をfixtureにして、ひとことを消す依頼を確かめる。
      final fixturePath = '${access.directory.path}/after-close.json';
      await File(fixturePath).writeAsString(
        jsonEncode({
          for (final e in after.entries)
            if (!e.key.startsWith('Input/') &&
                !e.key.startsWith('90_system/intake/'))
              e.key: e.value,
        }),
      );
      final dismissed = await service.saveDayDismiss(
        'c2111111-2222-4333-8444-555555555555',
        note.id,
      );
      final cleared = HubRepository(
        fixture(await protocol(access, dismissed.requestId, fixturePath, 'dd')),
      );
      expect(cleared.currentDayNote, isNull);
      expect(cleared.dayCloses.single.id, note.id);
    });

    test('取り下げは自分が保存したままの依頼だけを消し、同じ操作IDで保存し直さない', () async {
      final service = CaptureService(access, location);
      const op = 'e1111111-2222-4333-8444-555555555555';
      final saved = await service.save(
        const CaptureDraft(operationId: op, text: '書き間違えたメモ'),
      );
      expect(saved.saved, isTrue);
      expect(
        await service.journalRequests(),
        containsPair(saved.requestId, op),
      );
      expect(
        await service.withdraw(op, '書き間違えたメモ'),
        'withdrawn',
      );
      expect(await access.request(location, saved.requestId).exists(), isFalse);
      final list = await service.withdrawn();
      expect(list.single.requestId, saved.requestId);
      expect(list.single.title, '書き間違えたメモ');
      // 同じ操作IDで保存し直したり、保存を確かめ直したりしない（消したファイルを書き直さない）。
      await expectLater(
        service.save(
          const CaptureDraft(operationId: op, text: '書き間違えたメモ'),
        ),
        throwsStateError,
      );
      await expectLater(service.confirm(op), throwsStateError);
      expect(await service.pending(), isEmpty);
      // 別のVaultの一覧には出さない。
      expect(
        await CaptureService(
          access,
          const VaultLocation('two', '別'),
        ).withdrawn(),
        isEmpty,
      );

      // 保存した後に書き換わったファイルは消さない。
      const op2 = 'e2111111-2222-4333-8444-555555555555';
      final other = await service.save(
        const CaptureDraft(operationId: op2, text: '別のメモ'),
      );
      await access.request(location, other.requestId).writeAsString('変更');
      await expectLater(service.withdraw(op2, '別のメモ'), throwsStateError);
      expect(await access.request(location, other.requestId).exists(), isTrue);
      expect((await service.withdrawn()).map((w) => w.requestId), [
        saved.requestId,
      ]);
    });
  });

  test('取り下げは受付前の依頼だけに出し、受付の記録が後から届けば間に合わなかったと示す', () async {
    final access = UIAccess();
    await access.init();
    addTearDown(() => access.directory.delete(recursive: true));
    final c = HubController(access, sampleLoader: () async => fixtureFiles());
    addTearDown(c.dispose);
    await c.useSample();
    final saved = await c.save(
      const CaptureDraft(
        operationId: 'f1111111-2222-4333-8444-555555555555',
        text: '取り下げるメモ',
      ),
    );
    final raw = (await access.readRequest(c.location!, saved.requestId))!;
    final input = {...fixtureFiles(), 'Input/${saved.requestId}.md': raw};
    access.current = fixture(input);
    await c.reload();
    final status = c.repository!.intake.firstWhere(
      (s) => s.id == saved.requestId,
    );
    expect(c.canWithdraw(status), isTrue);
    // 受付の記録が同期されてきた依頼は、取り下げない。
    access.current = fixture({
      ...input,
      '90_system/intake/${saved.requestId}.json': jsonEncode({
        'schema_version': 1,
        'request_id': saved.requestId,
        'path': 'Input/${saved.requestId}.md',
        'operation': 'capture',
        'request_hash': digest(raw),
        'status': 'accepted',
        'accepted_at': '2026-11-24T00:00:00Z',
        'result': {'inputId': 'IN-01KAXQZ0000000000000000000', 'deduped': false},
      }),
    });
    await expectLater(c.withdrawRequest(saved.requestId), throwsStateError);
    expect(await access.readRequest(c.location!, saved.requestId), raw);
    access.current = fixture(input);
    await c.reload();
    await c.withdrawRequest(saved.requestId);
    expect(await access.readRequest(c.location!, saved.requestId), isNull);
    expect(c.withdrawnRequests.single.requestId, saved.requestId);
  });

  testWidgets('先に済ませることを選び、先待ち・動けるようになった項目に分けて示す', (tester) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final c = HubController(access, sampleLoader: () async => fixtureFiles());
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    access.current = fixture();
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    final tag = nextKey.substring(0, 12);
    await openMore(tester, tag);
    await tester.tap(find.byKey(Key('blocks-$tag')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('blocks-dialog')), findsOneWidget);
    // 自分自身は選べない。
    expect(find.byKey(Key('blocks-choice-$tag')), findsNothing);
    await tester.enterText(find.byKey(const Key('blocks-search')), 'Discord');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('blocks-choice-${openKey.substring(0, 12)}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('blocks-submit')));
    await tester.pumpAndSettle();
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect(meta['operation'], 'item-blocks');
    expect(meta['after'], [
      {'project_id': projectId, 'item_key': openKey},
    ]);

    // 反映後: 先の項目が残っている間は先待ち、片付くと動けるようになった項目に出る。
    access.requests.clear();
    final blocked = withAfter(fixtureFiles(), 0, [(projectId, openKey)]);
    access.current = fixture(blocked);
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('next-blocked')), findsOneWidget);
    expect(find.byKey(Key('after-note-$tag')), findsOneWidget);
    expect(find.textContaining('（AI Context Hub・残っている）'), findsOneWidget);
    access.current = fixture(withResolved(blocked, openKey));
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('next-blocked')), findsNothing);
    expect(find.byKey(const Key('next-ready')), findsOneWidget);
    expect(find.text('先に済ませることが片付きました。取りかかれます。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-home')).last);
    await tester.pumpAndSettle();
    expect(find.byKey(Key('home-ready-$tag')), findsOneWidget);

    // 対応前の本体では、先に済ませることの操作を出さない。
    access.current = fixture(withoutNewFeatures(fixtureFiles()));
    await c.reload();
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    await openMore(tester, tag);
    expect(find.byKey(Key('blocks-$tag')), findsNothing);
  });

  testWidgets('今日を締めてひとことを残し、ホームの先頭に出たひとことを消せる', (tester) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final c = HubController(access, sampleLoader: () async => fixtureFiles());
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final today = hubToday();
    access.current = fixture(withResolved(fixtureFiles(), openKey));
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    // 今日完了にした項目を並べ（本体の記録の時刻が今日のときだけ）、ひとことを書いて締める。
    await tester.tap(find.byKey(const Key('home-day-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day-close-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('day-close-note')),
      '1\n2\n3\n4',
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('day-close-submit'))).onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('day-close-note')),
      '見積もりの返事から始める',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('day-close-submit')));
    await tester.pumpAndSettle();
    final close = parseMarkdown(access.requests.values.single);
    expect((close.meta['operation'], close.meta['action'], close.meta['on']), (
      'day-close',
      'close',
      today,
    ));
    expect(close.body.trim(), '見積もりの返事から始める');

    // 反映後: ひとことをホームの先頭に出し、消す依頼を送れる。
    access.requests.clear();
    access.current = fixture(
      withDayClose(
        fixtureFiles(),
        'DAY-01KAXQZ0000000000000000001',
        today,
        '見積もりの返事から始める',
      ),
    );
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-day-note')), findsOneWidget);
    expect(find.text('前回の締め（$today・今日）'), findsOneWidget);
    expect(find.text('今日の締めを書き直す'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-day-note-dismiss')));
    await tester.pumpAndSettle();
    final dismiss = parseMarkdown(access.requests.values.single).meta;
    expect((dismiss['operation'], dismiss['action'], dismiss['close_id']), (
      'day-close',
      'dismiss',
      'DAY-01KAXQZ0000000000000000001',
    ));
  });
}
