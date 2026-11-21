import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/preferences.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/templates.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'next_actions_test.dart' show multiProjectFiles;
import 'fixtures.dart';

/// 本体が書く形で、項目一覧の項目に繰り返しの付いた期日を付ける。
Map<String, String> withRepeat(
  Map<String, String> files,
  int index, {
  String due = '2026-11-23',
  Object? repeat = const {'unit': 'week', 'every': 1},
}) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  item['schedule'] = {
    'id': 'SCH-01M7AAAAAAAAAAAAAAAAAAAA${index.toString().padLeft(2, '0')}',
    'due': due,
    'review_after': null,
    'repeat': repeat,
  };
  return {...files, path: jsonEncode(items)};
}

/// 本体の対応表（`intake-features.json`）を書き換える。nullなら対応表のない古い本体。
/// [features]は、新しい依頼のうち受け付けるもの（item-repeat・item-occurrence・ask・client-preferences）。
Map<String, String> withFeatures(
  Map<String, String> files,
  List<String>? features,
) {
  final next = {...files}..remove(intakeFeaturesPath);
  if (features != null) {
    next[intakeFeaturesPath] = jsonEncode({
      'schema_version': 1,
      'operations': [
        'capture',
        'item-schedule',
        for (final f in features)
          if (f != 'item-repeat') f,
      ],
      'capture_fields': ['happened_on'],
      'item_schedule_fields': [if (features.contains('item-repeat')) 'repeat'],
      'ask': {'enabled': features.contains('ask'), 'max_question_chars': 500},
    });
  }
  return next;
}

String preferencesFile(Map<String, Map<String, Object?>> groups) =>
    jsonEncode({'schema_version': 1, 'groups': groups});

void main() {
  test('項目一覧の繰り返しと本体の対応表を読み、不正な繰り返しの一覧は使わない', () {
    final repo = HubRepository(fixture(withRepeat(fixtureFiles(), 0)));
    final item = repo.projects[projectId]!.nowItems.first;
    expect(
      (item.due, item.repeat?.label, item.repeating),
      ('2026-11-23', '毎週', true),
    );
    expect(const RepeatRule('month', 3).label, '3か月ごと');
    expect(const RepeatRule('day', 1).label, '毎日');
    // 生成したfixtureの本体は、新しい依頼をすべて受け付ける。
    expect(repo.intakeFeatures.repeat, isTrue);
    expect(repo.intakeFeatures.occurrence, isTrue);
    expect(repo.intakeFeatures.ask, isTrue);
    expect(repo.intakeFeatures.preferences, isTrue);
    // 対応表のない古い本体では、どれも使わない。
    final old = HubRepository(fixture(withFeatures(fixtureFiles(), null)));
    expect(old.intakeFeatures.repeat || old.intakeFeatures.ask, isFalse);
    expect(old.warnings, isEmpty);
    for (final bad in [
      {'unit': 'year', 'every': 1},
      {'unit': 'week', 'every': 13},
      {'unit': 'week', 'every': 1, 'extra': true},
    ]) {
      final broken = HubRepository(
        fixture(withRepeat(fixtureFiles(), 0, repeat: bad)),
      );
      expect(broken.projects[projectId]!.nowItems, isEmpty, reason: '$bad');
      expect(broken.warnings, isNotEmpty);
    }
  });

  test('Dartの繰り返しと今回の完了の依頼を本体が受理し、次の回の期日が届く', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          item = HubRepository(
            fixture(files),
          ).projects[projectId]!.nowItems.first;
      final service = CaptureService(access, location);
      // 繰り返しは期日がなければ付けられない。
      await expectLater(
        service.saveItemSchedule(
          '81111111-2222-4333-8444-555555555555',
          projectId,
          item,
          null,
          '2026-11-20',
          withRepeat: true,
          repeat: const RepeatRule('week', 1),
        ),
        throwsFormatException,
      );
      final saved = await service.saveItemSchedule(
        '81111111-2222-4333-8444-555555555555',
        projectId,
        item,
        '2026-11-16',
        null,
        withRepeat: true,
        repeat: const RepeatRule('week', 1),
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(parseMarkdown(raw).meta['repeat'], {'unit': 'week', 'every': 1});
      expect(
        HubRepository(
          fixture({...files, 'Input/${saved.requestId}.md': raw}),
        ).intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('日付の依頼（期日 2026-11-16・毎週）'),
      );
      final scheduled = HubRepository(
        fixture(
          await protocol(
            access,
            saved.requestId,
            'assets/sample.json',
            'repeat-one',
          ),
        ),
      );
      expect(scheduled.warnings, isEmpty);
      final now = scheduled.projects[projectId]!.nowItems.firstWhere(
        (i) => i.key == item.key,
      );
      expect(
        (now.due, now.repeat),
        ('2026-11-16', const RepeatRule('week', 1)),
      );
      expect(
        scheduled.projects[projectId]!.sections['next']!.single.text,
        contains('期日 2026-11-16（毎週）'),
      );

      final done = await service.saveItemOccurrence(
        '91111111-2222-4333-8444-555555555555',
        projectId,
        now,
        'done',
      );
      final doneRaw = (await access.readRequest(location, done.requestId))!;
      expect(
        parseMarkdown(doneRaw).meta,
        allOf(
          containsPair('operation', 'item-occurrence'),
          containsPair('action', 'done'),
          containsPair('due', '2026-11-16'),
        ),
      );
      final previous = Map<String, String>.from(
        jsonDecode(
              await File(
                '${access.directory.path}/repeat-one.json',
              ).readAsString(),
            )
            as Map,
      );
      final waiting = HubRepository(
        fixture({...previous, 'Input/${done.requestId}.md': doneRaw}),
      );
      expect(waiting.scheduleRequestIdFor(item.key), done.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == done.requestId).title,
        startsWith('定例の「今回を完了」（期日 2026-11-16）'),
      );
      final synced = HubRepository(
        fixture(
          await protocol(
            access,
            done.requestId,
            '${access.directory.path}/repeat-one.json',
            'repeat-two',
          ),
        ),
      );
      expect(synced.warnings, isEmpty);
      final next = synced.projects[projectId]!.nowItems.firstWhere(
        (i) => i.key == item.key,
      );
      expect(next.resolved, isFalse);
      expect(next.due!.compareTo('2026-11-16'), greaterThan(0));
      expect(next.repeat, const RepeatRule('week', 1));
      expect(synced.scheduleRequestIdFor(item.key), isNull);
      expect(
        synced.intake.firstWhere((i) => i.id == done.requestId).detail,
        '定例の回をMiniが反映しました。次の期日は ${next.due} です。',
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('Dartの問いを本体が受理して答え、答えと根拠を問いに結び付けて読む', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      await expectLater(
        service.saveAsk('a1111111-2222-4333-8444-555555555555', '  ', null),
        throwsFormatException,
      );
      await expectLater(
        service.saveAsk(
          'a1111111-2222-4333-8444-555555555555',
          'あ' * (askQuestionChars + 1),
          null,
        ),
        throwsFormatException,
      );
      final saved = await service.saveAsk(
        'a1111111-2222-4333-8444-555555555555',
        'Discordの通知はどう決めた？',
        projectId,
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      final files = fixtureFiles();
      final waiting = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(waiting.asks.single.question, 'Discordの通知はどう決めた？');
      expect(waiting.asks.single.request?.state, 'waiting');
      expect(waiting.asks.single.answer, isNull);
      expect(waiting.intake.single.title, '記録に聞く: Discordの通知はどう決めた？');
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'ask'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final thread = synced.asks.single;
      expect(thread.request?.state, 'accepted');
      expect(thread.answer, isNotNull);
      expect(thread.answer!.pending, isFalse);
      expect(thread.answer!.project, projectId);
      // 答えの根拠は、届いている記録へたどれる。
      for (final s in thread.answer!.sentences) {
        for (final e in s.evidence) {
          expect(synced.inputRecord(e.inputId), isNotNull);
        }
      }
      expect(thread.request!.detail, askStatusLabels[thread.answer!.status]);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('答えの記録の形式が合わなければ使わず、問題として示す', () {
    const path = '90_system/answers/ASK-01M7AAAAAAAAAAAAAAAAAAAA00.json';
    Map<String, Object?> record([Map<String, Object?> extra = const {}]) => {
      'schema_version': 1,
      'id': 'ASK-01M7AAAAAAAAAAAAAAAAAAAA00',
      'status': 'answered',
      'question': 'バックアップは？',
      'project': null,
      'source': 'cli',
      'asked_at': '2026-11-20T00:00:00.000Z',
      'attempts': 1,
      'last_attempt_at': '2026-11-20T00:00:01.000Z',
      'answered_at': '2026-11-20T00:00:02.000Z',
      'sentences': [
        {
          'text': '週1回まとめて取ります。',
          'evidence': [
            {'input_id': inputId, 'quote': '週1回'},
          ],
        },
      ],
      'candidates': [
        {
          'input_id': inputId,
          'root_id': inputId,
          'occurred_at': '2026-09-14T00:00:00Z',
          'kind': 'work-summary',
        },
      ],
      'dropped': 0,
      'model': 'mock',
      'error': null,
      ...extra,
    };
    final ok = HubRepository(
      fixture({...fixtureFiles(), path: jsonEncode(record())}),
    );
    expect(ok.warnings, isEmpty);
    // CLIから聞いた問いの答えも並べる。
    expect(
      ok.asks.single.answer?.sentences.single.evidence.single.inputId,
      inputId,
    );
    expect(ok.asks.single.request, isNull);
    for (final bad in [
      {'status': 'done'},
      {
        'sentences': [
          {'text': '根拠なし', 'evidence': []},
        ],
      },
      {'id': 'ASK-01M7AAAAAAAAAAAAAAAAAAAA01'},
    ]) {
      final broken = HubRepository(
        fixture({...fixtureFiles(), path: jsonEncode(record(bad))}),
      );
      expect(broken.asks, isEmpty, reason: '$bad');
      expect(broken.problemPaths, contains(path));
    }
  });

  test('Dartの好みの依頼を本体が受理し、まとまりごとに記録したものを読む', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      final at = DateTime.utc(2026, 11, 21, 1);
      final payload = encodePreferencesPayload('app-mac', {
        'pins': (
          at: at,
          value: {
            'ids': [projectId],
          },
        ),
        'templates': (
          at: at,
          value: {
            'items': [
              {
                'id': 'default-meeting',
                'name': '会議',
                'body': '## 決まったこと\n',
                'project': projectId,
              },
            ],
          },
        ),
        'basket': (at: at, value: {'max_chars': 12000}),
      });
      expect(preferenceGroupsOf(payload), ['pins', 'templates', 'basket']);
      expect(preferenceGroupsOf(payload.replaceFirst('12000', '5000')), isNull);
      await expectLater(
        service.savePreferences('b1111111-2222-4333-8444-555555555555', '{}'),
        throwsFormatException,
      );
      final saved = await service.savePreferences(
        'b1111111-2222-4333-8444-555555555555',
        payload,
      );
      final synced = HubRepository(
        fixture(
          await protocol(
            access,
            saved.requestId,
            'assets/sample.json',
            'preferences',
          ),
        ),
      );
      expect(synced.warnings, isEmpty);
      expect(synced.sharedPreferences.keys, ['pins', 'templates', 'basket']);
      expect(pinsValue(synced.sharedPreferences['pins']!.value), [projectId]);
      expect(
        templatesValue(
          synced.sharedPreferences['templates']!.value,
        )!.single.project,
        projectId,
      );
      expect(basketValue(synced.sharedPreferences['basket']!.value), 12000);
      expect(synced.sharedPreferences['pins']!.updatedAt, at);
      expect(
        synced.intake.single.detail,
        'Miniが記録しました（ピン留めと並び順・メモのひな形・文脈かごの上限）。',
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('好みをそろえると、Vaultの新しい好みを取り込み、この端末の変更を送る', () async {
    final access = MemoryUIAccess();
    await access.init();
    final files = multiProjectFiles();
    final older = DateTime.utc(2026, 11, 20, 1).toIso8601String();
    final shared = preferencesFile({
      'pins': {
        'updated_at': older,
        'device': 'app-android',
        'request_id': 'REQ-${'a' * 32}',
        'value': {
          'ids': ['side-app'],
        },
      },
    });
    access.current = fixture({...files, clientPreferencesPath: shared});
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    expect(c.preferenceSyncSupported, isTrue);
    expect(c.preferenceSyncEnabled, isFalse);
    await c.setPinned('context-hub', true);
    // そろえる前の変更は送らない。
    expect(access.requests, isEmpty);

    await c.enablePreferenceSync(useVault: true);
    expect(c.preferenceSyncEnabled, isTrue);
    expect(c.pinnedProjectIds, ['side-app']);
    // Vaultにないまとまり（ひな形・かごの上限）は、この端末のものを、まとまりごとに送る。
    final first = access.requests.values.map(parseMarkdown).toList();
    expect(first.map((d) => d.meta['operation']).toSet(), {
      'client-preferences',
    });
    expect(first.map((d) => preferenceGroupsOf(d.body)).toSet(), {
      ['templates'],
      ['basket'],
    });

    await c.setBasketLimit(30000);
    await c.sendPreferences();
    final second = access.requests.values
        .map(parseMarkdown)
        .where((d) => d.body.contains('30000'))
        .single;
    expect(preferenceGroupsOf(second.body), ['basket']);

    // ほかの端末の新しいピン留めは、再読込のときに取り込む。古いものは取り込まない。
    final newer = DateTime.now().toUtc().add(const Duration(minutes: 1));
    access.current = fixture({
      ...files,
      clientPreferencesPath: preferencesFile({
        'pins': {
          'updated_at': newer.toIso8601String(),
          'device': 'app-android',
          'request_id': 'REQ-${'b' * 32}',
          'value': {
            'ids': ['old-plan', 'context-hub'],
          },
        },
        'basket': {
          'updated_at': older,
          'device': 'app-android',
          'request_id': 'REQ-${'c' * 32}',
          'value': {'max_chars': 6000},
        },
      }),
    });
    await c.reload();
    expect(c.pinnedProjectIds, ['old-plan', 'context-hub']);
    expect(c.basket.maxChars, 30000);

    // ひな形に秘密情報らしい文字列があれば、ひな形は送らずに知らせる。
    await c.saveTemplates([
      const MemoTemplate(
        id: 'keys',
        name: '鍵',
        body: 'token: ghp_abcdefghijklmnopqrstuvwxyz0123456789',
      ),
    ]);
    final before = access.requests.length;
    await c.sendPreferences();
    expect(access.requests.length, before);
    expect(c.preferenceNotice, contains('秘密情報らしい文字列'));

    await c.disablePreferenceSync();
    expect(c.preferenceSyncEnabled, isFalse);
    final settings = jsonDecode(access.states['settings.json']!) as Map;
    expect((settings['preferenceSync'] as Map)['device'], startsWith('app-'));
  });

  testWidgets('定例の項目で今回を完了でき、日付の画面で繰り返しを選べる', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = withRepeat(fixtureFiles(), 0, due: '2026-11-16');
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
    expect(find.text('定例を終える'), findsOneWidget);
    // 日付の画面では、今の繰り返しが選ばれ、期日を外すと繰り返しは選べない。
    await tester.ensureVisible(find.byKey(Key('schedule-$short')));
    await tester.tap(find.byKey(Key('schedule-$short')));
    await tester.pumpAndSettle();
    ChoiceChip chip(String key) =>
        tester.widget<ChoiceChip>(find.byKey(Key('schedule-repeat-$key')));
    expect(chip('week-1').selected, isTrue);
    await tester.tap(find.byKey(const Key('schedule-repeat-month-1')));
    await tester.pumpAndSettle();
    expect(chip('month-1').selected, isTrue);
    await tester.tap(find.byKey(const Key('schedule-due-clear')));
    await tester.pumpAndSettle();
    expect(chip('none').selected, isTrue);
    expect(chip('week-1').onSelected, isNull);
    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();
    expect(access.requests, isEmpty);
    await tester.ensureVisible(find.byKey(Key('round-done-$short')));
    await tester.tap(find.byKey(Key('round-done-$short')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('round-done-confirm')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-occurrence');
    expect(request['due'], '2026-11-16');

    // 依頼が同期されて反映待ちの間は、日付と今回の操作を重ねて出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(Key('round-done-$short')), findsNothing);
    expect(find.text('日付を依頼済み（反映待ち）'), findsOneWidget);
  });

  testWidgets('記録に聞くで問いを送り、届いた答えの根拠から元の記録を開ける', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final record = {
      'schema_version': 1,
      'id': 'ASK-01M7AAAAAAAAAAAAAAAAAAAA00',
      'status': 'answered',
      'question': '前の問い',
      'project': null,
      'source': 'cli',
      'asked_at': '2026-11-20T00:00:00.000Z',
      'attempts': 1,
      'last_attempt_at': '2026-11-20T00:00:01.000Z',
      'answered_at': '2026-11-20T00:00:02.000Z',
      'sentences': [
        {
          'text': '週1回まとめて取ります。',
          'evidence': [
            {'input_id': inputId, 'quote': '引用した一節'},
          ],
        },
      ],
      'candidates': [],
      'dropped': 0,
      'model': 'mock',
      'error': null,
    };
    final files = {
      ...fixtureFiles(),
      '90_system/answers/ASK-01M7AAAAAAAAAAAAAAAAAAAA00.json': jsonEncode(
        record,
      ),
    };
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
    await tester.tap(find.byKey(const Key('nav-ask')).first);
    await tester.pumpAndSettle();
    expect(find.text('週1回まとめて取ります。'), findsOneWidget);
    expect(find.text('「引用した一節」'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ask-question')), '通知はどう決めた？');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ask-send')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single);
    expect(request.meta['operation'], 'ask');
    expect(request.body, '通知はどう決めた？');
    expect(request.meta.containsKey('project'), isFalse);
    await tester.ensureVisible(find.byKey(const Key('ask-evidence-$inputId')));
    await tester.tap(find.byKey(const Key('ask-evidence-$inputId')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Discord'), findsWidgets);

    // 本体が対応していなければ、聞く欄を出さない。
    access.current = fixture(withFeatures(files, const []));
    await c.reload();
    await tester.pumpAndSettle();
    expect(c.repository!.intakeFeatures.ask, isFalse);
  });

  test('好みの新しさは本体の記録の日時で決め、時計のずれた端末でも本人の変更とほかの端末の変更を失わない', () async {
    final access = MemoryUIAccess();
    await access.init();
    final files = multiProjectFiles();
    String entry(DateTime at, String request, List<String> ids) => jsonEncode({
      'updated_at': at.toUtc().toIso8601String(),
      'device': 'app-other',
      'request_id': request,
      'value': {'ids': ids},
    });
    Map<String, String> vaultWith(Map<String, Object?> groups) => {
      ...files,
      clientPreferencesPath: jsonEncode({
        'schema_version': 1,
        'groups': groups,
      }),
    };
    // ほかの端末の版は、この端末の時計より先の日時で記録されている（この端末の時計が遅れている）。
    final ahead = DateTime.now().toUtc().add(const Duration(minutes: 5));
    access.current = fixture(
      vaultWith({
        'pins': jsonDecode(entry(ahead, 'REQ-${'a' * 32}', ['side-app'])),
      }),
    );
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    await c.enablePreferenceSync(useVault: true);
    expect(c.pinnedProjectIds, ['side-app']);
    await c.setPinned('context-hub', true);
    await c.sendPreferences();
    final sent = access.requests.entries
        .map((e) => (id: e.key, doc: parseMarkdown(e.value)))
        .where((r) => preferenceGroupsOf(r.doc.body)?.contains('pins') ?? false)
        .single;
    final body = jsonDecode(sent.doc.body) as Map;
    final stamped = DateTime.parse(
      (body['groups'] as Map)['pins']['updated_at'] as String,
    );
    // 本人の変更は、知っている版より後の日時で送る（本体に古い変更として捨てられない）。
    expect(stamped.isAfter(ahead), isTrue);

    // 本体が丸めた日時で記録した自分の版は取り込み直さず、その後のほかの端末の変更は取り込む。
    final clamped = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final own = jsonDecode(entry(clamped, sent.id, ['side-app', 'context-hub']))
      ..['device'] =
          (jsonDecode(access.states['settings.json']!)
              as Map)['preferenceSync']['device'];
    access.current = fixture(vaultWith({'pins': own}));
    await c.reload();
    expect(c.pinnedProjectIds, ['side-app', 'context-hub']);
    final later = clamped.add(const Duration(minutes: 10));
    access.current = fixture(
      vaultWith({
        'pins': jsonDecode(entry(later, 'REQ-${'b' * 32}', ['old-plan'])),
      }),
    );
    await c.reload();
    expect(c.pinnedProjectIds, ['old-plan']);

    // ひな形が受付ファイルの上限を超えるときは、ひな形だけを送らずに知らせ、ほかのまとまりは送る。
    await c.saveTemplates([
      for (var i = 0; i < 12; i++)
        MemoTemplate(id: 't$i', name: 'ひな形$i', body: 'あ' * 1000),
    ]);
    await c.setBasketLimit(12000);
    final before = access.requests.length;
    await c.sendPreferences();
    final added = access.requests.values
        .skip(before)
        .map((r) => preferenceGroupsOf(parseMarkdown(r).body))
        .toList();
    expect(added, [
      ['basket'],
    ]);
    expect(c.preferenceNotice, contains('大きすぎる'));
  });

  test('保存期間を過ぎて片付けられた答えを、答え待ちとして示さない', () {
    const id = 'REQ-0123456789abcdef0123456789abcdef';
    const raw =
        '---\n{"schema_version":1,"request_id":"$id","source":"flutter-client/x","occurred_at":"2026-09-01T00:00:00.000Z","operation":"ask"}\n---\n前の問い';
    Map<String, String> files(String receivedAt) => {
      ...fixtureFiles(),
      'Input/$id.md': raw,
      '90_system/intake/$id.json': jsonEncode({
        'schema_version': 1,
        'request_id': id,
        'request_hash': digest(raw),
        'path': 'Input/$id.md',
        'operation': 'ask',
        'status': 'accepted',
        'received_at': receivedAt,
        'result': {'askId': 'ASK-01M7AAAAAAAAAAAAAAAAAAAA00', 'deduped': false},
      }),
    };
    // fixtureの読込は2026-10-30。
    final old = HubRepository(fixture(files('2026-09-01T00:00:00.000Z')));
    expect(old.warnings, isEmpty);
    expect(old.asks.single.request?.detail, contains('保存期間（30日）を過ぎた'));
    final fresh = HubRepository(fixture(files('2026-10-29T00:00:00.000Z')));
    expect(fresh.asks.single.request?.detail, contains('次の整理'));
  });
}
