import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'capture_test.dart' show TempAccess, location, draft;

void main() {
  test('Dartの実保存REQを上流parseIntake/ingestが原文のまま重複なく受領', () async {
    final access = TempAccess();
    await access.init();
    try {
      final saved = await CaptureService(access, location).save(draft);
      final expected = File('${access.directory.path}/expected.json');
      await expected.writeAsString(
        jsonEncode({
          'text': draft.text,
          'operationId': draft.operationId,
          'project': draft.project,
        }),
      );
      final result = await Process.run('node', [
        'scripts/check_protocol.mjs',
        access.request(location, saved.requestId).path,
        expected.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      await access.directory.delete(recursive: true);
    }
  });
}
