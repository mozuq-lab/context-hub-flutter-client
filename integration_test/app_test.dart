import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:context_hub_client/main.dart' show loadSample;
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/storage/capture_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('実OS bridge: sample閲覧・検索・コピー・保存・再確認・既存不変', (tester) async {
    final access = NativeVaultAccess();
    final c = HubController(access, sampleLoader: loadSample);
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await c.useSample();
    await tester.pumpAndSettle();
    expect(c.error, isNull);
    expect(c.repository!.projects, isNotEmpty);
    final before = await access.readSnapshot(c.location!);
    final wide =
        tester.view.physicalSize.width / tester.view.devicePixelRatio >= 820;
    if (!wide) {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
    }
    await tester.tap(
      find.byKey(const Key('project-context-hub')).hitTestable().first,
    );
    await tester.pumpAndSettle();
    expect(find.text('現在地'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('copy-context')));
    await tester.tap(find.byKey(const Key('copy-context')));
    await tester.pumpAndSettle();
    expect((await Clipboard.getData('text/plain'))?.text, contains('IN-'));
    final source = find.byKey(const Key('source-record')).first;
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    if (!wide) {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('nav-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-query')), '同期');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-result')), findsWidgets);
    await tester.tap(find.byKey(const Key('new-memo')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('memo-text')),
      '実OS bridgeの架空テストメモ',
    );
    await tester.ensureVisible(find.byKey(const Key('save-memo')));
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに保存しました'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    final operation = const Uuid().v4();
    final draft = CaptureDraft(
      operationId: operation,
      text: '実OS排他・再起動確認\n原文保持',
    );
    final service = CaptureService(access, c.location!);
    final saved = await service.save(draft);
    expect(saved.saved, isTrue);
    expect(
      (await CaptureService(access, c.location!).save(draft)).requestId,
      saved.requestId,
    );
    expect((await service.confirm(operation)).saved, isTrue);
    final after = await access.readSnapshot(c.location!);
    for (final entry in before.files.entries) {
      expect(after.files[entry.key], entry.value, reason: entry.key);
    }
    expect(after.files.length, before.files.length + 2);
    await expectLater(
      NativeVaultAccess.channel.invokeMethod('writeRequest', {
        'handle': c.location!.handle,
        'requestId': '../outside',
        'raw': '拒否',
      }),
      throwsA(isA<PlatformException>()),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
