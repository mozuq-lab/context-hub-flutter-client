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

const statusOp = '21111111-2222-4333-8444-555555555555';
const projectPath = '10_projects/context-hub/project.md';

void main() {
  test('サンプルのふりかえりと、状態・停滞・定義hashを読む', () {
    final files = fixtureFiles(), repo = HubRepository(fixture(files));
    final digestDoc = repo.digestDocument!;
    expect(digestDoc.periodDays, 60);
    expect(digestDoc.body, contains('## 動きのあったプロジェクト'));
    expect(digestDoc.warnings, hasLength(1), reason: '整合性の注意は出さない');
    final project = repo.projects['context-hub']!;
    expect(project.lifecycle, 'active');
    expect(project.definitionHash, digest(files[projectPath]!));
    expect(project.lastEvidenceAt, isNotNull);
    expect(project.stale(DateTime.utc(2026, 11, 2)), isTrue);
    expect(project.stale(DateTime.utc(2026, 9, 20)), isFalse);
    expect(project.daysSinceEvidence(DateTime.utc(2026, 9, 20)), 5);
    expect(repo.warnings, isEmpty);
  });

  test('手で変えたREVIEW.mdは整合性の注意を付け、旧版の自由記述の状態は進行中として扱う', () {
    final files = fixtureFiles();
    files['REVIEW.md'] = '${files['REVIEW.md']!}\n手で追記\n';
    final doc = parseMarkdown(files[projectPath]!);
    files[projectPath] = encodePacket({...doc.meta, 'status': '検討中'}, doc.body);
    final repo = HubRepository(fixture(files));
    expect(repo.digestDocument!.warnings.last, contains('整合性を確認できません'));
    expect(repo.projects['context-hub']!.lifecycle, 'active');
    expect(repo.projects['context-hub']!.lifecycleLabel, '進行中');
    files.remove('REVIEW.md');
    expect(HubRepository(fixture(files)).digestDocument, isNull);
  });

  test('Dartの状態変更REQを本体が受理し、反映後の同期で依頼済み表示が外れる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          project = HubRepository(fixture(files)).projects['context-hub']!;
      final service = CaptureService(access, location);
      await expectLater(
        service.saveProjectStatus(statusOp, project, 'active'),
        throwsFormatException,
      );
      final saved = await service.saveProjectStatus(
        statusOp,
        project,
        'paused',
      );
      expect(saved.saved, isTrue);
      final raw = await access.readRequest(location, saved.requestId);
      final meta = parseMarkdown(raw!).meta;
      expect(meta, containsPair('operation', 'project-status'));
      expect(meta, containsPair('project_hash', project.definitionHash));
      // 同じ操作IDは再作成せず、別の内容には使えない。
      expect(
        (await service.saveProjectStatus(statusOp, project, 'paused')).saved,
        isTrue,
      );
      expect(access.writes, 1);
      await expectLater(
        service.saveProjectStatus(statusOp, project, 'done'),
        throwsStateError,
      );
      // 同期前は依頼済みとして扱う。
      final pending = {...files, 'Input/${saved.requestId}.md': raw};
      expect(
        HubRepository(
          fixture(pending),
        ).projectStatusRequestIdFor('context-hub'),
        saved.requestId,
      );
      final out = File('${access.directory.path}/snapshot.json');
      final result = await Process.run('node', [
        'scripts/check_project_status_protocol.mjs',
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
      expect(synced.projects['context-hub']!.lifecycle, 'paused');
      expect(
        synced.projects['context-hub']!.stale(DateTime.utc(2026, 11, 2)),
        isFalse,
      );
      expect(synced.projectStatusRequestIdFor('context-hub'), isNull);
      final item = synced.intake.firstWhere((i) => i.id == saved.requestId);
      expect(item.state, 'accepted');
      expect(item.title, '状態変更依頼: AI Context Hub → 休止');
      expect(item.detail, '状態の変更をMiniが反映しました。');
      expect(synced.orderedProjects.last.id, 'context-hub');
      // 再開すると定義は元のhashへ戻る。古い休止依頼を未反映と扱わず、再び状態を変えられる。
      final paused = synced.projects['context-hub']!;
      final resumed = await CaptureService(access, location).saveProjectStatus(
        '31111111-2222-4333-8444-555555555555',
        paused,
        'active',
      );
      final out2 = File('${access.directory.path}/snapshot2.json');
      final second = await Process.run('node', [
        'scripts/check_project_status_protocol.mjs',
        access.request(location, resumed.requestId).path,
        out.path,
        out2.path,
      ]);
      expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
      final back = HubRepository(
        fixture(
          Map<String, String>.from(
            jsonDecode(await out2.readAsString()) as Map,
          ),
        ),
      );
      expect(back.warnings, isEmpty);
      expect(
        back.projects['context-hub']!.definitionHash,
        project.definitionHash,
      );
      expect(back.projectStatusRequestIdFor('context-hub'), isNull);
      expect(
        back.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '状態の変更をMiniが反映しました（その後に別の変更があります）。',
      );
      expect(
        back.intake.firstWhere((i) => i.id == resumed.requestId).detail,
        '状態の変更をMiniが反映しました。',
      );
      expect(back.latestStatusChangeId('context-hub'), isNotNull);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('受付失敗の記録がある依頼は依頼済みとして扱わない', () async {
    final files = fixtureFiles(),
        project = HubRepository(fixture(files)).projects['context-hub']!;
    final access = TempAccess();
    await access.init();
    try {
      final saved = await CaptureService(
        access,
        location,
      ).saveProjectStatus(statusOp, project, 'done');
      final path = 'Input/${saved.requestId}.md';
      files[path] = (await access.readRequest(location, saved.requestId))!;
      files['90_system/intake-errors/${digest(path)}.json'] = jsonEncode({
        'schema_version': 1,
        'path': path,
        'file_hash': digest(files[path]!),
        'status': 'error',
        'code': '受付操作が未完了です',
        'updated_at': '2026-11-02T00:00:00Z',
      });
      final repo = HubRepository(fixture(files));
      expect(repo.projectStatusRequestIdFor('context-hub'), isNull);
      expect(
        repo.intake.firstWhere((i) => i.id == saved.requestId).state,
        'rejected',
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('ふりかえりを開き、プロジェクトの状態変更を依頼できる', (tester) async {
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
    expect(find.text('直近60日のふりかえり'), findsOneWidget);
    expect(find.textContaining('停滞しているプロジェクト 1件'), findsOneWidget);
    expect(find.textContaining('停滞（14日超）'), findsWidgets);
    await tester.tap(find.byKey(const Key('nav-digest')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('digest-body')), findsOneWidget);
    expect(find.textContaining('動きのあったプロジェクト'), findsWidgets);
    await tester.tap(find.byKey(const Key('project-context-hub')).first);
    await tester.pumpAndSettle();
    expect(find.text('PROJECT / 進行中'), findsOneWidget);
    expect(find.textContaining('再開するか、休止・完了にするか'), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-status')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-status-active')), findsNothing);
    final submit = find.byKey(const Key('project-status-submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.byKey(const Key('project-status-paused')));
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('状態の変更を依頼しました。Miniで受け付けられると反映されます。'), findsOneWidget);
    expect(access.writes, 1);
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect(meta['operation'], 'project-status');
    expect(meta['status'], 'paused');
    expect(meta['project_id'], 'context-hub');
    // Inputへの保存が同期されると依頼済みと表示し、重ねて依頼できない。
    access.current = VaultSnapshot({
      ...fixture().files,
      'Input/${meta['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.textContaining('状態の変更を依頼済みです'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('project-status')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
