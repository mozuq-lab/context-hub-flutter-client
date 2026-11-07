import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/guided.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'capture_test.dart' show TempAccess, location, draft;

Future<void> check(CaptureDraft draft) async {
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
        'meta': ?draft.meta,
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
}

void main() {
  test('Dartの実保存REQを上流parseIntake/ingestが原文のまま重複なく受領', () async {
    await check(draft);
  });
  test('選んで深掘りのメモを、metaを保ったまま上流が受領する', () async {
    final s = GuidedSession(
      id: '33333333-2222-4333-8444-555555555555',
      vault: 'vault',
      purpose: GuidedPurpose.sparring,
      project: draft.project,
      seed: '順番に迷う',
      contextLabel: 'project',
      startedAt: DateTime.utc(2026, 11, 7),
      steps: [
        GuidedStep(
          const GuidedQuestion(
            text: 'どちらを先に？',
            options: [GuidedOption('読取'), GuidedOption('画面')],
          ),
          const GuidedAnswer.free('読取から'),
        ),
      ],
    )..models.add('test-model');
    await check(
      CaptureDraft(
        operationId: '44444444-2222-4333-8444-555555555555',
        text: guidedBody('## 問い\n読取と画面のどちらを先にするか。', s),
        kind: 'memo',
        project: s.project,
        meta: guidedMeta(s),
      ),
    );
  });
}
