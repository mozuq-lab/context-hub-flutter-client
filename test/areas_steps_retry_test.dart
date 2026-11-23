import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/preferences.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'recurring_ask_preferences_test.dart' show openMore;
import 'fixtures.dart';

const plan = ['医療費の領収書を集める', 'ふるさと納税の受領証を探す', '提出する'];

/// 本体が書く形で、項目一覧の項目に手順を付ける。
Map<String, String> withSteps(
  Map<String, String> files,
  int index,
  Object? steps,
) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  if (steps == null) {
    item.remove('steps');
  } else {
    item['steps'] = steps;
  }
  return {...files, path: jsonEncode(items)};
}

/// project.mdのstatusの次の行に、領域（手で書いた値も）を足す。
Map<String, String> withArea(
  Map<String, String> files,
  String line, {
  String id = projectId,
}) {
  final path = '10_projects/$id/project.md';
  return {
    ...files,
    path: files[path]!.replaceFirst('status: active', 'status: active\n$line'),
  };
}

/// 2つ目の進行中のプロジェクトを足す（領域ごとのまとまりを確かめるため）。
Map<String, String> withSecondProject(Map<String, String> files) => {
  ...files,
  '10_projects/garden/project.md':
      '---\nid: garden\ntitle: 家庭菜園\naliases: []\nkeywords: []\nstatus: active\narea: 家\n---\n# 家庭菜園\n',
};

/// 整理済みのメモの処理記録を、本体が書く形で失敗にする。
Map<String, String> withFailed(
  Map<String, String> files,
  String inputId, {
  int attempts = 1,
}) {
  final path = '90_system/receipts/$inputId.json',
      receipt = jsonDecode(files[path]!) as Map<String, dynamic>;
  return {
    ...files,
    path: jsonEncode({
      ...receipt,
      'status': 'failed',
      'attempts': attempts,
      'result': null,
      'writes': [],
      'error': 'モデルの応答を読めませんでした',
    }),
  };
}

/// 対応表から、領域・手順・やり直しの対応を外す（対応前の本体）。
Map<String, String> withoutNewFeatures(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (!['project-area', 'item-steps', 'organize-retry'].contains(o)) o,
  ];
  features.remove('project_areas');
  features.remove('item_steps');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

void main() {
  test('領域と手順の規則・並び・表示は本体と同じ', () {
    expect(validArea('仕事'), isTrue);
    for (final bad in [
      '',
      ' 家',
      '家 ',
      'a' * 21,
      '家\n庭',
      'P​C',
      noAreaLabel,
      'ガ',
    ]) {
      expect(validArea(bad), isFalse, reason: bad);
    }
    expect(normalizeArea(' ガ '), 'ガ');
    expect(validAreaVocabulary(['仕事', '家']), isTrue);
    expect(validAreaVocabulary(['仕事', '仕事']), isFalse);
    expect(
      validAreaVocabulary(List.generate(areaVocabularyMax + 1, (i) => 'a$i')),
      isFalse,
    );
    expect(orderAreas(['b', null, 'a', 'c'], ['c']), ['c', 'a', 'b', null]);
    // 語彙にない領域は、本体と同じく文字コードの順に並べる。
    expect(orderAreas(['家', 'apple', '仕事', 'Zoo', 'かぞく'], const []), [
      'Zoo',
      'apple',
      'かぞく',
      '仕事',
      '家',
    ]);

    expect(const ItemSteps(plan, 0).label, '手順 1/3: 医療費の領収書を集める');
    expect(const ItemSteps(plan, 3).label, '手順 3/3 済み・項目の完了を確かめる');
    expect(const ItemSteps(plan, 3).finished, isTrue);
    expect(ItemSteps.tryParse({'items': plan, 'done': 1}), const ItemSteps(plan, 1));
    for (final bad in [
      {'items': ['1つだけ'], 'done': 0},
      {'items': plan, 'done': 4},
      {'items': plan, 'done': -1},
      {'items': List.generate(11, (i) => '手順$i'), 'done': 0},
      {'items': [' 前に空白', '次'], 'done': 0},
      {'items': plan, 'done': 0, 'extra': 1},
    ]) {
      expect(ItemSteps.tryParse(bad), isNull, reason: '$bad');
    }
  });

  test('対応表・項目一覧の手順・project.mdの領域を読み、不正な値は本体と同じく扱う', () {
    final steps = {
      'id': 'STP-01KAXQZ0000000000000000000',
      'items': plan,
      'done': 1,
    };
    final repo = HubRepository(
      fixture(withArea(withSteps(fixtureFiles(), 0, steps), 'area: 仕事')),
    );
    expect(repo.warnings, isEmpty);
    expect(repo.intakeFeatures.areas, isTrue);
    expect(repo.intakeFeatures.steps, isTrue);
    expect(repo.intakeFeatures.organizeRetry, isTrue);
    expect(repo.intakeFeatures.areaLimits, (maxChars: 20, vocabularyMax: 12));
    expect(repo.intakeFeatures.stepLimits, (min: 2, max: 10, maxChars: 200));
    final item = repo.projects[projectId]!.nowItems.first;
    expect(item.steps, const ItemSteps(plan, 1));
    expect(itemRecordLabel(item), contains('手順 2/3: ふるさと納税の受領証を探す'));
    expect(repo.projects[projectId]!.area, '仕事');
    expect(repo.usesAreas, isTrue);
    expect(repo.areasInUse, ['仕事']);

    // 手で書いた規則に合わない領域は、定義を捨てずに領域なしとして読む。
    final hand = HubRepository(
      fixture(withArea(fixtureFiles(), 'area: [仕事, 家]')),
    );
    expect(hand.projects[projectId], isNotNull);
    expect(hand.projects[projectId]!.area, isNull);
    expect(hand.usesAreas, isFalse);

    // 項目一覧の不正な手順は、その一覧を読めないものとして示す。
    for (final bad in [
      {'items': plan, 'done': 1},
      {'id': 'STP-x', 'items': plan, 'done': 1},
      {
        'id': 'STP-01KAXQZ0000000000000000000',
        'items': ['1つ'],
        'done': 0,
      },
    ]) {
      expect(
        HubRepository(fixture(withSteps(fixtureFiles(), 0, bad))).warnings,
        isNotEmpty,
        reason: '$bad',
      );
    }

    final old = HubRepository(fixture(withoutNewFeatures(fixtureFiles())));
    expect(old.intakeFeatures.areas, isFalse);
    expect(old.intakeFeatures.steps, isFalse);
    expect(old.intakeFeatures.organizeRetry, isFalse);
  });

  test('領域の語彙をVaultの好みから読み、週次レビューで領域を見渡す', () {
    final files = {
      ...withSecondProject(withArea(fixtureFiles(), 'area: 仕事')),
      clientPreferencesPath: jsonEncode({
        'schema_version': 1,
        'groups': {
          'areas': {
            'updated_at': '2026-11-22T01:00:00.000Z',
            'device': 'mac',
            'request_id': 'REQ-other',
            'value': {
              'items': ['家', '仕事', '健康'],
            },
          },
        },
      }),
    };
    final repo = HubRepository(fixture(files));
    expect(repo.warnings, isEmpty);
    expect(repo.areaVocabulary, ['家', '仕事', '健康']);
    expect(repo.areasInUse, ['家', '仕事', '健康']);
    final rows = repo.areaOverview(DateTime.utc(2026, 11, 23));
    expect(rows.map((r) => r.area), ['家', '仕事']);
    expect(rows.first.active, 1);
    // 根拠のない進行中のプロジェクトだけの領域は、動いていない領域として示す。
    expect(rows.first.quiet, isTrue);
    expect(HubRepository(fixture(fixtureFiles())).areaVocabulary, isEmpty);
  });

  test('Dartの手順・領域・やり直しの依頼を本体が受理し、項目・定義・整理に届く', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          repo = HubRepository(fixture(files)),
          project = repo.projects[projectId]!,
          item = project.nowItems.first,
          open = project.nowItems.firstWhere((i) => i.section == 'open');
      final service = CaptureService(access, location);
      // 未解決・不正な手順・変わらない手順は送らない。
      for (final (target, steps) in [
        (open, const ItemSteps(plan, 0)),
        (item, const ItemSteps(['1つ'], 0)),
        (item, null),
      ]) {
        await expectLater(
          service.saveItemSteps(
            'd1111111-2222-4333-8444-555555555555',
            projectId,
            target,
            steps,
          ),
          throwsFormatException,
          reason: '$steps',
        );
      }
      final saved = await service.saveItemSteps(
        'd1111111-2222-4333-8444-555555555555',
        projectId,
        item,
        const ItemSteps(plan, 1),
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(parseMarkdown(raw).meta['steps'], {'items': plan, 'done': 1});
      expect(parseMarkdown(raw).meta['expected'], isNull);
      expect(parseMarkdown(raw).meta.containsKey('expected'), isTrue);
      final waiting = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(waiting.stepsRequestIdFor(item.key), saved.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('手順の依頼（3つのうち1つ済み）'),
      );
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'stp'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final stepped = synced.projects[projectId]!.nowItems.firstWhere(
        (i) => i.key == item.key,
      );
      expect(stepped.steps, const ItemSteps(plan, 1));
      expect(synced.stepsRequestIdFor(item.key), isNull);
      expect(synced.latestStepsIdFor(item.key), startsWith('STP-'));
      final line = synced.projects[projectId]!.sections['next']!.single;
      expect(line.text, contains('手順 2/3: ふるさと納税の受領証を探す'));
      expect(line.itemKey, item.key);

      // 領域。表示中の定義hashに結び付ける。
      await expectLater(
        service.saveProjectArea(
          'a1111111-2222-4333-8444-555555555555',
          project,
          noAreaLabel,
        ),
        throwsFormatException,
      );
      final area = await service.saveProjectArea(
        'a1111111-2222-4333-8444-555555555555',
        project,
        '仕事',
      );
      final areaRaw = (await access.readRequest(location, area.requestId))!;
      expect(parseMarkdown(areaRaw).meta['project_hash'], project.definitionHash);
      final pending = HubRepository(
        fixture({...files, 'Input/${area.requestId}.md': areaRaw}),
      );
      expect(pending.projectAreaRequestIdFor(projectId), area.requestId);
      final areaSynced = HubRepository(
        fixture(
          await protocol(access, area.requestId, 'assets/sample.json', 'area'),
        ),
      );
      expect(areaSynced.warnings, isEmpty);
      expect(areaSynced.projects[projectId]!.area, '仕事');
      expect(areaSynced.projectAreaRequestIdFor(projectId), isNull);
      expect(areaSynced.latestAreaChangeId(projectId), startsWith('PAREA-'));

      // 整理のやり直し。protocolが元のメモを失敗にしてから受け付ける。
      final failed = HubRepository(fixture(withFailed(files, item.inputId)));
      expect(failed.failedAttemptsFor(item.inputId), 1);
      expect(failed.organizeErrorFor(item.inputId), contains('応答'));
      final retry = await service.saveOrganizeRetry(
        'e1111111-2222-4333-8444-555555555555',
        item.inputId,
        1,
      );
      final retryRaw = (await access.readRequest(location, retry.requestId))!;
      final asked = HubRepository(
        fixture({
          ...withFailed(files, item.inputId),
          'Input/${retry.requestId}.md': retryRaw,
        }),
      );
      expect(asked.organizeRetryRequestIdFor(item.inputId), retry.requestId);
      expect(failed.organizeRetryable(item.inputId), isTrue);
      // 訂正を依頼中のメモは、訂正した後のメモが整理されるので、やり直しを頼まない（本体はsupersededで断る）。
      final correction = await service.saveCorrection(
        'f1111111-2222-4333-8444-555555555555',
        item.inputId,
        '訂正した本文',
      );
      final correcting = HubRepository(
        fixture({
          ...withFailed(files, item.inputId),
          'Input/${correction.requestId}.md': (await access.readRequest(
            location,
            correction.requestId,
          ))!,
        }),
      );
      expect(correcting.failedAttemptsFor(item.inputId), 1);
      expect(correcting.organizeRetryable(item.inputId), isFalse);
      final request = asked.intake.firstWhere((i) => i.id == retry.requestId);
      expect(request.title, startsWith('整理のやり直しの依頼'));
      expect(request.state, 'waiting');
      final retried = HubRepository(
        fixture(
          await protocol(access, retry.requestId, 'assets/sample.json', 'ort'),
        ),
      );
      expect(retried.warnings, isEmpty);
      expect(retried.failedAttemptsFor(item.inputId), isNull);
      expect(retried.organizeRetryRequestIdFor(item.inputId), isNull);
      expect(
        retried.intake.firstWhere((i) => i.id == retry.requestId).detail,
        'やり直した整理が終わりました。',
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('やり直しを本体が記録した後は、次の整理を待っていると示し、重ねて頼まない', () async {
    final access = MemoryUIAccess();
    await access.init();
    final item = HubRepository(
          fixture(fixtureFiles()),
        ).projects[projectId]!.nowItems.first,
        files = {
          ...withFailed(fixtureFiles(), item.inputId, attempts: 2),
          '90_system/organize-retries/ORT-01KAXQZ0000000000000000000.json':
              jsonEncode({
                'schema_version': 1,
                'id': 'ORT-01KAXQZ0000000000000000000',
                'input_id': item.inputId,
                'attempts': 2,
                'source': 'cli',
                'created_at': '2026-11-23T00:00:00Z',
              }),
        };
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    expect(c.repository!.organizeRetryQueued(item.inputId), isTrue);
    await expectLater(
      c.requestOrganizeRetry(item.inputId),
      throwsA(isA<StateError>()),
    );
    // 本人が見ていた手順と、読み直した今の手順が違えば送らない。
    await expectLater(
      c.requestItemSteps(
        projectId,
        item.key,
        const ItemSteps(plan, 1),
        seen: const ItemSteps(plan, 0),
      ),
      throwsA(isA<StateError>()),
    );
    // 試した後もまた失敗すれば（試行回数が増えれば）、もう一度頼める。
    access.current = fixture({
      ...files,
      ...withFailed(files, item.inputId, attempts: 3),
    });
    await c.reload();
    expect(c.repository!.organizeRetryQueued(item.inputId), isFalse);
    await c.requestOrganizeRetry(item.inputId);
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect((meta['operation'], meta['attempts']), ('organize-retry', 3));
  });

  testWidgets('次の一手を手順に分け、今の手順を終えた・1つ戻すを依頼できる', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
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
    expect(find.byKey(Key('steps-next-$short')), findsNothing);
    await openMore(tester, short);
    await tester.tap(find.byKey(Key('steps-$short')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('steps-dialog')), findsOneWidget);
    // 1つだけでは依頼できない。
    await tester.enterText(find.byKey(const Key('steps-input')), '1つだけ');
    await tester.pumpAndSettle();
    expect(find.textContaining('2つ以上'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('steps-submit'))).onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('steps-input')),
      '${plan.join('\n')}\n\n',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('「手順 1/3: 医療費の領収書を集める」'), findsOneWidget);
    await tester.tap(find.byKey(const Key('steps-submit')));
    await tester.pumpAndSettle();
    final sent = parseMarkdown(access.requests.values.single).meta;
    expect(sent['operation'], 'item-steps');
    expect(sent['steps'], {'items': plan, 'done': 0});
    expect(sent['expected'], isNull);

    // 反映待ちの間は、手順の操作を重ねて出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('手順を依頼済み（反映待ち）'), findsOneWidget);
    await openMore(tester, short);
    expect(find.byKey(Key('steps-$short')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 反映された後は、今の手順を終えた・1つ戻すを、見ていた手順を添えて送る。
    access.requests.clear();
    access.current = fixture(
      withSteps(files, 0, {
        'id': 'STP-01KAXQZ0000000000000000000',
        'items': plan,
        'done': 1,
      }),
    );
    await c.reload();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(Key('steps-next-$short')));
    await tester.tap(find.byKey(Key('steps-next-$short')));
    await tester.pumpAndSettle();
    final next = parseMarkdown(access.requests.values.single).meta;
    expect(next['steps'], {'items': plan, 'done': 2});
    expect(next['expected'], {'items': plan, 'done': 1});
    access.requests.clear();
    await openMore(tester, short);
    await tester.tap(find.byKey(Key('steps-back-$short')));
    await tester.pumpAndSettle();
    final back = parseMarkdown(access.requests.values.single).meta;
    expect(back['steps'], {'items': plan, 'done': 0});

    // 対応前の本体には、手順の操作を出さない。
    access.current = fixture(withoutNewFeatures(files));
    await c.reload();
    await tester.pumpAndSettle();
    await openMore(tester, short);
    expect(find.byKey(Key('steps-$short')), findsNothing);
  });

  testWidgets('プロジェクトに領域を付け、ホームで領域ごとにまとめて絞り込める', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = withSecondProject(fixtureFiles());
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
    // 領域を付けたプロジェクトがあれば、ホームは領域ごとにまとめ、領域なしは最後にする。
    expect(find.byKey(const Key('area-heading-家')), findsOneWidget);
    expect(find.byKey(const Key('area-heading-$noAreaLabel')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('area-heading-家'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('area-heading-$noAreaLabel'))).dy,
      ),
    );
    await tester.tap(find.byKey(const Key('area-filter-家')));
    await tester.pumpAndSettle();
    Finder card(String id) => find.byWidgetPredicate(
      (w) => w is InkWell && w.key == Key('project-$id'),
    );
    expect(card('garden'), findsOneWidget);
    expect(card(projectId), findsNothing);
    await tester.tap(find.byKey(const Key('area-filter-all')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('project-$projectId')).first);
    await tester.pumpAndSettle();
    expect(find.text('領域: 未設定'), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-area-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('area-dialog')), findsOneWidget);
    // 今のプロジェクトに付いている領域を選べる。
    await tester.tap(find.byKey(const Key('area-choice-家')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('area-input')), ' 仕事 ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('area-submit')));
    await tester.pumpAndSettle();
    final sent = parseMarkdown(access.requests.values.single).meta;
    expect(sent['operation'], 'project-area');
    expect(sent['area'], '仕事');
    expect(
      sent['project_hash'],
      c.repository!.projects[projectId]!.definitionHash,
    );

    // 反映待ちの間は、定義の操作を出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextButton>(find.byKey(const Key('project-area-edit'))).onPressed,
      isNull,
    );

    // 領域の一覧を編集すると、Vaultの好みとして依頼する。
    access.requests.clear();
    access.current = fixture(files);
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-area-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('area-vocabulary-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('area-vocabulary-input')),
      noAreaLabel,
    );
    await tester.tap(find.byKey(const Key('area-vocabulary-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining('使えません'), findsWidgets);
    for (final a in ['仕事', '家']) {
      await tester.enterText(find.byKey(const Key('area-vocabulary-input')), a);
      await tester.tap(find.byKey(const Key('area-vocabulary-add')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('area-vocabulary-submit')));
    await tester.pumpAndSettle();
    final pref = access.requests.values
        .map(parseMarkdown)
        .firstWhere((d) => d.meta['operation'] == 'client-preferences');
    expect(((jsonDecode(pref.body) as Map)['groups'] as Map)['areas']['value'], {
      'items': ['仕事', '家'],
    });
  });
}
