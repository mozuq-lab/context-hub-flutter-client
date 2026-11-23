import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/attention_check.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/attention.dart';
import 'package:context_hub_client/core/due_notice.dart';
import 'package:context_hub_client/core/intake_features.dart'
    show unassignedScope;
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/ui/app.dart';

import 'package:context_hub_client/storage/capture_service.dart';
import 'attention_test.dart' show AttentionAccess, settingsOf;
import 'capture_test.dart' show TempAccess, location;
import 'fixtures.dart';
import 'item_exclusion_test.dart' show withExcluded;
import 'next_actions_test.dart' show multiProjectFiles;
import 'schedule_history_test.dart' show withSchedule;
import 'someday_test.dart' show withSomeday;
import 'waiting_test.dart' show withWaiting;

const projectId = 'context-hub';
const today = '2026-11-15';

/// 次の一手（0番）を期限切れ、未解決（1番）を今日、未解決（2番）を明日が期日にする。
Map<String, String> datedFiles([Map<String, String>? base]) {
  var files = base ?? fixtureFiles();
  files = withSchedule(files, projectId, 0, due: '2026-11-14');
  files = withSchedule(files, projectId, 1, due: today);
  return withSchedule(files, projectId, 2, due: '2026-11-16');
}

/// プロジェクトを決めずに本人が追加した行動を、本体が書く形で1件足す。
Map<String, String> withUnassignedAction(
  Map<String, String> files, {
  String? due,
  String? reviewAfter,
}) {
  const path = '90_system/now-items/$unassignedScope.json';
  final list = jsonDecode(files[path]!) as Map<String, dynamic>;
  (list['items'] as List).add({
    'key': 'c' * 64,
    'section': 'next',
    'label': '',
    'text': '書類を出す',
    'input_id': 'IN-01M2DSFVRRA5MFS95MKFPP2CCM',
    'resolution': null,
    'schedule': {
      'id': 'SCH-${'1' * 26}',
      'due': due,
      'review_after': reviewAfter,
    },
    'action': <String, Object?>{},
  });
  return {...files, path: jsonEncode(list)};
}

/// 端末の時刻（昼）。「今日」は本体と同じ日本時間で決めるので、期待値は[hubToday]から作る。
final noon = DateTime(2026, 11, 15, 12);

void main() {
  test('期限切れと今日が期日の項目を、次の一手・未解決から数える', () {
    final repo = HubRepository(fixture(datedFiles()));
    final items = dueItems(repo, today);
    expect(items.map((i) => (i.bucket, i.open)), [
      (ScheduleBucket.overdue, false),
      (ScheduleBucket.today, true),
    ]);
    final keys = repo.projects[projectId]!.nowItems.map((i) => i.key).toList();
    expect(items.map((i) => i.key), [keys[0], keys[1]]);
    // 期日のない日は数えない（明日が期日の項目は翌日に数える）。
    expect(dueItems(repo, '2026-11-13'), isEmpty);
    expect(dueItems(repo, '2026-11-16'), hasLength(3));
    // 見直す日だけの項目は、その日が来ても数えない（期日だけを知らせる）。
    final review = HubRepository(
      fixture(withSchedule(fixtureFiles(), projectId, 0, reviewAfter: today)),
    );
    expect(dueItems(review, today), isEmpty);
    // 期日が来ていれば、見直す日が先でも数える（「次の一手」の画面でも先頭に出る）。
    final both = HubRepository(
      fixture(
        withSchedule(
          fixtureFiles(),
          projectId,
          0,
          due: today,
          reviewAfter: '2026-11-20',
        ),
      ),
    );
    expect(dueItems(both, today), hasLength(1));
  });

  test('完了・誤りとして外した・連絡待ち・「いつかやる」・休止中のプロジェクトの項目は数えない', () {
    final files = datedFiles();
    final repo = HubRepository(fixture(files));
    final first = repo.projects[projectId]!.nowItems.first;
    // 誤りとして外した項目は、NOWの行に結び付かない（「次の一手」の画面にも出ない）。
    final excluded = HubRepository(
      fixture(withExcluded(files, first.key, note: '違った')),
    );
    expect(
      dueItems(excluded, today).map((i) => i.key),
      isNot(contains(first.key)),
    );
    expect(dueItems(excluded, today), hasLength(1));
    // 連絡待ちの印を付けた項目は、期日の欄ではなく「連絡待ち」にまとまる。
    final waiting = HubRepository(fixture(withWaiting(files, 0)));
    expect(
      dueItems(waiting, today).map((i) => i.key),
      isNot(contains(first.key)),
    );
    // 「いつかやる」へ移した項目は、次の一手に出ない。
    final someday = HubRepository(fixture(withSomeday(files, 0)));
    expect(
      dueItems(someday, today).map((i) => i.key),
      isNot(contains(first.key)),
    );
    // 進行中でないプロジェクトの項目は数えない。
    final paused = HubRepository(
      fixture(withSchedule(multiProjectFiles(), 'old-plan', 0, due: today)),
    );
    expect(paused.projects['old-plan']!.active, isFalse);
    expect(dueItems(paused, today), isEmpty);
  });

  test('この端末から完了の報告や日付の変更を依頼して反映を待つ項目は数えない', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = datedFiles();
      final items = HubRepository(fixture(files)).projects[projectId]!.nowItems;
      final service = CaptureService(access, location);
      final resolved = await service.saveItemResolution(
        '41111111-2222-4333-8444-555555555555',
        projectId,
        items[0],
        'resolve',
      );
      final moved = await service.saveItemSchedule(
        '41111111-2222-4333-8444-555555555556',
        projectId,
        items[1],
        '2026-11-30',
        null,
      );
      final pending = HubRepository(
        fixture({
          ...files,
          for (final id in [resolved.requestId, moved.requestId])
            'Input/$id.md': (await access.readRequest(location, id))!,
        }),
      );
      expect(pending.itemRequestIdFor(items[0].key), resolved.requestId);
      expect(pending.scheduleRequestIdFor(items[1].key), moved.requestId);
      expect(dueItems(pending, today), isEmpty);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('プロジェクトを決めずに本人が追加した行動も、期日が来たら数え、休ませている行動は数えない', () {
    final due = HubRepository(
      fixture(withUnassignedAction(fixtureFiles(), due: '2026-11-10')),
    );
    expect(due.unassignedOwnActions, hasLength(1));
    expect(dueItems(due, today).single.bucket, ScheduleBucket.overdue);
    final resting = HubRepository(
      fixture(withUnassignedAction(fixtureFiles(), reviewAfter: '2026-11-20')),
    );
    expect(dueItems(resting, today), isEmpty);
  });

  test('通知の文は件数だけで、本文とプロジェクト名を出さず、1日に1回の鍵を付ける', () {
    final repo = HubRepository(fixture(datedFiles()));
    final notice = dueNotice(dueItems(repo, today), today)!;
    expect(notice.key, today);
    expect(notice.title, '期日の来た項目が2件あります');
    expect(notice.text, '期限切れ 1件 · 今日 1件（うち未解決の欄に1件）。この端末に同期済みの内容です');
    final all = '${notice.title}${notice.text}';
    expect(all, isNot(contains('サンプルの検索')));
    expect(all, isNot(contains('Discord')));
    expect(all, isNot(contains('AI Context Hub')));
    expect(all, isNot(contains(projectId)));
    expect(dueNotice(const [], today), isNull);
    // 期限切れだけ・今日だけのときは、ない方を書かない。
    expect(
      dueNotice(const [DueItem('a', ScheduleBucket.today)], today)!.text,
      '今日 1件。この端末に同期済みの内容です',
    );
    // 端末の通知の上限（題80字・本文200字）に収まる。
    final many = [
      for (var i = 0; i < 9999; i++)
        DueItem('$i', ScheduleBucket.overdue, open: true),
    ];
    final long = dueNotice(many, today)!;
    expect(long.title.length, lessThanOrEqualTo(80));
    expect(long.text.length, lessThanOrEqualTo(200));
    // 夜（22時〜7時）は通知を控える。
    expect(dueQuietHour(DateTime(2026, 11, 15, 6, 59)), isTrue);
    expect(dueQuietHour(DateTime(2026, 11, 15, 7)), isFalse);
    expect(dueQuietHour(DateTime(2026, 11, 15, 21, 59)), isFalse);
    expect(dueQuietHour(DateTime(2026, 11, 15, 22)), isTrue);
  });

  test('期日の通知の設定は確認待ちの通知とは別に保存し、読めない値は無効として扱う', () {
    const both = AttentionSettings(AttentionState(), false, due: true);
    expect(both.toJson(), {'keys': <String, int>{}, 'due': true});
    expect(AttentionSettings.fromJson(both.toJson()).due, isTrue);
    expect(AttentionSettings.fromJson(both.toJson()).notify, isFalse);
    expect(AttentionSettings.fromJson({'due': 'yes'}).due, isFalse);
    expect(AttentionSettings.fromJson(null).due, isFalse);
  });

  group('アプリを閉じている間の期日の確認（Android）', () {
    late AttentionAccess access;
    late HubController c;
    setUp(() async {
      access = AttentionAccess(android: true)
        ..current = fixture(fixtureFiles());
      c = HubController(access, sampleLoader: () async => fixtureFiles());
      await c.useSample();
      access.snapshots = 0;
    });
    tearDown(() => c.dispose());

    /// [noon]の日本時間の日付から数えた日の期日を、次の一手（0番）に付ける。
    void dueIn(int days) {
      access.current = fixture(
        withSchedule(
          fixtureFiles(),
          projectId,
          0,
          due: addScheduleDays(hubToday(noon), days),
        ),
      );
    }

    test('期日の通知が無効なら、期日が来ていても通知しない', () async {
      dueIn(-1);
      expect(await runAttentionCheck(access, now: noon), isFalse);
      expect(access.snapshots, 0);
      expect(access.dueNotices, isEmpty);
    });

    test('有効にすると期限切れ・今日の件数を通知し、同じ日は同じ鍵にする', () async {
      expect(await c.setDueNotify(true), isTrue);
      expect(access.toggles.last, (enabled: true, request: true));
      expect(access.kinds.last, 'due');
      expect(settingsOf(access)['attention']['due'], isTrue);
      expect(settingsOf(access)['attention']['notify'], isNull);
      // 期日が明日なら通知せず、出したままの期日の通知があれば消す。
      dueIn(1);
      final cleared = access.cleared;
      expect(await runAttentionCheck(access, now: noon), isFalse);
      expect(access.dueNotices, isEmpty);
      expect(access.dueCleared, 1);
      // 確認待ちの通知は使っていないので、確認待ちは数えず、通知も消さない。
      expect(access.notices, isEmpty);
      expect(access.cleared, cleared);
      dueIn(-1);
      final before = access.states['settings.json'];
      expect(await runAttentionCheck(access, now: noon), isTrue);
      final (key, title, text) = access.dueNotices.single;
      expect(key, hubToday(noon));
      expect(title, '期日の来た項目が1件あります');
      expect(text, '期限切れ 1件。この端末に同期済みの内容です');
      expect('$title$text', isNot(contains('サンプルの検索')));
      // 確認は設定ファイルを書き換えない。同じ日のうちは同じ鍵で、端末側が出し直さない。
      expect(access.states['settings.json'], before);
      dueIn(0);
      expect(await runAttentionCheck(access, now: noon), isTrue);
      expect(access.dueNotices.last.$1, key);
      // 完了などで対象がなくなると、次の確認から通知しない。
      access.dueNotices.clear();
      access.current = fixture(fixtureFiles());
      expect(await runAttentionCheck(access, now: noon), isFalse);
      expect(access.dueNotices, isEmpty);
    });

    test('夜は通知を控え、読取が途中で終わったときは通知も消去もしない', () async {
      await c.setDueNotify(true);
      dueIn(-1);
      final night = DateTime(2026, 11, 15, 23);
      expect(await runAttentionCheck(access, now: night), isFalse);
      expect(access.dueNotices, isEmpty);
      access.current = VaultSnapshot(
        withSchedule(
          fixtureFiles(),
          projectId,
          0,
          due: addScheduleDays(hubToday(noon), -1),
        ),
        warnings: const ['読取できないファイル: 00_inbox/x.md'],
      );
      final cleared = access.dueCleared;
      expect(await runAttentionCheck(access, now: noon), isFalse);
      expect(access.dueNotices, isEmpty);
      expect(access.dueCleared, cleared);
      // 記録の形式を確かめられないもの（画面に読取の注意が出るもの）があるときも、通知も消去もしない。
      dueIn(-1);
      access.current = fixture({
        ...access.current.files,
        '90_system/weekly-review.json': '{',
      });
      expect(HubRepository(access.current).warnings, isNotEmpty);
      expect(await runAttentionCheck(access, now: noon), isFalse);
      expect(access.dueNotices, isEmpty);
      expect(access.dueCleared, cleared);
    });

    test('確認待ちと期日の通知は別々に切り替え、両方を止めたときだけ確認の登録を消す', () async {
      await c.setAttentionNotify(true);
      await c.setDueNotify(true);
      expect(access.kinds, ['attention', 'due']);
      // 端末には、有効にしている種類をすべて伝える。
      expect(access.actives.last, {'attention', 'due'});
      // 片方を止めても、もう片方のために確認の登録は残し、止めた種類の通知だけを消す。
      expect(await c.setDueNotify(false), isTrue);
      expect(access.toggles.last, (enabled: true, request: false));
      expect(access.kinds.last, 'attention');
      expect(access.actives.last, {'attention'});
      expect(access.dueCleared, 1);
      expect(settingsOf(access)['attention']['due'], isNull);
      expect(settingsOf(access)['attention']['notify'], isTrue);
      await c.setDueNotify(true);
      expect(await c.setAttentionNotify(false), isTrue);
      expect(access.toggles.last.enabled, isTrue);
      expect(access.actives.last, {'due'});
      expect(c.dueNotify, isTrue);
      // 両方を止めると、確認の登録を消す。
      expect(await c.setDueNotify(false), isTrue);
      expect(access.toggles.last, (enabled: false, request: false));
      // 両方とも有効なら、1回の確認で両方を知らせる。
      await c.setAttentionNotify(true);
      await c.setDueNotify(true);
      dueIn(-1);
      expect(await runAttentionCheck(access, now: noon), isTrue);
      expect(access.dueNotices, hasLength(1));
      expect(access.snapshots, 1);
    });

    test('端末で通知が許可されていなければ有効にせず、次の起動では止まっていることを示す', () async {
      access.granted = false;
      expect(await c.setDueNotify(false), isTrue);
      expect(await c.setDueNotify(true), isFalse);
      expect(c.dueNotify, isFalse);
      access.granted = true;
      await c.setAttentionNotify(true);
      await c.setDueNotify(true);
      // 期日のお知らせの種類だけを端末の設定で止めていたら、その設定だけが止まっていることを示す。
      access.dueBlocked = true;
      access.toggles.clear();
      access.kinds.clear();
      final next = HubController(
        access,
        sampleLoader: () async => fixtureFiles(),
      );
      addTearDown(next.dispose);
      await next.restore();
      await Future<void>.delayed(Duration.zero);
      expect(next.dueNotify, isTrue);
      expect(access.kinds, ['attention', 'due']);
      expect(access.toggles.every((t) => t.enabled && !t.request), isTrue);
      expect(next.dueNotifyBlocked, isTrue);
      expect(next.attentionNotifyBlocked, isFalse);
      // 片方を有効にして許可されたら、もう片方の「止められている」表示を確かめ直す。
      access.dueBlocked = false;
      expect(await next.setAttentionNotify(false), isTrue);
      expect(next.dueNotifyBlocked, isFalse);
      access.granted = false;
      final blocked = HubController(
        access,
        sampleLoader: () async => fixtureFiles(),
      );
      addTearDown(blocked.dispose);
      await blocked.restore();
      await Future<void>.delayed(Duration.zero);
      expect(blocked.dueNotifyBlocked, isTrue);
      access.granted = true;
      expect(await blocked.setAttentionNotify(true), isTrue);
      expect(blocked.dueNotifyBlocked, isFalse);
    });

    test('アプリでまだ開いていないVaultでも、期日は数える（確認待ちだけが既読の記録を要る）', () async {
      await c.setAttentionNotify(true);
      await c.setDueNotify(true);
      final raw = settingsOf(access);
      (raw['attention'] as Map)['vault'] = 'other-vault';
      access.states['settings.json'] = jsonEncode(raw);
      dueIn(-1);
      expect(await runAttentionCheck(access, now: noon), isTrue);
      expect(access.dueNotices, hasLength(1));
      expect(access.notices, isEmpty);
    });
  });

  testWidgets('設定から期日の通知を切り替え、通知を押すと次の一手を開く', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = AttentionAccess(android: true)
      ..current = fixture(datedFiles());
    final c = HubController(access, sampleLoader: () async => datedFiles());
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await c.useSample();
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('due-settings')),
        matching: find.text('オフ'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('due-settings')));
    await tester.pumpAndSettle();
    expect(find.textContaining('件数だけ'), findsOneWidget);
    expect(find.textContaining('ネットワークには接続しません'), findsOneWidget);
    access.granted = false;
    await tester.tap(find.byKey(const Key('due-notify')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('due-problem')), findsOneWidget);
    expect(c.dueNotify, isFalse);
    access.granted = true;
    await tester.tap(find.byKey(const Key('due-notify')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('due-problem')), findsNothing);
    expect(c.dueNotify, isTrue);
    expect(c.attentionNotify, isFalse);
    expect(access.kinds.last, 'due');
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('due-settings')),
        matching: find.text('オン'),
      ),
      findsOneWidget,
    );
    // 期日の通知を押すと、同期済みの内容を読み込み直してから次の一手を、次の一手の欄で開く。
    await tester.tap(find.byKey(const Key('nav-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('未解決 '));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<String>>(find.byKey(const Key('next-section')))
          .selected,
      {'open'},
    );
    access.loadedAt = DateTime.now().subtract(const Duration(minutes: 5));
    await c.reload();
    final reads = access.snapshots;
    access.action = 'due';
    access.onAction!();
    await tester.pumpAndSettle();
    expect(access.snapshots, reads + 1);
    expect(find.widgetWithText(AppBar, '次の一手'), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<String>>(find.byKey(const Key('next-section')))
          .selected,
      {'next'},
    );
    expect(tester.takeException(), isNull);
  });
}
