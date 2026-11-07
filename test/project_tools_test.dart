import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

const createOp = '41111111-2222-4333-8444-555555555555';

/// 保存した依頼を次の読込に含める（同期済みの端末のInputと同じ見え方）。
class _LiveAccess extends MemoryUIAccess {
  _LiveAccess(this.files);
  final Map<String, String> files;
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) async =>
      VaultSnapshot({
        ...files,
        for (final e in requests.entries) 'Input/${e.key}.md': e.value,
      });
}

const resolveOp = '51111111-2222-4333-8444-555555555555';

Future<Map<String, String>> runNode(List<String> args, Directory dir) async {
  final out = File('${dir.path}/out-${args.first}-${args.length}.json');
  if (await out.exists()) await out.delete();
  final result = await Process.run('node', [
    'scripts/check_project_tools_protocol.mjs',
    ...args,
    out.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return Map<String, String>.from(jsonDecode(await out.readAsString()) as Map);
}

Future<File> writeFixture(
  Directory dir,
  String name,
  Map<String, String> files,
) async {
  final f = File('${dir.path}/$name.json');
  await f.writeAsString(jsonEncode(files));
  return f;
}

void main() {
  test('新しいプロジェクトIDは本体と同じ形式で、名前の重なりと形式を先に検査する', () {
    final id = newProjectId(DateTime.utc(2026, 11, 7), Random(1));
    expect(newProjectIdPattern.hasMatch(id), isTrue, reason: id);
    expect(id, startsWith('project-01'));
    expect(NewProjectRequest.splitNames(' 菜園, 畑、 菜園\r\n野菜 ,'), [
      '菜園',
      '畑',
      '野菜',
    ]);
    final repo = HubRepository(fixture());
    NewProjectRequest req(String title, [List<String> aliases = const []]) =>
        NewProjectRequest(
          operationId: createOp,
          projectId: id,
          title: title,
          aliases: aliases,
        );
    expect(req('家庭菜園').formatError, isNull);
    expect(req('').formatError, isNotNull);
    expect(req(' 前後 ').formatError, isNotNull);
    expect(req('a' * 201).formatError, isNotNull);
    expect(req('家庭菜園', List.generate(51, (i) => 'a$i')).formatError, isNotNull);
    expect(req('家庭\r菜園').formatError, isNotNull);
    expect(req('家庭菜園', ['菜\r園']).formatError, isNotNull);
    // 各項目が上限内でも、受付ファイル全体が本体の読込上限を超える依頼は保存しない。
    final big = NewProjectRequest(
      operationId: createOp,
      projectId: id,
      title: '家庭菜園',
      aliases: List.generate(50, (i) => '別$i${'名' * 90}'),
      keywords: List.generate(50, (i) => '語$i${'語' * 90}'),
      firstMemo: 'メ' * 8000,
    );
    expect(big.formatError, contains('多すぎます'));
    expect(req('家庭菜園').overlapError(repo.projects.values, const []), isNull);
    // 全角・大文字の違いは同じ名前として扱う（本体と同じNFKC・小文字化）。
    expect(
      req('ＡＩ ＣＯＮＴＥＸＴ ＨＵＢ').overlapError(repo.projects.values, const []),
      contains('AI Context Hub'),
    );
    expect(
      req('新規', ['context-hub']).overlapError(repo.projects.values, const []),
      isNotNull,
    );
    expect(
      req('家庭菜園').overlapError(const [], [
        PendingProjectCreation(
          requestId: 'REQ-x',
          projectId: 'project-other',
          title: '家庭菜園',
          state: 'waiting',
        ),
      ]),
      contains('依頼済み'),
    );
  });

  test('Dartの作成REQを本体が受理し、最初のメモ付きでプロジェクトが増える', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(), id = newProjectId();
      final request = NewProjectRequest(
        operationId: createOp,
        projectId: id,
        title: '家庭菜園',
        aliases: const ['菜園'],
        keywords: const ['栽培'],
        firstMemo: 'トマトの苗を植えた',
      );
      final service = CaptureService(access, location);
      final saved = await service.saveProjectCreate(request);
      expect(saved.saved, isTrue);
      final raw = (await access.readRequest(location, saved.requestId))!;
      final doc = parseMarkdown(raw);
      expect(doc.meta, containsPair('operation', 'project-create'));
      expect(doc.meta, containsPair('project_id', id));
      expect(doc.body, 'トマトの苗を植えた');
      // 同じ操作IDは再作成せず、別の内容には使えない。
      expect((await service.saveProjectCreate(request)).saved, isTrue);
      expect(access.writes, 1);
      await expectLater(
        service.saveProjectCreate(
          NewProjectRequest(
            operationId: createOp,
            projectId: id,
            title: '別の名前',
          ),
        ),
        throwsStateError,
      );
      // 同期前は作成依頼中として表示し、同じ名前の依頼を重ねない。
      final pending = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(pending.pendingProjectCreations.single.title, '家庭菜園');
      expect(pending.pendingProjectCreations.single.state, 'waiting');
      expect(
        request.overlapError(
          pending.projects.values,
          pending.pendingProjectCreations,
        ),
        contains('依頼済み'),
      );
      final synced = HubRepository(
        fixture(
          await runNode([
            'ingest',
            access.request(location, saved.requestId).path,
            (await writeFixture(access.directory, 'base', files)).path,
          ], access.directory),
        ),
      );
      expect(synced.warnings, isEmpty);
      final project = synced.projects[id]!;
      expect(project.title, '家庭菜園');
      expect(project.aliases, ['菜園']);
      expect(synced.pendingProjectCreations, isEmpty);
      final item = synced.intake.firstWhere((i) => i.id == saved.requestId);
      expect(item.state, 'accepted');
      expect(item.title, '新しいプロジェクトの作成依頼: 家庭菜園');
      expect(item.detail, 'プロジェクトを作成しました。');
      final memo = synced.records.values.where(
        (r) => r.kind == 'memo' && r.body == 'トマトの苗を植えた',
      );
      expect(memo, hasLength(1));
      expect(memo.single.metadata['project'], id);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('止まったNOWの差分を示し、Dartの依頼を本体が受理すると生成版に戻る', () async {
    final access = TempAccess();
    await access.init();
    try {
      final base = await writeFixture(access.directory, 'base', fixtureFiles());
      final files = await runNode([
        'prepare-conflict',
        base.path,
      ], access.directory);
      final repo = HubRepository(fixture(files));
      final project = repo.projects['context-hub']!;
      final conflict = project.nowConflict!;
      expect(conflict.count, 1);
      expect(conflict.comparedWithGenerated, isTrue);
      expect(conflict.manualLines, hasLength(1));
      expect(conflict.manualLines.single, startsWith('- サンプルの検索は手で確認済み。'));
      expect(conflict.nowHash, digest(files[nowPath]!));
      expect(project.warnings.join(), isNot(contains('生成物の競合')));
      final service = CaptureService(access, location);
      final saved = await service.saveConflictResolve(resolveOp, project);
      expect(saved.saved, isTrue);
      final raw = (await access.readRequest(location, saved.requestId))!;
      final meta = parseMarkdown(raw).meta;
      expect(meta, containsPair('operation', 'conflict-resolve'));
      expect(meta, containsPair('target', nowPath));
      expect(meta, containsPair('target_hash', conflict.nowHash));
      // 同期前は依頼済みとして扱う。
      expect(
        HubRepository(
          fixture({...files, 'Input/${saved.requestId}.md': raw}),
        ).conflictRequestIdFor('context-hub'),
        saved.requestId,
      );
      final syncedFiles = await runNode([
        'ingest',
        access.request(location, saved.requestId).path,
        (await writeFixture(access.directory, 'conflict', files)).path,
      ], access.directory);
      final synced = HubRepository(fixture(syncedFiles));
      expect(synced.warnings, isEmpty);
      final restored = synced.projects['context-hub']!;
      expect(restored.nowConflict, isNull);
      expect(synced.conflictRequestIdFor('context-hub'), isNull);
      expect(
        restored.sections['next']!.map((e) => e.text).join(),
        contains('サンプルの検索を確認する。'),
      );
      final item = synced.intake.firstWhere((i) => i.id == saved.requestId);
      expect(item.title, 'NOWを生成版に戻す依頼: AI Context Hub');
      expect(item.detail, contains('生成版に戻しました'));
      final memo = synced.records.values.where(
        (r) => r.kind == 'memo' && r.body.contains('サンプルの検索は手で確認済み。'),
      );
      expect(memo, hasLength(1));
      expect(memo.single.metadata['project'], 'context-hub');
      // 片付け後に手で書き換えて新しく止まったNOWは、受理済みの依頼とは別の競合として戻す操作を出す。
      final again = HubRepository(
        fixture({
          ...syncedFiles,
          nowPath: syncedFiles[nowPath]!.replaceFirst(
            '- サンプルの検索を確認する。',
            '- また手で直した。',
          ),
          '90_system/conflicts/NOW.context-hub.01JZ0000000000000000000000.md':
              syncedFiles[nowPath]!,
        }),
      );
      expect(again.projects['context-hub']!.nowConflict, isNotNull);
      expect(again.conflictRequestIdFor('context-hub'), isNull);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('受付失敗の理由を、作成と生成版に戻す依頼に合わせた文で示す', () {
    final files = fixtureFiles();
    const id = 'REQ-0123456789abcdef0123456789abcdef', path = 'Input/$id.md';
    final raw = encodePacket({
      'schema_version': 1,
      'request_id': id,
      'source': 'flutter-client/x',
      'occurred_at': '2026-10-03T10:00:00Z',
      'operation': 'project-create',
      'project_id': 'project-01jc3b7q8k9m0n1p2q3r4s5t6v',
      'title': 'AI Context Hub',
      'aliases': <String>[],
      'keywords': <String>[],
      'confirmed': true,
    }, '');
    files[path] = raw;
    files['90_system/intake-errors/${digest(path)}.json'] = jsonEncode({
      'schema_version': 1,
      'path': path,
      'file_hash': digest(raw),
      'status': 'error',
      'code': '受付操作が未完了です。',
      'updated_at': '2026-10-03T10:00:00Z',
      'reason': {'code': 'project-overlap', 'project_id': 'context-hub'},
    });
    final repo = HubRepository(fixture(files));
    final item = repo.intake.firstWhere((i) => i.id == id);
    expect(item.state, 'rejected');
    expect(item.detail, contains('（context-hub）と重なる'));
    expect(repo.pendingProjectCreations, isEmpty);
  });

  testWidgets('メニューから新しいプロジェクトを依頼し、止まったNOWには戻す操作を出す', (tester) async {
    final files = fixtureFiles();
    files['90_system/conflicts/NOW.context-hub.01M2DSFVRRA5MFS95MKFPP2CCZ.md'] =
        files[nowPath]!;
    files[nowPath] = files[nowPath]!.replaceFirst(
      '- サンプルの検索を確認する。',
      '- 手で直した次の一手',
    );
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = _LiveAccess(files);
    await access.init();
    final c = HubController(access, sampleLoader: () async => files);
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
    expect(find.byKey(const Key('now-conflict')), findsOneWidget);
    expect(find.text('NOWの更新が止まっています'), findsOneWidget);
    expect(find.textContaining('手で直した次の一手'), findsWidgets);
    await tester.tap(find.byKey(const Key('conflict-resolve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    final resolve = access.requests.values
        .map(parseMarkdown)
        .firstWhere((d) => d.meta['operation'] == 'conflict-resolve');
    expect(resolve.meta['target'], nowPath);
    expect(find.textContaining('生成版に戻す依頼を送りました'), findsOneWidget);

    await tester.tap(find.byKey(const Key('new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('project-create-title')),
      'AI Context Hub',
    );
    await tester.tap(find.byKey(const Key('project-create-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('名前・別名と重なります'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('project-create-title')),
      '家庭菜園',
    );
    await tester.enterText(
      find.byKey(const Key('project-create-aliases')),
      '菜園、畑',
    );
    await tester.enterText(
      find.byKey(const Key('project-create-memo')),
      '最初のメモ',
    );
    await tester.tap(find.byKey(const Key('project-create-submit')));
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに作成の依頼を保存しました'), findsOneWidget);
    final create = access.requests.values
        .map(parseMarkdown)
        .firstWhere((d) => d.meta['operation'] == 'project-create');
    expect(create.meta['title'], '家庭菜園');
    expect(create.meta['aliases'], ['菜園', '畑']);
    expect(create.body, '最初のメモ');
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    final id = create.meta['project_id'] as String;
    expect(find.byKey(Key('pending-project-$id')), findsOneWidget);
    expect(find.text('作成依頼中'), findsOneWidget);

    // 別の操作の保存確認が残っている間は、新しい作成依頼を保存しない。
    final before = access.requests.length;
    c.pending = [const CaptureResult('other-op', 'REQ-other', 'unknown')];
    Object? failure;
    unawaited(
      c
          .requestProjectCreate(
            NewProjectRequest(
              operationId: createOp,
              projectId: newProjectId(),
              title: '別の新規',
            ),
          )
          .then<void>((_) {}, onError: (Object e) => failure = e),
    );
    await tester.pumpAndSettle();
    expect(
      failure,
      isA<StateError>().having((e) => e.message, 'message', contains('保存確認待ち')),
    );
    expect(access.requests.length, before);
  });
}
