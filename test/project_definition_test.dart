import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

const definitionOp = '41111111-2222-4333-8444-555555555555';

void main() {
  test('編集内容を整え、本体と同じ上限で止める', () {
    final next = ProjectDefinitionDraft(
      title: ' 新しい名前\n',
      aliases: ['Hub', ' hub ', '', 'ハブ'],
      keywords: ['再開', '再開'],
    );
    expect(next.title, '新しい名前');
    expect(next.aliases, ['Hub', 'ハブ']);
    expect(next.keywords, ['再開']);
    expect(next.problem, isNull);
    expect(
      ProjectDefinitionDraft(title: '', aliases: [], keywords: []).problem,
      contains('名前'),
    );
    expect(
      ProjectDefinitionDraft(
        title: 'A',
        aliases: [for (var i = 0; i < 51; i++) '別名$i'],
        keywords: [],
      ).problem,
      contains('50件'),
    );
    expect(
      ProjectDefinitionDraft(
        title: 'A',
        aliases: [],
        keywords: ['長' * 101],
      ).problem,
      contains('100文字'),
    );
  });

  test('Dartの定義変更REQを本体が受理し、反映後の同期で依頼済み表示が外れる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          project = HubRepository(fixture(files)).projects['context-hub']!;
      final service = CaptureService(access, location);
      final unchanged = ProjectDefinitionDraft(
        title: project.title,
        aliases: project.aliases,
        keywords: project.keywords,
      );
      await expectLater(
        service.saveProjectDefinition(definitionOp, project, unchanged),
        throwsFormatException,
      );
      final next = ProjectDefinitionDraft(
        title: project.title,
        aliases: [...project.aliases, 'ContextHub'],
        keywords: ['再開', 'メモ整理'],
      );
      final saved = await service.saveProjectDefinition(
        definitionOp,
        project,
        next,
      );
      expect(saved.saved, isTrue);
      final raw = await access.readRequest(location, saved.requestId);
      final meta = parseMarkdown(raw!).meta;
      expect(meta, containsPair('operation', 'project-definition'));
      expect(meta, containsPair('project_hash', project.definitionHash));
      expect(meta['aliases'], ['Hub', 'ContextHub']);
      // 同期前は依頼済みとして扱う。
      final pending = {...files, 'Input/${saved.requestId}.md': raw};
      final waiting = HubRepository(fixture(pending));
      expect(
        waiting.projectDefinitionRequestIdFor('context-hub'),
        saved.requestId,
      );
      expect(
        waiting.intake.firstWhere((i) => i.id == saved.requestId).title,
        '呼び名とキーワードの変更依頼: AI Context Hub',
      );
      final out = File('${access.directory.path}/snapshot.json');
      final result = await Process.run('node', [
        'scripts/check_project_definition_protocol.mjs',
        access.request(location, saved.requestId).path,
        'assets/sample.json',
        out.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final synced = HubRepository(
        fixture(
          Map<String, String>.from(jsonDecode(await out.readAsString()) as Map),
        ),
      );
      expect(synced.warnings, isEmpty);
      final after = synced.projects['context-hub']!;
      expect(after.aliases, ['Hub', 'ContextHub']);
      expect(after.keywords, ['再開', 'メモ整理']);
      expect(after.definitionHash, isNot(project.definitionHash));
      expect(synced.projectDefinitionRequestIdFor('context-hub'), isNull);
      final item = synced.intake.firstWhere((i) => i.id == saved.requestId);
      expect(item.state, 'accepted');
      expect(item.detail, '呼び名とキーワードの変更をMiniが反映しました。');
      expect(synced.latestDefinitionChangeId('context-hub'), isNotNull);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('プロジェクト画面から呼び名とキーワードの変更を依頼できる', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final c = HubController(access, sampleLoader: () async => fixture().files);
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-context-hub')).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('別名: Hub'), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-definition')));
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key('definition-submit'));
    // 変更がないうちは依頼できない。
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('definition-aliases')),
      'Hub\nコンテキストハブ',
    );
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
      find.text('呼び名とキーワードの変更を依頼しました。Miniで受け付けられると反映されます。'),
      findsOneWidget,
    );
    expect(access.writes, 1);
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect(meta['operation'], 'project-definition');
    expect(meta['aliases'], ['Hub', 'コンテキストハブ']);
    // Inputへの保存が同期されると依頼済みと表示し、定義を書き換える依頼を重ねられない。
    access.current = VaultSnapshot({
      ...fixture().files,
      'Input/${meta['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-definition-requested')),
      findsOneWidget,
    );
    for (final key in ['project-definition', 'project-status']) {
      expect(
        tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
        isNull,
      );
    }
    expect(tester.takeException(), isNull);
  });
}
