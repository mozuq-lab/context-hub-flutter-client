import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:context_hub_client/main.dart' show loadSample;
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/storage/review_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('実OS bridge: 候補と原文の確認・取消・採用依頼・既存ファイル不変', (t) async {
    final access = NativeVaultAccess(),
        c = HubController(NativeVaultAccess(), sampleLoader: loadSample);
    await t.pumpWidget(ContextHubApp(controller: c));
    await t.pumpAndSettle();
    await c.useSample();
    await t.pumpAndSettle();
    expect(c.error, isNull);
    final before = await access.readSnapshot(c.location!);
    expect(c.review!.pending.length, 4);
    if (t.view.physicalSize.width / t.view.devicePixelRatio < 820) {
      await t.tap(find.byTooltip('Open navigation menu'));
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('nav-review')));
    await t.pumpAndSettle();
    final item = c.review!.pending.firstWhere((i) => i.kind == 'decision');
    await t.scrollUntilVisible(find.byKey(Key('review-${item.id}')), 250);
    await t.tap(find.byKey(Key('review-${item.id}')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('review-source')).first);
    await t.tap(find.byKey(const Key('review-source')).first);
    await t.pumpAndSettle();
    expect(find.text('出典・日時'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('review-target')));
    await t.tap(
      find
          .descendant(
            of: find.byKey(const Key('review-target')),
            matching: find.byType(TextField),
          )
          .first,
    );
    await t.pumpAndSettle();
    await t.tap(find.text('全ての作業に共通（明示選択）').last);
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('review-approve')));
    await t.tap(find.byKey(const Key('review-approve')));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(
      (await access.readSnapshot(c.location!)).files.length,
      before.files.length,
    );
    await t.tap(find.byKey(const Key('review-approve')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-review')));
    await t.pumpAndSettle();
    expect(find.textContaining('Miniの判断待ち'), findsWidgets);
    final after = await access.readSnapshot(c.location!);
    for (final e in before.files.entries) {
      expect(after.files[e.key], e.value, reason: e.key);
    }
    final created = after.files.keys
        .where((p) => !before.files.containsKey(p))
        .single;
    expect(created, startsWith('Input/REQ-'));
    final doc = parseMarkdown(after.files[created]!);
    expect(doc.body, '');
    expect(doc.meta['operation'], 'knowledge-approve');
    expect(doc.meta['candidate_id'], item.id);
    final project = c.review!.pending.firstWhere((i) => i.kind == 'project');
    final operation = const Uuid().v4();
    final service = ReviewService(access, c.location!),
        saved = await service.submit(operation, project, 'reject');
    expect(saved.saved, isTrue);
    expect(
      (await service.submit(operation, project, 'reject')).requestId,
      saved.requestId,
    );
    final p = parseMarkdown(
      (await access.readRequest(c.location!, saved.requestId))!,
    );
    expect(p.meta['operation'], 'project-reject');
    expect(p.meta['confirmation_token'], project.confirmationToken);
    expect(p.body, '');
    expect(t.takeException(), isNull);
    c.dispose();
  });
}
