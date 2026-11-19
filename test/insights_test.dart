import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'unassigned_proposals_test.dart' show sample;
import 'widget_test.dart' show MemoryUIAccess;

/// 本体の週次の統合が書いた「今週の気づき」（90_system/insights.json）を含む架空のVault。
/// 5つの欄の項目と、気づきを作った後に訂正が届いた根拠のメモを含む。
Map<String, dynamic> insightsFixture() =>
    jsonDecode(File('test/fixtures/insights.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, String> insightsFiles() =>
    Map<String, String>.from(insightsFixture()['files'] as Map);
Map<String, dynamic> get expected =>
    insightsFixture()['expected'] as Map<String, dynamic>;
const insightsPath = HubRepository.insightsPath;

/// 一覧を書き換えたVault。
Map<String, String> changed(void Function(Map<String, dynamic>) change) {
  final files = insightsFiles(),
      j = jsonDecode(files[insightsPath]!) as Map<String, dynamic>;
  change(j);
  files[insightsPath] = jsonEncode(j);
  return files;
}

/// 本体が書いた、ほかの状態の一覧（running・failed・disabled）に差し替えたVault。
Map<String, String> inState(String state) => insightsFiles()
  ..[insightsPath] = jsonEncode(
    (expected['states'] as Map<String, dynamic>)[state],
  );

Map<String, dynamic> latestOf(Map<String, dynamic> j) =>
    j['latest'] as Map<String, dynamic>;
List<Map<String, dynamic>> itemsOf(Map<String, dynamic> j) =>
    (latestOf(j)['items'] as List).cast<Map<String, dynamic>>();

void main() {
  group('今週の気づき', () {
    test('本体の一覧から、欄ごとの気づきと最初の一歩と根拠のメモを読む', () {
      final repo = HubRepository(VaultSnapshot(insightsFiles()));
      expect(repo.warnings, isEmpty);
      final insights = repo.insights!;
      expect(insights.intervalDays, 7);
      expect(insights.mode, 'first');
      expect(insights.createdAt, DateTime.utc(2026, 11, 15));
      expect(insights.failure, isNull);
      expect(insights.recordProblems, 0);
      expect(insights.waiting, 0);
      expect(insights.items, hasLength(expected['total']));
      final sections = expected['sections'] as Map<String, dynamic>;
      for (final section in insightSectionLabels.keys) {
        expect(
          insights.items.where((i) => i.section == section).map((i) => i.text),
          sections[section],
          reason: section,
        );
      }
      expect(insights.items.map((i) => i.sources.length), expected['sources']);
      final stalled = insights.items.singleWhere((i) => i.section == 'stalled');
      expect(stalled.firstStep, expected['first_step']);
      expect(insights.items.where((i) => i.firstStep != null), [stalled]);
      // 気づきを作った後に訂正が届いたメモだけ、訂正ありと示す。
      for (final item in insights.items) {
        for (final source in item.sources) {
          expect(
            source.corrected,
            source.inputId == expected['corrected'],
            reason: source.inputId,
          );
          // 根拠のメモは、この端末で開ける。
          expect(repo.inputRecord(source.inputId)!.kind, 'memo');
        }
      }
    });

    test('根拠のメモが届いていない項目は載せず、届いてから載せる件数を数える', () {
      final full = HubRepository(VaultSnapshot(insightsFiles())).insights!;
      final shift = full.items.singleWhere((i) => i.section == 'shifts'),
          missing = shift.sources.first.inputId;
      final files = insightsFiles()
        ..removeWhere(
          (path, _) =>
              path.startsWith('00_inbox/') && path.endsWith('_$missing.md'),
        );
      final repo = HubRepository(VaultSnapshot(files));
      final insights = repo.insights!;
      final affected = full.items.where(
        (i) => i.sources.any((s) => s.inputId == missing),
      );
      expect(affected, isNotEmpty);
      expect(insights.waiting, affected.length);
      expect(insights.items, hasLength(full.items.length - affected.length));
      expect(insights.items.map((i) => i.key), isNot(contains(shift.key)));
    });

    test('このアプリの知らない欄の項目は、注意を出さずに載せない', () {
      final files = changed((j) {
        itemsOf(j).first['section'] = 'themes';
      });
      final repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      expect(repo.insights!.items, hasLength(expected['total'] - 1));
      expect(repo.insights!.waiting, 0);
    });

    test('最後の実行が失敗したときは理由を示し、前回までの気づきは残す', () {
      Insights read(Object? error) => HubRepository(
        VaultSnapshot(
          changed((j) {
            j['last_attempt'] = {
              ...(j['last_attempt'] as Map<String, dynamic>),
              'status': 'failed',
              'error': error,
            };
          }),
        ),
      ).insights!;
      final timeout = read('timeout');
      expect(timeout.failure, '応答待ちの時間切れ');
      expect(timeout.items, hasLength(expected['total']));
      expect(read('interrupted').failure, '実行が途中で止まった');
      // このアプリの知らない理由は、本体のHOMEへ案内する。
      expect(read('quota-exceeded').failure, '理由は本体のHOMEで確認');
      // 本体がモデルの障害の後に書いた一覧。
      final failed = HubRepository(VaultSnapshot(inState('failed')));
      expect(failed.warnings, isEmpty);
      expect(failed.insights!.failure, 'モデルの呼び出しに失敗');
      expect(failed.insights!.items, hasLength(expected['total']));
      // 本体がモデルを待つ間に書いた一覧（実行中）は、失敗として扱わない。
      final running = HubRepository(VaultSnapshot(inState('running')));
      expect(running.warnings, isEmpty);
      expect(running.insights!.failure, isNull);
      expect(running.insights!.items, hasLength(expected['total']));
      // 実行中・成功・足せる項目がなかった回は、失敗として扱わない。
      for (final status in ['running', 'ok', 'empty']) {
        final files = changed((j) {
          (j['last_attempt'] as Map<String, dynamic>)['status'] = status;
        });
        expect(
          HubRepository(VaultSnapshot(files)).insights!.failure,
          isNull,
          reason: status,
        );
      }
    });

    test('まだ成功した実行がなければ項目を出さず、読めない記録の件数は示す', () {
      final repo = HubRepository(
        VaultSnapshot(
          changed((j) {
            j['latest'] = null;
            j['record_problems'] = 2;
          }),
        ),
      );
      expect(repo.warnings, isEmpty);
      expect(repo.insights!.items, isEmpty);
      expect(repo.insights!.createdAt, isNull);
      expect(repo.insights!.recordProblems, 2);
    });

    test('本体で無効にした・一覧を書いていないときは、何も出さない', () {
      // 本体で有効にした後に無効へ戻したときに、本体が書く一覧。
      final disabled = HubRepository(VaultSnapshot(inState('disabled')));
      expect(disabled.insights, isNull);
      expect(disabled.warnings, isEmpty);
      final old = HubRepository(
        VaultSnapshot(insightsFiles()..remove(insightsPath)),
      );
      expect(old.insights, isNull);
      expect(old.warnings, isEmpty);
    });

    test('形式が不正な一覧は注意を1件出して使わず、資料のコピーは止めない', () {
      final changes = <void Function(Map<String, dynamic>)>[
        (j) => j.remove('generated_at'),
        (j) => j['enabled'] = 'yes',
        (j) => j['interval_days'] = 0,
        (j) => j['record_problems'] = -1,
        (j) => j['latest'] = [],
        (j) => j['next_due_at'] = '来週',
        (j) => latestOf(j)['id'] = 'SYN-1',
        (j) => latestOf(j)['created_at'] = null,
        (j) => latestOf(j)['items'] = {},
        (j) => itemsOf(j).first['key'] = 'abc',
        (j) => itemsOf(j)[1]['key'] = itemsOf(j).first['key'],
        (j) => itemsOf(j).first['text'] = ' ',
        (j) => itemsOf(j).first['first_step'] = '',
        (j) => itemsOf(j).first['sources'] = [],
        (j) => (itemsOf(j).first['sources'] as List).first['input_id'] = 'IN-1',
        (j) => (itemsOf(j).first['sources'] as List).first['corrected'] = 1,
        (j) => (itemsOf(j).first['sources'] as List).add(
          (itemsOf(j).first['sources'] as List).first,
        ),
        (j) =>
            (itemsOf(j).first['sources'] as List).first['occurred_at'] = '昨日',
        (j) => (j['last_attempt'] as Map<String, dynamic>)['status'] = 1,
        (j) => (j['last_attempt'] as Map<String, dynamic>)['error'] = 1,
      ];
      for (final (index, change) in changes.indexed) {
        final repo = HubRepository(VaultSnapshot(changed(change)));
        expect(repo.insights, isNull, reason: '$index');
        expect(repo.warnings.single, contains(insightsPath), reason: '$index');
        expect(repo.copyBlocked(), isFalse, reason: '$index');
      }
      // 本体が新しい形式で書いた一覧は、アプリの更新を案内する。
      final newer = HubRepository(
        VaultSnapshot(changed((j) => j['schema_version'] = 2)),
      );
      expect(newer.insights, isNull);
      expect(newer.warnings, [newerFormatWarning]);
    });

    test('間隔を過ぎても新しい結果がないときだけ、古い結果と分かるようにする', () {
      final insights = HubRepository(VaultSnapshot(insightsFiles())).insights!;
      final created = insights.createdAt!;
      expect(insights.ageDays(created.add(const Duration(hours: 23))), 0);
      expect(insights.stale(created.add(const Duration(days: 7))), isFalse);
      expect(insights.ageDays(created.add(const Duration(days: 8))), 8);
      expect(insights.stale(created.add(const Duration(days: 8))), isTrue);
      // 端末の時計が遅れていても、負の日数にしない。
      expect(insights.ageDays(created.subtract(const Duration(days: 1))), 0);
    });

    testWidgets('ホームの先頭に欄ごとの1件を出し、残りを開いて、根拠のメモを確かめられる', (t) async {
      final a = MemoryUIAccess(),
          // 実行日を昨日にして、古い結果の注記が出ない状態にする。
          files = changed((j) {
            latestOf(j)['created_at'] = DateTime.now()
                .toUtc()
                .subtract(const Duration(days: 1))
                .toIso8601String();
          }),
          c = await sample(t, a, files);
      final insights = c.repository!.insights!, items = insights.items;
      expect(find.text('今週の気づき ${items.length}件'), findsOneWidget);
      // 今週の気づきは「次の一手」より前に置く。
      expect(
        t.getTopLeft(find.byKey(const Key('home-insights'))).dy,
        lessThan(t.getTopLeft(find.byKey(const Key('home-next'))).dy),
      );
      final header = find.byKey(const Key('home-insights'));
      expect(
        find.descendant(of: header, matching: find.textContaining('AIの推定・未検証')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.textContaining('日前の結果')),
        findsNothing,
      );
      for (final section in insightSectionLabels.entries) {
        expect(find.byKey(Key('home-insights-${section.key}')), findsOneWidget);
        expect(find.text(section.value), findsWidgets);
      }
      // たたんでいる間は、欄ごとに先頭の1件だけを出す。
      final questions = items.where((i) => i.section == 'questions').toList();
      expect(questions, hasLength(2));
      expect(
        find.byKey(Key('home-insight-${questions[0].key}')),
        findsOneWidget,
      );
      expect(find.byKey(Key('home-insight-${questions[1].key}')), findsNothing);
      expect(find.text('ほか1件を表示'), findsOneWidget);
      await t.tap(find.byKey(const Key('home-insights-more')));
      await t.pumpAndSettle();
      for (final item in items) {
        expect(find.byKey(Key('home-insight-${item.key}')), findsOneWidget);
      }
      expect(find.text('たたむ'), findsOneWidget);
      // 最初の一歩と、訂正が届いた根拠を示す。
      expect(find.text('最初の一歩: ${expected['first_step']}'), findsOneWidget);
      final stalled = items.singleWhere((i) => i.section == 'stalled');
      final corrected = stalled.sources.single;
      expect(corrected.inputId, expected['corrected']);
      final button = find.byKey(
        Key('home-insight-source-${stalled.key}-${corrected.inputId}'),
      );
      expect(
        find.descendant(
          of: button,
          matching: find.text('${hubToday(corrected.at)}のメモ（訂正あり）'),
        ),
        findsOneWidget,
      );
      // 根拠のメモを開く。
      await t.tap(button);
      await t.pumpAndSettle();
      expect(find.text('出典・日時'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('home-insights')), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('前回の実行が失敗したときと、間隔を過ぎた古い結果のときに、それと分かるようにする', (t) async {
      final a = MemoryUIAccess(),
          // 本体がモデルの障害の後に書いた一覧を、間隔を過ぎた古い結果にする。
          state = Map<String, dynamic>.from(
            (expected['states'] as Map<String, dynamic>)['failed'] as Map,
          );
      state['latest'] = {
        ...(state['latest'] as Map<String, dynamic>),
        'created_at': '2026-01-01T00:00:00.000Z',
      };
      state['record_problems'] = 1;
      await sample(t, a, insightsFiles()..[insightsPath] = jsonEncode(state));
      final failure = find.byKey(const Key('home-insights-failure'));
      expect(
        find.descendant(
          of: failure,
          matching: find.textContaining('（モデルの呼び出しに失敗）。前回までの気づきを表示しています。'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('home-insights-records')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-insights')),
          matching: find.textContaining('日前の結果'),
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('成功した実行がないまま失敗したときは、失敗だけを示す', (t) async {
      final a = MemoryUIAccess(),
          state = Map<String, dynamic>.from(
            (expected['states'] as Map<String, dynamic>)['failed'] as Map,
          )..['latest'] = null;
      await sample(t, a, insightsFiles()..[insightsPath] = jsonEncode(state));
      final text = t
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('home-insights-failure')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(text, contains('（モデルの呼び出しに失敗）'));
      expect(text, isNot(contains('前回までの気づき')));
      expect(find.byKey(const Key('home-insights')), findsNothing);
    });

    testWidgets('新しいメモが少なかった回は、以前のメモの見直しが中心と示す', (t) async {
      final a = MemoryUIAccess();
      await sample(t, a, changed((j) => latestOf(j)['mode'] = 'quiet'));
      expect(
        find.descendant(
          of: find.byKey(const Key('home-insights')),
          matching: find.textContaining('以前のメモの見直しが中心'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('結果がない・本体で無効のときは、ホームに欄を出さない', (t) async {
      final a = MemoryUIAccess();
      await sample(t, a, inState('disabled'));
      expect(find.byKey(const Key('home-insights')), findsNothing);
      expect(find.byKey(const Key('home-insights-failure')), findsNothing);
      expect(find.byKey(const Key('home-next')), findsOneWidget);
    });

    testWidgets('根拠のメモがまだ届いていないときは、届いてから出すと示す', (t) async {
      final a = MemoryUIAccess(),
          files = insightsFiles()
            ..removeWhere((path, _) => path.startsWith('00_inbox/'));
      final c = await sample(t, a, files);
      expect(c.repository!.insights!.items, isEmpty);
      expect(find.byKey(const Key('home-insights')), findsNothing);
      expect(
        t.widget<Text>(find.byKey(const Key('home-insights-waiting'))).data,
        contains('届いていない${expected['total']}件'),
      );
    });

    testWidgets('狭い画面でもoverflowしない', (t) async {
      final a = MemoryUIAccess();
      final c = await sample(t, a, insightsFiles(), size: const Size(390, 844));
      Future<void> reach(Finder target) async {
        await t.scrollUntilVisible(
          target,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await t.pumpAndSettle();
        await t.ensureVisible(target);
        await t.pumpAndSettle();
      }

      expect(find.byKey(const Key('home-insights')), findsOneWidget);
      await reach(find.byKey(const Key('home-insights-more')));
      await t.tap(find.byKey(const Key('home-insights-more')));
      await t.pumpAndSettle();
      final last = c.repository!.insights!.items.last;
      await reach(find.byKey(Key('home-insight-${last.key}')));
      expect(t.takeException(), isNull);
    });
  });
}
