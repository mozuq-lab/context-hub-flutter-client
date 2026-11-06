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
import 'package:context_hub_client/ui/views.dart';
import 'capture_test.dart' show TempAccess, location;
import 'controller_test.dart' show UIAccess;
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

const ideaInput = 'IN-01M2DSFVQMH65989604KSVE1PV';
const questionInput = 'IN-01M2DSFVSNCJSF7XKRPW29TM7M';
const op1 = '11111111-1111-4111-8111-111111111111';
const op2 = '22222222-2222-4222-8222-222222222222';

HubRecord input(HubRepository repo, String id) =>
    repo.records.values.firstWhere((r) => r.sourceId == id);

/// 本体の原文と同じ形のメモを追加する。
Map<String, String> withMemos(Map<String, String> files, int count) {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  for (var i = 0; i < count; i++) {
    final id = 'IN-01M3${alphabet[i ~/ 32]}${alphabet[i % 32]}${'A' * 20}';
    final at = DateTime.utc(2026, 8, 1).add(Duration(hours: i));
    files['00_inbox/2026-08-01_$id.md'] = encodePacket({
      'schema_version': 1,
      'id': id,
      'kind': 'memo',
      'source': 'cli',
      'source_event_id': 'bulk-$i',
      'occurred_at': at.toIso8601String(),
      'received_at': at.toIso8601String(),
      'origin': 'user-note',
    }, i == 0 ? '同期 同期 同期の古いメモ' : '古いメモ$i');
  }
  return files;
}

Future<Map<String, String>> protocol(
  TempAccess access,
  String requestId,
  String fixturePath,
  String name, {
  String? mode,
}) async {
  final out = File('${access.directory.path}/$name.json');
  final result = await Process.run('node', [
    'scripts/check_request_protocol.mjs',
    access.request(location, requestId).path,
    fixturePath,
    out.path,
    ?mode,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return Map<String, String>.from(jsonDecode(await out.readAsString()) as Map);
}

void main() {
  group('検索の絞り込み', () {
    test('プロジェクトで絞り込み、AI推定の関連を区別する', () {
      final repo = HubRepository(fixture());
      final results = repo.search(
        '',
        const SearchFilter(project: 'context-hub'),
      );
      expect(
        results.map((r) => HubRepository.searchKindOf(r)).toSet(),
        containsAll(['memo', 'work-summary', 'idea', 'now']),
      );
      expect(
        repo.projectRelation(input(repo, questionInput), 'context-hub'),
        'owned',
      );
      expect(
        repo.projectRelation(input(repo, ideaInput), 'context-hub'),
        'estimated',
      );
      final idea = results.firstWhere((r) => r.kind == 'idea');
      expect(repo.projectRelation(idea, 'context-hub'), 'estimated');
      expect(repo.search('', const SearchFilter(project: 'other')), isEmpty);
    });

    test('種類と期間で絞り込み、検索語がなければ新しい順にする', () {
      final repo = HubRepository(fixture());
      final memos = repo.search('', const SearchFilter(kinds: {'memo'}));
      expect(memos.map((r) => r.sourceId), [questionInput, ideaInput]);
      expect(
        repo.search('', const SearchFilter(kinds: {'now'})).single.kind,
        'project',
      );
      final since = repo.search(
        '',
        SearchFilter(
          kinds: const {'memo', 'work-summary'},
          since: DateTime.parse('2026-09-14T10:05:00+09:00'),
        ),
      );
      expect(since.map((r) => r.sourceId), [questionInput]);
      final until = repo.search(
        '',
        SearchFilter(
          kinds: const {'memo'},
          until: DateTime.parse('2026-09-14T09:30:00+09:00'),
        ),
      );
      expect(until.map((r) => r.sourceId), [ideaInput]);
      // 検索語も絞り込みもなければ何も返さない。
      expect(repo.search('  '), isEmpty);
    });

    test('一致の多い順と新しい順を切り替え、件数を打ち切らない', () {
      final repo = HubRepository(fixture(withMemos(fixtureFiles(), 70)));
      expect(repo.recent.length, 73);
      final relevance = repo.search('同期', const SearchFilter(kinds: {'memo'}));
      expect(relevance.first.body, contains('同期 同期 同期'));
      final newest = repo.search(
        '同期',
        const SearchFilter(kinds: {'memo'}, sort: 'newest'),
      );
      expect(newest.first.sourceId, questionInput);
      expect(repo.search('古いメモ').length, 70);
    });
  });

  group('メモの訂正', () {
    test('訂正REQを本体が受理し、古い対象への訂正は理由付きで断られる', () async {
      final access = TempAccess();
      await access.init();
      try {
        final fixturePath = '${access.directory.path}/fixture.json';
        await File(fixturePath).writeAsString(jsonEncode(fixtureFiles()));
        const text = '同期とバックアップは別の仕組みにする。\n同期は削除も伝えるため。';
        final saved = await CaptureService(
          access,
          location,
        ).saveCorrection(op1, questionInput, text);
        expect(saved.saved, isTrue);
        final raw = await access
            .request(location, saved.requestId)
            .readAsString();
        expect(raw, contains('"operation":"correct"'));
        expect(raw, contains('"target_id":"$questionInput"'));
        final first = await protocol(
          access,
          saved.requestId,
          fixturePath,
          'first',
        );
        var repo = HubRepository(VaultSnapshot(first));
        final record = input(repo, questionInput);
        final chain = repo.correctionChainOf(record.id)!;
        expect(chain, hasLength(2));
        expect(chain.last.body.trim(), text);
        expect(repo.correctionRequestIdFor(record.id), isNull);
        expect(
          repo.intake.firstWhere((i) => i.id == saved.requestId).title,
          startsWith('訂正: '),
        );

        // 同じ元のメモを対象にした2件目の訂正は、最新の訂正を対象にしていないため断られる。
        final secondPath = '${access.directory.path}/second.json';
        await File(secondPath).writeAsString(jsonEncode(first));
        final stale = await CaptureService(
          access,
          location,
        ).saveCorrection(op2, questionInput, '別の訂正');
        final second = await protocol(
          access,
          stale.requestId,
          secondPath,
          'second',
          mode: 'stale',
        );
        repo = HubRepository(VaultSnapshot(second));
        final status = repo.intake.firstWhere((i) => i.id == stale.requestId);
        expect(status.state, 'rejected');
        expect(status.detail, contains('訂正対象が古くなっています'));
        expect(status.detail, contains(chain.last.sourceId));
        expect(repo.correctionRequestIdFor(record.id), isNull);
      } finally {
        await access.directory.delete(recursive: true);
      }
    });

    test('Miniに届くまでの訂正は反映待ちとして重ねて送らない', () {
      final files = fixtureFiles();
      files['Input/REQ-${op1.replaceAll('-', '')}.md'] = encodePacket({
        'schema_version': 1,
        'request_id': 'REQ-${op1.replaceAll('-', '')}',
        'source': 'flutter-client/$op1',
        'occurred_at': '2026-10-01T00:00:00.000Z',
        'operation': 'correct',
        'target_id': questionInput,
      }, '訂正後の本文');
      final repo = HubRepository(fixture(files));
      final record = input(repo, questionInput);
      expect(
        repo.correctionRequestIdFor(record.id),
        'REQ-${op1.replaceAll('-', '')}',
      );
      expect(repo.correctionRequestIdFor(input(repo, ideaInput).id), isNull);
      expect(repo.correctionChainOf(repo.ideas.first.id), isNull);
    });

    test('controllerは最新の対象・同じ本文・反映待ちを保存前に止める', () async {
      final access = UIAccess();
      await access.init();
      final c = HubController(
        access,
        sampleLoader: () async => fixture().files,
      );
      try {
        await c.useSample();
        final record = input(c.repository!, questionInput);
        await expectLater(
          c.requestCorrection(op1, record.id, ideaInput, '訂正'),
          throwsA(isA<CorrectionTargetChanged>()),
        );
        await expectLater(
          c.requestCorrection(
            op1,
            record.id,
            questionInput,
            '${record.body}\n',
          ),
          throwsA(isA<StateError>()),
        );
        expect(access.writes, 0);
        final saved = await c.requestCorrection(
          op1,
          record.id,
          questionInput,
          '同期とバックアップを分ける。',
        );
        expect(saved.saved, isTrue);
        expect(access.writes, 1);
        access.current = VaultSnapshot({
          ...fixture().files,
          'Input/${saved.requestId}.md': await access
              .request(c.location!, saved.requestId)
              .readAsString(),
        });
        await c.reload();
        expect(
          c.repository!.correctionRequestIdFor(record.id),
          saved.requestId,
        );
        await expectLater(
          c.requestCorrection(op2, record.id, questionInput, 'もう一度'),
          throwsA(isA<StateError>()),
        );
        expect(access.writes, 1);
      } finally {
        c.dispose();
        await access.directory.delete(recursive: true);
      }
    });
  });

  testWidgets('検索を絞り込み、続きを読み込み、記録から訂正を保存できる', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = withMemos(fixtureFiles(), 60);
    final c = HubController(access, sampleLoader: () async => files);
    access.current = fixture(files);
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-search')));
    await tester.pumpAndSettle();
    expect(find.text('語を入力するか、条件で絞り込んでください。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-kind-memo')));
    await tester.pumpAndSettle();
    expect(find.text('62件'), findsOneWidget);
    final main = find
        .descendant(of: find.byType(HubView), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('show-more')),
      500,
      scrollable: main,
    );
    expect(find.text('さらに読み込む（残り12件）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('show-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('show-more')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('search-query')),
      -500,
      scrollable: main,
    );
    await tester.enterText(find.byKey(const Key('search-query')), '同期');
    await tester.pumpAndSettle();
    expect(find.text('2件'), findsOneWidget);
    expect(find.byKey(const Key('search-snippet')), findsNWidgets(2));
    // プロジェクトで絞り込むと、AI推定の関連に印を付ける。
    await tester.tap(find.byKey(const Key('search-kind-memo')));
    await tester.enterText(find.byKey(const Key('search-query')), '面白そう');
    await tester.tap(find.byKey(const Key('search-project')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI Context Hub').last);
    await tester.pumpAndSettle();
    expect(find.text('AI推定の関連（帰属未確定）'), findsWidgets);

    await tester.tap(find.byKey(const Key('search-clear')));
    await tester.enterText(find.byKey(const Key('search-query')), 'バックアップ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-result')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('write-correction')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('correction-text')))
          .controller!
          .text,
      contains('同期とバックアップ'),
    );
    await tester.enterText(
      find.byKey(const Key('correction-text')),
      '同期とバックアップは別の仕組みにする。',
    );
    await tester.tap(find.byKey(const Key('save-correction')));
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに訂正を保存しました'), findsOneWidget);
    expect(access.requests.values.single, contains('"operation":"correct"'));
    expect(
      access.requests.values.single,
      contains('"target_id":"$questionInput"'),
    );
  });

  test('本体が既存の訂正を重複として返した場合も、反映待ちを解く', () {
    final files = fixtureFiles();
    const existing = 'IN-01M2DSFVSNCJSF7XKRPW29TM7N';
    files['00_inbox/2026-09-15_$existing.md'] = encodePacket({
      'schema_version': 1,
      'id': existing,
      'kind': 'correction',
      'source': 'cli-correction',
      'source_event_id': 'earlier',
      'corrects_input_id': questionInput,
      'occurred_at': '2026-09-15T00:00:00Z',
      'received_at': '2026-09-15T00:00:00Z',
      'project': 'context-hub',
      'origin': 'user-note',
    }, '訂正後の本文');
    final requestId = 'REQ-${op1.replaceAll('-', '')}';
    final raw = encodePacket({
      'schema_version': 1,
      'request_id': requestId,
      'source': 'flutter-client/$op1',
      'occurred_at': '2026-10-01T00:00:00.000Z',
      'operation': 'correct',
      'target_id': questionInput,
    }, '訂正後の本文');
    files['Input/$requestId.md'] = raw;
    files['90_system/intake/$requestId.json'] = jsonEncode({
      'schema_version': 1,
      'request_id': requestId,
      'request_hash': digest(raw),
      'path': 'Input/$requestId.md',
      'operation': 'correct',
      'status': 'accepted',
      'received_at': '2026-10-01T00:00:01.000Z',
      'result': {'inputId': existing, 'deduped': true},
    });
    final repo = HubRepository(fixture(files));
    final record = input(repo, questionInput);
    expect(repo.correctionChainOf(record.id), hasLength(2));
    expect(repo.correctionRequestIdFor(record.id), isNull);
  });

  test('抜粋はNFKCで一致箇所を探し、長い語を優先して強調する', () {
    final snippet = searchSnippet(
      '${'前置き' * 30}ＡＩの同期について',
      HubRepository.searchTokens('ai 同期'),
    );
    expect(snippet, startsWith('…'));
    expect(snippet, contains('AIの同期'));
    final spans = highlightSpans('abc ab', ['a', 'ab'], Colors.yellow);
    expect(spans.first.text, 'ab');
    // 大文字・小文字で長さが変わる文字があっても範囲外にならない。
    expect(searchSnippet('İ' * 300 + 'x', ['x']), contains('x'));
  });

  test('NOWは最終根拠の日時で期間を判断し、取り消したアイデアは種類の絞り込みに含めない', () {
    final files = fixtureFiles();
    final ideaPath = files.keys.firstWhere((p) => p.startsWith('20_ideas/'));
    var repo = HubRepository(fixture(files));
    final evidence = repo.projects['context-hub']!.lastEvidenceAt!;
    expect(
      repo.search('', SearchFilter(kinds: const {'now'}, until: evidence)),
      hasLength(1),
    );
    files[ideaPath] = files[ideaPath]!.replaceFirst(
      'category: idea',
      'category: idea\nretracted: true',
    );
    repo = HubRepository(fixture(files));
    expect(repo.search('', const SearchFilter(kinds: {'idea'})), isEmpty);
  });
}
