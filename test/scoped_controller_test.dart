import 'dart:convert';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/review_candidates.dart';
import 'policy_test.dart' show scopedFiles, scopedFixture;
import 'review_controller_test.dart' show ReviewAccess;

class CopyArrivalAccess extends ReviewAccess {
  bool arrival = false;
  int copyReads = 0;
  String kind = 'retirement';
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) async {
    final old = current;
    if (arrival && ++copyReads == 1) {
      final files = {...current.files},
          key = kind == 'retirement'
              ? '90_system/knowledge-retirements/KRET-${'1' * 26}.json'
              : '90_system/approvals/APR-${'1' * 26}.json';
      files[key] = jsonEncode({'schema_version': 1, 'status': '同期到着'});
      current = VaultSnapshot(files);
      return old;
    }
    return current;
  }
}

void main() {
  late ReviewAccess access;
  late HubController c;
  setUp(() async {
    access = ReviewAccess();
    await access.init();
    access.current = VaultSnapshot(scopedFiles());
    c = HubController(access, sampleLoader: () async => scopedFiles());
    await c.useSample();
  });
  tearDown(() async {
    c.dispose();
    await access.directory.delete(recursive: true);
  });
  test('提案された採用先を確認ticketへ凍結し対象変更後は書かない', () async {
    final target = AdoptionTarget.fromJson(
          Map<String, dynamic>.from(
            scopedFixture()['expected']['target'] as Map,
          ),
        ),
        item = c.review!.pending.single,
        ticket = await c.prepareReview(item.id, target: target);
    access.current = VaultSnapshot({
      ...scopedFiles(),
      '10_projects/example/project.md': '変更',
    });
    await expectLater(c.submitReview(ticket, 'approve'), throwsStateError);
    expect(access.writes, 0);
  });
  test('停止ticketは採用REQと分け同じ停止操作を重複保存しない', () async {
    final item = c.review!.history.firstWhere((i) => i.retirable),
        ticket = await c.prepareReview(item.id, retiring: true);
    final a = await c.submitReview(ticket, 'retire'),
        b = await c.submitReview(ticket, 'retire');
    expect(a.requestId, b.requestId);
    expect(access.writes, 1);
    expect(item.retired, isFalse);
  });
  for (final kind in ['retirement', 'approval']) {
    test('コピー走査後に到着した$kindを独立再走査で検出する', () async {
      final a = CopyArrivalAccess();
      await a.init();
      addTearDown(() => a.directory.delete(recursive: true));
      a.current = VaultSnapshot(scopedFiles());
      final controller = HubController(
        a,
        sampleLoader: () async => scopedFiles(),
      );
      addTearDown(controller.dispose);
      await controller.useSample();
      a.kind = kind;
      a.arrival = true;
      await expectLater(controller.context('example'), throwsStateError);
      expect(a.copyReads, 2);
      expect(a.writes, 0);
    });
  }
}
