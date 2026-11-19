import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'capture_test.dart' show TempAccess, location;
import 'insights_test.dart' show insightsFiles, expected;
import 'unassigned_proposals_test.dart' show sample;
import 'widget_test.dart' show MemoryUIAccess;

const reactOp = '91111111-2222-4333-8444-555555555555';
const clearOp = '92111111-2222-4333-8444-555555555555';
const answerOp = '93111111-2222-4333-8444-555555555555';
const missingOp = '94111111-2222-4333-8444-555555555555';

Future<Map<String, String>> runNode(List<String> args, Directory dir) async {
  final out = File(
    '${dir.path}/out-${args.first}-${DateTime.now().microsecondsSinceEpoch}.json',
  );
  final result = await Process.run('node', [
    'scripts/check_insight_protocol.mjs',
    ...args,
    out.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return Map<String, String>.from(jsonDecode(await out.readAsString()) as Map);
}

/// アプリが読むファイルだけにする（週次の統合の実行の記録は読み込まない）。
Map<String, String> synced(Map<String, String> files) => {
  for (final e in files.entries)
    if (!snapshotSkippedPaths.any((p) => e.key == p || e.key.startsWith('$p/')))
      e.key: e.value,
};

void main() {
  group('今週の気づきへの反応と答え（本体との突き合わせ）', () {
    late TempAccess access;
    setUp(() async {
      access = TempAccess();
      await access.init();
    });
    tearDown(() => access.directory.delete(recursive: true));

    /// 保存した依頼を本体に受け付けさせた後のVaultと、保存直後（受付前）のVaultを返す。
    Future<(Map<String, String>, Map<String, String>)> send(
      Map<String, String> files,
      CaptureResult saved,
    ) async {
      final req = access.request(location, saved.requestId);
      final waiting = {
        ...files,
        'Input/${saved.requestId}.md': await req.readAsString(),
      };
      final fixture = File(
        '${access.directory.path}/fixture-${DateTime.now().microsecondsSinceEpoch}.json',
      );
      await fixture.writeAsString(jsonEncode(files));
      final after = await runNode([
        'ingest',
        req.path,
        fixture.path,
      ], access.directory);
      return (waiting, after);
    }

    test('反応の依頼は受付前から反映待ちとして示し、本体が記録すると一覧の反応として読む。もう一度押すと外す', () async {
      final prepared = await runNode(['prepare'], access.directory);
      var repo = HubRepository(VaultSnapshot(synced(prepared)));
      expect(repo.warnings, isEmpty);
      final insights = repo.insights!, runId = insights.runId!;
      expect(runId, matches(RegExp(r'^SYN-')));
      final item = insights.items.singleWhere(
        (i) => i.section == 'connections',
      );
      expect(item.reaction, isNull);
      expect(repo.insightReactionOf(item), (reaction: null, pending: false));

      final service = CaptureService(access, location);
      final (waiting, reacted) = await send(
        prepared,
        await service.saveInsightReaction(reactOp, runId, item.key, 'useful'),
      );
      final request = parseMarkdown(waiting.entries.last.value).meta;
      expect(request['operation'], 'insight-reaction');
      expect(request['confirmed'], true);
      var pending = HubRepository(VaultSnapshot(synced(waiting)));
      expect(pending.warnings, isEmpty);
      expect(pending.insightReactionOf(pending.insights!.items.first), (
        reaction: 'useful',
        pending: true,
      ));
      expect(
        pending.intake.first.title,
        startsWith('今週の気づきへの反応（役に立った）: 11/03の関心'),
      );

      repo = HubRepository(VaultSnapshot(synced(reacted)));
      expect(repo.warnings, isEmpty);
      final shown = repo.insights!.items.singleWhere((i) => i.key == item.key);
      expect(shown.reaction, 'useful');
      expect(repo.insightReactionOf(shown), (
        reaction: 'useful',
        pending: false,
      ));
      expect(repo.intake.single.state, 'accepted');
      expect(repo.intake.single.detail, 'Miniが反応を記録しました。');

      // 受け付けた後、一覧がまだ届いていない間は、反映待ちのまま示す。
      final stale = {
        ...synced(reacted),
        HubRepository.insightsPath: prepared[HubRepository.insightsPath]!,
      };
      pending = HubRepository(VaultSnapshot(stale));
      expect(pending.insightReactionOf(pending.insights!.items.first), (
        reaction: 'useful',
        pending: true,
      ));
      expect(pending.intake.single.detail, contains('同期を待っています'));

      // もう一度押すと（none）、反応を外す。
      final (_, cleared) = await send(
        reacted,
        await service.saveInsightReaction(clearOp, runId, item.key, 'none'),
      );
      repo = HubRepository(VaultSnapshot(synced(cleared)));
      expect(repo.warnings, isEmpty);
      final after = repo.insights!.items.singleWhere((i) => i.key == item.key);
      expect(after.reaction, isNull);
      expect(repo.insightReactionOf(after), (reaction: null, pending: false));
      expect(
        repo.intake.map((i) => i.title),
        contains(startsWith('今週の気づきへの反応（反応を外す）')),
      );
    });

    test('問いへの答えはmeta付きのメモとして保存し、本体が項目に結び付けた答えを開ける', () async {
      final prepared = await runNode(['prepare'], access.directory);
      final repo0 = HubRepository(VaultSnapshot(synced(prepared)));
      final insights = repo0.insights!,
          question = insights.items.singleWhere(
            (i) => i.section == 'questions',
          );
      final target = InsightAnswerTarget(
        runId: insights.runId!,
        itemKey: question.key,
        question: question.text,
      );
      final (_, answered) = await send(
        prepared,
        await CaptureService(access, location).save(
          CaptureDraft(
            operationId: answerOp,
            text: '字幕の付け方を試したい',
            meta: target.meta,
          ),
        ),
      );
      final repo = HubRepository(VaultSnapshot(synced(answered)));
      expect(repo.warnings, isEmpty);
      final item = repo.insights!.items.singleWhere(
        (i) => i.key == question.key,
      );
      final answer = item.answers.single;
      final memo = repo.inputRecord(answer.inputId)!;
      expect(memo.kind, 'memo');
      expect(memo.body, contains('字幕の付け方を試したい'));
      expect(memo.metadata['meta'], {
        'capture_mode': 'insight-answer',
        'insight_run': insights.runId,
        'insight_key': question.key,
        'insight_question': question.text,
      });
    });

    test('知らない項目への反応は、本体が断った理由を受付状況に示す', () async {
      final prepared = await runNode(['prepare'], access.directory);
      final runId = HubRepository(
        VaultSnapshot(synced(prepared)),
      ).insights!.runId!;
      final (_, after) = await send(
        prepared,
        await CaptureService(
          access,
          location,
        ).saveInsightReaction(missingOp, runId, 'b' * 64, 'useful'),
      );
      final repo = HubRepository(VaultSnapshot(synced(after)));
      final status = repo.intake.single;
      expect(status.state, 'rejected');
      expect(status.detail, contains('今週の気づきが見つかりません'));
      // 今の週の気づきのうち、この端末に出ていない項目への反応と分かるようにする。
      expect(status.title, contains('この端末に出ていない項目'));
    });
  });

  group('今週の気づきへの反応と答え（読取と画面）', () {
    test('本体の一覧から反応と答えのメモを読む。届いていない答えと知らない反応は出さない', () {
      final repo = HubRepository(VaultSnapshot(insightsFiles()));
      expect(repo.warnings, isEmpty);
      final reaction = expected['reaction'] as Map<String, dynamic>,
          answer = expected['answer'] as Map<String, dynamic>;
      for (final item in repo.insights!.items) {
        expect(
          item.reaction,
          item.key == reaction['key'] ? reaction['value'] : null,
          reason: item.key,
        );
        expect(
          item.answers.map((a) => a.inputId),
          item.key == answer['key'] ? [answer['input_id']] : isEmpty,
        );
      }
      expect(repo.inputRecord(answer['input_id'] as String)!.kind, 'memo');

      final files = insightsFiles()
        ..removeWhere((path, _) => path.endsWith('_${answer['input_id']}.md'));
      final j =
          jsonDecode(files[HubRepository.insightsPath]!)
              as Map<String, dynamic>;
      final items = ((j['latest'] as Map)['items'] as List)
          .cast<Map<String, dynamic>>();
      items.firstWhere((i) => i['key'] == reaction['key'])['reaction'] =
          'later-kind';
      files[HubRepository.insightsPath] = jsonEncode(j);
      final later = HubRepository(VaultSnapshot(files));
      expect(later.warnings, isEmpty);
      expect(later.insights!.items.every((i) => i.reaction == null), isTrue);
      expect(later.insights!.items.every((i) => i.answers.isEmpty), isTrue);

      // 反応と答えを書かない版の本体の一覧も読む。
      for (final item in items) {
        item.remove('reaction');
        item.remove('answers');
      }
      files[HubRepository.insightsPath] = jsonEncode(j);
      final older = HubRepository(VaultSnapshot(files));
      expect(older.warnings, isEmpty);
      expect(older.insights!.items, hasLength(expected['total']));
    });

    testWidgets('ホームで反応を付け、もう一度押すと外す依頼を保存する', (t) async {
      final a = MemoryUIAccess(), files = insightsFiles();
      final c = await sample(t, a, files);
      final insights = c.repository!.insights!;
      final reacted = insights.items.singleWhere(
        (i) => i.key == (expected['reaction'] as Map)['key'],
      );
      final other = insights.items.firstWhere(
        (i) => i.key != reacted.key && i.reaction == null,
      );
      // 本体に記録された反応を選んだ状態で示す。
      expect(
        t
            .widget<ChoiceChip>(
              find.byKey(Key('home-insight-useful-${reacted.key}')),
            )
            .selected,
        isTrue,
      );
      expect(
        t
            .widget<ChoiceChip>(
              find.byKey(Key('home-insight-off-target-${other.key}')),
            )
            .selected,
        isFalse,
      );

      await t.tap(find.byKey(Key('home-insight-off-target-${other.key}')));
      await t.pumpAndSettle();
      var request = parseMarkdown(a.requests.values.single);
      expect(request.meta['operation'], 'insight-reaction');
      expect(request.meta['run_id'], insights.runId);
      expect(request.meta['item_key'], other.key);
      expect(request.meta['reaction'], 'off-target');
      expect(request.body.trim(), isEmpty);

      // 依頼が同期されると、反映待ちとして選んだ状態で示す。
      a.current = VaultSnapshot({
        ...files,
        'Input/${request.meta['request_id']}.md': a.requests.values.single,
      });
      await c.reload();
      await t.pumpAndSettle();
      expect(
        t
            .widget<ChoiceChip>(
              find.byKey(Key('home-insight-off-target-${other.key}')),
            )
            .selected,
        isTrue,
      );
      expect(
        find.byKey(Key('home-insight-pending-${other.key}')),
        findsOneWidget,
      );

      // 選んだ反応をもう一度押すと、反応を外す依頼になる。
      await t.tap(find.byKey(Key('home-insight-useful-${reacted.key}')));
      await t.pumpAndSettle();
      request = parseMarkdown(
        a.requests.values.firstWhere((r) => r.contains(reacted.key)),
      );
      expect(request.meta['reaction'], 'none');
      expect(t.takeException(), isNull);
    });

    testWidgets('問いに「答える」と、問いを示した入力欄を開き、答えを問いと結び付けて保存する。答えのメモを開ける', (t) async {
      final a = MemoryUIAccess(), files = insightsFiles();
      final c = await sample(t, a, files);
      final insights = c.repository!.insights!;
      final answered = insights.items.singleWhere(
        (i) => i.key == (expected['answer'] as Map)['key'],
      );
      // 答えのメモを開ける。
      final answerId = (expected['answer'] as Map)['input_id'] as String;
      final open = find.byKey(
        Key('home-insight-answered-${answered.key}-$answerId'),
      );
      expect(open, findsOneWidget);
      await t.tap(open);
      await t.pumpAndSettle();
      expect(find.textContaining('字幕の付け方を試したい'), findsWidgets);
      await t.pageBack();
      await t.pumpAndSettle();

      // 答えを出すのは、問いと止まっている意図だけ。
      for (final item in insights.items.where(
        (i) => i.section == 'connections' || i.section == 'actions',
      )) {
        expect(
          find.byKey(Key('home-insight-answer-${item.key}')),
          findsNothing,
        );
      }
      final stalled = insights.items.singleWhere((i) => i.section == 'stalled');
      expect(
        find.byKey(Key('home-insight-answer-${stalled.key}')),
        findsOneWidget,
      );

      await t.tap(find.byKey(Key('home-insight-answer-${answered.key}')));
      await t.pumpAndSettle();
      expect(find.text('問いに答える'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('answer-question')),
          matching: find.text(answered.text),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('template-menu')), findsNothing);
      // 答えは本人のメモとして残す（AIの作業要約にはしない）。
      expect(find.text('種類'), findsNothing);
      await t.enterText(find.byKey(const Key('memo-text')), 'まず3本の動画で試す');
      await t.tap(find.byKey(const Key('save-memo')));
      await t.pumpAndSettle();
      final request = parseMarkdown(a.requests.values.single);
      expect(request.meta['operation'], 'capture');
      expect(request.body.trim(), 'まず3本の動画で試す');
      expect(request.meta['meta'], {
        'capture_mode': 'insight-answer',
        'insight_key': answered.key,
        'insight_question': answered.text,
        'insight_run': insights.runId,
      });
      expect(t.takeException(), isNull);
    });

    testWidgets('答えの書きかけは問いごとに残し、ふつうのメモの書きかけと混ざらない', (t) async {
      final a = MemoryUIAccess(), files = insightsFiles();
      final c = await sample(t, a, files);
      final question = c.repository!.insights!.items.firstWhere(
        (i) => i.section == 'questions',
      );
      await t.tap(find.byKey(Key('home-insight-answer-${question.key}')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('memo-text')), '書きかけの答え');
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      Navigator.of(t.element(find.text('問いに答える'))).pop();
      await t.pumpAndSettle();
      final key = c.draftKey(
        answerTo: '${c.repository!.insights!.runId}/${question.key}',
      )!;
      expect((await c.drafts.read(key))?.text, '書きかけの答え');
      expect(await c.drafts.read(c.draftKey()!), isNull);
      expect(t.takeException(), isNull);
    });

    testWidgets('反応と答えに対応していない本体の一覧では、反応と「答える」を出さない', (t) async {
      final a = MemoryUIAccess(), files = insightsFiles();
      final j =
          jsonDecode(files[HubRepository.insightsPath]!)
              as Map<String, dynamic>;
      for (final item in ((j['latest'] as Map)['items'] as List).cast<Map>()) {
        item.remove('reaction');
        item.remove('answers');
      }
      files[HubRepository.insightsPath] = jsonEncode(j);
      final c = await sample(t, a, files);
      final items = c.repository!.insights!.items;
      expect(items, hasLength(expected['total']));
      expect(c.repository!.insights!.feedback, isFalse);
      await t.tap(find.byKey(const Key('home-insights-more')));
      await t.pumpAndSettle();
      for (final item in items) {
        expect(find.byKey(Key('home-insight-${item.key}')), findsOneWidget);
        expect(
          find.byKey(Key('home-insight-useful-${item.key}')),
          findsNothing,
        );
        expect(
          find.byKey(Key('home-insight-answer-${item.key}')),
          findsNothing,
        );
      }
      expect(t.takeException(), isNull);
    });

    test('受け付けた反応より後の判断が本体で有効なら、反映待ちのままにしない', () {
      final files = insightsFiles(),
          reaction = expected['reaction'] as Map<String, dynamic>;
      final runId = HubRepository(VaultSnapshot(files)).insights!.runId!;
      // ほかの端末の反応（役に立った。押した日時が後）が本体で有効なまま、この端末の古い依頼（的外れ）を後から受け付けた。
      const requestId = 'REQ-95111111222243338444555555555555',
          reactionId = 'IRX-01M7Z00000000000000000000A';
      final raw = encodePacket({
        'schema_version': 1,
        'request_id': requestId,
        'source': 'flutter-client/95111111-2222-4333-8444-555555555555',
        'occurred_at': '2026-11-15T01:00:00.000Z',
        'operation': 'insight-reaction',
        'run_id': runId,
        'item_key': reaction['key'],
        'reaction': 'off-target',
        'confirmed': true,
      }, '');
      files['Input/$requestId.md'] = raw;
      files['90_system/intake/$requestId.json'] = jsonEncode({
        'schema_version': 1,
        'request_id': requestId,
        'request_hash': digest(raw),
        'path': 'Input/$requestId.md',
        'operation': 'insight-reaction',
        'status': 'accepted',
        'received_at': '2026-11-20T00:00:00.000Z',
        'result': {
          'reactionId': reactionId,
          'runId': runId,
          'itemKey': reaction['key'],
          'reaction': 'off-target',
          'deduped': false,
        },
      });
      files['90_system/insight-reactions/$reactionId.json'] = jsonEncode({
        'schema_version': 1,
        'id': reactionId,
        'run_id': runId,
        'item_key': reaction['key'],
        'reaction': 'off-target',
        'decided_at': '2026-11-15T01:00:00.000Z',
        'source': 'flutter-client/95111111-2222-4333-8444-555555555555',
        'source_event_id': requestId,
        'created_at': '2026-11-20T00:00:00.000Z',
      });
      final repo = HubRepository(VaultSnapshot(files));
      expect(repo.warnings, isEmpty);
      final item = repo.insights!.items.singleWhere(
        (i) => i.key == reaction['key'],
      );
      expect(item.reaction, 'useful');
      expect(repo.insightReactionOf(item), (
        reaction: 'useful',
        pending: false,
      ));
      expect(repo.intake.single.state, 'accepted');
    });
  });
}
