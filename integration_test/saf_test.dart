import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:context_hub_client/main.dart' show loadSample;
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/core/parser.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android実SAF: 選択・永続権限・Input作成・保存・再確認・既存不変',
    (tester) async {
      if (!Platform.isAndroid) {
        return;
      }
      final access = NativeVaultAccess();
      final c = HubController(access, sampleLoader: loadSample);
      await tester.pumpWidget(ContextHubApp(controller: c));
      await tester.pumpAndSettle();
      // ホスト側から専用emulatorのDocuments/ContextHubFlutterSAFを選択する。
      final selected = await access.pickVault();
      expect(selected, isNotNull);
      await c.activate(selected!);
      await tester.pumpAndSettle();
      expect(c.error, isNull);
      expect(c.repository!.projects, isNotEmpty);
      final before = await access.readSnapshot(selected);
      final op = const Uuid().v4();
      final draft = CaptureDraft(
        operationId: op,
        text: 'SAFの架空テスト\n\n本文はそのまま。',
        project: 'context-hub',
      );
      final result = await c.save(draft);
      expect(result.saved, isTrue);
      final raw = (await access.readRequest(selected, result.requestId))!;
      expect(parseMarkdown(raw).body, draft.text);
      expect(
        (await CaptureService(access, selected).save(draft)).requestId,
        result.requestId,
      );
      final restored = HubController(access, sampleLoader: loadSample);
      await restored.restore();
      expect(restored.error, isNull);
      expect(restored.location!.handle, selected.handle);
      final after = await access.readSnapshot(restored.location!);
      for (final entry in before.files.entries) {
        expect(after.files[entry.key], entry.value, reason: entry.key);
      }
      expect(after.files.length, before.files.length + 1);
      await expectLater(
        NativeVaultAccess.channel.invokeMethod('readSnapshot', {
          'handle': 'content://unsupported.example/tree/any',
        }),
        throwsA(isA<PlatformException>()),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
