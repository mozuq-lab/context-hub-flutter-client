import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/ui/shortcuts.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

Future<HubController> openSample(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 2000);
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
  return c;
}

/// 修飾キー（Macは⌘、ほかはCtrl）を押しながらキーを押す。
Future<void> press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  final modifier = usesCommandKey
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

String appBarTitle(WidgetTester tester) =>
    (tester.widget<AppBar>(find.byType(AppBar)).title as Text).data!;

void main() {
  testWidgets('数字キーで画面を移り、入力欄が消えた後もショートカットが届く', (tester) async {
    await openSample(tester);
    await press(tester, LogicalKeyboardKey.digit2);
    expect(appBarTitle(tester), '次の一手');
    await press(tester, LogicalKeyboardKey.digit8);
    expect(appBarTitle(tester), '受付状況');
    // 検索を開くと入力欄へ移り、文字はそのまま入る。
    await press(tester, LogicalKeyboardKey.keyF);
    expect(appBarTitle(tester), '検索');
    final field = tester.widget<TextField>(
      find.byKey(const Key('search-query')),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(find.byKey(const Key('search-query')), 'サンプル');
    await tester.pumpAndSettle();
    // 入力中でも移動でき、入力欄が消えた後の画面でも次のキーが届く。
    await press(tester, LogicalKeyboardKey.digit1);
    expect(appBarTitle(tester), 'ホーム');
    await press(tester, LogicalKeyboardKey.digit4);
    expect(appBarTitle(tester), '最近のメモ');
    expect(tester.takeException(), isNull);
  });

  testWidgets('メモのフォームを開き、保存キーは空の本文を送らず、Escで閉じる', (tester) async {
    await openSample(tester);
    await press(tester, LogicalKeyboardKey.keyN);
    expect(find.text('思いつきを、そのまま。'), findsOneWidget);
    // フォームを開いている間は、画面の移動キーで裏の画面を変えない。
    await press(tester, LogicalKeyboardKey.digit2);
    expect(appBarTitle(tester), 'ホーム');
    // 開いた直後（入力欄を選ぶ前）から保存キーが届く。空の本文は送らない。
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('本文は1〜8000文字で入力してください。'), findsOneWidget);
    // 書きかけがあるときは、Escで閉じて捨てない。
    await tester.enterText(find.byKey(const Key('memo-text')), '書きかけ');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('思いつきを、そのまま。'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('memo-text')), '');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('思いつきを、そのまま。'), findsNothing);
    // 閉じた後もショートカットが届く。
    await press(tester, LogicalKeyboardKey.digit3);
    expect(appBarTitle(tester), 'ふりかえり');
    expect(tester.takeException(), isNull);
  });

  testWidgets('キーボード操作の一覧を開き、文脈のコピーはプロジェクト画面でだけ行う', (tester) async {
    final c = await openSample(tester);
    await press(tester, LogicalKeyboardKey.slash);
    expect(find.byKey(const Key('keyboard-help')), findsOneWidget);
    expect(find.text('Ctrl+N'), findsOneWidget);
    expect(find.text('Ctrl+1〜Ctrl+8'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyC, shift: true);
    expect(find.text('プロジェクトを開いてからコピーしてください。'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const Key('project-context-hub')).first);
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyC, shift: true);
    expect(copied, await c.context('context-hub'));
    expect(find.text('出典付きcontextをコピーしました'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Macでは⌘で操作し、メニューバーに同じ操作を並べる', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final sent = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.menu,
      (call) async {
        sent.add(call);
        return null;
      },
    );
    try {
      await openSample(tester);
      await press(tester, LogicalKeyboardKey.digit6);
      expect(appBarTitle(tester), '確認待ち');
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      expect(bar.menus.map((m) => (m as PlatformMenu).label), [
        'ContextHub',
        'ファイル',
        '編集',
        '移動',
        'ウインドウ',
        'ヘルプ',
      ]);
      final file = bar.menus[1] as PlatformMenu;
      final items = file.menus
          .expand((g) => (g as PlatformMenuItemGroup).members)
          .cast<PlatformMenuItem>();
      final memo = items.firstWhere((i) => i.label == 'メモを追加');
      expect((memo.shortcut! as SingleActivator).meta, isTrue);
      // 文脈のコピーはプロジェクト画面を開いていないと選べない。
      expect(
        items
            .firstWhere((i) => i.label == HubCommand.copyContext.label)
            .onSelected,
        isNull,
      );
      // メニューから選んでも、ショートカットと同じ操作になる。
      final move = bar.menus[3] as PlatformMenu;
      move.menus.first.onSelected!();
      await tester.pumpAndSettle();
      expect(appBarTitle(tester), 'ホーム');
      memo.onSelected!();
      await tester.pumpAndSettle();
      expect(find.text('思いつきを、そのまま。'), findsOneWidget);
      // フォームを開いている間のメニュー操作は受け付けない。
      final again = tester.widget<PlatformMenuBar>(
        find.byType(PlatformMenuBar),
      );
      (again.menus[3] as PlatformMenu).menus[1].onSelected!();
      await tester.pumpAndSettle();
      expect(find.text('思いつきを、そのまま。'), findsOneWidget);
      expect(sent, isNotEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.menu,
        null,
      );
    }
  });

  testWidgets('Macでアプリが背後に回って戻っても、入力欄のフォーカスを奪わない', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.menu,
      (call) async => null,
    );
    try {
      // デスクトップでは、アプリが背後に回るとフォーカスを最上位へ退避し、戻ったときに元へ戻す。
      FocusManager.instance.listenToApplicationLifecycleChangesIfSupported();
      await openSample(tester);
      await press(tester, LogicalKeyboardKey.keyF);
      final node = tester
          .widget<TextField>(find.byKey(const Key('search-query')))
          .focusNode!;
      expect(node.hasFocus, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(node.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.menu,
        null,
      );
    }
  });
}
