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

const projectId = 'context-hub';
const draftId = 'GDR-01M7AAAAAAAAAAAAAAAAAAAAAA';
const draftPath = '90_system/git-drafts/$draftId.json';

/// 本体が作る形の作業記録の下書き。
String draftJson() =>
    '${const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'id': draftId,
      'project_id': projectId,
      'repo': 'hub-app',
      'repo_path': '/fixture/hub-app',
      'commits': [
        {'sha': 'a' * 40, 'committed_at': '2026-11-01T01:00:00.000Z', 'subject': '画面を追加'},
      ],
      'omitted': 0,
      'text': 'hub-appのコミット履歴（2026-11-01〜2026-11-01、1件）から作った作業記録の下書きです。\n\n- 2026-11-01 画面を追加 (aaaaaaa)',
      'created_at': '2026-11-02T00:00:00.000Z',
    })}\n';

Future<Map<String, String>> protocol(
  TempAccess access,
  String requestId,
  String fixturePath,
  String name,
) async {
  final out = File('${access.directory.path}/$name.json');
  final result = await Process.run('node', [
    'scripts/check_request_protocol.mjs',
    access.request(location, requestId).path,
    fixturePath,
    out.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return Map<String, String>.from(jsonDecode(await out.readAsString()) as Map);
}

void main() {
  test('NOWの各行に本体の項目キーを結び付ける', () {
    final project = HubRepository(fixture()).projects[projectId]!;
    expect(project.nowItems, hasLength(3));
    expect(project.sections['next']!.single.itemKey, project.nowItems[0].key);
    expect(
      project.sections['open']!.map((e) => e.itemKey),
      project.nowItems.skip(1).map((i) => i.key),
    );
    expect(project.sections['current']!.single.itemKey, isNull);
    // 項目一覧がない旧版の本体では、操作できる項目を出さない。
    final files = fixtureFiles()..remove('90_system/now-items/$projectId.json');
    final old = HubRepository(fixture(files)).projects[projectId]!;
    expect(old.nowItems, isEmpty);
    expect(old.sections['next']!.single.itemKey, isNull);
  });

  test('Dartの完了報告を本体が受理し、同期後は解決済みへ移って再開もできる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          project = HubRepository(fixture(files)).projects[projectId]!,
          item = project.nowItems.first;
      final service = CaptureService(access, location);
      await expectLater(
        service.saveItemResolution(
          '41111111-2222-4333-8444-555555555555',
          projectId,
          item,
          'reopen',
        ),
        throwsFormatException,
      );
      final saved = await service.saveItemResolution(
        '41111111-2222-4333-8444-555555555555',
        projectId,
        item,
        'resolve',
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(
        parseMarkdown(raw).meta,
        containsPair('operation', 'item-resolution'),
      );
      // 同期前は報告済みとして扱う。
      final pending = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(pending.itemRequestIdFor(item.key), saved.requestId);
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'one'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final p = synced.projects[projectId]!;
      expect(
        p.sections['next']!.map((e) => e.text),
        isNot(contains(item.display)),
      );
      expect(p.resolvedItems.single.key, item.key);
      expect(synced.itemRequestIdFor(item.key), isNull);
      expect(
        synced.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '報告をMiniが反映しました。',
      );
      final reopened = await service.saveItemResolution(
        '51111111-2222-4333-8444-555555555555',
        projectId,
        p.resolvedItems.single,
        'reopen',
      );
      final back = HubRepository(
        fixture(
          await protocol(
            access,
            reopened.requestId,
            '${access.directory.path}/one.json',
            'two',
          ),
        ),
      );
      expect(back.projects[projectId]!.resolvedItems, isEmpty);
      expect(
        back.projects[projectId]!.sections['next']!.single.itemKey,
        item.key,
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('下書きを見送り、または下書きから作った入力で使用済みにする', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = {...fixtureFiles(), draftPath: draftJson()};
      final repo = HubRepository(fixture(files)),
          draft = repo.projects[projectId]!.drafts.single;
      expect(draft.hash, digest(draftJson()));
      expect(repo.gitDrafts[draftId]!.commitCount, 1);
      final fixtureFile = File('${access.directory.path}/with-draft.json')
        ..writeAsStringSync(jsonEncode(files));
      final service = CaptureService(access, location);
      final dismissed = await service.saveGitDraftDismiss(
        '61111111-2222-4333-8444-555555555555',
        draft,
      );
      final pendingRepo = HubRepository(
        fixture({
          ...files,
          'Input/${dismissed.requestId}.md': (await access.readRequest(
            location,
            dismissed.requestId,
          ))!,
        }),
      );
      expect(pendingRepo.draftRequestIdFor(draftId), dismissed.requestId);
      final afterDismiss = HubRepository(
        fixture(
          await protocol(
            access,
            dismissed.requestId,
            fixtureFile.path,
            'dismissed',
          ),
        ),
      );
      expect(afterDismiss.projects[projectId]!.drafts, isEmpty);
      expect(afterDismiss.warnings, isEmpty);
      // 別の経路: 本文を編集して入力にする。
      await expectLater(
        service.save(
          const CaptureDraft(
            operationId: '71111111-2222-4333-8444-555555555555',
            text: '編集',
            gitDraftId: draftId,
          ),
        ),
        throwsFormatException,
      );
      final used = await service.save(
        CaptureDraft(
          operationId: '71111111-2222-4333-8444-555555555555',
          text: '${draft.text}\n- 次は利用者に見せる',
          project: projectId,
          gitDraftId: draftId,
          gitDraftHash: draft.hash,
        ),
      );
      final usedRepo = HubRepository(
        fixture(
          await protocol(access, used.requestId, fixtureFile.path, 'used'),
        ),
      );
      expect(usedRepo.projects[projectId]!.drafts, isEmpty);
      expect(usedRepo.warnings, isEmpty);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('前回見てからの変化を示し、項目の完了と下書きの操作ができる', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = {...fixtureFiles(), draftPath: draftJson()};
    access.current = VaultSnapshot(files);
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
    // 初回は既読として記録し、新着を出さない。
    expect(find.byKey(const Key('home-changes')), findsNothing);
    final seen = jsonDecode(access.states['settings.json']!) as Map;
    expect(((seen['seen'] as Map).values.single as Map).keys, [projectId]);
    expect(find.text('作業記録の下書き 1件'), findsOneWidget);
    // NOWが変わったVaultを読み直すと、変化のあったプロジェクトとして表示する。
    final project = HubRepository(fixture(files)).projects[projectId]!;
    final now = files[nowPath]!.replaceFirst(
      '- 未解決: Discord実機接続は承認後に確認する。',
      '- 未解決: 配布方法を決める。',
    );
    expect(now, isNot(files[nowPath]));
    access.current = VaultSnapshot({...files, nowPath: now});
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-changes')), findsOneWidget);
    expect(find.byKey(const Key('project-changes-$projectId')), findsOneWidget);
    expect(find.text('新着1 · 外れた1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-$projectId')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-changes')), findsOneWidget);
    expect(find.textContaining('外れた（未解決）: 未解決: Discord実機接続'), findsOneWidget);
    expect(find.byKey(const Key('new-entry')), findsOneWidget);
    // 開いた時点で既読にし、ホームの印は消える。
    final stored = jsonDecode(access.states['settings.json']!) as Map;
    expect(
      (((stored['seen'] as Map).values.single as Map)[projectId]
          as Map)['items'],
      hasLength(4),
    );
    // 次の一手を完了にする。
    final key = project.nowItems.first.key;
    await tester.tap(find.byKey(Key('resolve-${key.substring(0, 12)}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(find.text('報告を保存しました。Miniで受け付けられるとNOWに反映されます。'), findsOneWidget);
    final request = access.requests.values.single;
    expect(parseMarkdown(request).meta['item_key'], key);
    access.current = VaultSnapshot({
      ...files,
      nowPath: now,
      'Input/${parseMarkdown(request).meta['request_id']}.md': request,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('報告済み（反映待ち）'), findsOneWidget);
    // 下書きを入力フォームへ読み込む。
    await tester.tap(find.byKey(const Key('draft-use-$draftId')));
    await tester.pumpAndSettle();
    expect(find.text('下書きから入力を作る'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('memo-text')));
    expect(field.controller!.text, contains('画面を追加'));
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    final saved = access.requests.values.firstWhere(
      (r) => parseMarkdown(r).meta['operation'] == 'capture',
    );
    expect(parseMarkdown(saved).meta['meta'], {
      'git_draft': draftId,
      'git_draft_hash': digest(draftJson()),
    });
    expect(parseMarkdown(saved).meta['project'], projectId);
    expect(tester.takeException(), isNull);
  });
}
