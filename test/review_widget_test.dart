import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/ui/review_view.dart';
import 'package:context_hub_client/core/review_candidates.dart';
import 'package:context_hub_client/core/parser.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'review_test.dart' show reviewFiles;

void main() {
  testWidgets('判断履歴の別名と検索語は現在の候補変更と混ぜない', (t) async {
    final files = reviewFiles(), a = MemoryUIAccess();
    a.current = VaultSnapshot(files);
    final c = HubController(a, sampleLoader: () async => files);
    await c.useSample();
    addTearDown(c.dispose);
    final original = c.review!.pending.firstWhere((i) => i.kind == 'project');
    final item = ReviewCandidate({
      ...original.data,
      'status': 'approved',
      'aliases': ['承認時の別名'],
      'keywords': ['承認時の検索語'],
    });
    final doc = parseMarkdown(files[item.path]!);
    files[item.path] = encodePacket({
      ...doc.meta,
      'proposal': {
        ...(doc.meta['proposal'] as Map),
        'aliases': ['承認後の変更'],
        'keywords': ['変更後の検索語'],
      },
    }, doc.body);
    a.current = VaultSnapshot(files);
    await c.reload();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReviewContent(controller: c, item: item),
          ),
        ),
      ),
    );
    expect(find.textContaining('承認時の別名'), findsOneWidget);
    expect(find.textContaining('承認時の検索語'), findsOneWidget);
    expect(find.textContaining('承認後の変更'), findsNothing);
  });
  testWidgets('確認待ち→原文→保留・取消→採用依頼まで操作できる', (t) async {
    t.view.physicalSize = const Size(1280, 1000);
    t.view.devicePixelRatio = 1;
    final a = MemoryUIAccess();
    a.current = VaultSnapshot(reviewFiles());
    final c = HubController(a, sampleLoader: () async => reviewFiles());
    addTearDown(() {
      c.dispose();
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    await t.pumpWidget(ContextHubApp(controller: c));
    await t.pumpAndSettle();
    await c.useSample();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-review')));
    await t.pumpAndSettle();
    expect(find.text('確認待ち（4件）'), findsOneWidget);
    expect(find.text('要確認（2件）'), findsOneWidget);
    final item = c.review!.pending.firstWhere((i) => i.kind == 'decision');
    await t.tap(find.byKey(Key('review-${item.id}')));
    await t.pumpAndSettle();
    expect(find.text(item.claim), findsWidgets);
    expect(find.text('AI候補・未承認'), findsOneWidget);
    final source = find.byKey(const Key('review-source')).first;
    await t.ensureVisible(source);
    await t.tap(source);
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
    expect(c.composing, isTrue);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(a.writes, 0);
    expect(c.composing, isFalse);
    await t.tap(find.byKey(const Key('review-approve')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-review')));
    await t.pumpAndSettle();
    expect(a.writes, 1);
    expect(find.textContaining('Miniの判断待ち'), findsWidgets);
    expect(t.takeException(), isNull);
  });
  testWidgets('モバイル幅の一覧と履歴がoverflowしない', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    final a = MemoryUIAccess();
    a.current = VaultSnapshot(reviewFiles());
    final c = HubController(a, sampleLoader: () async => reviewFiles());
    addTearDown(() {
      c.dispose();
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    await t.pumpWidget(ContextHubApp(controller: c));
    await t.pumpAndSettle();
    await c.useSample();
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-review')));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('判断履歴（2件）'), 400);
    expect(t.takeException(), isNull);
  });
}
