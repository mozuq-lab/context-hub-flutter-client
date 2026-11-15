import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/policies.dart';
import 'package:context_hub_client/core/repository.dart';
import 'fixtures.dart';

/// 本体の版が上がり、知らない版（schema_version 2）の記録が同期された場合。
void main() {
  test('知らない上位の版の記録は、ファイルごとの注意ではなく「アプリを更新」を1件だけ出す', () {
    final files = fixtureFiles();
    for (final id in [
      'IN-01M2DSFVSNCJSF7XKRPW29TM7A',
      'IN-01M2DSFVSNCJSF7XKRPW29TM7B',
    ]) {
      files['00_inbox/2026-09-20_$id.md'] = encodePacket({
        'schema_version': 2,
        'id': id,
        'kind': 'memo',
        'source': 'cli',
        'source_event_id': id,
        'occurred_at': '2026-09-20T00:00:00Z',
        'received_at': '2026-09-20T00:00:00Z',
        'origin': 'user-note',
      }, '新しい形式のメモ');
    }
    final repo = HubRepository(fixture(files));
    expect(repo.warnings, [newerFormatWarning]);
    expect(repo.newerFormat, isTrue);
    // 読める記録は表示を続ける。
    expect(repo.projects['context-hub'], isNotNull);
  });

  test('受付記録の版が新しいときは、競合ではなく本体が新しいことを示す', () {
    final files = fixtureFiles();
    const op = '11111111-1111-4111-8111-111111111111';
    final requestId = 'REQ-${op.replaceAll('-', '')}';
    final raw = encodePacket({
      'schema_version': 1,
      'request_id': requestId,
      'source': 'flutter-client/$op',
      'occurred_at': '2026-10-01T00:00:00.000Z',
      'operation': 'capture',
      'kind': 'memo',
      'tool': 'context-hub-flutter',
    }, '新しい本体で受け付けたメモ');
    files['Input/$requestId.md'] = raw;
    files['90_system/intake/$requestId.json'] = jsonEncode({
      'schema_version': 2,
      'request_id': requestId,
      'request_hash': digest(raw),
      'path': 'Input/$requestId.md',
      'operation': 'capture',
      'status': 'accepted',
      'received_at': '2026-10-01T00:00:01.000Z',
      'result': {'inputId': 'IN-01M2DSFVSNCJSF7XKRPW29TM7C', 'deduped': false},
    });
    final repo = HubRepository(fixture(files));
    final item = repo.intake.singleWhere((i) => i.id == requestId);
    expect(item.state, isNot('conflict'));
    expect(item.state, 'unknown');
    expect(item.detail, contains('アプリを更新'));
    expect(repo.warnings, [newerFormatWarning]);
  });

  test('方針と確認待ち一覧の版が新しいときも、更新を案内する', () {
    final files = fixtureFiles();
    for (final path in [
      '90_system/policies/index.json',
      '90_system/review/index.json',
    ]) {
      final value = jsonDecode(files[path]!) as Map;
      value['schema_version'] = 2;
      files[path] = jsonEncode(value);
    }
    final snapshot = fixture(files);
    expect(
      () => PolicyReader(snapshot).read(),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('アプリを更新'),
        ),
      ),
    );
    final repo = HubRepository(snapshot);
    expect(repo.review.warnings.join(), contains('アプリを更新'));
  });
}
