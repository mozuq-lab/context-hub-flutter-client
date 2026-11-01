import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/policies.dart';
import 'package:context_hub_client/core/review_candidates.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/storage/review_service.dart';
import 'capture_test.dart' show TempAccess, location, op;

Map<String, dynamic> scopedFixture() =>
    jsonDecode(File('assets/scoped-policy.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, String> scopedFiles() =>
    Map<String, String>.from(scopedFixture()['files'] as Map);
void main() {
  test('本体と同じ全文・有効範囲を読みproject内の知識を閲覧できる', () {
    final repo = HubRepository(VaultSnapshot(scopedFiles())),
        bundle = PolicyReader(repo.snapshot).read('example');
    expect(bundle.text, scopedFixture()['expected']['text']);
    expect(bundle.text, contains('共通の採用方針'));
    expect(bundle.text, contains('対象固有の採用方針'));
    expect(bundle.text, isNot(contains('必要時に参照する知識')));
    expect(bundle.text, isNot(contains('停止した古い方針')));
    expect(
      repo.records.values.any((r) => r.path.contains('/knowledge/')),
      isTrue,
    );
    expect(repo.context('example').startsWith(bundle.text), isTrue);
    expect(() => repo.context('example', maxChars: 200), throwsFormatException);
  });
  test('正本・停止・manifest・POLICYの部分同期を空方針として使わない', () {
    for (final mode in ['missing', 'stop', 'knw', 'projection', 'new']) {
      final files = scopedFiles();
      if (mode == 'missing') files.remove('90_system/policies/index.json');
      if (mode == 'stop') {
        files.removeWhere(
          (p, _) => p.startsWith('90_system/knowledge-retirements/'),
        );
      }
      if (mode == 'knw') {
        final p = files.keys.firstWhere((p) => p.startsWith('30_knowledge/'));
        files[p] = '${files[p]}変更';
      }
      if (mode == 'projection') files['POLICY.md'] = '変更';
      if (mode == 'new') {
        files['90_system/approvals/APR-${'0' * 26}.json'] = '{}';
      }
      expect(
        () => PolicyReader(VaultSnapshot(files)).read('example'),
        throwsFormatException,
        reason: mode,
      );
    }
  });
  test('採用先なしを拒否しscope付きREQと停止REQを先行journalで保存する', () async {
    final a = TempAccess();
    await a.init();
    addTearDown(() => a.directory.delete(recursive: true));
    final repo = HubRepository(VaultSnapshot(scopedFiles())),
        candidate = repo.review.pending.single,
        s = ReviewService(a, location);
    await expectLater(
      s.submit(op, candidate, 'approve'),
      throwsFormatException,
    );
    final target = AdoptionTarget.fromJson(
      Map<String, dynamic>.from(scopedFixture()['expected']['target'] as Map),
    );
    final result = await s.submit(op, candidate, 'approve', target: target),
        raw = (await a.readRequest(location, result.requestId))!;
    expect(parseMarkdown(raw).meta, containsPair('project_id', 'example'));
    expect(
      (await s.submit(op, candidate, 'approve', target: target)).saved,
      isTrue,
    );
    expect(a.writes, 1);
    await expectLater(
      s.submit(op, candidate, 'approve', target: AdoptionTarget.global()),
      throwsStateError,
    );
    final old = repo.review.history.firstWhere(
      (i) => !i.retired && i.kind != 'project',
    );
    final stop = await s.retire('11111111-1111-1111-1111-111111111111', old);
    expect(
      parseMarkdown(
        (await a.readRequest(location, stop.requestId))!,
      ).meta['operation'],
      'knowledge-retire',
    );
  });
  for (final mode in ['project', 'global', 'retire']) {
    test('Dartの$mode要求を本体で受理し方針と停止履歴を再同期する', () async {
      final a = TempAccess();
      await a.init();
      addTearDown(() => a.directory.delete(recursive: true));
      final before = HubRepository(VaultSnapshot(scopedFiles())),
          service = ReviewService(a, location);
      final candidate = mode == 'retire'
          ? before.review.history.firstWhere(
              (i) => i.retirable && i.kind == 'decision',
            )
          : before.review.pending.single;
      final target = mode == 'global'
          ? AdoptionTarget.global()
          : AdoptionTarget.fromJson(
              Map<String, dynamic>.from(
                scopedFixture()['expected']['target'] as Map,
              ),
            );
      final result = mode == 'retire'
              ? await service.retire(op, candidate)
              : await service.submit(op, candidate, 'approve', target: target),
          out = '${a.directory.path}/after.json';
      final node = await Process.run('node', [
        'scripts/check_policy_protocol.mjs',
        a.request(location, result.requestId).path,
        'assets/scoped-policy.json',
        out,
      ]);
      expect(node.exitCode, 0, reason: '${node.stdout}\n${node.stderr}');
      final files = Map<String, String>.from(
            jsonDecode(await File(out).readAsString()) as Map,
          ),
          after = HubRepository(VaultSnapshot(files));
      expect(after.review.byId(candidate.id)!.retired, mode == 'retire');
      expect(after.intake.single.state, 'accepted');
      expect(
        after.intake.single.detail,
        contains(mode == 'retire' ? '適用停止' : '承認済み'),
      );
      final policy = PolicyReader(after.snapshot).read('example').text;
      expect(policy.contains(candidate.claim), mode != 'retire');
    });
  }
  test('数字だけと英数字のproject IDが混在しても本体と同じ方針を読む', () {
    final fixture =
            jsonDecode(
                  File('test/fixtures/numeric-policy.json').readAsStringSync(),
                )
                as Map,
        files = Map<String, String>.from(fixture['files'] as Map),
        bundle = PolicyReader(VaultSnapshot(files)).read('100');
    expect(bundle.text, fixture['expected']['text']);
    expect(bundle.text, contains('対象100の方針'));
    expect(bundle.text, isNot(contains('対象20の方針')));
  });
}
