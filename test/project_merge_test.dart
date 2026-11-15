import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

const script = 'scripts/check_project_merge_protocol.mjs';
const specUrl = '<https://example.com/spec>';

Future<Map<String, String>> run(
  List<String> args,
  File out, [
  List<String> rest = const [],
]) async {
  final result = await Process.run('node', [
    script,
    ...args,
    out.path,
    ...rest,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return Map<String, String>.from(jsonDecode(await out.readAsString()) as Map);
}

Map<String, String>? _before, _merged;

/// 2つ目のプロジェクトを足したVaultと、それを統合して本体が反映した後のVault。
Future<({Map<String, String> before, Map<String, String> merged})>
mergeStates() async {
  if (_before == null || _merged == null) {
    final access = TempAccess();
    await access.init();
    try {
      File out(String name) => File('${access.directory.path}/$name.json');
      final before = await run(['prepare', 'assets/sample.json'], out('a'));
      final repo = HubRepository(fixture(before));
      final saved = await CaptureService(access, location).saveProjectMerge(
        'a1111111-2222-4333-8444-555555555555',
        repo.projects['hub-tool']!,
        repo.projects['context-hub']!,
      );
      _merged = await run([
        'ingest',
        access.request(location, saved.requestId).path,
        out('a').path,
      ], out('b'));
      _before = before;
    } finally {
      await access.directory.delete(recursive: true);
    }
  }
  return (before: Map.of(_before!), merged: Map.of(_merged!));
}

void main() {
  test(
    '統合済みのプロジェクトは、検索の関連表示・文脈のコピー・かごでも統合先として読む',
    () async {
      final repo = HubRepository(fixture((await mergeStates()).merged));
      // 検索: 統合元で絞っても、AI推定の関連を本人指定の帰属と区別する。
      final hits = repo.search('', const SearchFilter(project: 'hub-tool'));
      final relations = [
        for (final r in hits) repo.projectRelation(r, 'hub-tool'),
      ];
      expect(relations, [
        for (final r in hits) repo.projectRelation(r, 'context-hub'),
      ]);
      expect(relations, contains('estimated'));
      expect(relations, contains('owned'));
      // 文脈のコピー: 統合先の現在地・方針・関連メモを渡す。
      String body(String text) => text.split('\n').skip(1).join('\n');
      final copied = repo.context('hub-tool');
      expect(copied, contains('# AI Context Hub'));
      expect(body(copied), body(repo.context('context-hub')));
      // かご: 統合元のNOWを入れていても、統合先のNOWとして束ねる。
      final bundled = repo.bundleContext([
        repo.projects['hub-tool']!.nowRecordId!,
      ]).text;
      expect(bundled, contains('プロジェクト: AI Context Hub（context-hub）'));
      expect(bundled, isNot(contains('プロジェクト: まとめツール')));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '統合の反映は統合先の定義も同期されるまで待ち、統合先への依頼を止めておく',
    () async {
      final states = await mergeStates();
      const target = '10_projects/context-hub/project.md';
      // 統合元の定義と記録だけが先に同期され、統合先の定義がまだ古い。
      final partial = HubRepository(
        fixture({...states.merged, target: states.before[target]!}),
      );
      final request = partial.projectMergeRequestIdFor('context-hub');
      expect(request, isNotNull);
      expect(partial.projectMergeRequestIdFor('hub-tool'), request);
      expect(
        partial.intake.firstWhere((i) => i.id == request).detail,
        contains('同期を待っています'),
      );
      final synced = HubRepository(fixture(states.merged));
      expect(synced.projectMergeRequestIdFor('context-hub'), isNull);
      expect(synced.projectMergeRequestIdFor('hub-tool'), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'Dartの統合REQを本体が受理し、資料・帰属・検索を統合先として読み、取り消すと元へ戻る',
    () async {
      final access = TempAccess();
      await access.init();
      try {
        File out(String name) => File('${access.directory.path}/$name.json');
        final files = await run(['prepare', 'assets/sample.json'], out('a'));
        final repo = HubRepository(fixture(files));
        expect(repo.warnings, isEmpty);
        final from = repo.projects['hub-tool']!,
            into = repo.projects['context-hub']!;
        expect(from.merged, isFalse);
        // 統合前: 資料は統合元の資料棚に並び、検索の種類「資料」で見つかる。
        expect(from.shelf!.body, contains(specUrl));
        expect(from.shelf!.warnings, hasLength(1), reason: '整合性の注意は出さない');
        expect(into.shelf, isNull);
        final memo = repo
            .search(
              '',
              const SearchFilter(project: 'hub-tool', kinds: {'reference'}),
            )
            .single;
        expect(memo.kind, 'memo');
        expect(repo.isReference(memo), isTrue);
        expect(
          repo.search(
            '',
            const SearchFilter(project: 'context-hub', kinds: {'reference'}),
          ),
          isEmpty,
        );

        final service = CaptureService(access, location);
        const op = '41111111-2222-4333-8444-555555555555';
        // 同じプロジェクト同士、統合されていないものの取り消しは保存しない。
        await expectLater(
          service.saveProjectMerge(op, from, from),
          throwsFormatException,
        );
        await expectLater(
          service.saveProjectMerge(op, from, into, unmerge: true),
          throwsFormatException,
        );
        final saved = await service.saveProjectMerge(op, from, into);
        final raw = (await access.readRequest(location, saved.requestId))!;
        expect(parseMarkdown(raw).meta, {
          ...parseMarkdown(raw).meta,
          'operation': 'project-merge',
          'project_id': 'hub-tool',
          'project_hash': from.definitionHash,
          'into_id': 'context-hub',
          'into_hash': into.definitionHash,
          'confirmed': true,
        });
        // 同期前は、統合元と統合先のどちらも依頼済みとして扱う。
        final pending = HubRepository(
          fixture({...files, 'Input/${saved.requestId}.md': raw}),
        );
        expect(pending.projectMergeRequestIdFor('hub-tool'), saved.requestId);
        expect(
          pending.projectMergeRequestIdFor('context-hub'),
          saved.requestId,
        );
        expect(
          pending.intake.firstWhere((i) => i.id == saved.requestId).title,
          '統合の依頼: まとめツール → AI Context Hub',
        );

        final mergedFiles = await run([
          'ingest',
          access.request(location, saved.requestId).path,
          out('a').path,
        ], out('b'));
        final merged = HubRepository(fixture(mergedFiles));
        expect(merged.warnings, isEmpty);
        final source = merged.projects['hub-tool']!,
            target = merged.projects['context-hub']!;
        expect(source.merged, isTrue);
        expect(source.mergedInto, 'context-hub');
        expect(source.mergeTarget, 'context-hub');
        expect(source.lifecycle, 'done');
        expect(merged.resolveProject('hub-tool'), 'context-hub');
        expect(merged.mergedSources('context-hub').map((p) => p.id), [
          'hub-tool',
        ]);
        expect(target.aliases, containsAll(['まとめツール', 'まとめ']));
        expect(target.keywords, contains('まとめる'));
        expect(merged.projectMergeRequestIdFor('hub-tool'), isNull);
        expect(merged.projectMergeRequestIdFor('context-hub'), isNull);
        final item = merged.intake.firstWhere((i) => i.id == saved.requestId);
        expect(item.state, 'accepted');
        // 資料は統合先の資料棚に並び、統合元の資料棚は統合先を案内する。
        expect(target.shelf!.body, contains(specUrl));
        expect(source.shelf!.body, contains('統合済みです'));
        expect(source.shelf!.body, isNot(contains(specUrl)));
        // 統合元で絞っても統合先で絞っても、同じ記録が見つかる。
        for (final id in ['hub-tool', 'context-hub']) {
          expect(
            merged
                .search(
                  '',
                  SearchFilter(project: id, kinds: const {'reference'}),
                )
                .map((r) => r.sourceId),
            [memo.sourceId],
          );
        }
        // 統合元の未解決は統合先のNOWに並ぶ。
        expect(
          target.nowItems.map((i) => i.text),
          contains(contains('配布方法が決まっていない')),
        );

        // 取り消すと、統合元は統合前の定義（同じhash）へ戻る。古い統合の依頼を未反映とは扱わない。
        final undo = await service.saveProjectMerge(
          '51111111-2222-4333-8444-555555555555',
          source,
          target,
          unmerge: true,
        );
        final undoneFiles = await run([
          'ingest',
          access.request(location, undo.requestId).path,
          out('b').path,
        ], out('c'));
        final undone = HubRepository(fixture(undoneFiles));
        expect(undone.warnings, isEmpty);
        final back = undone.projects['hub-tool']!;
        expect(back.merged, isFalse);
        expect(back.definitionHash, from.definitionHash);
        expect(
          undone.projects['context-hub']!.definitionHash,
          into.definitionHash,
        );
        expect(back.shelf!.body, contains(specUrl));
        expect(undone.projectMergeRequestIdFor('hub-tool'), isNull);
        expect(
          undone.intake.firstWhere((i) => i.id == undo.requestId).title,
          '統合の取り消しの依頼: まとめツール ← AI Context Hub',
        );
        expect(
          undone.search(
            '',
            const SearchFilter(project: 'context-hub', kinds: {'reference'}),
          ),
          isEmpty,
        );
        // もう一度統合できる（定義は最初と同じhashでも、新しい依頼として扱う）。
        final again = await service.saveProjectMerge(
          '61111111-2222-4333-8444-555555555555',
          back,
          undone.projects['context-hub']!,
        );
        final remerged = HubRepository(
          fixture(
            await run([
              'ingest',
              access.request(location, again.requestId).path,
              out('c').path,
            ], out('d')),
          ),
        );
        expect(remerged.warnings, isEmpty);
        expect(remerged.projects['hub-tool']!.mergeTarget, 'context-hub');
        expect(remerged.projectMergeRequestIdFor('hub-tool'), isNull);
      } finally {
        await access.directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '本体が受け付けなかった統合と、統合済みのプロジェクトへの依頼は、理由を示して依頼済みから外す',
    () async {
      final access = TempAccess();
      await access.init();
      try {
        File out(String name) => File('${access.directory.path}/$name.json');
        final files = await run(['prepare', 'assets/sample.json'], out('a'));
        final repo = HubRepository(fixture(files));
        final from = repo.projects['hub-tool']!,
            into = repo.projects['context-hub']!;
        final service = CaptureService(access, location);
        // 確認した後に統合先の定義が変わっていた。
        final stale = await service.saveProjectMerge(
          '71111111-2222-4333-8444-555555555555',
          from,
          into,
        );
        final changed = HubRepository(
          fixture(
            await run(
              [
                'reject',
                access.request(location, stale.requestId).path,
                out('a').path,
              ],
              out('b'),
              ['context-hub'],
            ),
          ),
        );
        final refused = changed.intake.firstWhere(
          (i) => i.id == stale.requestId,
        );
        expect(refused.state, 'rejected');
        expect(refused.detail, contains('確認した後にプロジェクト定義が変わっていました'));
        expect(changed.projects['hub-tool']!.merged, isFalse);
        expect(changed.projectMergeRequestIdFor('hub-tool'), isNull);
        expect(changed.projectMergeRequestIdFor('context-hub'), isNull);

        // 統合した後に、統合元の状態を変える依頼が届いた（古い端末からの依頼など）。
        final merge = await service.saveProjectMerge(
          '81111111-2222-4333-8444-555555555555',
          from,
          into,
        );
        final mergedFiles = await run([
          'ingest',
          access.request(location, merge.requestId).path,
          out('a').path,
        ], out('c'));
        final source = HubRepository(
          fixture(mergedFiles),
        ).projects['hub-tool']!;
        final late = await service.saveProjectStatus(
          '91111111-2222-4333-8444-555555555555',
          source,
          'active',
        );
        final after = HubRepository(
          fixture(
            await run([
              'reject',
              access.request(location, late.requestId).path,
              out('c').path,
            ], out('d')),
          ),
        );
        final stopped = after.intake.firstWhere((i) => i.id == late.requestId);
        expect(stopped.state, 'rejected');
        expect(
          stopped.detail,
          'このプロジェクトは（context-hub）に統合済みのため、受け付けられませんでした。再読込して、統合先で操作してください。',
        );
        expect(after.projects['hub-tool']!.merged, isTrue);
        expect(after.projectStatusRequestIdFor('hub-tool'), isNull);
      } finally {
        await access.directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('手で書いたmerged_intoは統合先をたどり、見つからない・循環する統合先は統合として扱わず注意を出す', () {
    final files = fixtureFiles();
    String definition(String id, String title, [String? into]) => encodePacket({
      'schema_version': 1,
      'id': id,
      'title': title,
      'aliases': <String>[],
      'keywords': <String>[],
      'status': 'done',
      'merged_into': ?into,
    }, '# $title\n');
    files['10_projects/a1/project.md'] = definition('a1', 'A', 'b1');
    files['10_projects/b1/project.md'] = definition('b1', 'B', 'context-hub');
    files['10_projects/x1/project.md'] = definition('x1', 'X', 'y1');
    files['10_projects/y1/project.md'] = definition('y1', 'Y', 'x1');
    files['10_projects/z1/project.md'] = definition('z1', 'Z', 'gone');
    final repo = HubRepository(fixture(files));
    expect(repo.projects['a1']!.mergeTarget, 'context-hub');
    expect(repo.projects['b1']!.mergeTarget, 'context-hub');
    expect(repo.mergedSources('context-hub').map((p) => p.id), ['a1', 'b1']);
    for (final id in ['x1', 'y1', 'z1']) {
      expect(repo.projects[id]!.merged, isFalse, reason: id);
      expect(repo.resolveProject(id), id);
      expect(
        repo.projects[id]!.warnings,
        contains(contains('統合として扱っていません')),
        reason: id,
      );
    }
    expect(repo.projects['a1']!.warnings.join(), isNot(contains('統合として')));
    // 形式が合わない統合先と、値のない統合先は定義として読まない（本体と同じ）。
    files['10_projects/z1/project.md'] = definition('z1', 'Z', 'Not An Id');
    expect(HubRepository(fixture(files)).projects.containsKey('z1'), isFalse);
    files['10_projects/z1/project.md'] = encodePacket({
      'schema_version': 1,
      'id': 'z1',
      'title': 'Z',
      'aliases': <String>[],
      'keywords': <String>[],
      'status': 'done',
      'merged_into': null,
    }, '# Z\n');
    expect(HubRepository(fixture(files)).projects.containsKey('z1'), isFalse);
  });

  test('状態が進行中のまま手で統合先を書いたプロジェクトも、進行中の一覧・停滞・次の一手に数えない', () {
    final files = fixtureFiles();
    const path = '10_projects/context-hub/project.md';
    files['10_projects/keep/project.md'] = encodePacket({
      'schema_version': 1,
      'id': 'keep',
      'title': '残すほう',
      'aliases': <String>[],
      'keywords': <String>[],
      'status': 'active',
    }, '# 残すほう\n');
    final doc = parseMarkdown(files[path]!);
    files[path] = encodePacket({...doc.meta, 'merged_into': 'keep'}, doc.body);
    final repo = HubRepository(fixture(files));
    final merged = repo.projects['context-hub']!;
    expect(merged.status, 'active');
    expect(merged.merged, isTrue);
    expect(merged.active, isFalse);
    expect(merged.stale(DateTime.utc(2026, 11, 2)), isFalse);
    expect(repo.actionableProjects.map((p) => p.id), ['keep']);
    expect(repo.orderedProjects.map((p) => p.id), ['keep', 'context-hub']);
  });

  testWidgets('資料を開き、統合を依頼し、反映後は統合済みとして表示して取り消しを依頼できる', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('context-hub-merge-widget-'),
    ))!;
    File out(String name) => File('${dir.path}/$name.json');
    final files = (await tester.runAsync(
      () => run(['prepare', 'assets/sample.json'], out('a')),
    ))!;
    final access = MemoryUIAccess();
    await access.init();
    access.current = VaultSnapshot(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('merged-projects')), findsNothing);
    await tester.tap(find.byKey(const Key('project-hub-tool')).first);
    await tester.pumpAndSettle();
    // 資料は本体が作ったREFERENCES.mdをそのまま示す。
    await tester.tap(find.byKey(const Key('project-shelf')));
    await tester.pumpAndSettle();
    expect(find.text('まとめツールの資料'), findsWidgets);
    expect(find.byKey(const Key('shelf-body')), findsOneWidget);
    expect(find.textContaining('https://example.com/spec'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 統合先を選び、同じものだと確認するまで依頼できない。
    await tester.tap(find.byKey(const Key('project-merge')));
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key('project-merge-submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.byKey(const Key('project-merge-into')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('AI Context Hub（').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-merge-effects')), findsOneWidget);
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.byKey(const Key('project-merge-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('統合を依頼しました。Miniで受け付けられると反映されます。'), findsOneWidget);
    final raw = access.requests.values.single;
    final meta = parseMarkdown(raw).meta;
    expect(meta['operation'], 'project-merge');
    expect(meta['project_id'], 'hub-tool');
    expect(meta['into_id'], 'context-hub');

    // 同期前は依頼済みと表示し、重ねて依頼できない。
    access.current = VaultSnapshot({
      ...files,
      'Input/${meta['request_id']}.md': raw,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-merge-requested')), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('project-merge')))
          .onPressed,
      isNull,
    );

    // 本体が反映すると、統合済みとして統合先を案内する。
    final merged = (await tester.runAsync(() async {
      final request = File('${dir.path}/${meta['request_id']}.md');
      await request.writeAsString(raw);
      return run(['ingest', request.path, out('a').path], out('b'));
    }))!;
    access.current = VaultSnapshot(merged);
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-merged')), findsOneWidget);
    expect(find.byKey(const Key('project-merge-requested')), findsNothing);
    expect(find.byKey(const Key('project-merge')), findsNothing);
    expect(find.textContaining('統合済み（統合先: AI Context Hub）'), findsWidgets);
    // 統合元の画面からは、統合先にまとまった資料を開く。
    expect(find.text('資料（統合先）'), findsOneWidget);
    // 先の通知が消えてから次の操作をする。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-unmerge')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取り消しを依頼'));
    await tester.pumpAndSettle();
    expect(find.text('統合の取り消しを依頼しました。Miniで受け付けられると反映されます。'), findsOneWidget);
    expect(
      parseMarkdown(access.requests.values.last).meta['operation'],
      'project-unmerge',
    );
    // 統合先には統合元を示し、ほかのプロジェクトへは統合できない。
    await tester.tap(find.byKey(const Key('project-merge-target')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-merge-sources')), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('project-merge')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('project-shelf')));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://example.com/spec'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // ホームでは統合済みを後ろにまとめる。
    await tester.tap(find.byKey(const Key('nav-home')));
    await tester.pumpAndSettle();
    expect(find.text('統合済み（1件）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
