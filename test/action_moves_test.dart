import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';

import 'capture_test.dart' show TempAccess, location;
import 'unassigned_actions_test.dart' show fixturePath;
import 'unassigned_proposals_test.dart' show inboxFiles, sample;
import 'unassigned_records_test.dart' show writeFixture;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol;

const projectId = 'garden';

/// 対応表から、行動を移す操作への対応を外す（古い本体）。
Map<String, String> withoutMoves(Map<String, String> files) {
  final features =
      jsonDecode(files[intakeFeaturesPath]!) as Map<String, dynamic>;
  features.remove('action_moves');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

/// プロジェクト未定の行動を1件追加し、本体が反映したVaultを返す。
Future<Map<String, String>> withOwnAction(
  TempAccess access,
  String text,
) async {
  final saved = await CaptureService(access, location).saveAction(
    '61111111-2222-4333-8444-666666666666',
    unassignedScope,
    text,
  );
  return protocol(access, saved.requestId, fixturePath, 'own');
}

void main() {
  test('対応した本体は、行動を別の置き場へ移せると示す', () {
    expect(
      HubRepository(VaultSnapshot(inboxFiles())).intakeFeatures.actionMoves,
      isTrue,
    );
    expect(
      HubRepository(
        VaultSnapshot(withoutMoves(inboxFiles())),
      ).intakeFeatures.actionMoves,
      isFalse,
    );
  });

  test('プロジェクト未定の行動をプロジェクトへ移す依頼を本体が受理し、元の行動は一覧から外れ、追加の依頼も反映待ちに戻らない', () async {
    final access = TempAccess();
    await access.init();
    try {
      var files = await withOwnAction(access, '見積もりを頼む');
      var repo = HubRepository(VaultSnapshot(files));
      final item = repo.unassignedOwnActions.single;
      expect(repo.unassignedPendingActions, isEmpty);
      final service = CaptureService(access, location);
      final moved = await service.saveAction(
        '62111111-2222-4333-8444-666666666666',
        projectId,
        item.text,
        from: ActionSource(inputId: item.inputId, text: item.text, key: item.key),
      );
      // 反映待ちの間は、元の行動をプロジェクト未定から外し、移す先に反映待ちとして示す（二重に数えない）。
      final request = (await access.readRequest(location, moved.requestId))!;
      final pending = HubRepository(
        VaultSnapshot({...files, 'Input/${moved.requestId}.md': request}),
      );
      expect(pending.warnings, isEmpty);
      expect(pending.unassignedOwnActions, isEmpty);
      expect(pending.unassignedActionCount, 0);
      expect(pending.projects[projectId]!.pendingActions.single.from?.key, item.key);
      files = await protocol(
        access,
        moved.requestId,
        await writeFixture(access, files),
        'move',
      );
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.unassignedOwnActions, isEmpty);
      // 元の行動の追加の依頼は、元の行動が一覧から外れても反映待ちに戻らない。
      expect(repo.unassignedPendingActions, isEmpty);
      expect(
        repo.intake.where((i) => i.detail == '次の一手にMac miniが追加しました。'),
        hasLength(2),
      );
      final project = repo.projects[projectId]!;
      expect(project.pendingActions, isEmpty);
      final target = project.nowItems.singleWhere((i) => i.action);
      expect(
        (target.text, target.fromInputId, target.fromKey),
        (item.text, item.inputId, item.key),
      );
      expect(
        project.sections['next']!.any((e) => e.itemKey == target.key),
        isTrue,
      );
      // 戻すときは、移した先の行動をもう一度移す。
      final back = await service.saveAction(
        '64111111-2222-4333-8444-666666666666',
        unassignedScope,
        target.text,
        from: ActionSource(
          inputId: target.inputId,
          text: target.text,
          key: target.key,
        ),
      );
      files = await protocol(
        access,
        back.requestId,
        await writeFixture(access, files),
        'back',
      );
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.projects[projectId]!.nowItems.where((i) => i.action), isEmpty);
      expect(repo.unassignedOwnActions.single.fromKey, target.key);
      expect(repo.unassignedPendingActions, isEmpty);
      expect(repo.projects[projectId]!.pendingActions, isEmpty);
      // 移す依頼がこの端末の受付にない（本体のCLIで移したなど）ときも、同期済みの入力から移したと分かり、
      // 元の行動の追加の依頼を反映待ちに戻さない。
      final viaCli = HubRepository(
        VaultSnapshot({
          for (final e in files.entries)
            if (e.key != 'Input/${moved.requestId}.md' &&
                e.key != 'Input/${back.requestId}.md')
              e.key: e.value,
        }),
      );
      expect(viaCli.unassignedPendingActions, isEmpty);
      expect(viaCli.unassignedOwnActions.single.fromKey, target.key);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('移す先の一覧だけが先に同期されても、元の行動を二重に並べない', () async {
    final access = TempAccess();
    await access.init();
    try {
      final before = await withOwnAction(access, '見積もりを頼む');
      final item = HubRepository(VaultSnapshot(before)).unassignedOwnActions.single;
      final moved = await CaptureService(access, location).saveAction(
        '63111111-2222-4333-8444-666666666666',
        projectId,
        item.text,
        from: ActionSource(inputId: item.inputId, text: item.text, key: item.key),
      );
      final after = await protocol(
        access,
        moved.requestId,
        await writeFixture(access, before),
        'move',
      );
      // プロジェクトの項目一覧は新しく、プロジェクト未定の項目一覧はまだ古い。
      const unassigned = '90_system/now-items/$unassignedScope.json';
      final repo = HubRepository(
        VaultSnapshot({...after, unassigned: before[unassigned]!}),
      );
      expect(repo.unassignedOwnActions, isEmpty);
      expect(repo.projects[projectId]!.nowItems.where((i) => i.action), hasLength(1));
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('移す依頼は、本人が追加した未完了の行動を、別の進行中の置き場へだけ送る', () async {
    final access = TempAccess();
    await access.init();
    addTearDown(() => access.directory.delete(recursive: true));
    final files = await withOwnAction(access, '見積もりを頼む');
    final a = MemoryUIAccess()..current = VaultSnapshot(files);
    final c = HubController(a, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final repo = c.repository!,
        own = repo.unassignedOwnActions.single,
        ai = repo.unassignedItems.firstWhere((i) => !i.action);
    await expectLater(
      c.requestMoveAction(unassignedScope, own.key, unassignedScope),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      c.requestMoveAction(unassignedScope, ai.key, projectId),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      c.requestMoveAction(unassignedScope, own.key, 'missing'),
      throwsA(isA<StateError>()),
    );
    expect(a.requests, isEmpty);
    // 文面の訂正が反映待ちの行動は移さない（訂正前の文面で移してしまうため）。
    final correction = await CaptureService(access, location).saveCorrection(
      '65111111-2222-4333-8444-666666666666',
      own.inputId,
      '見積もりを2社に頼む',
    );
    final withCorrection = {
      ...files,
      'Input/${correction.requestId}.md': (await access.readRequest(
        location,
        correction.requestId,
      ))!,
    };
    final correcting = MemoryUIAccess()
      ..current = VaultSnapshot(withCorrection);
    final e = HubController(
      correcting,
      sampleLoader: () async => withCorrection,
    );
    addTearDown(e.dispose);
    await e.useSample();
    expect(e.repository!.correctionRequestIdForInput(own.inputId), isNotNull);
    await expectLater(
      e.requestMoveAction(unassignedScope, own.key, projectId),
      throwsA(isA<StateError>()),
    );
    expect(correcting.requests, isEmpty);
    final saved = await c.requestMoveAction(unassignedScope, own.key, projectId);
    expect(saved.saved, isTrue);
    final meta = parseMarkdown(a.requests.values.single).meta;
    expect(meta['project'], projectId);
    expect(meta['meta'], {
      'action_from_input': own.inputId,
      'action_from_text': own.text,
      'action_from_key': own.key,
    });

    // 対応前の本体には送らない。
    final old = withoutMoves(files);
    final b = MemoryUIAccess()..current = VaultSnapshot(old);
    final d = HubController(b, sampleLoader: () async => old);
    addTearDown(d.dispose);
    await d.useSample();
    await expectLater(
      d.requestMoveAction(unassignedScope, own.key, projectId),
      throwsA(isA<StateError>()),
    );
    expect(b.requests, isEmpty);
  });

  testWidgets('プロジェクト未定の行動の「…」から「プロジェクトへ移す」で移す先を選び、元の行は反映待ちの間も並べない', (t) async {
    final files = (await t.runAsync(() async {
      final access = TempAccess();
      await access.init();
      try {
        return await withOwnAction(access, '見積もりを頼む');
      } finally {
        await access.directory.delete(recursive: true);
      }
    }))!;
    final a = MemoryUIAccess(), c = await sample(t, a, files);
    final item = c.repository!.unassignedOwnActions.single,
        tag = item.key.substring(0, 12);
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(Key('unassigned-more-$tag')));
    await t.tap(find.byKey(Key('unassigned-more-$tag')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('unassigned-move-$tag')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('move-action-dialog')), findsOneWidget);
    // プロジェクト未定からは、プロジェクトだけを選べる。
    expect(find.byKey(const Key('move-action-to-$unassignedScope')), findsNothing);
    await t.tap(find.byKey(const Key('move-action-to-$projectId')));
    await t.pumpAndSettle();
    final request = a.requests.values.single,
        meta = parseMarkdown(request).meta;
    expect(meta['project'], projectId);
    expect(meta['meta'], containsPair('action_from_key', item.key));
    a.current = VaultSnapshot({
      ...files,
      'Input/${meta['request_id']}.md': request,
    });
    await c.reload();
    await t.pumpAndSettle();
    expect(find.byKey(Key('unassigned-action-$tag')), findsNothing);
    expect(
      find.byKey(Key('pending-action-${meta['request_id']}')),
      findsWidgets,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('対応前の本体では、「プロジェクトへ移す」を出さない', (t) async {
    final files = (await t.runAsync(() async {
      final access = TempAccess();
      await access.init();
      try {
        return withoutMoves(await withOwnAction(access, '見積もりを頼む'));
      } finally {
        await access.directory.delete(recursive: true);
      }
    }))!;
    final a = MemoryUIAccess(), c = await sample(t, a, files);
    final tag = c.repository!.unassignedOwnActions.single.key.substring(0, 12);
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(Key('unassigned-more-$tag')));
    await t.tap(find.byKey(Key('unassigned-more-$tag')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('unassigned-move-$tag')), findsNothing);
    expect(t.takeException(), isNull);
  });
}

