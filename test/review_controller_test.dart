import 'package:context_hub_client/core/review_candidates.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'controller_test.dart' show UIAccess;
import 'review_test.dart' show reviewFiles;

class ReviewAccess extends UIAccess {
  Completer<VaultSnapshot>? next;
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) {
    final wait = next;
    next = null;
    return wait?.future ?? Future.value(current);
  }
}

void main() {
  late ReviewAccess access;
  late HubController c;
  setUp(() async {
    access = ReviewAccess();
    await access.init();
    access.current = VaultSnapshot(reviewFiles());
    c = HubController(access, sampleLoader: () async => reviewFiles());
    await c.useSample();
  });
  tearDown(() async {
    c.dispose();
    await access.directory.delete(recursive: true);
  });
  test('確認ダイアログ中の変更を再読込し依頼を保存しない', () async {
    final item = c.review!.pending.first,
        ticket = await c.prepareReview(item.id);
    access.current = VaultSnapshot({...reviewFiles(), item.path: '変更'});
    await expectLater(c.submitReview(ticket, 'approve'), throwsStateError);
    expect(access.writes, 0);
    expect(c.review!.byId(item.id)!.actionable, isFalse);
  });
  test('同じ候補の二重送信と別Vaultへの古い確認を止める', () async {
    final ticket = await c.prepareReview(
      c.review!.pending.first.id,
      target: AdoptionTarget.global(),
    );
    final first = c.submitReview(ticket, 'approve');
    await expectLater(c.submitReview(ticket, 'approve'), throwsStateError);
    await first;
    expect(access.writes, 1);
    await c.activate(const VaultLocation('other', '別'));
    await expectLater(c.submitReview(ticket, 'approve'), throwsStateError);
    expect(access.writes, 1);
  });
  test('確認取得の古い応答を別Vaultへ適用しない', () async {
    final delayed = Completer<VaultSnapshot>();
    access.next = delayed;
    final pending = c.prepareReview(
          c.review!.pending.first.id,
          target: AdoptionTarget.global(),
        ),
        check = expectLater(pending, throwsStateError);
    await c.activate(const VaultLocation('new', '新しい'));
    delayed.complete(VaultSnapshot(reviewFiles()));
    await check;
    expect(c.location!.handle, 'new');
    expect(access.writes, 0);
  });
}
