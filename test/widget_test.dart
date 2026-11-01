import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/ui/app.dart';
import 'controller_test.dart' show UIAccess;
import 'fixtures.dart';
import 'package:context_hub_client/storage/vault_access.dart';

class MemoryUIAccess extends UIAccess {
  final states = <String, String>{}, requests = <String, String>{};
  @override
  Future<void> init() async {}
  @override
  Future<String?> readState(String name) async => states[name];
  @override
  Future<void> writeState(
    String name,
    String raw, {
    bool exclusive = false,
  }) async {
    if (exclusive && states.containsKey(name)) {
      throw StateError('既存');
    }
    states[name] = raw;
  }

  @override
  Future<List<String>> listJournals() async =>
      states.keys.where((n) => n != 'settings.json').toList();
  @override
  Future<String?> readRequest(VaultLocation l, String id) async => requests[id];
  @override
  Future<void> writeRequest(VaultLocation l, String id, String raw) async {
    if (requests.containsKey(id)) {
      throw StateError('既存');
    }
    requests[id] = raw;
    writes++;
  }
}

void main() {
  testWidgets('サンプル→プロジェクト→原文→検索→コピー→メモ保存を操作できる', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final c = HubController(access, sampleLoader: () async => fixture().files);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'];
        }
        return null;
      },
    );
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-context-hub')).first);
    await tester.pumpAndSettle();
    expect(find.text('現在地'), findsWidgets);
    await tester.tap(find.byKey(const Key('copy-context')));
    await tester.pumpAndSettle();
    expect(clipboard, contains('IN-'));
    await tester.tap(find.byKey(const Key('source-record')).first);
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-query')), '同期');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-result')), findsWidgets);
    await tester.tap(find.byKey(const Key('new-memo')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memo-text')), '雑な思いつきを保存');
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに保存しました'), findsOneWidget);
    expect(access.writes, 1);
  });
  testWidgets('狭い画面でもdrawerから最近のメモを開ける', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
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
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-recent')));
    await tester.pumpAndSettle();
    expect(find.text('最近のメモ'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
