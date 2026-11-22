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
import 'package:context_hub_client/ui/app.dart';

import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';
import 'project_definition_test.dart' show openProjectMore;

const outcomeOp = '51111111-2222-4333-8444-555555555555';

/// project.mdのfrontmatterの末尾に1行足す（手で書いた望む結果など）。
Map<String, String> withProjectLine(
  Map<String, String> files,
  String id,
  String line,
) {
  final path = '10_projects/$id/project.md', raw = files[path]!;
  final end = raw.indexOf('\n---', 4);
  return {
    ...files,
    path: '${raw.substring(0, end)}\n$line${raw.substring(end)}',
  };
}

/// DartのREQを本体に受理させ、反映後のスナップショットと本体の登録簿hashを返す。
Future<(HubRepository, String)> accept(
  TempAccess access,
  String requestId,
  Map<String, String> files,
) async {
  final input = File('${access.directory.path}/fixture.json'),
      out = File('${access.directory.path}/snapshot.json');
  await input.writeAsString(jsonEncode({'files': files}));
  final result = await Process.run('node', [
    'scripts/check_project_definition_protocol.mjs',
    access.request(location, requestId).path,
    input.path,
    out.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  final registry = RegExp(r'REGISTRY:([a-f0-9]{64})')
      .firstMatch(result.stdout as String)![1]!;
  return (
    HubRepository(
      fixture(
        Map<String, String>.from(jsonDecode(await out.readAsString()) as Map),
      ),
    ),
    registry,
  );
}

void main() {
  test('本体の上限を読み、対応前の本体では望む結果を出さない', () {
    expect(
      IntakeFeatures.parse(
        jsonEncode({
          'schema_version': 1,
          'operations': ['project-definition'],
          'capture_fields': [],
          'project_outcome': {'max_chars': 500, 'max_lines': 10},
        }),
      ).projectOutcome,
      (maxChars: 500, maxLines: 10),
    );
    expect(
      IntakeFeatures.parse(
        jsonEncode({
          'schema_version': 1,
          'operations': ['project-definition'],
          'capture_fields': [],
        }),
      ).projectOutcome,
      isNull,
    );
    expect(HubRepository(fixture()).intakeFeatures.projectOutcome, isNotNull);
  });

  test('望む結果を本体と同じ規則で整え、上限で止める', () {
    expect(projectOutcomeLines('- 収穫する\r\n\r\n・食べる \n-5kg減らす\u0085'), [
      '収穫する',
      '食べる',
      '-5kg減らす',
    ]);
    expect(normalizeProjectOutcome('  夏\r\n\r\n\t秋  '), '夏\n秋');
    final project = HubProject(id: 'garden', title: '菜園', outcome: '夏');
    ProjectDefinitionDraft draft(String? outcome) => ProjectDefinitionDraft(
      title: '菜園',
      aliases: const [],
      keywords: const [],
      outcome: outcome,
      outcomeLimits: (maxChars: 10, maxLines: 2),
    );
    expect(draft(null).sameAs(project), isTrue);
    expect(draft(' 夏 ').sameAs(project), isTrue);
    expect(draft('').sameAs(project), isFalse);
    expect(draft('秋').problem, isNull);
    expect(draft('長' * 11).problem, contains('10文字'));
    expect(draft('一\n二\n三').problem, contains('2行'));
    expect(draft('ベル\u0007').problem, contains('使えない文字'));
    final request = NewProjectRequest(
      operationId: outcomeOp,
      projectId: newProjectId(),
      title: '菜園',
      outcome: ' 夏に収穫 \n',
    );
    expect(request.fields['outcome'], '夏に収穫');
    expect(
      NewProjectRequest(
        operationId: outcomeOp,
        projectId: newProjectId(),
        title: '菜園',
      ).fields.containsKey('outcome'),
      isFalse,
    );
  });

  test('Dartの望む結果の変更REQを本体が受理し、登録簿hashが本体と一致する', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          project = HubRepository(fixture(files)).projects['context-hub']!;
      expect(project.outcome, isNull);
      final service = CaptureService(access, location);
      final saved = await service.saveProjectDefinition(
        outcomeOp,
        project,
        ProjectDefinitionDraft(
          title: project.title,
          aliases: project.aliases,
          keywords: project.keywords,
          outcome: ' 再開に迷わない \n\n- 出典をたどれる',
        ),
      );
      final raw = await access.readRequest(location, saved.requestId);
      expect(parseMarkdown(raw!).meta['outcome'], '再開に迷わない\n- 出典をたどれる');
      final waiting = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(
        waiting.intake.firstWhere((i) => i.id == saved.requestId).title,
        '呼び名・キーワード・望む結果の変更依頼: AI Context Hub',
      );
      final (synced, registry) = await accept(access, saved.requestId, files);
      expect(synced.warnings, isEmpty);
      final after = synced.projects['context-hub']!;
      expect(after.outcome, '再開に迷わない\n- 出典をたどれる');
      expect(after.outcomeLines, ['再開に迷わない', '出典をたどれる']);
      expect(projectRegistryHash(synced.projects.values), registry);
      expect(synced.projectDefinitionRequestIdFor('context-hub'), isNull);
      // 本体はNOWの先頭に載せるが、アプリの欄の読み取りには混ざらない。
      expect(
        synced.snapshot.files['10_projects/context-hub/NOW.md'],
        contains('# 望む結果（本人が書いた完了の基準）\n- 再開に迷わない\n- 出典をたどれる'),
      );
      expect(
        after.sections['current']!.map((e) => e.text),
        HubRepository(fixture(files))
            .projects['context-hub']!
            .sections['current']!
            .map((e) => e.text),
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('手で書いた望む結果は、望む結果を送らない変更で消えず、登録簿hashも本体と一致する', () async {
    final access = TempAccess();
    await access.init();
    try {
      // 全角空白・箇条書き・空の行を含む手書きの文。
      final files = withProjectLine(
        fixtureFiles(),
        'context-hub',
        'outcome: "　- 再開に迷わない\\n\\n・出典 "',
      );
      final project = HubRepository(fixture(files)).projects['context-hub']!;
      expect(project.outcomeLines, ['再開に迷わない', '出典']);
      final saved = await CaptureService(access, location)
          .saveProjectDefinition(
            outcomeOp,
            project,
            ProjectDefinitionDraft(
              title: project.title,
              aliases: [...project.aliases, 'ContextHub'],
              keywords: project.keywords,
            ),
          );
      final raw = await access.readRequest(location, saved.requestId);
      expect(parseMarkdown(raw!).meta.containsKey('outcome'), isFalse);
      final (synced, registry) = await accept(access, saved.requestId, files);
      expect(synced.projects['context-hub']!.outcome, project.outcome);
      expect(projectRegistryHash(synced.projects.values), registry);
      // 空・nullは書いていないものとして読み、文字列でない値は不正な定義。
      for (final line in ['outcome:', 'outcome: ""']) {
        final repo = HubRepository(
          fixture(withProjectLine(fixtureFiles(), 'context-hub', line)),
        );
        expect(repo.projects['context-hub']!.outcome, isNull);
      }
      expect(
        HubRepository(
          fixture(
            withProjectLine(fixtureFiles(), 'context-hub', 'outcome: [a]'),
          ),
        ).projects.containsKey('context-hub'),
        isFalse,
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('プロジェクト画面に望む結果を示し、書く・完了の確認で見られる', (tester) async {
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
    expect(find.byKey(const Key('project-outcome-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-outcome-edit')));
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key('definition-submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('definition-outcome')),
      '再開に迷わない\n出典をたどれる',
    );
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
      find.text('呼び名・キーワード・望む結果の変更を依頼しました。Mac miniで処理されると反映されます。'),
      findsOneWidget,
    );
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect(meta['operation'], 'project-definition');
    expect(meta['outcome'], '再開に迷わない\n出典をたどれる');

    // 反映後は先頭に望む結果を示し、完了にするときの確認にも添える。
    access.current = VaultSnapshot(
      withProjectLine(
        fixture().files,
        'context-hub',
        'outcome: "再開に迷わない\\n出典をたどれる"',
      ),
    );
    await c.reload();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('project-outcome-text')))
          .data,
      '再開に迷わない\n出典をたどれる',
    );
    await openProjectMore(tester);
    await tester.tap(find.byKey(const Key('project-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-status-done')));
    await tester.pumpAndSettle();
    expect(find.textContaining('これを満たしたかを確かめてから完了にしてください'), findsOneWidget);
    expect(find.textContaining('再開に迷わない'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新しいプロジェクトの作成で望む結果を送れる', (tester) async {
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
    await tester.tap(find.byKey(const Key('new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('project-create-title')),
      '家庭菜園',
    );
    await tester.enterText(
      find.byKey(const Key('project-create-outcome')),
      '夏に収穫する',
    );
    await tester.tap(find.byKey(const Key('project-create-submit')));
    await tester.pumpAndSettle();
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect(meta['operation'], 'project-create');
    expect(meta['outcome'], '夏に収穫する');
    expect(tester.takeException(), isNull);
  });
}
