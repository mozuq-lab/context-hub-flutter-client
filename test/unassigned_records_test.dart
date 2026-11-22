import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';

import 'capture_test.dart' show TempAccess, location;
import 'unassigned_actions_test.dart' show fixturePath;
import 'unassigned_proposals_test.dart' show inboxFiles, sample;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol;

/// 本体の対応表から、プロジェクト未定の行動への日付・手間の目安の対応を外す（古い本体）。
Map<String, String> withoutRecordScopes(Map<String, String> files) {
  final features =
      jsonDecode(files[intakeFeaturesPath]!) as Map<String, dynamic>;
  features.remove('item_record_scopes');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

/// 項目一覧の本人が追加した行動に、本体が書くのと同じ形で日付と手間の目安を付ける。
Map<String, String> withRecords(
  Map<String, String> files, {
  String? due,
  String? reviewAfter,
  String? effort,
}) {
  const path = '90_system/now-items/$unassignedScope.json';
  final list = jsonDecode(files[path]!) as Map<String, dynamic>;
  for (final raw in list['items'] as List) {
    final item = raw as Map<String, dynamic>;
    if (item['action'] == null) continue;
    if (due != null || reviewAfter != null) {
      item['schedule'] = {
        'id': 'SCH-${'0' * 26}',
        'due': due,
        'review_after': reviewAfter,
      };
    }
    if (effort != null) item['effort'] = effort;
  }
  return {...files, path: jsonEncode(list)};
}

/// 前の依頼を本体が反映したVaultを、次の依頼の上流検査に渡すファイルとして書く。
Future<String> writeFixture(
  TempAccess access,
  Map<String, String> files,
) async {
  final file = File('${access.directory.path}/base-${files.length}.json');
  await file.writeAsString(jsonEncode(files));
  return file.path;
}

String dateAfter(int days) =>
    hubToday(DateTime.now().add(Duration(days: days)));

void main() {
  test('対応した本体は、プロジェクト未定の行動に日付と手間の目安を付けられると示す', () {
    expect(
      HubRepository(VaultSnapshot(inboxFiles()))
          .intakeFeatures
          .unassignedRecords,
      isTrue,
    );
    expect(
      HubRepository(VaultSnapshot(withoutRecordScopes(inboxFiles())))
          .intakeFeatures
          .unassignedRecords,
      isFalse,
    );
  });

  test('プロジェクト未定の行動への期日（繰り返し）・手間の目安・定例の回の依頼を本体が受理し、項目一覧に載る', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      final added = await service.saveAction(
        '51111111-2222-4333-8444-666666666666',
        unassignedScope,
        'ゴミを出す',
      );
      var files = await protocol(access, added.requestId, fixturePath, 'add');
      var repo = HubRepository(VaultSnapshot(files));
      var item = repo.unassignedOwnActions.single;
      final due = dateAfter(1);
      final schedule = await service.saveItemSchedule(
        '52111111-2222-4333-8444-666666666666',
        unassignedScope,
        item,
        due,
        null,
        withRepeat: true,
        repeat: const RepeatRule('week', 1),
      );
      final meta = parseMarkdown(
        (await access.readRequest(location, schedule.requestId))!,
      ).meta;
      expect(meta['project_id'], unassignedScope);
      // 同期前は、日付の依頼が反映待ちとして示される。
      final pending = HubRepository(
        VaultSnapshot({
          ...files,
          'Input/${schedule.requestId}.md': (await access.readRequest(
            location,
            schedule.requestId,
          ))!,
        }),
      );
      expect(pending.warnings, isEmpty);
      expect(pending.scheduleRequestIdFor(item.key), schedule.requestId);
      files = await protocol(
        access,
        schedule.requestId,
        await writeFixture(access, files),
        'schedule',
      );
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      item = repo.unassignedOwnActions.single;
      expect(item.due, due);
      expect(item.repeat, const RepeatRule('week', 1));
      expect(repo.scheduleRequestIdFor(item.key), isNull);
      expect(
        repo.intake.firstWhere((i) => i.id == schedule.requestId).detail,
        '日付をMac miniが反映しました。',
      );

      final effort = await service.saveItemEffort(
        '53111111-2222-4333-8444-666666666666',
        unassignedScope,
        item,
        'quick',
      );
      files = await protocol(
        access,
        effort.requestId,
        await writeFixture(access, files),
        'effort',
      );
      repo = HubRepository(VaultSnapshot(files));
      item = repo.unassignedOwnActions.single;
      expect(item.effort, 'quick');
      expect(itemRecordLabel(item), '期日 $due（毎週）・手間 15分ほど');

      final round = await service.saveItemOccurrence(
        '54111111-2222-4333-8444-666666666666',
        unassignedScope,
        item,
        'done',
      );
      files = await protocol(
        access,
        round.requestId,
        await writeFixture(access, files),
        'round',
      );
      repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      item = repo.unassignedOwnActions.single;
      expect(item.due!.compareTo(due), greaterThan(0));
      expect(item.resolved, isFalse);
      expect(repo.scheduleRequestIdFor(item.key), isNull);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('AIの行と、対応していない本体には、日付と手間の目安を依頼しない', () async {
    final repo = HubRepository(VaultSnapshot(inboxFiles())),
        ai = repo.unassignedItems.firstWhere((i) => !i.action);
    final a = MemoryUIAccess()..current = VaultSnapshot(inboxFiles());
    final c = HubController(a, sampleLoader: () async => inboxFiles());
    addTearDown(c.dispose);
    await c.useSample();
    await expectLater(
      c.requestItemSchedule(unassignedScope, ai.key, '2026-12-01', null),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      c.requestItemEffort(unassignedScope, ai.key, 'quick'),
      throwsA(isA<StateError>()),
    );
    expect(a.requests, isEmpty);
  });

  test('期日が近いプロジェクト未定の行動は、ウィジェットでも期日順に先頭へ、休ませている行動は出さない', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      final added = await service.saveAction(
        '55111111-2222-4333-8444-666666666666',
        unassignedScope,
        '書類を出す',
      );
      final files = await protocol(access, added.requestId, fixturePath, 'w');
      const shown = HomeWidgetSettings(showText: true);
      final soon = HubRepository(
        VaultSnapshot(withRecords(files, due: dateAfter(0))),
      );
      final lines =
          homeWidgetContent(soon, settings: shown)['lines'] as List<String>;
      expect(lines.first, contains('書類を出す'));
      final resting = HubRepository(
        VaultSnapshot(withRecords(files, reviewAfter: dateAfter(10))),
      );
      expect(
        (homeWidgetContent(resting, settings: shown)['lines'] as List<String>)
            .join('\n'),
        isNot(contains('書類を出す')),
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('期日が近いプロジェクト未定の行動を「次の一手」の期日の欄に出し、「…」から手間の目安を依頼できる', (t) async {
    final synced = (await t.runAsync(() async {
      final access = TempAccess();
      await access.init();
      try {
        final saved = await CaptureService(access, location).saveAction(
          '56111111-2222-4333-8444-666666666666',
          unassignedScope,
          '歯医者を予約する',
        );
        return await protocol(access, saved.requestId, fixturePath, 'ui');
      } finally {
        await access.directory.delete(recursive: true);
      }
    }))!;
    final due = dateAfter(0),
        files = withRecords(synced, due: due, effort: 'hour');
    final a = MemoryUIAccess(), c = await sample(t, a, files);
    final item = c.repository!.unassignedOwnActions.single,
        tag = item.key.substring(0, 12);
    // ホームでは、行動の下に日付と手間の目安を示す。
    expect(find.text('期日 $due・手間 1時間ほど'), findsOneWidget);
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    // 期日の欄（今日）に、プロジェクト未定として載り、プロジェクト未定の欄では件数だけを示す。
    expect(find.byKey(const Key('next-bucket-today')), findsOneWidget);
    expect(find.byKey(Key('unassigned-action-$tag')), findsOneWidget);
    expect(find.byKey(const Key('unassigned-moved')), findsOneWidget);
    expect(find.byKey(Key('unassigned-label-$tag')), findsOneWidget);
    // 手間の目安で絞り込んでも、合う行動は残る。
    await t.tap(find.byKey(const Key('effort-filter-quick')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('unassigned-action-$tag')), findsNothing);
    await t.tap(find.byKey(const Key('effort-filter-hour')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('unassigned-action-$tag')), findsOneWidget);
    await t.tap(find.byKey(const Key('effort-filter-all')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(Key('unassigned-more-$tag')));
    await t.tap(find.byKey(Key('unassigned-more-$tag')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('unassigned-schedule-$tag')), findsOneWidget);
    await t.tap(find.byKey(Key('unassigned-effort-$tag')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('effort-choice-quick')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('effort-submit')));
    await t.pumpAndSettle();
    final meta = parseMarkdown(a.requests.values.single).meta;
    expect(meta['operation'], 'item-effort');
    expect(meta['project_id'], unassignedScope);
    expect(meta['item_key'], item.key);
    expect(meta['effort'], 'quick');
    expect(t.takeException(), isNull);
  });

  testWidgets('日付に対応していない本体では、プロジェクト未定の行動に「…」を出さない', (t) async {
    final synced = (await t.runAsync(() async {
      final access = TempAccess();
      await access.init();
      try {
        final saved = await CaptureService(access, location).saveAction(
          '57111111-2222-4333-8444-666666666666',
          unassignedScope,
          '電池を買う',
        );
        return await protocol(access, saved.requestId, fixturePath, 'old');
      } finally {
        await access.directory.delete(recursive: true);
      }
    }))!;
    final a = MemoryUIAccess(),
        c = await sample(t, a, withoutRecordScopes(synced));
    final tag = c.repository!.unassignedOwnActions.single.key.substring(0, 12);
    await t.tap(find.byKey(const Key('home-unassigned')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('unassigned-action-$tag')), findsOneWidget);
    expect(find.byKey(Key('unassigned-more-$tag')), findsNothing);
    expect(t.takeException(), isNull);
  });
}
