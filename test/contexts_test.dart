import 'dart:convert';
import 'package:flutter/material.dart';
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

/// 本体が書く形で、項目一覧の項目に場所・道具の札を付ける。
Map<String, String> withContexts(
  Map<String, String> files,
  int index,
  List<Object?>? contexts,
) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  if (contexts == null) {
    item.remove('contexts');
  } else {
    item['contexts'] = contexts;
  }
  return {...files, path: jsonEncode(items)};
}

/// 本体が書く形で、好みの記録に札の語彙を置く。
Map<String, String> withVocabulary(
  Map<String, String> files,
  List<String> items, {
  String requestId = 'REQ-other',
}) => {
  ...files,
  clientPreferencesPath: jsonEncode({
    'schema_version': 1,
    'groups': {
      'contexts': {
        'updated_at': '2026-11-22T01:00:00.000Z',
        'device': 'mac',
        'request_id': requestId,
        'value': {'items': items},
      },
    },
  }),
};

/// 対応表から、札の対応を外す（対応前の本体）。
Map<String, String> withoutContexts(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (o != 'item-contexts') o,
  ];
  features.remove('item_contexts');
  features.remove('action_fields');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

void main() {
  test('対応表と項目一覧から札を読み、不正な札の一覧は使わない', () {
    final repo = HubRepository(
      fixture(withContexts(fixtureFiles(), 0, ['PC', '家'])),
    );
    expect(repo.intakeFeatures.contexts, isTrue);
    expect(repo.intakeFeatures.actionContexts, isTrue);
    expect(repo.intakeFeatures.actionEffort, isTrue);
    expect(repo.projects[projectId]!.nowItems.first.contexts, ['PC', '家']);
    expect(repo.projects[projectId]!.nowItems[1].contexts, isEmpty);
    // 語彙がなければ既定の例。項目に付いている札も、絞り込みの選択肢に足す。
    expect(repo.contextVocabulary, defaultContextVocabulary);
    expect(repo.contextTagsInUse, [...defaultContextVocabulary]);
    final extra = HubRepository(
      fixture(withContexts(fixtureFiles(), 0, ['図書館'])),
    );
    expect(extra.contextTagsInUse, [...defaultContextVocabulary, '図書館']);

    final old = HubRepository(fixture(withoutContexts(fixtureFiles())));
    expect(old.intakeFeatures.contexts, isFalse);
    expect(old.intakeFeatures.actionContexts, isFalse);

    for (final bad in [
      ['外 出'],
      ['家', '家'],
      <Object?>[1],
      <Object?>[],
    ]) {
      final broken = HubRepository(
        fixture(withContexts(fixtureFiles(), 0, bad)),
      );
      expect(broken.warnings, isNotEmpty, reason: '$bad');
    }
  });

  test('札の規則と絞り込みは本体と同じ', () {
    expect(validContextTag('元気なとき'), isTrue);
    for (final bad in ['', '外 出', '@家', '家・PC', 'a,b', '（家）', 'x' * 21]) {
      expect(validContextTag(bad), isFalse, reason: bad);
    }
    expect(validContextTags(['家', 'PC']), isTrue);
    expect(validContextTags([]), isFalse);
    expect(validContextTags(List.generate(9, (i) => 't$i')), isFalse);
    expect(contextFits(null, const []), isTrue);
    expect(contextFits('家', ['PC', '家']), isTrue);
    expect(contextFits('家', ['PC']), isFalse);
    expect(contextFits(contextFilterNone, const []), isTrue);
    expect(contextFits(contextFilterNone, ['PC']), isFalse);
    expect(contextsLabel(['家', 'PC']), '@家 @PC');
  });

  test('Vaultの語彙を読み、反映待ちの語彙の変更があればそれを使う', () {
    final files = withVocabulary(fixtureFiles(), ['家', '電話']);
    final repo = HubRepository(fixture(files));
    expect(repo.contextVocabulary, ['家', '電話']);
    expect(repo.contextVocabularyPending, isFalse);
    final payload = encodePreferencesPayload('android', {
      'contexts': (
        at: DateTime.utc(2026, 11, 22, 2),
        value: {
          'items': ['家', '電話', '元気なとき'],
        },
      ),
    });
    const id = 'REQ-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345';
    final request =
        '---\nschema_version: 1\nrequest_id: $id\nsource: flutter\noccurred_at: 2026-11-22T02:00:00Z\noperation: client-preferences\nconfirmed: true\n---\n$payload';
    final waiting = HubRepository(
      fixture({...files, 'Input/$id.md': request}),
    );
    expect(waiting.contextVocabulary, ['家', '電話', '元気なとき']);
    expect(waiting.contextVocabularyPending, isTrue);
    // 記録に載れば、記録の語彙を使う（反映待ちではない）。
    final synced = HubRepository(
      fixture({
        ...withVocabulary(files, ['家', '電話', '元気なとき'], requestId: id),
        'Input/$id.md': request,
      }),
    );
    expect(synced.contextVocabularyPending, isFalse);
    // 知らないまとまりがあっても、知っているまとまりは読む。
    final newer = jsonDecode(files[clientPreferencesPath]!) as Map;
    (newer['groups'] as Map)['future'] = {'x': 1};
    expect(
      HubRepository(
        fixture({...files, clientPreferencesPath: jsonEncode(newer)}),
      ).contextVocabulary,
      ['家', '電話'],
    );
  });

  test('Dartの札の依頼と、札を付けた行動の追加を本体が受理し、項目と現状に届く', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          item = HubRepository(
            fixture(files),
          ).projects[projectId]!.nowItems.first;
      final service = CaptureService(access, location);
      await expectLater(
        service.saveItemContexts(
          'c1111111-2222-4333-8444-555555555555',
          projectId,
          item,
          ['外 出'],
        ),
        throwsFormatException,
      );
      // 付いていない札は外せない。
      await expectLater(
        service.saveItemContexts(
          'c1111111-2222-4333-8444-555555555555',
          projectId,
          item,
          null,
        ),
        throwsFormatException,
      );
      final saved = await service.saveItemContexts(
        'c1111111-2222-4333-8444-555555555555',
        projectId,
        item,
        ['PC', '家'],
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(parseMarkdown(raw).meta['contexts'], ['PC', '家']);
      final waiting = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(waiting.contextsRequestIdFor(item.key), saved.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('場所・道具の札の依頼（@PC @家）'),
      );
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'ctx'),
        ),
      );
      expect(synced.warnings, isEmpty);
      expect(
        synced.projects[projectId]!.nowItems
            .firstWhere((i) => i.key == item.key)
            .contexts,
        ['PC', '家'],
      );
      expect(synced.contextsRequestIdFor(item.key), isNull);
      expect(synced.latestContextIdFor(item.key), startsWith('CTX-'));
      expect(
        synced.projects[projectId]!.sections['next']!.single.text,
        contains('@PC @家'),
      );
      expect(
        synced.projects[projectId]!.sections['next']!.single.itemKey,
        item.key,
      );

      // 行動の追加と一緒に手間の目安と札を付ける。
      final action = await service.saveAction(
        'a1111111-2222-4333-8444-555555555555',
        projectId,
        '見積もりを頼む',
        effort: 'quick',
        contexts: ['電話'],
      );
      final meta = parseMarkdown(
        (await access.readRequest(location, action.requestId))!,
      ).meta;
      expect(meta['effort'], 'quick');
      expect(meta['contexts'], ['電話']);
      final added = HubRepository(
        fixture(
          await protocol(
            access,
            action.requestId,
            'assets/sample.json',
            'act',
          ),
        ),
      );
      expect(added.warnings, isEmpty);
      final own = added.projects[projectId]!.nowItems.firstWhere(
        (i) => i.text == '見積もりを頼む',
      );
      expect(own.effort, 'quick');
      expect(own.contexts, ['電話']);

      // 札の語彙をVaultの好みとして送る。
      final payload = encodePreferencesPayload('android', {
        'contexts': (
          at: DateTime.utc(2026, 11, 22, 2),
          value: {
            'items': ['家', '外出先', '元気なとき'],
          },
        ),
      });
      final vocabulary = await service.savePreferences(
        'b1111111-2222-4333-8444-555555555555',
        payload,
      );
      final shared = HubRepository(
        fixture(
          await protocol(
            access,
            vocabulary.requestId,
            'assets/sample.json',
            'voc',
          ),
        ),
      );
      expect(shared.contextVocabulary, ['家', '外出先', '元気なとき']);
      expect(shared.contextVocabularyPending, isFalse);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('項目に札を付ける依頼をし、次の一手で札と札なしで絞り込める', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = withVocabulary(fixtureFiles(), ['家', 'PC']);
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
    await tester.tap(find.byKey(Key('contexts-$short')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('contexts-dialog')), findsOneWidget);
    // 札を選ぶまで依頼できない。選んだ札は語彙の並びで送る。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('contexts-submit')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('contexts-choice-PC')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('contexts-choice-家')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('contexts-submit')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-contexts');
    expect(request['contexts'], ['家', 'PC']);
    expect(request['item_key'], item.key);

    // 依頼が同期されて反映待ちの間は、札の操作を重ねて出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('札を依頼済み（反映待ち）'), findsOneWidget);
    await openMore(tester, short);
    expect(find.byKey(Key('contexts-$short')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 「次の一手」画面で、札の付いた項目だけ・札のない項目だけに絞り込める。語彙にない札も選択肢に出る。
    final reflected = withContexts(files, 0, ['家', '図書館']);
    access.current = fixture(reflected);
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    final line = c.repository!.projects[projectId]!.sections['next']!.single;
    expect(find.byKey(const Key('context-filter-図書館')), findsOneWidget);
    await tester.tap(find.byKey(const Key('context-filter-')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-filter-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('context-filter-PC')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-filter-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('context-filter-家')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-filter-empty')), findsNothing);
    expect(find.textContaining(line.text.split(' — ').first), findsWidgets);
    // 絞り込みを外すと、今と同じ並びに戻る。
    await tester.tap(find.byKey(const Key('context-filter-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-filter-empty')), findsNothing);

    // 札の一覧を編集すると、Vaultの好みとして依頼する。
    await tester.tap(find.byKey(const Key('context-vocabulary-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-vocabulary-dialog')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('vocabulary-input')), '外 出');
    await tester.tap(find.byKey(const Key('vocabulary-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining('空白'), findsWidgets);
    await tester.enterText(find.byKey(const Key('vocabulary-input')), '電話');
    await tester.tap(find.byKey(const Key('vocabulary-add')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('vocabulary-remove-PC')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('vocabulary-submit')));
    await tester.pumpAndSettle();
    final sent = access.requests.values
        .map(parseMarkdown)
        .firstWhere((d) => d.meta['operation'] == 'client-preferences');
    expect(
      ((jsonDecode(sent.body) as Map)['groups'] as Map)['contexts']['value'],
      {
        'items': ['家', '電話'],
      },
    );
  });

  testWidgets('次の一手を追加するときに、手間の目安と札を一緒に選べる', (tester) async {
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
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next-add-action')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('action-text')), '見積もりを頼む');
    await tester.tap(find.byKey(const Key('action-effort-quick')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('action-context-電話')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-submit')));
    await tester.pumpAndSettle();
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect(meta['kind'], 'action');
    expect(meta['effort'], 'quick');
    expect(meta['contexts'], ['電話']);

    // 対応前の本体には、札と目安の欄を出さない。
    access.current = fixture(withoutContexts(files));
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next-add-action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-context-電話')), findsNothing);
    expect(find.byKey(const Key('action-effort-quick')), findsNothing);
  });
}
