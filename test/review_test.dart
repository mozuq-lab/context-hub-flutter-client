import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/review_candidates.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/storage/review_service.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'capture_test.dart' show TempAccess, location, op;

Map<String, dynamic> reviewFixture() =>
    jsonDecode(File('assets/review.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, String> reviewFiles() =>
    Map<String, String>.from(reviewFixture()['files'] as Map);
ReviewRepository review(Map<String, String> files) {
  final s = VaultSnapshot(files);
  return ReviewRepository(s, HubRepository(s).records.values);
}

void main() {
  test('Node生成fixtureの4種類・履歴・古い根拠を同じ件数で読む', () {
    final r = review(reviewFiles()),
        expected = reviewFixture()['expected'] as Map;
    expect(r.pending.length, expected['pending']);
    expect(r.attention.length, expected['attention']);
    expect(r.history.length, expected['history']);
    expect(r.pending.map((i) => i.kind).toSet(), {
      'project',
      'knowledge',
      'decision',
      'preference',
    });
    expect(
      r.history.where((i) => i.status == 'approved').single.reflected,
      isTrue,
    );
  });
  test('依存欠損・変更・新しい訂正を操作可能とせず他の候補を残す', () {
    for (final mode in ['missing', 'changed', 'correction', 'decision']) {
      final files = reviewFiles(),
          before = review(files),
          item = before.pending.firstWhere((i) => i.kind == 'decision');
      if (mode == 'missing') files.remove(item.path);
      if (mode == 'changed') files[item.path] = '${files[item.path]}変更';
      if (mode == 'decision') {
        files['90_system/approvals/APR-${item.id.substring(4)}.json'] = '{}';
      }
      if (mode == 'correction') {
        const id = 'IN-00000000000000000000000001';
        files['00_inbox/2026-11-01_$id.md'] = encodePacket({
          'id': id,
          'corrects_input_id': item.inputIds.last,
        }, '新しい訂正');
      }
      final r = review(files);
      expect(r.byId(item.id)!.actionable, isFalse, reason: mode);
      expect(r.pending.any((i) => i.kind == 'preference'), isTrue);
    }
  });
  test('pageのhash不一致や破損行を他の閲覧へ波及させない', () {
    final files = reviewFiles(),
        root = jsonDecode(files['90_system/review/index.json']!) as Map;
    final raw = jsonEncode({'schema_version': 1, 'items': root['items']});
    files['90_system/review/page-00000.json'] = raw;
    files['90_system/review/index.json'] = jsonEncode({
      ...root,
      'items': [],
      'pages': [
        {'path': '90_system/review/page-00000.json', 'hash': digest(raw)},
      ],
    });
    expect(review(files).pending.length, 4);
    files['90_system/review/page-00000.json'] = '$raw ';
    expect(review(files).pending, isEmpty);
    expect(review(files).warnings, isNotEmpty);
    expect(HubRepository(VaultSnapshot(files)).recent, isNotEmpty);
  });
  test('承認記録があっても反映先が未同期なら反映済みとしない', () {
    final files = reviewFiles(),
        r = review(files),
        approved = r.history.firstWhere((i) => i.status == 'approved');
    files.remove(approved.targetPath);
    expect(review(files).byId(approved.id)!.reflected, isFalse);
  });
  test('二重保存・応答消失・反対判断・別Vaultを先行journalで扱う', () async {
    final access = TempAccess();
    await access.init();
    addTearDown(() => access.directory.delete(recursive: true));
    final c = review(
          reviewFiles(),
        ).pending.firstWhere((i) => i.kind == 'knowledge'),
        s = ReviewService(access, location);
    access.loseResponse = true;
    final results = await Future.wait([
      s.submit(op, c, 'approve', target: AdoptionTarget.global()),
      s.submit(op, c, 'approve', target: AdoptionTarget.global()),
    ]);
    expect(results.every((r) => r.saved), isTrue);
    expect(access.writes, 1);
    final raw = (await access.readRequest(location, results.first.requestId))!,
        packet = parseMarkdown(raw);
    expect(packet.body, '');
    expect(packet.meta['operation'], 'knowledge-approve');
    expect(packet.meta['confirmed'], true);
    expect(await access.readState('$op.json'), isNot(contains(c.claim)));
    await expectLater(s.submit(op, c, 'reject'), throwsStateError);
    expect((await CaptureService(access, location).confirm(op)).saved, isTrue);
  });
  for (final kind in ['decision', 'project']) {
    for (final action in ['approve', 'reject']) {
      test('Dartの$kind/$actionを固定上流で受理して再同期する', () async {
        final access = TempAccess();
        await access.init();
        addTearDown(() => access.directory.delete(recursive: true));
        final c = review(
          reviewFiles(),
        ).pending.firstWhere((i) => i.kind == kind);
        final result = await ReviewService(
          access,
          location,
        ).submit(op, c, action, target: AdoptionTarget.global());
        final output = '${access.directory.path}/after.json';
        final node = await Process.run('node', [
          'scripts/check_review_protocol.mjs',
          access.request(location, result.requestId).path,
          'assets/review.json',
          output,
        ]);
        expect(node.exitCode, 0, reason: '${node.stdout}\n${node.stderr}');
        final files = Map<String, String>.from(
          jsonDecode(await File(output).readAsString()) as Map,
        );
        final repo = HubRepository(VaultSnapshot(files));
        expect(repo.review.pending.length, 2);
        expect(
          repo.review.byId(c.id)!.status,
          action == 'approve' ? 'approved' : 'rejected',
        );
        expect(repo.review.byId(c.id)!.reflected, isTrue);
        expect(repo.intake.single.state, 'accepted');
        expect(
          repo.intake.single.detail,
          contains(action == 'approve' ? '承認済み' : '却下済み'),
        );
      });
    }
  }
}
