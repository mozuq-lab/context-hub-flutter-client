import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/ui/notice.dart';
import 'package:context_hub_client/ui/theme.dart';
import 'fixtures.dart';
import 'shortcuts_test.dart' show press;
import 'widget_test.dart' show MemoryUIAccess;

const memoTitle = '同期とバックアップを分けるにはどうする？';

Future<HubController> openSample(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final access = MemoryUIAccess();
  await access.init();
  final c = HubController(access, sampleLoader: () async => fixture().files);
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

/// 本文の領域の題名（詳細を開いているときは、詳細の題名）。
String topTitle(WidgetTester tester) =>
    (tester.widgetList<AppBar>(find.byType(AppBar)).last.title as Text).data!;

/// 広い画面で、最近のメモから記録の詳細を開く。
Future<void> openRecordWide(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-recent')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(memoTitle).first);
  await tester.pumpAndSettle();
  expect(find.text('出典・日時'), findsOneWidget);
}

/// 指定した場所だけ読めないVault。
class _BadAccess extends MemoryUIAccess {
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) {
    if (location.handle == 'bad') throw StateError('読めません');
    return super.readSnapshot(location);
  }
}

void main() {
  testWidgets('狭い画面では、操作付きの案内が出ていても右下の「メモを追加」を押せ、詳細を開いている間は隠す', (
    tester,
  ) async {
    await openSample(tester, const Size(390, 800));
    final fab = find.byKey(const Key('new-memo'));
    // 操作付きの案内は閉じるまで残るので、ボタンと重ならないことを確かめる。
    notice(
      tester.element(fab),
      '受け付けられました',
      action: (label: '最近のメモ', onPressed: () {}),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .getRect(find.byType(SnackBar))
          .overlaps(tester.getRect(fab)),
      isFalse,
    );
    await tester.tap(fab);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memo-text')), findsOneWidget);
    await tester.tap(find.text('フォームを閉じる'));
    await tester.pumpAndSettle();
    // 詳細を開いている間は出さず、閉じると戻る。
    await tester.tap(find.byKey(const Key('nav-recent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(memoTitle).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-memo')), findsNothing);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-memo')), findsOneWidget);
  });

  for (final size in [const Size(390, 800), const Size(1200, 800)]) {
    testWidgets('設定を開いたままVaultを読めなくなったら、ようこそ画面に戻る（${size.width.toInt()}幅）', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final access = _BadAccess();
      await access.init();
      final c = HubController(
        access,
        sampleLoader: () async => fixture().files,
      );
      addTearDown(() {
        c.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ContextHubApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('サンプルで試す'));
      await tester.pumpAndSettle();
      if (size.width < 820) {
        await tester.tap(find.byKey(const Key('nav-more')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('choose-vault')), findsOneWidget);
      await c.activate(const VaultLocation('bad', 'Bad'));
      await tester.pumpAndSettle();
      expect(c.repository, isNull);
      expect(find.byKey(const Key('choose-vault')), findsNothing);
      expect(find.text('サンプルで試す'), findsOneWidget);
    });
  }

  testWidgets('広い画面では、記録の詳細を開いたままサイドバーからほかの画面へ移れる', (tester) async {
    await openSample(tester, const Size(1280, 900));
    await openRecordWide(tester);
    // サイドバーは詳細の横に残り、メニューを開くボタンは出さない。
    expect(find.byKey(const Key('nav-ideas')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('detail-menu')), findsNothing);
    await tester.tap(find.byKey(const Key('nav-ideas')));
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), 'アイデア');
    // 詳細を閉じた後も、元の画面へ戻る操作は要らない（戻る先の詳細は残らない）。
    expect(find.byType(BackButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('広い画面では、記録の詳細を開いたままプロジェクトを開ける', (tester) async {
    await openSample(tester, const Size(1280, 900));
    await openRecordWide(tester);
    await tester.tap(find.byKey(const Key('project-context-hub')));
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), 'プロジェクト');
    expect(find.byKey(const Key('copy-context')), findsOneWidget);
  });

  testWidgets('記録の詳細を開いたまま、キーボードで画面を移れる', (tester) async {
    await openSample(tester, const Size(1280, 900));
    await openRecordWide(tester);
    await press(tester, LogicalKeyboardKey.digit2);
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), '次の一手');
    // 詳細から戻った後も、続けてキーが届く。
    await press(tester, LogicalKeyboardKey.digit6);
    expect(topTitle(tester), 'アイデア');
    expect(tester.takeException(), isNull);
  });

  testWidgets('詳細の「戻る」とAndroidの戻る操作は、開いている詳細だけを閉じる', (tester) async {
    await openSample(tester, const Size(1280, 900));
    await openRecordWide(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), '最近のメモ');
    await tester.tap(find.text(memoTitle).first);
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsOneWidget);
    // 端末の「戻る」はアプリを閉じず、詳細を閉じる。
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), '最近のメモ');
  });

  testWidgets('狭い画面では、詳細を開いたまま下のタブと「その他」からほかの画面へ移れる', (tester) async {
    await openSample(tester, const Size(390, 844));
    await tester.tap(find.byKey(const Key('nav-recent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(memoTitle).first);
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsOneWidget);
    // 下のタブは詳細の下にも残る。毎日使う画面へはそのまま移れる。
    await tester.tap(find.byKey(const Key('nav-next')));
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), '次の一手');
    await tester.tap(find.byKey(const Key('nav-recent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(memoTitle).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-ideas')));
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), 'アイデア');
    expect(tester.takeException(), isNull);
  });

  testWidgets('狭い画面で詳細の上にメニューを開いたとき、Androidの戻る操作はメニューだけを閉じる', (tester) async {
    await openSample(tester, const Size(390, 844));
    await tester.tap(find.byKey(const Key('nav-recent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(memoTitle).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-more')));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('出典・日時'), findsOneWidget);
    // もう一度の「戻る」で詳細を閉じる。
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsNothing);
    expect(topTitle(tester), '最近のメモ');
  });

  testWidgets('本文の領域で選択肢の一覧を開いている間は、ショートカットで入力フォームを開かない', (tester) async {
    await openSample(tester, const Size(1280, 900));
    await press(tester, LogicalKeyboardKey.keyF);
    final dropdown = find.byWidgetPredicate(
      (w) => w is DropdownButtonFormField,
    );
    expect(dropdown, findsWidgets);
    await tester.tap(dropdown.first);
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyN);
    expect(find.text('思いつきを、そのまま。'), findsNothing);
  });

  for (final size in [const Size(1280, 900), const Size(400, 800)]) {
    testWidgets('「保存と反映」の項目を開いた画面は、「閉じる」でその画面だけを閉じる（${size.width.toInt()}幅）', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final access = MemoryUIAccess();
      await access.init();
      final files = fixtureFiles();
      access.current = VaultSnapshot(files, loadedAt: DateTime(2000));
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
      // この端末で保存したメモが、同期でVaultに届いた（Mac miniはまだ受け取っていない）。
      final saved = await tester.runAsync(
        () => c.save(
          const CaptureDraft(
            operationId: '0b9d4c3a-1111-4222-8333-444455556667',
            text: '帰りに牛乳を買う',
          ),
        ),
      );
      access.current = VaultSnapshot({
        ...files,
        'Input/${saved!.requestId}.md': access.requests[saved.requestId]!,
      }, loadedAt: DateTime(2000));
      await tester.runAsync(c.refreshQuietly);
      await tester.pumpAndSettle();
      if (size.width < 800) {
        await tester.tap(find.byKey(const Key('nav-more')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('nav-intake')));
      await tester.pumpAndSettle();
      expect(topTitle(tester), '保存と反映');
      final intakeItem = find.ancestor(
        of: find.textContaining('保存済み'),
        matching: find.byType(ListTile),
      );
      expect(intakeItem, findsOneWidget);
      await tester.tap(intakeItem);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();
      // 開いた画面だけが閉じ、「保存と反映」の一覧はそのまま残る。
      expect(find.byType(AlertDialog), findsNothing);
      expect(topTitle(tester), '保存と反映');
      expect(intakeItem, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('続けて出した案内は、前の案内が消えるのを待たずに出る', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                notice(context, '一つ目の案内');
                notice(context, '二つ目の案内');
              },
              child: const Text('出す'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('出す'));
    // 既定のSnackBarなら一つ目が4秒出続け、二つ目はその後になる。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('二つ目の案内'), findsOneWidget);
    expect(find.text('一つ目の案内'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  test('案内を出しておく時間は文の長さに合わせ、4〜10秒に収める', () {
    expect(noticeDuration('保存しました'), const Duration(seconds: 4));
    expect(noticeDuration('あ' * 60), const Duration(milliseconds: 6800));
    expect(noticeDuration('あ' * 500), const Duration(seconds: 10));
  });

  test('明るい表示と暗い表示で、カードの余白・枠と入力欄の形をそろえる', () {
    final light = hubTheme(Brightness.light), dark = hubTheme(Brightness.dark);
    for (final t in [light, dark]) {
      expect(t.cardTheme.margin, EdgeInsets.zero);
      expect(t.cardTheme.elevation, 0);
      expect(t.inputDecorationTheme.border, isA<OutlineInputBorder>());
    }
    expect(light.colorScheme.brightness, Brightness.light);
    expect(dark.colorScheme.brightness, Brightness.dark);
    // 面は色味のない灰色にし、緑がかった背景にしない。
    final bg = light.scaffoldBackgroundColor;
    expect((bg.r - bg.g).abs() < .02 && bg.b >= bg.g, isTrue);
    expect(light.colorScheme.primary, hubAccent);
  });
}
