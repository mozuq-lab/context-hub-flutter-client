import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/ui/app.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

/// サンプルのプロジェクトを複製して、別のプロジェクトを足す。
/// [lastEvidence]はNOWの最終根拠、[status]はproject.mdの状態。
Map<String, String> withProject(
  Map<String, String> files,
  String id,
  String title, {
  String status = 'active',
  String? lastEvidence,
  String? next,
}) {
  final project = files['10_projects/context-hub/project.md']!
      .replaceFirst('id: context-hub', 'id: $id')
      .replaceFirst('title: AI Context Hub', 'title: $title')
      .replaceFirst('status: active', 'status: $status');
  var now = files[nowPath]!.replaceFirst(
    'project: context-hub',
    'project: $id',
  );
  if (lastEvidence != null) {
    now = now.replaceFirst(
      RegExp(r'last_evidence_at: .*'),
      'last_evidence_at: $lastEvidence',
    );
  }
  final items =
      jsonDecode(files['90_system/now-items/context-hub.json']!)
          as Map<String, dynamic>;
  items['project'] = id;
  for (final i in items['items'] as List) {
    final m = i as Map<String, dynamic>;
    m['key'] = digest('$id/${m['key']}');
    if (next != null && m['section'] == 'next') m['text'] = next;
  }
  if (next != null) now = now.replaceFirst('サンプルの検索を確認する。', next);
  return {
    ...files,
    '10_projects/$id/project.md': project,
    '10_projects/$id/NOW.md': now,
    '90_system/now-items/$id.json': jsonEncode(items),
  };
}

Map<String, String> multiProjectFiles() {
  var files = fixtureFiles();
  files = withProject(
    files,
    'side-app',
    '別のアプリ',
    lastEvidence: '2026-10-01T09:00:00+09:00',
    next: '設定画面を作る。',
  );
  files = withProject(
    files,
    'old-plan',
    '休止中の計画',
    status: 'paused',
    lastEvidence: '2026-10-20T09:00:00+09:00',
    next: '休止中の作業。',
  );
  return files;
}

void main() {
  test('進行中のプロジェクトだけを、最新の根拠が新しい順に並べる', () {
    final repo = HubRepository(fixture(multiProjectFiles()));
    expect(repo.warnings, isEmpty);
    expect(repo.actionableProjects.map((p) => p.id), [
      'side-app',
      'context-hub',
    ]);
    // 根拠のないプロジェクトは後ろに置く。
    final files = multiProjectFiles()
      ..remove('10_projects/side-app/NOW.md')
      ..remove('90_system/now-items/side-app.json');
    expect(HubRepository(fixture(files)).actionableProjects.map((p) => p.id), [
      'context-hub',
      'side-app',
    ]);
  });

  testWidgets('ホームから全プロジェクトの次の一手を開き、その場で完了を報告できる', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = multiProjectFiles();
    access.current = VaultSnapshot(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    // 休止中のプロジェクトは数えない。
    expect(find.text('次の一手 2件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-next')));
    await tester.pumpAndSettle();
    expect(find.text('次の一手 2件'), findsOneWidget);
    expect(find.text('未解決 4件'), findsOneWidget);
    expect(find.textContaining('設定画面を作る。'), findsOneWidget);
    expect(find.textContaining('サンプルの検索を確認する。'), findsOneWidget);
    expect(find.textContaining('休止中の作業。'), findsNothing);
    // 最新の根拠が新しいプロジェクトを先に出す。
    expect(
      tester.getTopLeft(find.byKey(const Key('next-project-side-app'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('next-project-context-hub'))).dy,
      ),
    );
    // 未解決の欄に切り替える。
    await tester.tap(find.text('未解決 4件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Discord実機接続は承認後に確認する。'), findsNWidgets(2));
    expect(find.textContaining('設定画面を作る。'), findsNothing);
    await tester.tap(find.text('次の一手 2件'));
    await tester.pumpAndSettle();
    // 別のプロジェクトの次の一手を、この画面から完了にする。
    final item = HubRepository(
      fixture(files),
    ).projects['side-app']!.nowItems.firstWhere((i) => i.section == 'next');
    await tester.tap(find.byKey(Key('resolve-${item.key.substring(0, 12)}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-resolution');
    expect(request['project_id'], 'side-app');
    expect(request['item_key'], item.key);
    access.current = VaultSnapshot({
      ...files,
      'Input/${request['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('報告済み（反映待ち）'), findsOneWidget);
    // プロジェクト名からプロジェクト画面へ移る。
    await tester.tap(find.byKey(const Key('next-project-side-app')));
    await tester.pumpAndSettle();
    expect(find.text('PROJECT / 進行中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('進行中のプロジェクトに次の一手がなければ、そう表示する', (tester) async {
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
    files['10_projects/context-hub/project.md'] =
        files['10_projects/context-hub/project.md']!.replaceFirst(
          'status: active',
          'status: done',
        );
    access.current = VaultSnapshot(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    expect(find.text('進行中のプロジェクトに次の一手はありません'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-next')));
    await tester.pumpAndSettle();
    expect(find.text('進行中のプロジェクトはありません。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
