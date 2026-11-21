import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/today.dart';
import 'package:context_hub_client/ui/app.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'next_actions_test.dart' show multiProjectFiles;
import 'project_pins_test.dart' show FailingStateAccess;
import 'fixtures.dart';

String key(String c) => c * 64;
TodayPick pick(String c, {int carried = 0}) =>
    TodayPick('p-$c', key(c), '項目$c', carried: carried);

/// [repo]の進行中のプロジェクトの、次の一手・未解決の項目（プロジェクトID、項目）。
List<(String, NowItemRef)> itemsOf(HubRepository repo) => [
  for (final p in repo.actionableProjects)
    for (final i in p.nowItems)
      if (!i.resolved) (p.id, i),
];

void main() {
  test('今日の3つは3件までで、同じ項目を重ねず、持ち越しから選ぶと続けた日数を残す', () {
    var t = const TodayFocus(date: '2026-11-21');
    t = t.add(pick('a')).add(pick('b')).add(pick('a'));
    expect(t.picks.map((p) => p.itemKey), [key('a'), key('b')]);
    t = t.add(pick('c'));
    expect(t.full, isTrue);
    expect(() => t.add(pick('d')), throwsStateError);
    t = t.remove(key('b'));
    expect(t.picks.map((p) => p.itemKey), [key('a'), key('c')]);
    // 持ち越しの確認にある項目を選ぶと、持ち越しから移し、続けた日数はそのまま。
    final carried = TodayFocus(
      date: '2026-11-21',
      carry: [pick('e', carried: 2)],
    ).add(pick('e'));
    expect(carried.carry, isEmpty);
    expect(carried.picks.single.carried, 2);
  });

  test('日付が変わると、片付いていない項目だけを持ち越しの確認へ回し、続けた日数を数える', () {
    final t = TodayFocus(
      date: '2026-11-20',
      picks: [pick('a'), pick('b', carried: 1)],
      carry: [pick('c', carried: 2)],
    );
    // 同じ日なら何もしない。
    expect(identical(t.rollOver('2026-11-20', (_) => true), t), isTrue);
    final next = t.rollOver('2026-11-21', (p) => p.itemKey != key('a'));
    expect(next.date, '2026-11-21');
    expect(next.picks, isEmpty);
    // 片付いたaは消える。前の日に選んだbを先に置き、決めていなかった持ち越しcも日数を1つ増やす。
    expect(
      [for (final p in next.carry) (p.itemKey, p.carried)],
      [(key('b'), 2), (key('c'), 3)],
    );
    // 上限を超えるときは、古い持ち越しから手放し、前の日に選んだものを残す。
    final crowded = TodayFocus(
      date: '2026-11-20',
      picks: [pick('a'), pick('b'), pick('c')],
      carry: [
        for (final c in ['d', 'e', 'f', '1', '2']) pick(c),
      ],
    ).rollOver('2026-11-21', (_) => true);
    expect(crowded.carry.map((p) => p.projectId), [
      'p-a',
      'p-b',
      'p-c',
      'p-d',
      'p-e',
      'p-f',
    ]);
    // 読み直しても同じ状態になる（読むたびに日数は増えない）。
    expect(
      jsonEncode(TodayFocus.fromJson(next.toJson()).toJson()),
      jsonEncode(next.toJson()),
    );
  });

  test('壊れた記録は、読める項目だけを上限まで使う', () {
    final t = TodayFocus.fromJson({
      'date': '2026-11-21',
      'picks': [
        {'p': 'a', 'k': key('a'), 't': 'x'},
        {'p': 'a', 'k': key('a'), 't': '重複'},
        {'p': '', 'k': key('b'), 't': 'プロジェクトなし'},
        {'p': 'c', 'k': 'not-a-key', 't': '形の違う鍵'},
        'ゴミ',
        {'p': 'd', 'k': key('d'), 't': 'y', 'n': -1},
        {'p': 'e', 'k': key('e'), 't': 'z'},
        {'p': 'f', 'k': key('f'), 't': 'z'},
        {'p': 'g', 'k': key('9'), 't': '上限を超える'},
      ],
      'carry': 'ゴミ',
    });
    expect(t.picks.map((p) => p.projectId), ['a', 'e', 'f']);
    expect(t.carry, isEmpty);
    expect(TodayFocus.fromJson('ゴミ').isEmpty, isTrue);
    expect(TodayFocus.fromJson({'date': '昨日'}).date, isNull);
  });

  test('今日の3つは端末の設定にVaultごとに保存し、Vaultには何も書かず、翌日は持ち越しの確認になる', () async {
    final access = MemoryUIAccess();
    final files = multiProjectFiles();
    access.current = fixture(files);
    // 開き直すため、途中で閉じる（後片付けで二度閉じない）。
    final c = HubController(access, sampleLoader: () async => files);
    await c.useSample();
    final items = itemsOf(c.repository!);
    expect(items.length, greaterThanOrEqualTo(4));
    for (final (project, item) in items.take(3)) {
      await c.setToday(project, item.key, true);
    }
    expect(c.today.picks.map((p) => p.itemKey), [
      for (final (_, i) in items.take(3)) i.key,
    ]);
    await expectLater(
      c.setToday(items[3].$1, items[3].$2.key, true),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('3件まで')),
      ),
    );
    // NOWにない項目は選べない。
    await expectLater(c.setToday('side-app', key('f'), true), throwsStateError);
    expect(access.requests, isEmpty);
    final saved = jsonDecode(access.states['settings.json']!) as Map;
    expect((saved['today'] as Map)['sample']['date'], hubToday());
    expect((saved['today'] as Map)['sample']['picks'], hasLength(3));

    // 前の日に選んだことにして、開き直す。選んだ項目は持ち越しの確認へ回る。
    (saved['today'] as Map)['sample']['date'] = '2000-01-01';
    access.states['settings.json'] = jsonEncode(saved);
    final target = c.location!;
    c.dispose();
    final d = HubController(access, sampleLoader: () async => files);
    addTearDown(d.dispose);
    await d.activate(target);
    expect(d.today.picks, isEmpty);
    expect(d.today.carry.map((p) => (p.itemKey, p.carried)), [
      for (final (_, i) in items.take(3)) (i.key, 1),
    ]);
    // 持ち越しは開いたときに記録し、読み直しても日数は増えない。
    await d.reload();
    expect(d.today.carry.map((p) => p.carried), [1, 1, 1]);
    // 今日も続ける・外す。
    await d.setToday(items[0].$1, items[0].$2.key, true);
    await d.dropCarried(items[1].$2.key);
    expect(d.today.picks.single.carried, 1);
    expect(d.today.carry.map((p) => p.itemKey), [items[2].$2.key]);
    await d.clearCarried();
    expect(d.today.carry, isEmpty);
    expect(access.requests, isEmpty);
  });

  test('NOWから見つからない項目も持ち越し、本人に外してもらう（同期の途中で見えないだけのこともある）', () {
    final files = multiProjectFiles();
    final repo = HubRepository(fixture(files));
    final (project, item) = itemsOf(repo).first;
    final chosen = TodayFocus(
      date: '2026-11-20',
      picks: [
        TodayPick(project, item.key, item.text),
        TodayPick(project, key('f'), '消えた項目'),
      ],
    );
    final next = chosen.rollOver('2026-11-21', (p) => todayOpen(repo, p));
    expect(next.carry.map((p) => p.itemKey), [item.key, key('f')]);
    expect(todayEntry(repo, chosen.picks[1]).missing, isTrue);
    expect(todayEntry(repo, chosen.picks[1]).text, '消えた項目');
  });

  test('設定を保存できなければ、選んだことにしない', () async {
    final access = FailingStateAccess();
    final files = multiProjectFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final (project, item) = itemsOf(c.repository!).first;
    access.fail = true;
    await expectLater(c.setToday(project, item.key, true), throwsStateError);
    expect(c.today.picks, isEmpty);
  });

  test('ホーム画面ウィジェットは、今日の3つに選んだ次の一手を先に出す', () {
    final repo = HubRepository(fixture(multiProjectFiles()));
    const settings = HomeWidgetSettings(showText: true);
    expect(homeWidgetContent(repo, settings: settings)['lines'], [
      '設定画面を作る。（別のアプリ）',
      'サンプルの検索を確認する。（AI Context Hub）',
    ]);
    final chosen = repo.projects['context-hub']!.nowItems.firstWhere(
      (i) => i.section == 'next',
    );
    expect(
      homeWidgetContent(
        repo,
        settings: settings,
        focus: [TodayPick('context-hub', chosen.key, chosen.text)],
      )['lines'],
      ['サンプルの検索を確認する。（AI Context Hub）', '設定画面を作る。（別のアプリ）'],
    );
  });

  testWidgets('次の一手から「今日やる」を選ぶと、ホームと次の一手の先頭に出て、その場で外せる', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = multiProjectFiles();
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
    // 何も選んでいなければ、ホームには出さない。
    expect(find.byKey(const Key('today')), findsNothing);
    await tester.tap(find.byKey(const Key('home-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-empty')), findsOneWidget);
    final item = c.repository!.projects['side-app']!.nowItems.firstWhere(
      (i) => i.section == 'next',
    );
    final short = item.key.substring(0, 12);
    await tester.tap(find.byKey(Key('today-$short')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today')), findsOneWidget);
    expect(find.text('今日の3つ（1/3）'), findsOneWidget);
    expect(find.text('今日の3つから外す'), findsNWidgets(2));
    // ホームにも出る。
    await tester.tap(find.text('ホーム').first);
    await tester.pumpAndSettle();
    expect(find.byKey(Key('today-pick-$short')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('today'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('home-next'))).dy),
    );
    await tester.tap(find.byKey(Key('today-remove-$short')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today')), findsNothing);
    expect(c.today.picks, isEmpty);
    expect(access.requests, isEmpty);
  });

  testWidgets('前の日からの持ち越しを、今日も続ける・外すで片付けられ、3日続くと注意を添える', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = multiProjectFiles();
    access.current = VaultSnapshot(files);
    final repo = HubRepository(fixture(files));
    final items = itemsOf(repo);
    access.states['settings.json'] = jsonEncode({
      'handle': 'sample',
      'name': 'サンプル',
      'identity': 'sample',
      'today': {
        'sample': {
          'date': '2000-01-01',
          'picks': [
            for (final (p, i) in items.take(2))
              {'p': p, 'k': i.key, 't': i.text, 'n': 2},
          ],
        },
      },
    });
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    if (c.location == null) {
      await tester.tap(find.text('サンプルで試す'));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('today-carry')), findsOneWidget);
    expect(find.text('前の日から持ち越した項目（2件）'), findsOneWidget);
    final first = items[0].$2.key.substring(0, 12),
        second = items[1].$2.key.substring(0, 12);
    expect(find.textContaining('3日続けて持ち越しています'), findsNWidgets(2));
    await tester.tap(find.byKey(Key('today-keep-$first')));
    await tester.pumpAndSettle();
    expect(find.text('今日の3つ（1/3）'), findsOneWidget);
    expect(find.text('前の日から持ち越した項目（1件）'), findsOneWidget);
    await tester.tap(find.byKey(Key('today-drop-$second')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-carry')), findsNothing);
    expect(c.today.picks.single.itemKey, items[0].$2.key);
  });
}
