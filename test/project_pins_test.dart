import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'next_actions_test.dart' show multiProjectFiles, withProject;
import 'fixtures.dart';

/// 設定を書けない端末。
class FailingStateAccess extends MemoryUIAccess {
  bool fail = false;
  @override
  Future<void> writeState(
    String name,
    String raw, {
    bool exclusive = false,
  }) async {
    if (fail) throw StateError('書けません');
    await super.writeState(name, raw, exclusive: exclusive);
  }
}

void main() {
  test('ピン留めしたプロジェクトを本人が決めた順で先頭に、残りは今までの順に並べる', () {
    final repo = HubRepository(fixture(multiProjectFiles()));
    // ピン留めがなければ、進行中→休止・完了の順のまま。
    expect(repo.orderedProjects.map((p) => p.id), [
      'context-hub',
      'side-app',
      'old-plan',
    ]);
    // 休止中のプロジェクトも先頭に置けるが、「次の一手」には出さない。VaultにないID・重複は並びに使わない。
    repo.pinned = ['old-plan', 'context-hub', 'gone', 'old-plan'];
    expect(repo.pinnedProjects.map((p) => p.id), ['old-plan', 'context-hub']);
    expect(repo.orderedProjects.map((p) => p.id), [
      'old-plan',
      'context-hub',
      'side-app',
    ]);
    expect(repo.actionableProjects.map((p) => p.id), [
      'context-hub',
      'side-app',
    ]);
    expect(repo.isPinned('old-plan'), isTrue);
    expect(repo.isPinned('side-app'), isFalse);
    expect(repo.isPinned('gone'), isFalse);
    // ホーム画面ウィジェットも、ピン留めしたプロジェクトの次の一手を先に出す。
    expect(
      homeWidgetContent(
        repo,
        settings: const HomeWidgetSettings(showText: true),
      )['lines'],
      ['サンプルの検索を確認する。（AI Context Hub）', '設定画面を作る。（別のアプリ）'],
    );
    // 別のAIへ渡す文脈は、端末の並びに左右させない。
    repo.pinned = ['side-app'];
    final text = repo.vaultContext();
    expect(
      text.indexOf('（context-hub）'),
      inInclusiveRange(0, text.indexOf('（side-app）') - 1),
    );
  });

  test('ピン留めは端末の設定にVaultごとに保存し、Vaultには何も書かない', () async {
    final access = MemoryUIAccess();
    final files = multiProjectFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    await c.useSample();
    expect(c.pinnedProjectIds, isEmpty);
    expect(access.states['settings.json'], isNot(contains('pins')));
    await c.setPinned('context-hub', true);
    await c.setPinned('old-plan', true);
    // 同じプロジェクトを二重に持たない。
    await c.setPinned('context-hub', true);
    expect(c.pinnedProjectIds, ['old-plan', 'context-hub']);
    await c.movePin('context-hub', -1);
    expect(c.pinnedProjectIds, ['context-hub', 'old-plan']);
    // 端の先へは動かさない。
    await c.movePin('context-hub', -1);
    await c.movePin('old-plan', 1);
    await c.movePin('side-app', 1);
    expect(c.pinnedProjectIds, ['context-hub', 'old-plan']);
    expect(jsonDecode(access.states['settings.json']!)['pins'], {
      'sample': ['context-hub', 'old-plan'],
    });
    expect(access.requests, isEmpty);
    expect(access.writes, 0);
    // 読み直しても並びを保つ。
    await c.reload();
    expect(c.repository!.actionableProjects.map((p) => p.id), [
      'context-hub',
      'side-app',
    ]);
    // このVaultにないプロジェクトはピン留めできない。
    await expectLater(c.setPinned('gone', true), throwsStateError);
    // 別のVaultへは持ち込まない。戻ると元の並びになる。
    await c.activate(const VaultLocation('other', '別のVault'));
    expect(c.pinnedProjectIds, isEmpty);
    await c.setPinned('side-app', true);
    await c.useSample();
    expect(c.pinnedProjectIds, ['context-hub', 'old-plan']);
    c.dispose();
    // 次の起動でも保つ。
    final next = MemoryUIAccess()..states.addAll(access.states);
    next.current = fixture(files);
    final restored = HubController(next, sampleLoader: () async => files);
    await restored.restore();
    expect(restored.pinnedProjectIds, ['context-hub', 'old-plan']);
    // 外すと設定からも消える。
    await restored.setPinned('context-hub', false);
    await restored.setPinned('old-plan', false);
    expect(jsonDecode(next.states['settings.json']!)['pins'], {
      'other': ['side-app'],
    });
    restored.dispose();
  });

  test('Vaultからなくなったプロジェクトのピン留めは並びに使わず、次の変更で手放す', () async {
    final access = MemoryUIAccess();
    final files = multiProjectFiles();
    access.current = fixture(files);
    access.states['settings.json'] = jsonEncode({
      'handle': 'sample',
      'name': '架空サンプル',
      'identity': 'sample',
      'pins': {
        'sample': ['gone', 'side-app', 7, 'side-app'],
        'broken': 'x',
      },
    });
    final c = HubController(access, sampleLoader: () async => files);
    await c.restore();
    expect(c.error, isNull);
    expect(c.pinnedProjectIds, ['side-app']);
    await c.setPinned('context-hub', true);
    expect(jsonDecode(access.states['settings.json']!)['pins']['sample'], [
      'side-app',
      'context-hub',
    ]);
    c.dispose();
  });

  test('ピン留めは上限までで、保存できなかった並びを保存できたように見せない', () async {
    final access = FailingStateAccess();
    var files = fixtureFiles();
    for (var i = 0; i < HubController.maxPins; i++) {
      files = withProject(files, 'p$i', '計画$i');
    }
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    await c.useSample();
    for (var i = 0; i < HubController.maxPins; i++) {
      await c.setPinned('p$i', true);
    }
    await expectLater(c.setPinned('context-hub', true), throwsStateError);
    expect(c.pinnedProjectIds, hasLength(HubController.maxPins));
    await c.setPinned('p0', false);
    access.fail = true;
    await expectLater(c.setPinned('context-hub', true), throwsStateError);
    expect(c.pinnedProjectIds, isNot(contains('context-hub')));
    await expectLater(c.movePin('p2', -1), throwsStateError);
    expect(c.pinnedProjectIds.take(2), ['p1', 'p2']);
    access.fail = false;
    await c.movePin('p2', -1);
    expect(c.pinnedProjectIds.take(2), ['p2', 'p1']);
    c.dispose();
  });

  testWidgets('ホームでピン留めすると、ホームと「次の一手」の先頭に並び、並びを変えられる', (tester) async {
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
    double top(String key) => tester.getTopLeft(find.byKey(Key(key)).last).dy;
    expect(find.byKey(const Key('home-pins')), findsNothing);
    expect(top('pin-context-hub'), lessThan(top('pin-old-plan')));
    // 休止中のプロジェクトをピン留めすると、進行中より前に出る。
    await tester.tap(find.byKey(const Key('pin-old-plan')));
    await tester.pumpAndSettle();
    expect(find.textContaining('ピン留め 1件を先頭に表示'), findsOneWidget);
    expect(top('pin-old-plan'), lessThan(top('pin-context-hub')));
    await tester.tap(find.byKey(const Key('pin-context-hub')));
    await tester.pumpAndSettle();
    expect(c.pinnedProjectIds, ['old-plan', 'context-hub']);
    // 並び替えの画面で前へ動かす。休止中であることも示す。
    await tester.tap(find.byKey(const Key('reorder-pins')));
    await tester.pumpAndSettle();
    expect(find.textContaining('（「次の一手」には出ません）'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('pin-up-old-plan')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('pin-up-context-hub')));
    await tester.pumpAndSettle();
    expect(c.pinnedProjectIds, ['context-hub', 'old-plan']);
    await tester.tap(find.byKey(const Key('pin-remove-old-plan')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pin-row-old-plan')), findsNothing);
    await tester.tap(find.byKey(const Key('pin-order-close')));
    await tester.pumpAndSettle();
    expect(c.pinnedProjectIds, ['context-hub']);
    expect(top('pin-context-hub'), lessThan(top('pin-side-app')));
    // 「次の一手」でも、根拠の新しいプロジェクトより先に出す。
    await tester.tap(find.byKey(const Key('home-next')));
    await tester.pumpAndSettle();
    expect(
      top('next-project-context-hub'),
      lessThan(top('next-project-side-app')),
    );
    expect(access.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('プロジェクトの画面からピン留めを切り替えられる', (tester) async {
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
    await tester.tap(find.byKey(const Key('project-side-app')).last);
    await tester.pumpAndSettle();
    expect(find.text('ピン留め'), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-pin')));
    await tester.pumpAndSettle();
    expect(find.text('ピン留めを外す'), findsOneWidget);
    expect(c.pinnedProjectIds, ['side-app']);
    await tester.tap(find.byKey(const Key('project-pin')));
    await tester.pumpAndSettle();
    expect(c.pinnedProjectIds, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
