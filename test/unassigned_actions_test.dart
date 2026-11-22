import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'capture_test.dart' show TempAccess, location;
import 'unassigned_proposals_test.dart' show inboxFiles, sample;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol;

const fixturePath = 'test/fixtures/unassigned-and-proposals.json';

/// 対応表から、プロジェクトを決めない行動への対応を外す（古い本体）。
Map<String, String> withoutActionScopes() {
  final files = inboxFiles(),
      features = jsonDecode(files[intakeFeaturesPath]!) as Map<String, dynamic>;
  features.remove('action_scopes');
  files[intakeFeaturesPath] = jsonEncode(features);
  return files;
}

/// 端末に保存した依頼を、同期前のVaultに足す。
Future<HubRepository> withRequest(TempAccess access, String requestId) async =>
    HubRepository(
      VaultSnapshot({
        ...inboxFiles(),
        'Input/$requestId.md': (await access.readRequest(location, requestId))!,
      }),
    );

void main() {
  test('対応した本体は、プロジェクトを決めない行動を受け付けると示す', () {
    expect(
      HubRepository(VaultSnapshot(inboxFiles())).intakeFeatures.unassignedActions,
      isTrue,
    );
    expect(
      HubRepository(
        VaultSnapshot(withoutActionScopes()),
      ).intakeFeatures.unassignedActions,
      isFalse,
    );
  });

  test('プロジェクトを決めない行動の依頼を本体が受理し、プロジェクト未定の行動として載る', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      final saved = await service.saveAction(
        '21111111-2222-4333-8444-666666666666',
        unassignedScope,
        '牛乳を買う',
      );
      final meta = parseMarkdown(
        (await access.readRequest(location, saved.requestId))!,
      ).meta;
      expect(meta['kind'], 'action');
      expect(meta.containsKey('project'), isFalse);
      // 同期前は、プロジェクト未定の反映待ちの行動として数える。
      final pending = await withRequest(access, saved.requestId);
      expect(pending.warnings, isEmpty);
      expect(pending.unassignedPendingActions.single.text, '牛乳を買う');
      expect(pending.unassignedPendingActions.single.projectId, unassignedScope);
      expect(pending.unassignedActionCount, 1);
      expect(
        pending.intake.firstWhere((i) => i.id == saved.requestId).title,
        contains('（プロジェクト未定）'),
      );
      final before = homeWidgetContent(pending)['counts'] as String;
      final base =
          homeWidgetContent(
                HubRepository(VaultSnapshot(inboxFiles())),
              )['counts']
              as String;
      int count(String s) =>
          int.parse(RegExp(r'次の一手 (\d+)件').firstMatch(s)![1]!);
      expect(count(before), count(base) + 1);
      // 本体が受け付けると、プロジェクト未定の項目一覧に本人の言葉のまま載り、反映待ちから外れる。
      final synced = HubRepository(
        VaultSnapshot(
          await protocol(access, saved.requestId, fixturePath, 'unassigned'),
        ),
      );
      expect(synced.warnings, isEmpty);
      expect(synced.unassignedPendingActions, isEmpty);
      final item = synced.unassignedOwnActions.single;
      expect(item.text, '牛乳を買う');
      expect(item.label, actionLabel);
      expect(item.action, isTrue);
      expect(synced.unassignedActionCount, 1);
      expect(
        synced.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '次の一手にMac miniが追加しました。',
      );
      // プロジェクトの次の一手には載らない。
      expect(
        synced.projects.values.expand((p) => p.nowItems).where((i) => i.action),
        isEmpty,
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('プロジェクト未定のAIの行を行動にすると、元の行は一覧から外れる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final repo = HubRepository(VaultSnapshot(inboxFiles())),
          memo = repo.unassignedMemos.firstWhere((m) => m.suggestions.isNotEmpty),
          row = repo.unassignedRow(memo.inputId, memo.suggestions.first)!;
      final service = CaptureService(access, location);
      final saved = await service.saveAction(
        '31111111-2222-4333-8444-666666666666',
        unassignedScope,
        '自分の言葉で直した行動',
        from: ActionSource(inputId: row.inputId, text: row.text, key: row.key),
      );
      final pending = await withRequest(access, saved.requestId);
      expect(pending.pendingActionFrom(row.inputId, row.text), isTrue);
      expect(pending.takenOver(row.inputId, row.text), isTrue);
      final synced = HubRepository(
        VaultSnapshot(
          await protocol(access, saved.requestId, fixturePath, 'take-over'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final item = synced.unassignedOwnActions.single;
      expect(item.text, '自分の言葉で直した行動');
      expect(item.fromKey, row.key);
      expect(synced.unassignedRow(row.inputId, row.text), isNull);
      expect(synced.takenOver(row.inputId, row.text), isTrue);
      expect(
        synced.unassignedMemos
            .where((m) => m.inputId == row.inputId)
            .expand((m) => m.suggestions),
        isNot(contains(row.text)),
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('「次の一手」画面から、プロジェクトを決めずに行動を追加し、反映待ちとして示す', (t) async {
    final a = MemoryUIAccess(), c = await sample(t, a, inboxFiles());
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('next-add-action')));
    await t.pumpAndSettle();
    // 追加先に「プロジェクト未定」を選べる。
    if (find.byKey(const Key('action-project')).evaluate().isNotEmpty) {
      await t.tap(find.byKey(const Key('action-project')));
      await t.pumpAndSettle();
      await t.tap(find.text('プロジェクト未定').last);
      await t.pumpAndSettle();
    }
    expect(find.textContaining('プロジェクト未定の次の一手に載ります'), findsOneWidget);
    await t.enterText(find.byKey(const Key('action-text')), '歯医者を予約する');
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('action-submit')));
    await t.pumpAndSettle();
    final request = parseMarkdown(a.requests.values.single);
    expect(request.meta['kind'], 'action');
    expect(request.meta.containsKey('project'), isFalse);
    expect(request.body.trim(), '歯医者を予約する');
    a.current = VaultSnapshot({
      ...inboxFiles(),
      'Input/${request.meta['request_id']}.md': a.requests.values.single,
    });
    await c.reload();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('unassigned-own')), findsOneWidget);
    expect(
      find.byKey(Key('pending-action-${request.meta['request_id']}')),
      findsOneWidget,
    );
    expect(find.textContaining('プロジェクト未定（行動1件'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('プロジェクト未定のAIの行から「自分の行動にする」を開くと、プロジェクト未定を選んでおく', (t) async {
    final a = MemoryUIAccess(), c = await sample(t, a, inboxFiles());
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    final repo = c.repository!,
        memo = repo.unassignedMemos.firstWhere((m) => m.suggestions.isNotEmpty),
        row = repo.unassignedRow(memo.inputId, memo.suggestions.first)!,
        tag = row.key.substring(0, 12);
    await t.ensureVisible(find.byKey(Key('unassigned-take-$tag')));
    await t.tap(find.byKey(Key('unassigned-take-$tag')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('action-from')), findsOneWidget);
    expect(find.textContaining('プロジェクト未定の次の一手に載り'), findsOneWidget);
    await t.tap(find.byKey(const Key('action-submit')));
    await t.pumpAndSettle();
    final meta = parseMarkdown(a.requests.values.single).meta;
    expect(meta.containsKey('project'), isFalse);
    expect(meta['meta'], containsPair('action_from_key', row.key));
    a.current = VaultSnapshot({
      ...inboxFiles(),
      'Input/${meta['request_id']}.md': a.requests.values.single,
    });
    await c.reload();
    await t.pumpAndSettle();
    // 反映待ちの間は、元の行に操作を出さない。
    expect(find.byKey(Key('unassigned-take-$tag')), findsNothing);
    expect(find.text('自分の行動にしました（反映待ち）'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('反映したプロジェクト未定の行動を、ホームと「次の一手」に数えて示し、完了を報告できる', (t) async {
    final synced = (await t.runAsync(() async {
      final access = TempAccess();
      await access.init();
      try {
        final saved = await CaptureService(access, location).saveAction(
          '41111111-2222-4333-8444-666666666666',
          unassignedScope,
          '電池を買う',
        );
        return await protocol(access, saved.requestId, fixturePath, 'widget');
      } finally {
        await access.directory.delete(recursive: true);
      }
    }))!;
    final a = MemoryUIAccess(), c = await sample(t, a, synced);
    final item = c.repository!.unassignedOwnActions.single,
        tag = item.key.substring(0, 12);
    expect(find.textContaining('プロジェクト未定の次の一手 行動1件'), findsOneWidget);
    expect(find.byKey(Key('home-unassigned-action-$tag')), findsOneWidget);
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('unassigned-action-$tag')), findsOneWidget);
    expect(find.text('本人が追加: 電池を買う'), findsOneWidget);
    // 本人が追加した行動には、自分の行動にする操作は出さない。
    expect(find.byKey(Key('unassigned-take-$tag')), findsNothing);
    await t.ensureVisible(find.byKey(Key('unassigned-resolve-$tag')));
    await t.tap(find.byKey(Key('unassigned-resolve-$tag')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-action')));
    await t.pumpAndSettle();
    final meta = parseMarkdown(a.requests.values.single).meta;
    expect(meta['operation'], 'item-resolution');
    expect(meta['project_id'], unassignedScope);
    expect(meta['item_key'], item.key);
    expect(meta['action'], 'resolve');
    expect(t.takeException(), isNull);
  });

  testWidgets('プロジェクトを決めない行動に対応していない本体では、追加先に選ばせない', (t) async {
    final a = MemoryUIAccess(), c = await sample(t, a, withoutActionScopes());
    expect(c.repository!.intakeFeatures.unassignedActions, isFalse);
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    // 対応前の本体は引き取った行を一覧から外さないため、プロジェクト未定の行に「自分の行動にする」を出さない。
    for (final item in c.repository!.unassignedItems) {
      expect(
        find.byKey(Key('unassigned-take-${item.key.substring(0, 12)}')),
        findsNothing,
      );
    }
    if (find.byKey(const Key('next-add-action')).evaluate().isNotEmpty) {
      await t.tap(find.byKey(const Key('next-add-action')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('action-project-unassigned')), findsNothing);
      expect(find.text('プロジェクト未定'), findsNothing);
      await t.tap(find.text('やめる'));
      await t.pumpAndSettle();
    }
    expect(t.takeException(), isNull);
  });
}
