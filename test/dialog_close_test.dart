import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/ui/parts.dart';
import 'shell_navigation_test.dart' show openRecordWide, openSample, topTitle;

/// ダイアログを開くボタンだけの画面。押すと[dialog]を開き、閉じたときの戻り値を[result]に残す。
class _Opener extends StatefulWidget {
  const _Opener(this.dialog);
  final Widget Function(BuildContext dialog) dialog;
  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  Object? result = 'まだ閉じていない';
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async {
          final r = await showDialog<Object>(
            context: context,
            builder: widget.dialog,
          );
          setState(() => result = r);
        },
        child: const Text('開く'),
      ),
    ),
  );
}

Future<_OpenerState> _open(
  WidgetTester tester,
  Widget Function(BuildContext dialog) dialog, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: _Opener(dialog)));
  await tester.tap(find.text('開く'));
  await tester.pumpAndSettle();
  return tester.state<_OpenerState>(find.byType(_Opener));
}

void main() {
  /// lib の Dart ファイル（共通部品の parts.dart を除く）。
  Iterable<File> sources() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => f.uri.path != 'lib/ui/parts.dart');

  test('アプリのダイアログは、すべて右上に閉じるボタンのある形で開く', () {
    // 閉じるボタンの付かない作りを直接使わず、parts.dart の部品を通す。
    // 全画面のダイアログ（Dialog.fullscreen・fullscreenDialog）は AppBar の右端に閉じるボタンを置く。
    final banned = RegExp(
      r'(?<![\w.])(AlertDialog|AboutDialog|CupertinoAlertDialog|Dialog)(\.adaptive)?\(|'
      r'show(About|General|Cupertino)Dialog\(|show(Modal)?BottomSheet\(',
    );
    final offenders = <String>[];
    for (final file in sources()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (banned.hasMatch(line)) offenders.add('${file.path}:${i + 1}');
        // SimpleDialog は題名に closableTitle を使う。
        if (RegExp(r'(?<![\w.])SimpleDialog\(').hasMatch(line) &&
            !lines.skip(i).take(6).any((l) => l.contains('closableTitle('))) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('閉じるボタンは、どのダイアログでも、そのダイアログのボタンのどれかと同じ処理をする', () {
    // onClose の処理（「busy ? null : 」を除く）が、同じダイアログの中の onPressed のどれかと同じ文であること。
    // 手で書き足すときに、取り消し以外の処理や、ページの context で閉じる処理を渡していないかを見る。
    final mismatched = <String>[];
    var checked = 0;
    String norm(String s) => s.replaceAll(RegExp(r'\s+'), '');
    for (final file in sources()) {
      final text = file.readAsStringSync();
      final starts = RegExp(r'HubAlertDialog\(').allMatches(text).toList();
      for (var k = 0; k < starts.length; k++) {
        final body = text.substring(
          starts[k].start,
          k + 1 < starts.length ? starts[k + 1].start : text.length,
        );
        final close = RegExp(
          r'onClose:\s*(?:busy\s*\?\s*null\s*:\s*)?(\(\)\s*=>[^\n]*?\)),\n',
        ).firstMatch(body);
        final line = text.substring(0, starts[k].start).split('\n').length;
        if (close == null) {
          mismatched.add('${file.path}:$line（onClose が読めない）');
          continue;
        }
        final want = norm(close.group(1)!);
        final presses = RegExp(
          r'onPressed:\s*(?:busy\s*\?\s*null\s*:\s*)?(\(\)\s*=>[\s\S]*?\)),\n',
        ).allMatches(body).map((m) => norm(m.group(1)!));
        if (!presses.contains(want)) mismatched.add('${file.path}:$line');
        checked++;
      }
    }
    expect(mismatched, isEmpty);
    expect(checked, greaterThan(30));
  });

  for (final size in [const Size(1280, 900), const Size(390, 800)]) {
    testWidgets('閉じるボタンは、取り消しのボタンと同じ値で閉じ、長い題名でも右上に残る（${size.width.toInt()}幅）', (
      tester,
    ) async {
      final opener = await _open(
        tester,
        (dialog) => HubAlertDialog(
          title: const Text('とても長い題名のダイアログで、狭い画面では二行以上に折り返す題名'),
          onClose: () => Navigator.pop(dialog, false),
          content: const Text('本文'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('やめる'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('する'),
            ),
          ],
        ),
        size: size,
      );
      // ダイアログの面（まわりの余白を除く）。
      final dialog = tester.getRect(
        find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first,
      );
      final close = tester.getRect(find.byKey(const Key('dialog-close')));
      expect(dialog.right - close.right, inInclusiveRange(8, 16));
      expect(close.top - dialog.top, inInclusiveRange(8, 20));
      expect(
        tester.getRect(find.textContaining('とても長い題名')).right,
        lessThanOrEqualTo(close.left),
      );
      await tester.tap(find.byKey(const Key('dialog-close')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(opener.result, false);
    });
  }

  testWidgets('取り消せない間は、閉じるボタンも押せない', (tester) async {
    await _open(
      tester,
      (dialog) => const HubAlertDialog(title: Text('保存中'), onClose: null),
    );
    final button = tester.widget<IconButton>(
      find.byKey(const Key('dialog-close')),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.byKey(const Key('dialog-close')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('保存中'), findsOneWidget);
  });

  for (final size in [const Size(1280, 900), const Size(390, 800)]) {
    testWidgets('メモを追加のフォームは、右上の閉じるボタンで閉じる（${size.width.toInt()}幅）', (
      tester,
    ) async {
      await openSample(tester, size);
      await tester.tap(find.byKey(const Key('new-memo')).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memo-text')), findsOneWidget);
      await tester.tap(find.byKey(const Key('dialog-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memo-text')), findsNothing);
      expect(topTitle(tester), 'ホーム');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('記録の詳細の上で開いたフォームを閉じるボタンで閉じても、詳細は残る', (tester) async {
    await openSample(tester, const Size(1280, 900));
    await openRecordWide(tester);
    final title = topTitle(tester);
    await tester.tap(find.byKey(const Key('new-memo')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dialog-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memo-text')), findsNothing);
    expect(topTitle(tester), title);
    expect(find.text('出典・日時'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Macの「ContextHub Clientについて」は、ライセンスを開けて、閉じるボタンで閉じる', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.menu,
      (call) async => null,
    );
    try {
      await openSample(tester, const Size(1280, 900));
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      final about = (bar.menus.first as PlatformMenu).menus
          .expand((g) => (g as PlatformMenuItemGroup).members)
          .cast<PlatformMenuItem>()
          .firstWhere((i) => i.label == 'ContextHub Clientについて');
      about.onSelected!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('about-dialog')), findsOneWidget);
      expect(find.textContaining('バージョン'), findsOneWidget);
      await tester.tap(find.text('ライセンスを表示'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsNothing);
      expect(find.byKey(const Key('about-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('dialog-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('about-dialog')), findsNothing);
      expect(topTitle(tester), 'ホーム');
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
