import 'dart:convert';
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
import 'work_records_test.dart' show protocol, projectId;
import 'fixtures.dart';

const ideaInput = 'IN-01M2DSFVQMH65989604KSVE1PV';
const resA = 'RES-01M9AAAAAAAAAAAAAAAAAAAAAA';
const resB = 'RES-01M9BBBBBBBBBBBBBBBBBBBBBB';
const resC = 'RES-01M9CCCCCCCCCCCCCCCCCCCCCC';
const questionInput = 'IN-01M2DSFVSNCJSF7XKRPW29TM7M';

/// 本体が残す形の、項目への報告の記録。
String resolutionJson(
  String id,
  NowItemRef item,
  String action, {
  String? reason,
  String? note,
  String project = projectId,
  String? inputId,
  String at = '2026-11-10T00:00:00.000Z',
}) => jsonEncode({
  'schema_version': 1,
  'id': id,
  'project_id': project,
  'item_key': item.key,
  'section': item.section,
  'text': item.text,
  'input_id': inputId ?? item.inputId,
  'action': action,
  'source': 'cli',
  'created_at': at,
  'reason': ?reason,
  'note': ?note,
});

/// 項目一覧の1件を、本体が誤りとして外したときの形にする。
Map<String, String> withExcluded(
  Map<String, String> files,
  String key, {
  String reason = 'misread',
  String? note,
  String id = resA,
}) {
  final path = '90_system/now-items/$projectId.json',
      items = jsonDecode(files[path]!) as Map<String, dynamic>;
  for (final i in items['items'] as List) {
    if ((i as Map)['key'] != key) continue;
    i['resolution'] = {
      'id': id,
      'at': '2026-11-10T00:00:00.000Z',
      'source': 'cli',
      'action': 'exclude',
      'reason': reason,
      'note': ?note,
    };
  }
  return {...files, path: jsonEncode(items)};
}

void main() {
  test('誤りとして外した項目を、完了・解決とは別に読む', () {
    final files = fixtureFiles(),
        item = HubRepository(fixture(files)).projects[projectId]!.nowItems[1];
    final excluded = withExcluded(files, item.key, note: 'まだ決めていない')
      ..['90_system/item-resolutions/$resA.json'] = resolutionJson(
        resA,
        item,
        'exclude',
        reason: 'misread',
        note: 'まだ決めていない',
      );
    final repo = HubRepository(fixture(excluded)),
        project = repo.projects[projectId]!;
    expect(repo.warnings, isEmpty);
    expect(project.resolvedItems, isEmpty);
    final found = project.excludedItems.single;
    expect(found.key, item.key);
    expect(found.excluded, isTrue);
    expect(found.exclusionReason, 'misread');
    expect(found.exclusionNote, 'まだ決めていない');
    expect(repo.latestResolutionIdFor(item.key), resA);
    // 欄の行には結び付けない（外した項目を、もう一度操作させない）。
    expect(
      project.sections['open']!.map((e) => e.itemKey),
      isNot(contains(item.key)),
    );
    // 理由のない「外す」や、完了・解決に付いた理由は、壊れた記録として知らせる。
    for (final broken in [
      {'id': resA, 'at': '2026-11-10T00:00:00.000Z', 'action': 'exclude'},
      {
        'id': resA,
        'at': '2026-11-10T00:00:00.000Z',
        'action': 'exclude',
        'reason': 'unknown',
      },
      {'id': resA, 'at': '2026-11-10T00:00:00.000Z', 'reason': 'misread'},
      {
        'id': resA,
        'at': '2026-11-10T00:00:00.000Z',
        'action': 'exclude',
        'reason': 'misread',
        'note': '2行の\n一言',
      },
    ]) {
      final path = '90_system/now-items/$projectId.json',
          items = jsonDecode(files[path]!) as Map<String, dynamic>;
      ((items['items'] as List)[1] as Map)['resolution'] = broken;
      final bad = HubRepository(fixture({...files, path: jsonEncode(items)}));
      expect(bad.warnings, isNotEmpty, reason: '$broken');
      expect(bad.projects[projectId]!.nowItems, isEmpty);
    }
    for (final broken in [
      resolutionJson(resA, item, 'exclude'),
      resolutionJson(resA, item, 'resolve', reason: 'misread'),
      resolutionJson(resA, item, 'exclude', reason: 'misread', note: ' 空白 '),
    ]) {
      final bad = HubRepository(
        fixture({...files, '90_system/item-resolutions/$resA.json': broken}),
      );
      expect(bad.warnings, isNotEmpty, reason: broken);
    }
  });

  test('一言は本体と同じ決まり（1行・200文字以内・前後の空白なし）で確かめる', () {
    expect(validExclusionNote('検討しただけで、まだ決めていない'), isTrue);
    expect(validExclusionNote('あ' * 200), isTrue);
    expect(validExclusionNote('あ' * 201), isFalse);
    expect(validExclusionNote(''), isFalse);
    expect(validExclusionNote(' 前後の空白'), isFalse);
    expect(validExclusionNote('改行\nあり'), isFalse);
    expect(validExclusionNote('タブ\tあり'), isFalse);
    expect(validExclusionNote(null), isFalse);
  });

  test('「別のプロジェクトの話」として外すと、AIが推定した関連を本体と同じく外して読む', () {
    final files = fixtureFiles(),
        base = HubRepository(fixture(files)),
        idea = base.inputRecord(ideaInput)!;
    expect(base.projectRelation(idea, projectId), 'estimated');
    // 本体は、関連を外した入力の項目を、戻せるように項目一覧へ残す。ここでは記録だけを置く。
    final item = NowItemRef(
      key: 'a' * 64,
      section: 'next',
      label: '',
      text: '別の話',
      inputId: ideaInput,
    );
    final wrong = {
      ...files,
      '90_system/item-resolutions/$resA.json': resolutionJson(
        resA,
        item,
        'exclude',
        reason: 'wrong-project',
      ),
    };
    final detached = HubRepository(fixture(wrong));
    expect(detached.warnings, isEmpty);
    expect(
      detached.projectRelation(detached.inputRecord(ideaInput)!, projectId),
      isNull,
    );
    // 「読み違い」「もう古い」では関連を変えない。
    for (final reason in ['misread', 'outdated']) {
      final kept = HubRepository(
        fixture({
          ...files,
          '90_system/item-resolutions/$resA.json': resolutionJson(
            resA,
            item,
            'exclude',
            reason: reason,
          ),
        }),
      );
      expect(
        kept.projectRelation(kept.inputRecord(ideaInput)!, projectId),
        'estimated',
      );
    }
    // 未解決へ戻すと、関連も元に戻る。
    final reopened = HubRepository(
      fixture({
        ...wrong,
        '90_system/item-resolutions/$resB.json': resolutionJson(
          resB,
          item,
          'reopen',
        ),
      }),
    );
    expect(
      reopened.projectRelation(reopened.inputRecord(ideaInput)!, projectId),
      'estimated',
    );
    // 本人がプロジェクトを指定したメモは、外しても関連を変えない。
    final owned = base.projects[projectId]!.nowItems.first;
    expect(base.itemOwnedByProject(projectId, owned), isTrue);
    expect(base.itemOwnedByProject(projectId, item), isFalse);
    final stay = HubRepository(
      fixture({
        ...files,
        '90_system/item-resolutions/$resA.json': resolutionJson(
          resA,
          owned,
          'exclude',
          reason: 'wrong-project',
        ),
      }),
    );
    expect(
      stay.projectRelation(stay.inputRecord(owned.inputId)!, projectId),
      'owned',
    );
  });

  test('本体が読み直したメモは、読み直しの関連候補で読む。条件が変わった読み直しは使わない', () {
    var files = fixtureFiles();
    files['10_projects/side-app/project.md'] =
        files['10_projects/context-hub/project.md']!
            .replaceFirst('id: context-hub', 'id: side-app')
            .replaceFirst('title: AI Context Hub', 'title: 別のアプリ');
    final receipt =
        jsonDecode(files['90_system/receipts/$ideaInput.json']!) as Map;
    final raw = files.entries
        .firstWhere((e) => e.key.contains(ideaInput) && e.key.startsWith('00'))
        .value;
    final item = NowItemRef(
      key: 'a' * 64,
      section: 'next',
      label: '',
      text: '別の話',
      inputId: ideaInput,
    );
    Map<String, Object?> reread({
      List<String> ids = const [resA],
      String status = 'reread',
    }) => {
      'schema_version': 1,
      'input_id': ideaInput,
      'latest_input_id': ideaInput,
      'evidence_hash': digest('$ideaInput:${digest(raw)}'),
      'receipt_organized_at': receipt['organized_at'],
      'resolution_ids': ids,
      'status': status,
      'attempts': 1,
      'result': status == 'reread'
          ? {
              'category': 'idea',
              'summary': '読み直した要約',
              'project_candidates': [
                {'id': 'side-app', 'confidence': 0.9},
              ],
              'next_action_suggestions': [],
              'extracted': {'current': [], 'next': [], 'open': []},
            }
          : null,
      'error': status == 'reread' ? null : 'timeout',
      'reread_at': '2026-11-10T01:00:00.000Z',
      'model': 'mock',
      'views_complete': true,
    };
    final exclusion = {
      '90_system/item-resolutions/$resA.json': resolutionJson(
        resA,
        item,
        'exclude',
        reason: 'wrong-project',
      ),
    };
    String? relation(Map<String, String> extra, String project) {
      final repo = HubRepository(fixture({...files, ...extra}));
      expect(repo.warnings, isEmpty);
      return repo.projectRelation(repo.inputRecord(ideaInput)!, project);
    }

    final path = '90_system/item-rereads/$ideaInput.json';
    final applied = {...exclusion, path: jsonEncode(reread())};
    expect(relation(applied, 'side-app'), 'estimated');
    expect(relation(applied, projectId), isNull);
    // 読み直しに失敗した記録、別の「外す」記録の組に対する読み直しは使わない。
    expect(
      relation({
        ...exclusion,
        path: jsonEncode(reread(status: 'failed')),
      }, 'side-app'),
      isNull,
    );
    expect(
      relation({
        ...exclusion,
        path: jsonEncode(reread(ids: [resB])),
      }, 'side-app'),
      isNull,
    );
    // 外した記録を戻した後は、読み直しを重ねない。
    expect(
      relation({
        ...applied,
        '90_system/item-resolutions/$resB.json': resolutionJson(
          resB,
          item,
          'reopen',
        ),
      }, 'side-app'),
      isNull,
    );
    // 読み直した後でさらに外した項目があっても、次の読み直しまでは今の読み直しを使う。
    final another = NowItemRef(
      key: 'b' * 64,
      section: 'next',
      label: '',
      text: '読み直した後の別の話',
      inputId: ideaInput,
    );
    final later = {
      '90_system/item-resolutions/$resC.json': resolutionJson(
        resC,
        another,
        'exclude',
        reason: 'misread',
        at: '2026-11-11T00:00:00.000Z',
      ),
    };
    expect(relation({...applied, ...later}, 'side-app'), 'estimated');
    // もとになった記録の1つが今は有効でない読み直しは使わない。
    expect(
      relation({
        ...exclusion,
        path: jsonEncode(reread(ids: [resA, resC])),
      }, 'side-app'),
      isNull,
    );
    // 壊れた読み直しの記録、もとになった記録のない読み直しは使わず、知らせる。
    final broken = HubRepository(fixture({...files, ...exclusion, path: '{'}));
    expect(broken.warnings, isNotEmpty);
    final empty = HubRepository(
      fixture({...files, ...exclusion, path: jsonEncode(reread(ids: []))}),
    );
    expect(empty.warnings, isNotEmpty);
    expect(
      empty.projectRelation(empty.inputRecord(ideaInput)!, 'side-app'),
      isNull,
    );
  });

  test('本体が読み直したメモは、コンテキストにも読み直した要約を出す。アイデアの要約は変えない', () {
    final files = fixtureFiles();
    Map<String, String> rereadOf(String input, String category) {
      final receipt =
          jsonDecode(files['90_system/receipts/$input.json']!) as Map;
      final raw = files.entries
          .firstWhere((e) => e.key.contains(input) && e.key.startsWith('00'))
          .value;
      final id = input == ideaInput ? resA : resC;
      return {
        '90_system/item-resolutions/$id.json': resolutionJson(
          id,
          NowItemRef(
            key: (input == ideaInput ? 'a' : 'c') * 64,
            section: 'open',
            label: '',
            text: '読み違えた項目',
            inputId: input,
          ),
          'exclude',
          reason: 'misread',
        ),
        '90_system/item-rereads/$input.json': jsonEncode({
          'schema_version': 1,
          'input_id': input,
          'latest_input_id': input,
          'evidence_hash': digest('$input:${digest(raw)}'),
          'receipt_organized_at': receipt['organized_at'],
          'resolution_ids': [id],
          'status': 'reread',
          'attempts': 1,
          'result': {
            'category': category,
            'summary': '読み直した要約（$category）',
            'project_candidates': [
              {'id': projectId, 'confidence': 0.9},
            ],
            'next_action_suggestions': [],
            'extracted': {'current': [], 'next': [], 'open': []},
          },
          'error': null,
          'reread_at': '2026-11-10T01:00:00.000Z',
          'model': 'mock',
          'views_complete': true,
        }),
      };
    }

    const original = '同期とバックアップを分けるにはどうする？';
    final base = HubRepository(fixture(files));
    expect(base.context(projectId), contains('有効解釈: $original'));
    final repo = HubRepository(
      fixture({
        ...files,
        ...rereadOf(questionInput, 'question'),
        ...rereadOf(ideaInput, 'question'),
      }),
    );
    expect(repo.warnings, isEmpty);
    final context = repo.context(projectId);
    expect(context, contains('有効解釈: 読み直した要約（question）'));
    expect(context, isNot(contains('有効解釈: $original')));
    // アイデアとして保存した入力は、アイデアの本文と食い違わないよう要約を変えない。
    expect(context, contains('有効解釈: 数日ぶりの開発再開を助ける仕組み、面白そう。'));
    final bundle = repo.bundleContext([
      repo.inputRecord(questionInput)!.id,
      repo.inputRecord(ideaInput)!.id,
    ], maxChars: 20000).text;
    expect(bundle, contains('有効解釈（AI整理・未検証）: 読み直した要約（question）'));
    expect(bundle, contains('有効解釈（AI整理・未検証）: 数日ぶりの開発再開を助ける仕組み、面白そう。'));
    // 読み直しでアイデアへ変わった入力も、要約は元のままにする。
    final toIdea = HubRepository(
      fixture({...files, ...rereadOf(questionInput, 'idea')}),
    );
    expect(toIdea.context(projectId), contains('有効解釈: $original'));
  });

  test('Dartの「誤りとして外す」報告を本体が受理し、読み直しの後も一覧に残って未解決へ戻せる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles(),
          project = HubRepository(fixture(files)).projects[projectId]!,
          item = project.nowItems.first;
      final service = CaptureService(access, location);
      // 理由のない依頼、決まりに合わない一言、完了・解決に付けた理由は保存しない。
      for (final bad in [
        () => service.saveItemResolution(
          '61111111-2222-4333-8444-555555555555',
          projectId,
          item,
          'exclude',
        ),
        () => service.saveItemResolution(
          '61111111-2222-4333-8444-555555555555',
          projectId,
          item,
          'exclude',
          reason: 'unknown',
        ),
        () => service.saveItemResolution(
          '61111111-2222-4333-8444-555555555555',
          projectId,
          item,
          'exclude',
          reason: 'misread',
          note: '2行の\n一言',
        ),
        () => service.saveItemResolution(
          '61111111-2222-4333-8444-555555555555',
          projectId,
          item,
          'resolve',
          reason: 'misread',
        ),
      ]) {
        await expectLater(bad(), throwsFormatException);
      }
      final saved = await service.saveItemResolution(
        '61111111-2222-4333-8444-555555555555',
        projectId,
        item,
        'exclude',
        reason: 'misread',
        note: '検討しただけで、まだ決めていない',
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      final meta = parseMarkdown(raw).meta;
      expect(meta['operation'], 'item-resolution');
      expect(meta['action'], 'exclude');
      expect(meta['reason'], 'misread');
      expect(meta['note'], '検討しただけで、まだ決めていない');
      // 同期前は報告済みとして扱う。
      final pending = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(pending.warnings, isEmpty);
      expect(pending.itemRequestIdFor(item.key), saved.requestId);
      expect(
        pending.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('誤りとして外す（読み違い）報告: '),
      );
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'one'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final p = synced.projects[projectId]!;
      expect(
        p.sections['next']!.map((e) => e.itemKey),
        isNot(contains(item.key)),
      );
      expect(p.resolvedItems, isEmpty);
      final excluded = p.excludedItems.single;
      expect(excluded.key, item.key);
      expect(excluded.exclusionReason, 'misread');
      expect(excluded.exclusionNote, '検討しただけで、まだ決めていない');
      expect(synced.itemRequestIdFor(item.key), isNull);
      // 外した項目を、もう一度外す・完了にすることはできない。
      await expectLater(
        service.saveItemResolution(
          '71111111-2222-4333-8444-555555555555',
          projectId,
          excluded,
          'exclude',
          reason: 'outdated',
        ),
        throwsFormatException,
      );
      final reopened = await service.saveItemResolution(
        '71111111-2222-4333-8444-555555555555',
        projectId,
        excluded,
        'reopen',
      );
      final back = HubRepository(
        fixture(
          await protocol(
            access,
            reopened.requestId,
            '${access.directory.path}/one.json',
            'two',
          ),
        ),
      );
      expect(back.warnings, isEmpty);
      expect(back.projects[projectId]!.excludedItems, isEmpty);
      expect(
        back.projects[projectId]!.sections['next']!.single.itemKey,
        item.key,
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('プロジェクトの画面で理由と一言を選んで外し、外した項目を未解決へ戻せる', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
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
    await tester.tap(find.byKey(const Key('project-context-hub')).last);
    await tester.pumpAndSettle();
    final item = HubRepository(fixture(files)).projects[projectId]!.nowItems[1];
    final short = item.key.substring(0, 12);
    await tester.tap(find.byKey(Key('exclude-$short')));
    await tester.pumpAndSettle();
    // 理由を選ぶまでは依頼できない。本人がプロジェクトを指定したメモでは、関連付けを変えないと伝える。
    FilledButton submit() =>
        tester.widget<FilledButton>(find.byKey(const Key('exclude-submit')));
    expect(submit().onPressed, isNull);
    expect(find.textContaining('関連付けは変えず、この項目だけを外します'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exclude-reason-misread')));
    await tester.pumpAndSettle();
    expect(submit().onPressed, isNotNull);
    // 文字数は本体の検査と同じ数え方で示す。絵文字は2文字と数え、200文字を超えると依頼できない。
    expect(find.text('0 / 200'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('exclude-note')), '😀' * 100);
    await tester.pumpAndSettle();
    expect(find.text('200 / 200'), findsOneWidget);
    expect(submit().onPressed, isNotNull);
    await tester.enterText(find.byKey(const Key('exclude-note')), '😀' * 101);
    await tester.pumpAndSettle();
    expect(find.text('202 / 200'), findsOneWidget);
    expect(submit().onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('exclude-note')),
      '  まだ決めていない ',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('exclude-submit')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-resolution');
    expect(request['action'], 'exclude');
    expect(request['reason'], 'misread');
    expect(request['note'], 'まだ決めていない');
    expect(request['item_key'], item.key);
    // 反映待ちの間は、同じ項目へ重ねて依頼させない。
    access.current = VaultSnapshot({
      ...files,
      'Input/${request['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.byKey(Key('exclude-$short')), findsNothing);
    // 本体が反映すると、完了・解決とは別の欄に理由と一言を添えて出る。
    access.current = VaultSnapshot(
      withExcluded(files, item.key, note: 'まだ決めていない')
        ..['90_system/item-resolutions/$resA.json'] = resolutionJson(
          resA,
          item,
          'exclude',
          reason: 'misread',
          note: 'まだ決めていない',
        ),
    );
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('誤りとして外した項目（本人報告）'), findsOneWidget);
    expect(find.textContaining('理由: 読み違い（まだ決めていない）'), findsOneWidget);
    expect(find.text('解決済み・完了（本人報告）'), findsNothing);
    await tester.tap(find.byKey(Key('reopen-$short')));
    await tester.pumpAndSettle();
    // 読み違いで外した項目は、読み直しが元に戻ると伝える（プロジェクトとの関連は変えていないので触れない）。
    expect(find.textContaining('メモの読み直しも元に戻ります'), findsOneWidget);
    expect(find.textContaining('関連の変更'), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    final reopen = parseMarkdown(access.requests.values.last).meta;
    expect(reopen['action'], 'reopen');
    expect(reopen.containsKey('reason'), isFalse);
    // 「もう古い」で外した項目は、読み直しも関連の変更もないので、戻すことだけを伝える。
    access.requests.clear();
    access.current = VaultSnapshot(
      withExcluded(files, item.key, reason: 'outdated')
        ..['90_system/item-resolutions/$resA.json'] = resolutionJson(
          resA,
          item,
          'exclude',
          reason: 'outdated',
        ),
    );
    await c.reload();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('reopen-$short')));
    await tester.pumpAndSettle();
    expect(find.textContaining('この項目をNOWの元の欄へ戻すよう依頼します。'), findsOneWidget);
    expect(find.textContaining('元に戻ります'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
