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
import 'package:context_hub_client/ui/views.dart' show RecordView;
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'recurring_ask_preferences_test.dart' show openMore;
import 'fixtures.dart';

/// 本体が書く形で、項目一覧の項目に手間の目安を付ける。
Map<String, String> withEffort(
  Map<String, String> files,
  int index,
  String? effort,
) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  if (effort == null) {
    item.remove('effort');
  } else {
    item['effort'] = effort;
  }
  return {...files, path: jsonEncode(items)};
}

/// 項目一覧の最初の項目の目安に、任意の値を書く（壊れた一覧）。
Map<String, String> withEffortValue(Map<String, String> files, Object value) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>;
  ((items['items'] as List).first as Map<String, dynamic>)['effort'] = value;
  return {...files, path: jsonEncode(items)};
}

/// 対応表から、続きと手間の目安の対応を外す（対応前の本体）。
Map<String, String> withoutNewFeatures(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (o != 'item-effort') o,
  ];
  features['capture_fields'] = ['happened_on'];
  features.remove('item_efforts');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

void main() {
  test('対応表から続きと手間の目安の対応を読み、項目一覧の目安を読む', () {
    final repo = HubRepository(fixture(withEffort(fixtureFiles(), 0, 'hour')));
    expect(repo.intakeFeatures.effort, isTrue);
    expect(repo.intakeFeatures.continues, isTrue);
    expect(repo.projects[projectId]!.nowItems.first.effort, 'hour');
    expect(repo.warnings, isEmpty);
    final old = HubRepository(fixture(withoutNewFeatures(fixtureFiles())));
    expect(old.intakeFeatures.effort || old.intakeFeatures.continues, isFalse);
    // 新しい本体が足した知らない段階は、一覧を捨てずに目安なしとして読む。
    final newer = HubRepository(fixture(withEffort(fixtureFiles(), 0, 'week')));
    expect(newer.projects[projectId]!.nowItems.first.effort, isNull);
    expect(newer.warnings, isEmpty);
    // 文字列でない目安は壊れた一覧として扱う。
    final broken = HubRepository(fixture(withEffortValue(fixtureFiles(), 3)));
    expect(broken.projects[projectId]!.nowItems, isEmpty);
    expect(broken.warnings, isNotEmpty);
  });

  test('目安の絞り込みは、1時間でできるものに15分でできるものを含める', () {
    expect(effortFits(null, null), isTrue);
    expect(effortFits('quick', 'quick'), isTrue);
    expect(effortFits('quick', 'hour'), isFalse);
    expect(effortFits('hour', 'quick'), isTrue);
    expect(effortFits('hour', 'hour'), isTrue);
    expect(effortFits('hour', 'half-day'), isFalse);
    expect(effortFits('hour', null), isFalse);
    expect(effortFits('none', null), isTrue);
    expect(effortFits('none', 'quick'), isFalse);
  });

  test('Dartの目安の依頼を本体が受理し、項目と現状に目安が届く', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          item = HubRepository(
            fixture(files),
          ).projects[projectId]!.nowItems.first;
      final service = CaptureService(access, location);
      await expectLater(
        service.saveItemEffort(
          'e1111111-2222-4333-8444-555555555555',
          projectId,
          item,
          'week',
        ),
        throwsFormatException,
      );
      // 付いていない目安は外せない。
      await expectLater(
        service.saveItemEffort(
          'e1111111-2222-4333-8444-555555555555',
          projectId,
          item,
          null,
        ),
        throwsFormatException,
      );
      final saved = await service.saveItemEffort(
        'e1111111-2222-4333-8444-555555555555',
        projectId,
        item,
        'quick',
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(
        parseMarkdown(raw).meta,
        allOf(
          containsPair('operation', 'item-effort'),
          containsPair('effort', 'quick'),
        ),
      );
      final waiting = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(waiting.effortRequestIdFor(item.key), saved.requestId);
      expect(
        waiting.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('手間の目安の依頼（15分ほど）'),
      );
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'eff'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final now = synced.projects[projectId]!.nowItems.firstWhere(
        (i) => i.key == item.key,
      );
      expect(now.effort, 'quick');
      expect(synced.effortRequestIdFor(item.key), isNull);
      expect(synced.latestEffortIdFor(item.key), startsWith('EFF-'));
      expect(
        synced.projects[projectId]!.sections['next']!.single.text,
        contains('手間 15分ほど'),
      );
      // 項目キーは目安の付いた行にも結び付く。
      expect(
        synced.projects[projectId]!.sections['next']!.single.itemKey,
        item.key,
      );
      expect(
        synced.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '手間の目安をMac miniが反映しました。',
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('Dartの続きを本体が受理し、前のメモとプロジェクトにつながる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(), repo = HubRepository(fixture(files));
      final parent = repo.inputRecord(inputId)!;
      final service = CaptureService(access, location);
      await expectLater(
        service.save(
          const CaptureDraft(
            operationId: 'c1111111-2222-4333-8444-555555555555',
            text: '続き',
            continues: 'IN-bad',
          ),
        ),
        throwsFormatException,
      );
      final saved = await service.save(
        CaptureDraft(
          operationId: 'c1111111-2222-4333-8444-555555555555',
          text: 'さっきの件の続き。通知はまとめて送ることにした。',
          continues: parent.sourceId,
        ),
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(parseMarkdown(raw).meta['continues'], parent.sourceId);
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'cont'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final later = synced.continuationsOf(parent.sourceId);
      expect(later, hasLength(1));
      expect(later.single.body.trim(), 'さっきの件の続き。通知はまとめて送ることにした。');
      expect(synced.previousOf(later.single)?.sourceId, parent.sourceId);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('次の一手で手間の目安を依頼し、目安で絞り込める', (tester) async {
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
    await openMore(tester, short);
    await tester.tap(find.byKey(Key('effort-$short')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-dialog')), findsOneWidget);
    // 目安を選ぶまで依頼できず、付いていない目安は外す選択肢を出さない。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('effort-submit')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('effort-choice-none')), findsNothing);
    await tester.tap(find.byKey(const Key('effort-choice-quick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('effort-submit')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-effort');
    expect(request['effort'], 'quick');
    expect(request['item_key'], item.key);

    // 依頼が同期されて反映待ちの間は、目安の操作を重ねて出さない。
    access.current = fixture({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('目安を依頼済み（反映待ち）'), findsOneWidget);
    await openMore(tester, short);
    expect(find.byKey(Key('effort-$short')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // 「次の一手」画面で、目安の付いた項目だけに絞り込める。
    final reflected = withEffort(files, 0, 'quick');
    access.current = fixture(reflected);
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    final line = c.repository!.projects[projectId]!.sections['next']!.single;
    expect(find.byKey(const Key('effort-filter-quick')), findsOneWidget);
    await tester.tap(find.byKey(const Key('effort-filter-none')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-filter-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('effort-filter-quick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-filter-empty')), findsNothing);
    expect(find.textContaining(line.text.split(' — ').first), findsWidgets);
  });

  testWidgets('記録の画面から続きを書き、指定しなければ前のメモのプロジェクトを引き継ぐと示す', (tester) async {
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
    final parent = c.repository!.inputRecord(inputId)!;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordView(controller: c, record: parent),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('write-continuation')));
    await tester.tap(find.byKey(const Key('write-continuation')));
    await tester.pumpAndSettle();
    expect(find.text('続きを書く'), findsWidgets);
    expect(find.byKey(const Key('continues-previous')), findsOneWidget);
    final title = c
        .repository!
        .projects[c.repository!.resolveProject(
          parent.metadata['project'] as String,
        )]!
        .title;
    expect(find.text('前のメモと同じ（$title）'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '続きのメモ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['continues'], parent.sourceId);
    // 指定しなければ本体が前のメモのプロジェクトを引き継ぐので、プロジェクトは送らない。
    expect(request.containsKey('project'), isFalse);
  });
}
