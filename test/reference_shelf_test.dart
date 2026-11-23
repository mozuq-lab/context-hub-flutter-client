import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/draft_store.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/ui/reference_shelf.dart';
import 'package:context_hub_client/ui/views.dart' show RecordView;
import 'capture_test.dart' show TempAccess, location;
import 'draft_test.dart' show openForm, openSample;
import 'unassigned_records_test.dart' show writeFixture;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'fixtures.dart';

/// 対応表から資料棚の編集を外す（対応前の本体）。
Map<String, String> withoutReferences(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['operations'] = [
    for (final o in features['operations'] as List)
      if (o != 'reference-mark') o,
  ];
  features['capture_fields'] = [
    for (final f in features['capture_fields'] as List)
      if (f != 'reference' && f != 'reference_title') f,
  ];
  features.remove('references');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

void main() {
  test('Dartの資料の依頼（加える・名前・外す・保存時）を本体が受理し、資料の一覧から読める', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      final files = fixtureFiles();
      final plain = HubRepository(fixture(files));
      expect(plain.intakeFeatures.references, isTrue);
      expect(plain.intakeFeatures.referenceTitleMax, 100);
      expect(plain.referenceIndex, isNull);
      final old = HubRepository(fixture(withoutReferences(files)));
      expect(old.intakeFeatures.references, isFalse);

      // 外す依頼に名前は付けず、名前は1行に限る。
      await expectLater(
        service.saveReferenceMark(
          'a1111111-2222-4333-8444-555555555555',
          inputId,
          'remove',
          title: '名前',
        ),
        throwsFormatException,
      );
      await expectLater(
        service.saveReferenceMark(
          'a1111111-2222-4333-8444-555555555555',
          inputId,
          'add',
          title: '1行目\n2行目',
        ),
        throwsFormatException,
      );
      await expectLater(
        service.save(
          const CaptureDraft(
            operationId: 'a1111111-2222-4333-8444-555555555555',
            text: '本文',
            referenceTitle: '資料として保存しない名前',
          ),
        ),
        throwsFormatException,
      );

      // 名前を付けて加える。
      final add = await service.saveReferenceMark(
        'b1111111-2222-4333-8444-555555555555',
        inputId,
        'add',
        title: '集約の設計資料',
      );
      final addRaw = (await access.readRequest(location, add.requestId))!;
      final pending = HubRepository(
        fixture({...files, 'Input/${add.requestId}.md': addRaw}),
      );
      expect(pending.referenceRequestIdFor(inputId), add.requestId);
      final asked = pending.intake.firstWhere((i) => i.id == add.requestId);
      expect(asked.title, startsWith('資料の名前の依頼（集約の設計資料）'));
      final added = await protocol(
        access,
        add.requestId,
        'assets/sample.json',
        'refm-add',
      );
      final synced = HubRepository(fixture(added));
      expect(synced.warnings, isEmpty);
      final entry = synced.referenceEntryOf(inputId)!;
      expect(
        (entry.label, entry.title, entry.addedByPerson),
        ('集約の設計資料', '集約の設計資料', true),
      );
      expect(synced.referencesFor(projectId).map((e) => e.inputId), [
        inputId,
      ]);
      expect(synced.referenceRequestIdFor(inputId), isNull);
      expect(
        synced.intake.firstWhere((i) => i.id == add.requestId).detail,
        '資料棚に反映しました。',
      );

      // 外すと、外す前の名前を残して「外した資料」に移る。
      final remove = await service.saveReferenceMark(
        'c1111111-2222-4333-8444-555555555555',
        inputId,
        'remove',
      );
      final removed = HubRepository(
        fixture(
          await protocol(
            access,
            remove.requestId,
            await writeFixture(access, added),
            'refm-remove',
          ),
        ),
      );
      expect(removed.warnings, isEmpty);
      expect(removed.referenceEntryOf(inputId), isNull);
      expect(removed.removedReferenceOf(inputId)!.title, '集約の設計資料');
      expect(removed.removedReferencesFor(projectId), hasLength(1));
      expect(
        removed.intake.firstWhere((i) => i.id == remove.requestId).title,
        startsWith('資料棚から外す依頼'),
      );

      // 保存と同時に資料にする。AIの分類に関係なく資料棚に載り、URLも並ぶ。
      final saved = await service.save(
        const CaptureDraft(
          operationId: 'd1111111-2222-4333-8444-555555555555',
          text: '集約の参考資料 https://example.org/hub',
          project: projectId,
          reference: true,
          referenceTitle: '集約の参考',
        ),
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      final meta = parseMarkdown(raw).meta;
      expect((meta['reference'], meta['reference_title']), (true, '集約の参考'));
      final captured = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(
        captured.intake.firstWhere((i) => i.id == saved.requestId).title,
        '資料として保存: 集約の参考',
      );
      final shelf = HubRepository(
        fixture(
          await protocol(
            access,
            saved.requestId,
            'assets/sample.json',
            'refm-capture',
          ),
        ),
      );
      expect(shelf.warnings, isEmpty);
      final reference = shelf.referencesFor(projectId).single;
      expect((reference.title, reference.addedByPerson), ('集約の参考', true));
      expect(reference.urls, ['https://example.org/hub']);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('壊れた資料の一覧・記録は使わず、警告を出す', () {
    final broken = HubRepository(
      fixture({
        ...fixtureFiles(),
        '90_system/references.json': '{"schema_version":1}',
        '90_system/reference-marks/REFM-01KAXQZ0000000000000000000.json':
            '{"broken":true}',
      }),
    );
    expect(broken.referenceIndex, isNull);
    expect(broken.warnings.length, greaterThanOrEqualTo(2));
    // 新しい形式の一覧は読まず、本体より古いアプリだと示す。
    final newer = HubRepository(
      fixture({
        ...fixtureFiles(),
        '90_system/references.json': jsonEncode({
          'schema_version': 2,
          'generated_at': '2026-11-23T00:00:00Z',
        }),
      }),
    );
    expect(newer.referenceIndex, isNull);
  });

  group('画面', () {
    late Map<String, String> shelfFiles;
    setUpAll(() async {
      final access = TempAccess();
      await access.init();
      try {
        final service = CaptureService(access, location);
        final add = await service.saveReferenceMark(
          'e1111111-2222-4333-8444-555555555555',
          inputId,
          'add',
          title: '集約の設計資料',
        );
        shelfFiles = await protocol(
          access,
          add.requestId,
          'assets/sample.json',
          'refm-ui',
        );
      } finally {
        await access.directory.delete(recursive: true);
      }
    });

    /// 端末が書いた依頼をVaultに載せて読み直す（同期の後と同じ）。
    Future<void> synced(
      WidgetTester tester,
      HubController c,
      MemoryUIAccess access,
      Map<String, String> files,
    ) async {
      access.current = fixture({
        ...files,
        for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
      });
      await c.reload();
      await tester.pumpAndSettle();
    }

    Future<HubController> open(
      WidgetTester tester,
      MemoryUIAccess access,
      Map<String, String> files,
    ) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      await access.init();
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
      return c;
    }

    testWidgets('資料棚の画面で名前を変える・外す依頼を出し、反映待ちの間は重ねない', (tester) async {
      final access = MemoryUIAccess();
      final c = await open(tester, access, shelfFiles);
      final project = c.repository!.projects[projectId]!;
      await tester.pumpWidget(
        MaterialApp(
          home: ReferenceShelfPage(
            controller: c,
            projectId: projectId,
            title: project.title,
            onRecord: (context, record) => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RecordView(controller: c, record: record),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('集約の設計資料'), findsOneWidget);
      expect(find.textContaining('本人が追加'), findsOneWidget);

      // 同じ名前は送らない。
      await tester.tap(find.byKey(Key('reference-rename-$inputId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reference-title-save')));
      await tester.pumpAndSettle();
      expect(access.requests, isEmpty);
      expect(find.textContaining('資料の名前は変わっていません'), findsOneWidget);

      await tester.tap(find.byKey(Key('reference-rename-$inputId')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('reference-title-field')),
        '  新しい資料名  ',
      );
      await tester.tap(find.byKey(const Key('reference-title-save')));
      await tester.pumpAndSettle();
      final meta = parseMarkdown(access.requests.values.single).meta;
      expect(
        (meta['operation'], meta['input_id'], meta['action'], meta['title']),
        ('reference-mark', inputId, 'add', '新しい資料名'),
      );
      // 依頼がVaultに届いた（同期した）後は、反映待ちの間は名前を変える・外すを出さない。
      await synced(tester, c, access, shelfFiles);
      expect(find.byKey(Key('reference-pending-$inputId')), findsOneWidget);
      expect(find.byKey(Key('reference-remove-$inputId')), findsNothing);
      await expectLater(
        c.requestReferenceMark(inputId, 'remove'),
        throwsA(isA<StateError>()),
      );
    });

    testWidgets('記録の画面から資料に加え、資料棚にあれば外せる', (tester) async {
      final access = MemoryUIAccess();
      final c = await open(tester, access, shelfFiles);
      final other = c.repository!.projects[projectId]!.nowItems
          .map((i) => i.inputId)
          .firstWhere(
            (id) =>
                id != inputId &&
                c.repository!.inputRecord(id)?.kind == 'memo' &&
                c.repository!.referenceEntryOf(id) == null,
          );
      await tester.pumpWidget(
        MaterialApp(
          home: RecordView(
            controller: c,
            record: c.repository!.inputRecord(other)!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('資料棚にはありません。'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('reference-add')));
      await tester.tap(find.byKey(const Key('reference-add')));
      await tester.pumpAndSettle();
      expect(find.text('資料に加える'), findsWidgets);
      await tester.tap(find.byKey(const Key('reference-title-save')));
      await tester.pumpAndSettle();
      final meta = parseMarkdown(access.requests.values.single).meta;
      expect(
        (meta['input_id'], meta['action'], meta.containsKey('title')),
        (other, 'add', false),
      );
      await synced(tester, c, access, shelfFiles);
      expect(find.byKey(const Key('reference-requested')), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: RecordView(
            controller: c,
            record: c.repository!.inputRecord(inputId)!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('資料棚にあります: 集約の設計資料'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('reference-remove')));
      await tester.tap(find.byKey(const Key('reference-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-reference-remove')));
      await tester.pumpAndSettle();
      final removes = access.requests.values
          .map((r) => parseMarkdown(r).meta)
          .where((m) => m['action'] == 'remove');
      expect(removes.single['input_id'], inputId);
    });

    testWidgets('プロジェクトの資料ボタンから資料棚の画面を開く', (tester) async {
      final access = MemoryUIAccess();
      await open(tester, access, shelfFiles);
      await tester.tap(find.text('AI Context Hub').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('project-shelf')));
      await tester.tap(find.byKey(const Key('project-shelf')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reference-shelf')), findsOneWidget);
      expect(find.text('集約の設計資料'), findsOneWidget);
    });
  });

  testWidgets('「資料として保存」を選ぶと、資料の名前と一緒に保存し、書きかけにも残す', (tester) async {
    final access = MemoryUIAccess();
    await openSample(tester, access);
    await openForm(tester);
    expect(find.byKey(const Key('capture-reference-title')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('capture-reference')));
    await tester.tap(find.byKey(const Key('capture-reference')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memo-text')), '集約の参考資料の要点');
    await tester.enterText(
      find.byKey(const Key('capture-reference-title')),
      '集約の参考',
    );
    await tester.pump(const Duration(seconds: 1));
    final stored = jsonDecode(access.states[DraftStore.fileName]!) as Map;
    expect(jsonEncode(stored), contains('"rt":"集約の参考"'));
    await tester.ensureVisible(find.byKey(const Key('save-memo')));
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect((meta['reference'], meta['reference_title']), (true, '集約の参考'));
  });

  testWidgets('対応前の本体では「資料として保存」を出さない', (tester) async {
    final access = MemoryUIAccess();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    await access.init();
    final files = withoutReferences(fixtureFiles());
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
    await openForm(tester);
    expect(find.byKey(const Key('capture-reference')), findsNothing);
  });
}
