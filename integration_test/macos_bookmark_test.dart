import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:context_hub_client/main.dart' show loadSample;
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/storage/capture_service.dart';

// choose→プロセス終了→restoreの2回で実行する。OSの選択画面では専用の架空Vaultだけを選ぶ。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac実選択・bookmark再起動復元・再選択・Input排他',
    (t) async {
      if (!Platform.isMacOS) return;
      const phase = String.fromEnvironment(
        'MAC_TEST_PHASE',
        defaultValue: 'choose',
      );
      const operation = String.fromEnvironment('MAC_TEST_OPERATION');
      expect(operation, isNotEmpty, reason: '両段階へ同じテスト操作UUIDを指定してください');
      final access = NativeVaultAccess();
      final c = HubController(access, sampleLoader: loadSample);
      await t.pumpWidget(ContextHubApp(controller: c));
      await t.pumpAndSettle();
      if (phase == 'choose') {
        final selected = await access.pickVault();
        expect(selected, isNotNull);
        await c.activate(selected!);
      } else {
        expect(phase, 'restore');
        await c.restore();
      }
      expect(c.error, isNull);
      expect(c.location?.handle, startsWith('bookmark:'));
      final before = await access.readSnapshot(c.location!);
      // 誤って実Vaultを選んでも、このマーカーを確認するまで書き込まない。
      final marker = before.files['90_system/mac-test-marker.json'];
      expect(marker, isNotNull, reason: '専用の架空Vaultを選択してください');
      expect(
        (jsonDecode(marker!) as Map)['purpose'],
        'context-hub-native-bookmark-test',
      );
      expect(before.warnings.join(' '), contains('symlink'));
      expect(before.warnings.join(' '), contains('oversized.md'));
      expect(before.files.containsKey('00_inbox/outside-link.md'), isFalse);
      expect(before.files.containsKey('00_inbox/oversized.md'), isFalse);
      final draft = CaptureDraft(
        operationId: operation,
        text: 'Mac bookmarkの架空確認',
        project: 'context-hub',
      );
      final service = CaptureService(access, c.location!);
      if (phase == 'restore') {
        expect((await service.confirm(operation)).saved, isTrue);
        final identity = c.location!.identity;
        final selected = await access.pickVault();
        expect(selected, isNotNull);
        expect(selected!.identity, identity);
        await c.activate(selected);
      }
      final result = await CaptureService(access, c.location!).save(draft);
      expect(result.saved, isTrue);
      expect(
        (await CaptureService(access, c.location!).save(draft)).requestId,
        result.requestId,
      );
      final after = await access.readSnapshot(c.location!);
    for (final entry in before.files.entries) {
        expect(after.files[entry.key], entry.value, reason: entry.key);
    }
      expect(
        after.files.keys.where((p) => p.startsWith('Input/')),
        hasLength(1),
      );
      expect(
        after.files.length,
        before.files.length + (phase == 'choose' ? 1 : 0),
      );
      expect(t.takeException(), isNull);
      c.dispose();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
