import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/calendar.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'draft_test.dart' show LosingAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'next_actions_test.dart' show multiProjectFiles;
import 'fixtures.dart';

const historyPath = '10_projects/context-hub/HISTORY.md';

/// 本体が書く形で、項目一覧の項目に期日・見直す日を付ける。
Map<String, String> withSchedule(
  Map<String, String> files,
  String project,
  int index, {
  String? due,
  String? reviewAfter,
}) {
  final path = '90_system/now-items/$project.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>,
      item = (items['items'] as List)[index] as Map<String, dynamic>;
  item['schedule'] = {
    'id': 'SCH-01M7AAAAAAAAAAAAAAAAAAAA${index.toString().padLeft(2, '0')}',
    'due': due,
    'review_after': reviewAfter,
  };
  return {...files, path: jsonEncode(items)};
}

/// 項目の「…」を開く。
Future<void> openMore(WidgetTester tester, String tag) async {
  await tester.ensureVisible(find.byKey(Key('item-more-$tag')));
  await tester.tap(find.byKey(Key('item-more-$tag')));
  await tester.pumpAndSettle();
}

void main() {
  test('期日の暦日と区分は本体と同じ規則で決める', () {
    expect(validScheduleDate('2026-11-20'), isTrue);
    for (final bad in [
      '2026-02-30',
      '2026-13-01',
      '1999-12-31',
      '2100-01-01',
      '2026-1-1',
      20261120,
      null,
    ]) {
      expect(validScheduleDate(bad), isFalse, reason: '$bad');
    }
    expect(addScheduleDays('2026-12-30', 3), '2027-01-02');
    // 「今日」は端末のタイムゾーンではなく、本体と同じ日本時間で決める。
    expect(hubToday(DateTime.utc(2026, 11, 15, 14, 59)), '2026-11-15');
    expect(hubToday(DateTime.utc(2026, 11, 15, 15)), '2026-11-16');
    expect(hubToday(DateTime.parse('2026-11-15T10:00:00-08:00')), '2026-11-16');
    const today = '2026-11-15';
    expect(scheduleBucket('2026-11-14', null, today), (
      bucket: ScheduleBucket.overdue,
      hidden: false,
    ));
    expect(scheduleBucket(today, null, today), (
      bucket: ScheduleBucket.today,
      hidden: false,
    ));
    expect(scheduleBucket('2026-11-21', null, today), (
      bucket: ScheduleBucket.week,
      hidden: false,
    ));
    expect(scheduleBucket('2026-11-22', null, today), (
      bucket: ScheduleBucket.later,
      hidden: false,
    ));
    expect(scheduleBucket(null, '2026-11-16', today), (
      bucket: ScheduleBucket.none,
      hidden: true,
    ));
    expect(scheduleBucket('2026-11-17', '2026-11-20', today), (
      bucket: ScheduleBucket.week,
      hidden: false,
    ));
    expect(scheduleBucket('2026-12-01', '2026-11-20', today), (
      bucket: ScheduleBucket.later,
      hidden: true,
    ));
  });

  test('項目一覧の日付を読み、不正な日付の一覧は読まずに問題として示す', () {
    final files = withSchedule(fixtureFiles(), projectId, 0, due: '2026-11-20');
    final item = HubRepository(
      fixture(files),
    ).projects[projectId]!.nowItems.first;
    expect(
      (item.due, item.reviewAfter, item.scheduled),
      ('2026-11-20', null, true),
    );
    expect(
      HubRepository(fixture()).projects[projectId]!.nowItems.first.scheduled,
      isFalse,
    );
    final broken = HubRepository(
      fixture(withSchedule(fixtureFiles(), projectId, 0, due: '2026-02-30')),
    );
    expect(broken.projects[projectId]!.nowItems, isEmpty);
    expect(broken.warnings, isNotEmpty);
  });

  test('Dartの日付の依頼を本体が受理してNOWに反映し、外す依頼も受理される', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          item = HubRepository(
            fixture(files),
          ).projects[projectId]!.nowItems.first;
      final service = CaptureService(access, location);
      // 変わらない日付・不正な日付は保存しない。
      await expectLater(
        service.saveItemSchedule(
          '61111111-2222-4333-8444-555555555555',
          projectId,
          item,
          null,
          null,
        ),
        throwsFormatException,
      );
      await expectLater(
        service.saveItemSchedule(
          '61111111-2222-4333-8444-555555555555',
          projectId,
          item,
          '2026-02-30',
          null,
        ),
        throwsFormatException,
      );
      final saved = await service.saveItemSchedule(
        '61111111-2222-4333-8444-555555555555',
        projectId,
        item,
        '2026-11-20',
        '2026-11-18',
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(
        parseMarkdown(raw).meta,
        allOf(
          containsPair('operation', 'item-schedule'),
          containsPair('due', '2026-11-20'),
          containsPair('review_after', '2026-11-18'),
        ),
      );
      final pending = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(pending.scheduleRequestIdFor(item.key), saved.requestId);
      expect(
        pending.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('日付の依頼（期日 2026-11-20・見直す日 2026-11-18）'),
      );

      final synced = HubRepository(
        fixture(
          await protocol(
            access,
            saved.requestId,
            'assets/sample.json',
            'schedule-one',
          ),
        ),
      );
      expect(synced.warnings, isEmpty);
      final p = synced.projects[projectId]!,
          now = p.nowItems.firstWhere((i) => i.key == item.key);
      expect((now.due, now.reviewAfter), ('2026-11-20', '2026-11-18'));
      // NOWの行末の日付は表示文に残り、行と項目の照合は変わらない。
      final entry = p.sections['next']!.single;
      expect(entry.itemKey, item.key);
      expect(entry.text, contains('期日 2026-11-20・見直す日 2026-11-18'));
      expect(synced.scheduleRequestIdFor(item.key), isNull);
      expect(
        synced.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '日付をMac miniが反映しました。',
      );

      final cleared = await service.saveItemSchedule(
        '71111111-2222-4333-8444-555555555555',
        projectId,
        now,
        null,
        null,
      );
      final back = HubRepository(
        fixture(
          await protocol(
            access,
            cleared.requestId,
            '${access.directory.path}/schedule-one.json',
            'schedule-two',
          ),
        ),
      );
      expect(
        back.projects[projectId]!.nowItems
            .firstWhere((i) => i.key == item.key)
            .scheduled,
        isFalse,
      );
      expect(
        back.projects[projectId]!.sections['next']!.single.text,
        isNot(contains('期日')),
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('プロジェクトの経緯を読み、手で変えたものには注意を付ける', () {
    final repo = HubRepository(fixture());
    final history = repo.projects[projectId]!.history!;
    expect(history.body, contains('# AI Context Hubの経緯'));
    expect(history.warnings, hasLength(1));
    final files = fixtureFiles();
    final edited = HubRepository(
      fixture({
        ...files,
        historyPath: files[historyPath]!.replaceFirst('の経緯', 'の経緯（手直し）'),
      }),
    );
    expect(
      edited.projects[projectId]!.history!.warnings.last,
      contains('整合性を確認できません'),
    );
    final other = HubRepository(
      fixture({
        ...files,
        historyPath: files[historyPath]!.replaceFirst(
          'project: context-hub',
          'project: other',
        ),
      }),
    );
    expect(other.projects[projectId]!.history, isNull);
    expect(other.warnings, isNotEmpty);
  });

  testWidgets('次の一手で期日の近い項目を先頭に、見直す日が先の項目を末尾にたたみ、日付を依頼できる', (tester) async {
    tester.view.physicalSize = const Size(1280, 2600);
    tester.view.devicePixelRatio = 1;
    final today = hubToday();
    var files = multiProjectFiles();
    // side-appの次の一手は期限切れ、context-hubの次の一手は見直す日が先。
    files = withSchedule(files, 'side-app', 0, due: addScheduleDays(today, -2));
    files = withSchedule(
      files,
      projectId,
      0,
      reviewAfter: addScheduleDays(today, 5),
    );
    final access = MemoryUIAccess();
    await access.init();
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
    await tester.tap(find.byKey(const Key('home-next')));
    await tester.pumpAndSettle();
    expect(find.text('期限切れ（1件）'), findsOneWidget);
    expect(find.byKey(const Key('next-project-side-app')), findsNothing);
    expect(find.byKey(const Key('next-project-context-hub')), findsNothing);
    expect(find.text('見直す日まで休ませている項目（1件）'), findsOneWidget);
    // たたんだ項目は開くまで出さない。
    expect(find.textContaining('サンプルの検索を確認する。'), findsNothing);
    await tester.tap(find.byKey(const Key('next-resting')));
    await tester.pumpAndSettle();
    expect(find.textContaining('サンプルの検索を確認する。'), findsOneWidget);

    // 期限切れの項目に新しい期日を付ける。
    final item = HubRepository(
      fixture(files),
    ).projects['side-app']!.nowItems.firstWhere((i) => i.section == 'next');
    await openMore(tester, item.key.substring(0, 12));
    await tester.tap(find.byKey(Key('schedule-${item.key.substring(0, 12)}')));
    await tester.pumpAndSettle();
    expect(find.text('期日と次に見直す日'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('schedule-due')), '2026-02-30');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('schedule-save')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('schedule-due-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-schedule');
    expect(request['project_id'], 'side-app');
    expect(request['item_key'], item.key);
    expect(request['due'], addScheduleDays(today, 7));
    expect(request['review_after'], isNull);
    access.current = VaultSnapshot({
      ...files,
      'Input/${request['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('期日を依頼済み（反映待ち）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('期日のある項目だけをカレンダーへ渡し、伏せ字の規則を確かめられないときは渡さない', (tester) async {
    tester.view.physicalSize = const Size(1280, 2600);
    tester.view.devicePixelRatio = 1;
    final today = hubToday(), due = addScheduleDays(today, 3);
    var files = withSchedule(multiProjectFiles(), 'side-app', 0, due: due);
    files = withSchedule(
      files,
      projectId,
      0,
      reviewAfter: addScheduleDays(today, -1),
    );
    final access = CalendarAccess();
    await access.init();
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
    await tester.tap(find.byKey(const Key('home-next')));
    await tester.pumpAndSettle();
    final repo = HubRepository(fixture(files)),
        item = repo.projects['side-app']!.nowItems.firstWhere(
          (i) => i.section == 'next',
        ),
        undated = repo.projects[projectId]!.nowItems.firstWhere(
          (i) => i.section == 'next',
        );
    // 見直す日だけの項目には出さない。
    await openMore(tester, undated.key.substring(0, 12));
    expect(
      find.byKey(Key('calendar-${undated.key.substring(0, 12)}')),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await openMore(tester, item.key.substring(0, 12));
    await tester.tap(find.byKey(Key('calendar-${item.key.substring(0, 12)}')));
    await tester.pumpAndSettle();
    final event = access.events.single;
    expect(event.date, due);
    expect(event.uid, endsWith('-due@context-hub'));
    expect(event.title, startsWith('[期日] '));
    expect(access.writes, 0);

    // 伏せ字の規則が読めない間は、カレンダーへ渡さず理由を示す。
    access.current = VaultSnapshot({
      ...files,
      '90_system/privacy/patterns.json': '{',
    });
    await c.reload();
    await tester.pumpAndSettle();
    await openMore(tester, item.key.substring(0, 12));
    await tester.tap(find.byKey(Key('calendar-${item.key.substring(0, 12)}')));
    await tester.pumpAndSettle();
    expect(access.events, hasLength(1));
    expect(find.textContaining('伏せ字の追加規則'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('プロジェクト画面から経緯を開く', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
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
    await tester.tap(find.text('AI Context Hub').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-history')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history-view')), findsOneWidget);
    expect(find.text('AI Context Hubの経緯'), findsWidgets);
    expect(find.textContaining('届いた入力: 3件'), findsOneWidget);
  });

  test('保存結果が不明だった依頼を確認した後、外してから同じ日付を付け直す依頼は新しく保存する', () async {
    final access = LosingAccess();
    await access.init();
    final files = fixtureFiles();
    access.current = VaultSnapshot(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final item = c.repository!.projects[projectId]!.nowItems.first;
    access.lose = true;
    final first = await c.requestItemSchedule(
      projectId,
      item.key,
      '2026-11-20',
      null,
    );
    expect(first.state, 'uncertain');
    access.lose = false;
    expect((await c.confirm(c.pending.single.operationId)).saved, isTrue);
    expect(access.requests, hasLength(1));
    // 本体が日付を付け、その後に外した状態（項目の日付はなく、記録は2件）。
    Map<String, String> record(String id, String? due) => {
      '90_system/item-schedules/$id.json': jsonEncode({
        'schema_version': 1,
        'id': id,
        'project_id': projectId,
        'item_key': item.key,
        'due': due,
        'review_after': null,
        'created_at': '2026-11-15T00:00:00.000Z',
      }),
    };
    const applied = 'SCH-01M7AAAAAAAAAAAAAAAAAAAAA1',
        removed = 'SCH-01M7AAAAAAAAAAAAAAAAAAAAA2';
    final after = {
      ...files,
      ...record(applied, '2026-11-20'),
      ...record(removed, null),
    };
    expect(
      HubRepository(fixture(after)).latestScheduleIdFor(item.key),
      removed,
    );
    access.current = VaultSnapshot(after);
    await c.reload();
    final again = await c.requestItemSchedule(
      projectId,
      item.key,
      '2026-11-20',
      null,
    );
    expect(again.saved, isTrue);
    expect(again.requestId, isNot(first.requestId));
    expect(access.requests, hasLength(2));
  });

  test('完了・解決の報告が反映待ちの項目には、日付を依頼しない', () async {
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
    access.current = VaultSnapshot(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final item = c.repository!.projects[projectId]!.nowItems.first;
    final report = await c.requestItemResolution(
      projectId,
      item.key,
      'resolve',
    );
    access.current = VaultSnapshot({
      ...files,
      'Input/${report.requestId}.md': access.requests[report.requestId]!,
    });
    await c.reload();
    expect(c.repository!.itemRequestIdFor(item.key), report.requestId);
    await expectLater(
      c.requestItemSchedule(projectId, item.key, '2026-11-20', null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('完了・解決の報告'),
        ),
      ),
    );
    expect(access.requests, hasLength(1));
  });
}

/// カレンダーへ渡した予定を記録する端末。
class CalendarAccess extends MemoryUIAccess {
  final events = <CalendarEvent>[];
  @override
  bool get calendarSupported => true;
  @override
  Future<void> addToCalendar(CalendarEvent event) async => events.add(event);
}
