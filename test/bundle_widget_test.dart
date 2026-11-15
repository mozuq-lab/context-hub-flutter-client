import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/storage/basket_store.dart';
import 'package:context_hub_client/ui/app.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

Future<HubController> open(WidgetTester tester, MemoryUIAccess access) async {
  final c = HubController(access, sampleLoader: () async => fixture().files);
  addTearDown(c.dispose);
  await tester.pumpWidget(ContextHubApp(controller: c));
  await tester.pumpAndSettle();
  // 2回目以降は、前回開いたVault（サンプル）を設定から開き直す。
  if (find.text('サンプルで試す').evaluate().isNotEmpty) {
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
  }
  return c;
}

void main() {
  String? clipboard;
  setUp(() => clipboard = null);
  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'];
        }
        return null;
      },
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }

  testWidgets('一覧と詳細からかごに入れ、並べ替えてまとめてコピーし、端末に残る', (tester) async {
    wide(tester);
    final access = MemoryUIAccess();
    await access.init();
    final c = await open(tester, access);
    final recent = c.repository!.recent;
    await tester.tap(find.byKey(const Key('nav-recent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('basket-toggle-${recent[0].id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('文脈かごに入れました（1件）'), findsOneWidget);
    // 記録の詳細からも入れられる。
    await tester.tap(find.text(recent[1].title).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-basket')));
    await tester.pumpAndSettle();
    expect(find.text('かごから外す'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(c.basket.ids, [recent[0].id, recent[1].id]);
    expect(find.text('文脈かご（2）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav-basket')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('basket-item-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('basket-down-0')));
    await tester.pumpAndSettle();
    expect(c.basket.ids, [recent[1].id, recent[0].id]);
    await tester.tap(find.text('12000字'));
    await tester.pumpAndSettle();
    expect(c.basket.maxChars, 12000);
    ScaffoldMessenger.of(
      tester.element(find.byKey(const Key('copy-bundle'))),
    ).clearSnackBars();
    await tester.tap(find.byKey(const Key('copy-bundle')));
    await tester.pumpAndSettle();
    expect(clipboard, contains('# 選んだ記録（2件）'));
    final order = RegExp(
      r'^## \[([^\]]+)\]',
      multiLine: true,
    ).allMatches(clipboard!).map((m) => m[1]).toList();
    expect(order, [recent[1].sourceId, recent[0].sourceId]);
    expect(find.text('2件をまとめてコピーしました'), findsOneWidget);

    // かごは端末の状態ファイルに残り、Vaultには書かない。保存確認の情報とは分ける。
    expect(access.states.containsKey(BasketStore.fileName), isTrue);
    expect(access.writes, 0);
    await tester.tap(find.byKey(const Key('new-memo')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memo-text')), 'かごがあっても保存できる');
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに保存しました'), findsOneWidget);
    expect(access.writes, 1);

    await tester.pumpWidget(const SizedBox());
    final again = await open(tester, access);
    expect(again.basket.ids, [recent[1].id, recent[0].id]);
    expect(again.basket.maxChars, 12000);
  });

  testWidgets('見つからない記録があるとコピーを止め、外せば再開できる', (tester) async {
    wide(tester);
    final access = MemoryUIAccess();
    await access.init();
    final probe = await open(tester, access);
    final identity = probe.location!.identity,
        first = probe.repository!.recent[0];
    await tester.pumpWidget(const SizedBox());
    access.states[BasketStore.fileName] = jsonEncode({
      'version': 1,
      'vaults': {
        identity: {
          'ids': ['record-${'0' * 24}', first.id],
          'max': 6000,
          'at': '2026-11-01T00:00:00Z',
        },
      },
    });
    final c = await open(tester, access);
    await tester.tap(find.byKey(const Key('nav-basket')));
    await tester.pumpAndSettle();
    expect(find.text('見つからない記録'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('copy-bundle')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('basket-remove-0')));
    await tester.pumpAndSettle();
    expect(c.basket.ids, [first.id]);
    await tester.tap(find.byKey(const Key('copy-bundle')));
    await tester.pumpAndSettle();
    expect(clipboard, contains(first.sourceId));
    await tester.tap(find.byKey(const Key('basket-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('basket-clear-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('basket-empty')), findsOneWidget);
  });

  testWidgets('狭い画面でもdrawerから文脈かごを開ける', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final access = MemoryUIAccess();
    await access.init();
    final c = await open(tester, access);
    await c.toggleBasket(c.repository!.recent.first.id);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-basket')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('basket-item-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
