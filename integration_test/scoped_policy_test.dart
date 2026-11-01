import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/ui/review_view.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('実OS bridge: 方針全文・採用先・適用停止と既存記録の保持', (t) async {
    final fixture =
            jsonDecode(await rootBundle.loadString('assets/scoped-policy.json'))
                as Map,
        files = Map<String, String>.from(fixture['files'] as Map),
        access = NativeVaultAccess(),
        c = HubController(access, sampleLoader: () async => files);
    await t.pumpWidget(ContextHubApp(controller: c));
    await t.pumpAndSettle();
    await c.useSample();
    await t.pumpAndSettle();
    expect(c.error, isNull);
    final before = await access.readSnapshot(c.location!);
    expect(before.files['POLICY.md'], files['POLICY.md']);
    expect(
      await c.context('example'),
      startsWith(fixture['expected']['text'] as String),
    );
    final candidate = c.review!.pending.single;
    await t.pumpWidget(
      MaterialApp(
        home: ReviewDetail(
          controller: c,
          id: candidate.id,
          identity: c.location!.identity,
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.byKey(const Key('review-approve')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.byKey(const Key('review-approve')));
    await t.pumpAndSettle();
    expect(find.textContaining('プロジェクト: example'), findsWidgets);
    await t.tap(find.byKey(const Key('confirm-review')));
    await t.pumpAndSettle();
    final after = await access.readSnapshot(c.location!);
    final request = after.files.entries
        .where((e) => !before.files.containsKey(e.key))
        .single;
    expect(parseMarkdown(request.value).meta, containsPair('scope', 'project'));
    expect(
      parseMarkdown(request.value).meta,
      containsPair('project_id', 'example'),
    );
    final old = c.review!.history.firstWhere(
      (i) => i.retirable && i.kind == 'decision',
    );
    await t.pumpWidget(
      MaterialApp(
        home: ReviewDetail(
          key: const Key('stop-detail'),
          controller: c,
          id: old.id,
          identity: c.location!.identity,
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.byKey(const Key('review-retire')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.byKey(const Key('review-retire')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-review')));
    await t.pumpAndSettle();
    final finalSnapshot = await access.readSnapshot(c.location!);
    final created = finalSnapshot.files.entries
        .where((e) => !before.files.containsKey(e.key))
        .toList();
    expect(created.length, 2);
    expect(
      created.any(
        (e) => parseMarkdown(e.value).meta['operation'] == 'knowledge-retire',
      ),
      isTrue,
    );
    for (final e in before.files.entries) {
      expect(finalSnapshot.files[e.key], e.value, reason: e.key);
    }
    expect(t.takeException(), isNull);
    c.dispose();
  });
}
