import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/today.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'capture_test.dart' show TempAccess, location;
import 'unassigned_proposals_test.dart' show inboxFiles, sample;
import 'widget_test.dart' show MemoryUIAccess;

const itemsPath = '90_system/now-items/$unassignedScope.json';

/// 対応表から、プロジェクト未定の行の完了・却下への対応を外す（古い本体）。
Map<String, String> withoutScopes() {
  final files = inboxFiles(),
      features = jsonDecode(files[intakeFeaturesPath]!) as Map<String, dynamic>;
  features.remove('item_scopes');
  files[intakeFeaturesPath] = jsonEncode(features);
  return files;
}

void main() {
  test('本体の項目一覧から、プロジェクト未定の行のキーを読む', () {
    final repo = HubRepository(VaultSnapshot(inboxFiles()));
    expect(repo.warnings, isEmpty);
    expect(repo.intakeFeatures.unassignedItems, isTrue);
    for (final memo in repo.unassignedMemos) {
      if (memo.task) {
        expect(repo.unassignedRow(memo.inputId, memo.text), isNotNull);
      }
      for (final s in memo.suggestions) {
        expect(repo.unassignedRow(memo.inputId, s)?.label, 'AI提案: ');
      }
    }
    expect(repo.closedUnassigned, isEmpty);
    // 項目一覧が壊れていたら、操作を出さずに注意を示す。
    final broken = HubRepository(
      VaultSnapshot({...inboxFiles(), itemsPath: '{"schema_version":1}'}),
    );
    expect(broken.unassignedItems, isEmpty);
    expect(broken.problemPaths, contains(itemsPath));
    // 別のAIへ渡す資料は止めない。
    expect(broken.copyBlocked(), isFalse);
  });

  test('今日の3つの行は、プロジェクト未定の項目に結び付く', () {
    final repo = HubRepository(VaultSnapshot(inboxFiles())),
        item = repo.unassignedItems.first,
        pick = TodayPick.unassigned(item),
        entry = todayEntry(repo, pick);
    expect(pick.projectId, unassignedScope);
    expect(entry.unassigned, isTrue);
    expect(entry.item?.key, item.key);
    expect(entry.project, isNull);
    expect(todayOpen(repo, pick), isTrue);
  });

  test('Dartの却下と完了を本体が受理し、行が一覧から外れて元に戻せる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final repo = HubRepository(VaultSnapshot(inboxFiles())),
          item = repo.unassignedItems.first,
          service = CaptureService(access, location);
      // 却下は「もう古い」だけ。
      await expectLater(
        service.saveItemResolution(
          '51111111-2222-4333-8444-555555555555',
          unassignedScope,
          item,
          'exclude',
          reason: 'misread',
        ),
        throwsFormatException,
      );
      final saved = await service.saveItemResolution(
        '51111111-2222-4333-8444-555555555555',
        unassignedScope,
        item,
        'exclude',
        reason: 'outdated',
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(
        parseMarkdown(raw).meta,
        containsPair('project_id', unassignedScope),
      );
      final pending = HubRepository(
        VaultSnapshot({...inboxFiles(), 'Input/${saved.requestId}.md': raw}),
      );
      expect(pending.warnings, isEmpty);
      expect(pending.itemRequestIdFor(item.key), saved.requestId);
      final out = File('${access.directory.path}/out.json');
      final result = await Process.run('node', [
        'scripts/check_request_protocol.mjs',
        access.request(location, saved.requestId).path,
        'test/fixtures/unassigned-and-proposals.json',
        out.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final synced = HubRepository(
        VaultSnapshot(
          Map<String, String>.from(jsonDecode(await out.readAsString()) as Map),
        ),
      );
      expect(synced.warnings, isEmpty);
      expect(synced.itemRequestIdFor(item.key), isNull);
      expect(
        synced.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '報告をMiniが反映しました。',
      );
      expect(synced.closedUnassigned.single.key, item.key);
      expect(synced.closedUnassigned.single.excluded, isTrue);
      // 一覧の行からは外れる。
      expect(
        synced.unassignedMemos.any(
          (m) =>
              (m.inputId == item.inputId) &&
              ((m.task && m.text == item.text) ||
                  m.suggestions.contains(item.text)),
        ),
        isFalse,
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('次の一手の「プロジェクト未定」で、今日やる・却下を操作できる', (t) async {
    final a = MemoryUIAccess(), c = await sample(t, a, inboxFiles());
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    final repo = c.repository!,
        memo = repo.unassignedMemos.first,
        row = repo.unassignedRow(memo.inputId, memo.suggestions.first)!,
        tag = row.key.substring(0, 12);
    // 今日やると、今日の3つに「プロジェクト未定」として出る。
    await t.tap(find.byKey(Key('today-$tag')));
    await t.pumpAndSettle();
    expect(c.today.picks.single.projectId, unassignedScope);
    expect(find.byKey(Key('today-pick-$tag')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(Key('today-pick-$tag')),
        matching: find.text('プロジェクト未定'),
      ),
      findsOneWidget,
    );
    // 却下すると依頼を保存し、反映待ちを示す。
    await t.tap(find.byKey(Key('unassigned-reject-$tag')));
    await t.pumpAndSettle();
    expect(find.text('却下する'), findsWidgets);
    await t.tap(find.byKey(const Key('confirm-action')));
    await t.pumpAndSettle();
    expect(a.requests, hasLength(1));
    final meta = parseMarkdown(a.requests.values.single).meta;
    expect(meta['project_id'], unassignedScope);
    expect(meta['action'], 'exclude');
    expect(meta['reason'], 'outdated');
    expect(t.takeException(), isNull);
  });

  testWidgets('古い本体では、プロジェクト未定の行に操作を出さない', (t) async {
    final a = MemoryUIAccess();
    final c = await sample(t, a, withoutScopes());
    expect(c.repository!.intakeFeatures.unassignedItems, isFalse);
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    final row = c.repository!.unassignedItems.first;
    expect(
      find.byKey(Key('today-${row.key.substring(0, 12)}')),
      findsNothing,
    );
    expect(find.text('却下'), findsNothing);
  });
}
