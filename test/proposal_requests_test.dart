import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/attention.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/review_candidates.dart';
import 'package:context_hub_client/storage/review_service.dart';
import 'capture_test.dart' show TempAccess, location;
import 'review_test.dart' show nativeReviewFiles, reviewFiles;
import 'unassigned_proposals_test.dart'
    show expected, inboxFiles, leadOf, manyUnassigned, reseal, sample;
import 'widget_test.dart' show MemoryUIAccess;

const indexPath = '90_system/review/index.json';
const unassignedPath = '90_system/unassigned-actions.json';
String uuid(int n) =>
    '${n.toString().padLeft(8, '0')}-2222-4333-8444-555555555555';

/// アプリが保存する採用・却下の依頼を作り、Inputのパスと本文を返す。
Future<MapEntry<String, String>> request(
  int n,
  ReviewCandidate candidate,
  String action, {
  List<ReviewCandidate> covers = const [],
  AdoptionTarget? target,
}) async {
  final access = MemoryUIAccess(),
      result = await ReviewService(
        access,
        location,
      ).submit(uuid(n), candidate, action, covers: covers, target: target);
  return MapEntry(
    'Input/${result.requestId}.md',
    access.requests[result.requestId]!,
  );
}

String idOf(MapEntry<String, String> request) =>
    parseMarkdown(request.value).meta['request_id'] as String;

/// 本体が依頼を受け付けられなかったときに書く記録。
Map<String, String> refused(
  MapEntry<String, String> request, {
  String status = 'error',
  String? fileHash,
}) => {
  '90_system/intake-errors/${digest(request.key)}.json': jsonEncode({
    'schema_version': 1,
    'path': request.key,
    'file_hash': fileHash ?? digest(request.value),
    'status': status,
    'code': '受付操作が未完了です。対象・確認情報・停止回復をdoctorで確認してください',
    'updated_at': '2026-11-08T00:00:00.000Z',
  }),
};

/// 本体が依頼を受け付けたときに書く記録。
Map<String, String> accepted(MapEntry<String, String> request) {
  final meta = parseMarkdown(request.value).meta,
      candidate = meta['candidate_id'] as String;
  return {
    '90_system/intake/${meta['request_id']}.json': jsonEncode({
      'schema_version': 1,
      'status': 'accepted',
      'path': request.key,
      'request_id': meta['request_id'],
      'operation': meta['operation'],
      'request_hash': digest(request.value),
      'result': {
        'candidateId': candidate,
        'projectId': 'project-${candidate.substring(5).toLowerCase()}',
        'decisionId': 'PAPR-${candidate.substring(5)}',
        'deduped': false,
      },
    }),
  };
}

/// 確認待ち一覧（index.json）の候補を書き換える。
Map<String, String> withIndex(
  Map<String, String> files,
  void Function(List<Map<String, dynamic>> items) change,
) {
  final root = jsonDecode(files[indexPath]!) as Map<String, dynamic>;
  change((root['items'] as List).cast<Map<String, dynamic>>());
  return {...files, indexPath: jsonEncode(root)};
}

/// 候補の内容を書き換える（依頼の後で、候補が作り直された状態）。確認待ちのまま、内容のhashだけが変わる。
Map<String, String> rewritten(Map<String, String> source, String id) {
  final files = {...source};
  return withIndex(files, (items) {
    final row = items.singleWhere((i) => i['id'] == id),
        path = row['path'] as String,
        confirmation = '90_system/project-confirmations/$id.json';
    files[path] = '${files[path]}\n';
    files[confirmation] = jsonEncode({
      ...jsonDecode(files[confirmation]!) as Map,
      'candidate_hash': digest(files[path]!),
    });
    row['candidateHash'] = digest(files[path]!);
    (row['dependencies'] as Map)
      ..[path] = digest(files[path]!)
      ..[confirmation] = digest(files[confirmation]!);
  });
}

/// 確認待ちの知識の候補を1件、[title]の名前で加える（候補と根拠は、候補確認のサンプルのもの）。
Map<String, String> withKnowledge(Map<String, String> source, String title) {
  final other = reviewFiles(),
      row = ((jsonDecode(other[indexPath]!) as Map)['items'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (i) => i['status'] == 'pending' && i['kind'] == 'knowledge',
          );
  return withIndex({
    ...other,
    ...source,
  }, (items) => items.add({...row, 'title': title}));
}

/// 候補を複製する。[lead]を渡すと代表の案にまとめた案として、渡さなければ単独の案として加える。
Map<String, String> clones(
  int count, {
  required String of,
  bool grouped = true,
}) {
  final files = inboxFiles();
  return withIndex(files, (items) {
    final source = items.singleWhere((i) => i['title'] == of),
        id = source['id'] as String,
        lead = items.singleWhere((i) => i['title'] == expected['lead']);
    for (var n = 0; n < count; n++) {
      final copy = 'PCAN-${n.toString().padLeft(26, '0')}',
          path = '90_system/project-candidates/$copy.md',
          confirmation = '90_system/project-confirmations/$copy.json';
      files[path] = files[source['path']]!.replaceAll(id, copy);
      files[confirmation] = jsonEncode({
        'schema_version': 1,
        'candidate_id': copy,
        'candidate_hash': digest(files[path]!),
        'confirmation_token': source['confirmationToken'],
      });
      items.add({
        ...source,
        'id': copy,
        'path': path,
        'title': '複製した案$n',
        'candidateHash': digest(files[path]!),
        'dependencies': {
          for (final e in (source['dependencies'] as Map).entries)
            if ((e.key as String).startsWith('00_inbox/')) e.key: e.value,
          path: digest(files[path]!),
          '90_system/project-approvals/PAPR-${copy.substring(5)}.json': null,
          confirmation: digest(files[confirmation]!),
        },
        if (grouped) 'duplicateOf': lead['id'],
      });
      if (grouped) (lead['duplicates'] as List).add(copy);
    }
  });
}

Future<HubController> controllerOf(
  MemoryUIAccess access,
  Map<String, String> files,
) async {
  access.current = VaultSnapshot(files);
  final c = HubController(access, sampleLoader: () async => files);
  addTearDown(c.dispose);
  await c.useSample();
  return c;
}

Future<void> show(
  HubController c,
  MemoryUIAccess access,
  Map<String, String> files,
) async {
  access.current = VaultSnapshot(files);
  await c.reload();
}

void main() {
  group('受け付けられなかった依頼', () {
    test('本体が受け付けられなかった依頼は、依頼済みとして扱わない', () async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead),
          saved = await request(1, lead, 'reject', covers: members),
          id = idOf(saved);
      ReviewRepository review(Map<String, String> more) => HubRepository(
        VaultSnapshot({...files, saved.key: saved.value, ...more}),
      ).review;
      // 判断を待っている間は、代表の案とまとめた案を依頼済みとして扱う。
      var r = review({});
      for (final c in [lead, ...members]) {
        expect(r.requestIdFor(c.id), id);
        expect(r.failedRequestIdFor(c.id), isNull);
      }
      // 本体が受け付けられなかった依頼は、依頼済みから外し、もう一度判断できるようにする。
      for (final status in ['error', 'conflict']) {
        final repo = HubRepository(
          VaultSnapshot({
            ...files,
            saved.key: saved.value,
            ...refused(saved, status: status),
          }),
        );
        r = repo.review;
        expect(repo.warnings, isEmpty, reason: status);
        for (final c in [lead, ...members]) {
          expect(r.requestIdFor(c.id), isNull, reason: status);
          expect(r.failedRequestIdFor(c.id), id, reason: status);
        }
        expect(
          r.groupMembers(r.byId(lead.id)!).map((m) => m.id),
          members.map((m) => m.id),
          reason: status,
        );
        expect(r.pendingRows, hasLength(expected['rows']), reason: status);
        // 判断待ちの件数にも戻す。
        expect(
          attentionItems(repo).where((i) => i.kind == 'candidate'),
          hasLength(expected['rows']),
          reason: status,
        );
        expect(
          repo.intake.single.state,
          status == 'error' ? 'rejected' : 'conflict',
        );
      }
      // 別の内容の依頼への失敗の記録と、受け付けた後に残った失敗の記録では、依頼済みのままにする。
      r = review(refused(saved, fileHash: 'f' * 64));
      expect(r.requestIdFor(lead.id), id);
      expect(r.failedRequestIdFor(lead.id), isNull);
      r = review({...refused(saved), ...accepted(saved)});
      expect(r.requestIdFor(members.last.id), id);
      expect(r.failedRequestIdFor(members.last.id), isNull);
      // 読めない失敗の記録、別の依頼への記録、知らない形式や状態の記録では、依頼済みのままにする。
      final record = refused(saved).entries.single,
          error = jsonDecode(record.value) as Map<String, dynamic>;
      for (final (index, value) in [
        '{',
        jsonEncode({...error, 'path': 'Input/REQ-${'0' * 32}.md'}),
        jsonEncode({...error, 'schema_version': 2}),
        jsonEncode({...error, 'status': 'accepted'}),
      ].indexed) {
        r = review({record.key: value});
        expect(r.requestIdFor(lead.id), id, reason: '$index');
        expect(r.failedRequestIdFor(lead.id), isNull, reason: '$index');
      }
      // 受け付けられなかった依頼の後で保存した依頼があれば、依頼済みとして扱う。
      final again = await request(2, lead, 'approve', covers: members);
      r = review({...refused(saved), again.key: again.value});
      expect(r.requestIdFor(lead.id), idOf(again));
      expect(r.failedRequestIdFor(lead.id), isNull);
      // 候補の内容が変わった後は、前の依頼を示さない。
      r = HubRepository(
        VaultSnapshot(
          withIndex({...files, saved.key: saved.value, ...refused(saved)}, (
            items,
          ) {
            final row = items.singleWhere((i) => i['id'] == members.last.id);
            row['candidateHash'] = 'e' * 64;
            (row['dependencies'] as Map)[row['path']] = 'e' * 64;
          }),
        ),
      ).review;
      expect(r.failedRequestIdFor(members.last.id), isNull);
      expect(r.failedRequestIdFor(members.first.id), id);
    });

    test('知識の候補でも、受け付けられなかった依頼は依頼済みから外す', () async {
      final files = reviewFiles(),
          candidate = HubRepository(
            VaultSnapshot(files),
          ).review.pending.firstWhere((c) => c.kind != 'project'),
          access = MemoryUIAccess(),
          result = await ReviewService(
            access,
            location,
          ).submit(uuid(1), candidate, 'reject'),
          saved = MapEntry(
            'Input/${result.requestId}.md',
            access.requests[result.requestId]!,
          );
      var r = HubRepository(
        VaultSnapshot({...files, saved.key: saved.value}),
      ).review;
      expect(r.requestIdFor(candidate.id), result.requestId);
      r = HubRepository(
        VaultSnapshot({...files, saved.key: saved.value, ...refused(saved)}),
      ).review;
      expect(r.requestIdFor(candidate.id), isNull);
      expect(r.failedRequestIdFor(candidate.id), result.requestId);
    });

    test('受け付けられなかった後の判断は、新しい依頼として保存する', () async {
      final access = MemoryUIAccess(),
          files = inboxFiles(),
          c = await controllerOf(access, files),
          lead = leadOf(c.review!);
      final first = await c.submitReview(
        await c.prepareReview(lead.id),
        'reject',
      );
      expect(first.saved, isTrue);
      final saved = MapEntry(
        'Input/${first.requestId}.md',
        access.requests[first.requestId]!,
      );
      // 判断を待っている間は、同じ案をもう一度判断できない。
      await show(c, access, {...files, saved.key: saved.value});
      await expectLater(c.prepareReview(lead.id), throwsStateError);
      // 本体が受け付けられなかった後は、判断を変えて依頼し直せる。
      // 別の端末からの依頼も受け付けられなかった（IDは、この端末の依頼より前に並ぶ）。
      final other = await request(1, lead, 'reject'),
          failed = {
            ...files,
            other.key: other.value,
            ...refused(other),
            saved.key: saved.value,
            ...refused(saved),
          };
      await show(c, access, failed);
      final second = await c.submitReview(
        await c.prepareReview(lead.id),
        'approve',
      );
      expect(second.saved, isTrue);
      expect(second.requestId, isNot(first.requestId));
      expect(access.writes, 2);
      expect(
        parseMarkdown(access.requests[second.requestId]!).meta['operation'],
        'project-approve',
      );
      // 前の依頼は書き換えない。
      expect(access.requests[first.requestId], saved.value);
      // 同じ確認のまま押し直しても、依頼を重ねて保存しない。
      await show(c, access, failed);
      final ticket = await c.prepareReview(lead.id);
      expect(
        (await c.submitReview(ticket, 'approve')).requestId,
        second.requestId,
      );
      expect(access.writes, 2);
      // 依頼し直した依頼も受け付けられなかったら、さらに新しい依頼として保存する。
      // 受け付けられなかった依頼のうち最初の1件が同じでも、前の依頼と取り違えない。
      final again = MapEntry(
        'Input/${second.requestId}.md',
        access.requests[second.requestId]!,
      );
      await show(c, access, {
        ...failed,
        again.key: again.value,
        ...refused(again),
      });
      expect(
        c.review!.failedRequestIdsFor(lead.id),
        [idOf(other), first.requestId, second.requestId]..sort(),
      );
      expect(c.review!.failedRequestIdsFor(lead.id).first, idOf(other));
      final third = await c.submitReview(
        await c.prepareReview(lead.id),
        'approve',
      );
      expect(third.saved, isTrue);
      expect(third.requestId, isNot(second.requestId));
      expect(access.requests.keys, hasLength(3));
    });

    test(
      '先に届いた採用で受け付けられなくなったまとめた却下を、固定上流の記録どおりに示す',
      () async {
        final access = TempAccess();
        await access.init();
        addTearDown(() => access.directory.delete(recursive: true));
        final r = HubRepository(VaultSnapshot(inboxFiles())).review,
            lead = leadOf(r),
            members = r.groupMembers(lead),
            service = ReviewService(access, location);
        // 別の端末で、まとめた案の1件（別名が代表の案の名前と同じ）だけを採用していた。
        final approve = await service.submit(uuid(1), members.last, 'approve'),
            reject = await service.submit(
              uuid(2),
              lead,
              'reject',
              covers: members,
            );
        final output = '${access.directory.path}/after.json';
        final node = await Process.run('node', [
          'scripts/check_review_sequence_protocol.mjs',
          'refused',
          access.request(location, approve.requestId).path,
          access.request(location, reject.requestId).path,
          'test/fixtures/unassigned-and-proposals.json',
          output,
        ]);
        expect(node.exitCode, 0, reason: '${node.stdout}\n${node.stderr}');
        final repo = HubRepository(
              VaultSnapshot(
                nativeReviewFiles(
                  Map<String, String>.from(
                    jsonDecode(await File(output).readAsString()) as Map,
                  ),
                ),
              ),
            ),
            review = repo.review;
        expect(review.warnings, isEmpty);
        expect(review.byId(members.last.id)!.status, 'approved');
        expect(review.byId(lead.id)!.status, 'stale');
        // 判断が記録されなかった案は、依頼済みのままにせず、もう一度判断できるようにする。
        final rest = review.byId(members.first.id)!;
        expect(rest.status, 'pending');
        expect(review.requestIdFor(rest.id), isNull);
        expect(review.failedRequestIdFor(rest.id), reject.requestId);
        expect(review.pendingRows.map((i) => i.id), contains(rest.id));
        expect(
          attentionItems(repo).map((i) => i.key),
          contains(AttentionItem('candidate', rest.id, 'review').key),
        );
        expect(
          {for (final i in repo.intake) i.id: i.state},
          {approve.requestId: 'accepted', reject.requestId: 'rejected'},
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      '名前も別名も一致しない案の採用の後に届いたまとめた却下は、固定上流が受け付ける',
      () async {
        final access = TempAccess();
        await access.init();
        addTearDown(() => access.directory.delete(recursive: true));
        final r = HubRepository(VaultSnapshot(inboxFiles())).review,
            lead = leadOf(r),
            members = r.groupMembers(lead),
            service = ReviewService(access, location);
        // 代表の案と名前が含まれる関係にあるだけの案を採用しても、残りの案は古い案にならない。
        final approve = await service.submit(uuid(1), members.first, 'approve'),
            reject = await service.submit(
              uuid(2),
              lead,
              'reject',
              covers: [members.last],
            );
        final output = '${access.directory.path}/after.json';
        final node = await Process.run('node', [
          'scripts/check_review_sequence_protocol.mjs',
          'accepted',
          access.request(location, approve.requestId).path,
          access.request(location, reject.requestId).path,
          'test/fixtures/unassigned-and-proposals.json',
          output,
        ]);
        expect(node.exitCode, 0, reason: '${node.stdout}\n${node.stderr}');
        final repo = HubRepository(
              VaultSnapshot(
                nativeReviewFiles(
                  Map<String, String>.from(
                    jsonDecode(await File(output).readAsString()) as Map,
                  ),
                ),
              ),
            ),
            review = repo.review;
        expect(review.warnings, isEmpty);
        expect(review.byId(members.first.id)!.status, 'approved');
        expect(review.byId(lead.id)!.status, 'rejected');
        expect(review.byId(members.last.id)!.status, 'rejected');
        expect(review.byId(members.last.id)!.coveredBy, lead.id);
        expect(
          {for (final i in repo.intake) i.id: i.state},
          {approve.requestId: 'accepted', reject.requestId: 'accepted'},
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets('受け付けられなかった依頼を一覧と詳細で示し、もう一度判断できる', (t) async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead);
      late MapEntry<String, String> saved;
      await t.runAsync(() async {
        saved = await request(1, lead, 'reject', covers: members);
      });
      final a = MemoryUIAccess();
      await sample(t, a, {...files, saved.key: saved.value, ...refused(saved)});
      // ホームの問いかけと確認待ちの件数に戻る。
      expect(find.byKey(Key('home-proposal-${lead.id}')), findsOneWidget);
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      expect(
        find.text('プロジェクト案 · 未承認 · 根拠のメモ3件（同じ対象の案をまとめて表示）\n前の依頼は受け付けられませんでした'),
        findsOneWidget,
      );
      expect(find.textContaining('依頼保存済み'), findsNothing);
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-failed')), findsOneWidget);
      await t.tap(find.text('3件をまとめて採用する'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-review')));
      await t.pumpAndSettle();
      expect(a.writes, 1);
      expect(a.requests.keys.single, isNot(idOf(saved)));
      // 保存し直した後は、前の依頼の表示をやめる。
      expect(find.byKey(const Key('review-failed')), findsNothing);
      expect(find.textContaining('依頼をこの端末に保存しました'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('詳細を開いたまま、保存した依頼が受け付けられなかったら、もう一度判断できる', (t) async {
      final files = inboxFiles(),
          a = MemoryUIAccess(),
          c = await sample(t, a, files);
      final lead = leadOf(c.review!), members = c.review!.groupMembers(lead);
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      await t.tap(find.text('3件をまとめて却下する'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-review')));
      await t.pumpAndSettle();
      expect(a.writes, 1);
      expect(find.textContaining('依頼をこの端末に保存しました'), findsOneWidget);
      final saved = MapEntry(
        'Input/${a.requests.keys.single}.md',
        a.requests.values.single,
      );
      OutlinedButton reject() =>
          t.widget<OutlinedButton>(find.byKey(const Key('review-reject')));
      // 依頼が同期されて、Miniの判断を待つ間は、判断し直せない。
      a.current = VaultSnapshot({...files, saved.key: saved.value});
      await c.reload();
      await t.pumpAndSettle();
      expect(reject().onPressed, isNull);
      expect(find.byKey(const Key('review-failed')), findsNothing);
      // 受け付けられなかった記録が届いたら、保存済みの表示をやめて、もう一度判断できるようにする。
      a.current = VaultSnapshot({
        ...files,
        saved.key: saved.value,
        ...refused(saved),
      });
      await c.reload();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-failed')), findsOneWidget);
      expect(find.textContaining('依頼をこの端末に保存しました'), findsNothing);
      expect(reject().onPressed, isNotNull);
      expect(
        t
            .widget<CheckboxListTile>(
              find.byKey(Key('review-include-${members.last.id}')),
            )
            .onChanged,
        isNotNull,
      );
      await t.tap(find.text('3件をまとめて採用する'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-review')));
      await t.pumpAndSettle();
      expect(a.writes, 2);
      expect(a.requests.keys, hasLength(2));
      expect(find.byKey(const Key('review-failed')), findsNothing);
      expect(find.textContaining('依頼をこの端末に保存しました'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('まとめた案の前の依頼が受け付けられなかったことも、代表の行と詳細に示す', (t) async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead);
      late MapEntry<String, String> saved;
      await t.runAsync(() async {
        saved = await request(1, members.last, 'reject');
      });
      final a = MemoryUIAccess();
      await sample(t, a, {...files, saved.key: saved.value, ...refused(saved)});
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      expect(
        find.text(
          'プロジェクト案 · 未承認 · 根拠のメモ3件（同じ対象の案をまとめて表示）\nまとめた案の前の依頼は受け付けられませんでした',
        ),
        findsOneWidget,
      );
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-failed')), findsNothing);
      expect(
        find.byKey(Key('review-member-failed-${members.last.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('review-member-failed-${members.first.id}')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    });
  });

  group('まとめる案の選び方', () {
    test('ほかの案の依頼に含まれている代表の案には、残りの案をまとめない', () async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead),
          // 一覧が作り直される前に、まとめた案の1件を代表として、いまの代表の案だけを含めて依頼した。
          saved = await request(
            1,
            members.first,
            'reject',
            covers: [lead],
          ),
          repo = HubRepository(
            VaultSnapshot({...files, saved.key: saved.value}),
          ),
          r = repo.review;
      expect(repo.warnings, isEmpty);
      expect(r.requestIdFor(lead.id), idOf(saved));
      expect(r.requestIdFor(members.first.id), idOf(saved));
      expect(r.requestIdFor(members.last.id), isNull);
      // 依頼に含まれていない案は、依頼済みの行に隠さず、1件として示す。
      expect(r.groupMembers(r.byId(lead.id)!), isEmpty);
      expect(r.groupLead(r.byId(members.last.id)!), isNull);
      expect(r.pendingRows.map((i) => i.id), contains(members.last.id));
      expect(r.pendingRows, hasLength(4));
      expect(
        attentionItems(repo).where((i) => i.kind == 'candidate'),
        hasLength(2),
      );
    });

    test('ほかの依頼に含まれている案は、まとめる対象にしない', () async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead),
          single = before.pendingRows.singleWhere((i) => i.id != lead.id),
          saved = await request(1, single, 'reject', covers: [members.last]),
          access = MemoryUIAccess(),
          c = await controllerOf(access, {...files, saved.key: saved.value}),
          r = c.review!;
      expect(r.requestIdFor(members.last.id), idOf(saved));
      expect(r.groupMembers(r.byId(lead.id)!).map((m) => m.id), [
        members.first.id,
      ]);
      expect(r.groupLead(r.byId(members.last.id)!), isNull);
      // 依頼にも含めない。
      final ticket = await c.prepareReview(lead.id);
      expect(ticket.covers.map((m) => m.id), [members.first.id]);
      // 受け付けられなかった依頼に含まれていた案は、まとめる対象に戻す。
      await show(c, access, {
        ...files,
        saved.key: saved.value,
        ...refused(saved),
      });
      expect(
        c.review!.groupMembers(c.review!.byId(lead.id)!).map((m) => m.id),
        members.map((m) => m.id),
      );
    });

    test('20件を超える案と、代表の案を指していない案はまとめない', () {
      var r = HubRepository(VaultSnapshot(clones(19, of: '読書の記録づくり'))).review;
      expect(r.warnings, isEmpty);
      var lead = leadOf(r);
      expect(lead.duplicates, hasLength(21));
      // 1回の判断でまとめられるのは20件まで。超える分は1件ずつ示す。
      expect(r.groupMembers(lead), hasLength(maxProposalCovers));
      expect(r.groupMembers(lead).map((m) => m.id), lead.duplicates.take(20));
      expect(r.pendingRows.map((i) => i.id), contains(lead.duplicates.last));
      expect(r.pendingRows, hasLength(3));
      // ちょうど20件なら、すべてをまとめる。
      r = HubRepository(VaultSnapshot(clones(18, of: '読書の記録づくり'))).review;
      expect(r.groupMembers(leadOf(r)), hasLength(20));
      expect(r.pendingRows, hasLength(2));
      // 代表の案を指していない案（一覧の作り直しの途中など）は、まとめない。
      final files = inboxFiles(),
          members = HubRepository(VaultSnapshot(files)).review.groupMembers(
            leadOf(HubRepository(VaultSnapshot(files)).review),
          );
      for (final change in <void Function(Map<String, dynamic>)>[
        (row) => row.remove('duplicateOf'),
        (row) => row['duplicateOf'] = members.last.id,
      ]) {
        r = HubRepository(
          VaultSnapshot(
            withIndex(
              files,
              (items) =>
                  change(items.singleWhere((i) => i['id'] == members.first.id)),
            ),
          ),
        ).review;
        lead = leadOf(r);
        expect(r.groupMembers(lead).map((m) => m.id), [members.last.id]);
        expect(r.pendingRows.map((i) => i.id), contains(members.first.id));
      }
    });

    test('依頼に含めた案だけをまとめ、内容が変わった案は外す', () async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead),
          saved = await request(1, lead, 'reject', covers: [members.last]);
      var r = HubRepository(
        VaultSnapshot({...files, saved.key: saved.value}),
      ).review;
      expect(r.groupMembers(r.byId(lead.id)!).map((m) => m.id), [
        members.last.id,
      ]);
      expect(r.requestIdFor(members.last.id), idOf(saved));
      // 含めなかった案は、1件として判断を待つ。
      expect(r.requestIdFor(members.first.id), isNull);
      expect(r.pendingRows.map((i) => i.id), contains(members.first.id));
      // 依頼の後で内容が変わった案は、依頼済みとして扱わず、まとめからも外す。
      r = HubRepository(
        VaultSnapshot(
          withIndex({...files, saved.key: saved.value}, (items) {
            final row = items.singleWhere((i) => i['id'] == members.last.id);
            row['candidateHash'] = 'e' * 64;
            (row['dependencies'] as Map)[row['path']] = 'e' * 64;
          }),
        ),
      ).review;
      expect(r.requestIdFor(lead.id), idOf(saved));
      expect(r.requestIdFor(members.last.id), isNull);
      expect(r.groupMembers(r.byId(lead.id)!), isEmpty);
      // 依頼に含めた案でも、別の端末がその案だけの判断を依頼していたら、1件として示す。
      final alone = await request(2, members.last, 'reject');
      r = HubRepository(
        VaultSnapshot({
          ...files,
          saved.key: saved.value,
          alone.key: alone.value,
        }),
      ).review;
      expect(r.groupMembers(r.byId(lead.id)!), isEmpty);
      expect(r.pendingRows.map((i) => i.id), contains(members.last.id));
      // 本体が受け付けられなかった依頼は、まとめる案を絞らない（すべての案をまとめ直す）。
      r = HubRepository(
        VaultSnapshot({...files, saved.key: saved.value, ...refused(saved)}),
      ).review;
      expect(
        r.groupMembers(r.byId(lead.id)!).map((m) => m.id),
        members.map((m) => m.id),
      );
    });

    test('名前か別名が同じ案の採用が反映を待つ間は、その案を含むまとめた判断をしない', () async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead),
          // 別名が、代表の案の名前と同じ案。
          approve = await request(
            1,
            members.last,
            'approve',
          ),
          access = MemoryUIAccess(),
          c = await controllerOf(access, {
            ...files,
            approve.key: approve.value,
          });
      ReviewCandidate? blocker() {
        final current = c.review!.byId(lead.id)!;
        return c.review!.groupBlocker(current, c.review!.groupMembers(current));
      }

      // 採用でプロジェクトができると、名前か別名が同じ代表の案は古い案になり、まとめた依頼の全体が受け付けられなくなる。
      expect(
        c.review!.groupMembers(c.review!.byId(lead.id)!).map((m) => m.id),
        [members.first.id],
      );
      expect(blocker()!.id, members.last.id);
      await expectLater(c.prepareReview(lead.id), throwsStateError);
      // 確認した後に採用の依頼が届いたときも、依頼しない。
      final real = await c.prepareReview(lead.id, exclude: {members.first.id});
      expect(real.covers, isEmpty);
      await expectLater(
        c.submitReview(
          ReviewConfirmation(
            real.candidate,
            real.fingerprint,
            real.identity,
            real.epoch,
            covers: [c.review!.byId(members.first.id)!],
          ),
          'reject',
        ),
        throwsStateError,
      );
      expect(access.writes, 0);
      // 代表の案だけ、まとめた案だけなら判断できる。
      expect((await c.submitReview(real, 'reject')).saved, isTrue);
      expect(
        (await c.submitReview(
          await c.prepareReview(members.first.id),
          'reject',
        )).saved,
        isTrue,
      );
      // 名前も別名も一致しない案の採用は、まとめた判断を妨げない（本体は、どちらの順でも受け付ける）。
      final apart = await request(2, members.first, 'approve');
      await show(c, access, {...files, apart.key: apart.value});
      expect(blocker(), isNull);
      expect((await c.prepareReview(lead.id)).covers.map((m) => m.id), [
        members.last.id,
      ]);
      // 却下の依頼は、残りの案の判断を妨げない。
      final reject = await request(3, members.last, 'reject');
      await show(c, access, {...files, reject.key: reject.value});
      expect(blocker(), isNull);
      expect((await c.prepareReview(lead.id)).covers.map((m) => m.id), [
        members.first.id,
      ]);
      // 同じ案に却下と採用の依頼が両方あるときは、並びの順によらず、採用の反映を待つ。
      for (final both in [
        {reject.key: reject.value, approve.key: approve.value},
        {approve.key: approve.value, reject.key: reject.value},
      ]) {
        await show(c, access, {...files, ...both});
        expect(blocker()!.id, members.last.id);
      }
      // 受け付けられなかった採用の依頼は、妨げない。
      await show(c, access, {
        ...files,
        approve.key: approve.value,
        ...refused(approve),
      });
      expect(blocker(), isNull);
      expect((await c.prepareReview(lead.id)).covers, hasLength(2));
      // 採用を依頼済みの案そのものは、待つ理由にしない（依頼済みの案は、もう判断しない）。
      await show(c, access, {...files, approve.key: approve.value});
      expect(
        c.review!.groupBlocker(c.review!.byId(members.last.id)!, [
          c.review!.byId(members.first.id)!,
        ]),
        isNull,
      );
      // 依頼の後で内容が変わった案の採用は、本体が受け付けないので、妨げない。
      await show(
        c,
        access,
        rewritten({...files, approve.key: approve.value}, members.last.id),
      );
      expect(c.review!.byId(members.last.id)!.status, 'pending');
      expect(c.review!.requestIdFor(members.last.id), isNull);
      expect(
        c.review!.groupBlocker(c.review!.byId(lead.id)!, [
          c.review!.byId(members.first.id)!,
        ]),
        isNull,
      );
      // 知識の候補の採用は、名前が同じでも、プロジェクトができないので妨げない。
      final mixed = withKnowledge(files, lead.title),
          knowledge = HubRepository(
            VaultSnapshot(mixed),
          ).review.pending.singleWhere((i) => i.kind == 'knowledge'),
          learned = await request(
            6,
            knowledge,
            'approve',
            target: AdoptionTarget.global(),
          ),
          learning = HubRepository(
            VaultSnapshot({...mixed, learned.key: learned.value}),
          ).review;
      expect(learning.warnings, isEmpty);
      expect(knowledge.title, lead.title);
      expect(learning.requestIdFor(knowledge.id), idOf(learned));
      expect(
        learning.groupBlocker(
          learning.byId(lead.id)!,
          learning.groupMembers(learning.byId(lead.id)!),
        ),
        isNull,
      );
      // ほかの案の採用にまとめられているだけの案は、その名前でプロジェクトができないので、妨げない。
      final single = before.pendingRows.singleWhere((i) => i.id != lead.id),
          covering = await request(
            4,
            single,
            'approve',
            covers: [members.last],
          );
      await show(c, access, {...files, covering.key: covering.value});
      expect(c.review!.requestIdFor(members.last.id), idOf(covering));
      expect(blocker(), isNull);
      // 組の外の案でも、別名が同じ案の採用は、その案を含むまとめた判断を妨げる。
      // 半角カナと前後の空白の違いは、本体と同じ正規化で同じ名前として扱う。
      expect(members.first.aliases, ['読書アプリ']);
      final renamed = withIndex(files, (items) {
            items.singleWhere((i) => i['id'] == single.id)['aliases'] = [
              ' 読書ｱﾌﾟﾘ ',
            ];
          }),
          outside = await request(
            5,
            HubRepository(VaultSnapshot(renamed)).review.byId(single.id)!,
            'approve',
          );
      await show(c, access, {...renamed, outside.key: outside.value});
      expect(blocker()!.id, single.id);
      await expectLater(c.prepareReview(lead.id), throwsStateError);
      // 名前の重なる案を外せば、残りをまとめて判断できる。
      expect(
        (await c.prepareReview(
          lead.id,
          exclude: {members.first.id},
        )).covers.map((m) => m.id),
        [members.last.id],
      );
    });

    test('まとめた判断が反映を待つ間は、名前か別名が同じ案を採用しない', () async {
      final access = MemoryUIAccess(),
          files = inboxFiles(),
          c = await controllerOf(access, files),
          lead = leadOf(c.review!),
          members = c.review!.groupMembers(lead),
          single = c.review!.pendingRows.singleWhere((i) => i.id != lead.id);
      // 別名が代表の案の名前と同じ案を外して、残りをまとめて却下する。
      final grouped = await c.submitReview(
            await c.prepareReview(lead.id, exclude: {members.last.id}),
            'reject',
          ),
          saved = MapEntry(
            'Input/${grouped.requestId}.md',
            access.requests[grouped.requestId]!,
          ),
          waiting = {...files, saved.key: saved.value};
      await show(c, access, waiting);
      // 外した案は1件で並ぶ。先に採用が反映されると、代表の案が古い案になり、まとめた却下の全体が受け付けられなくなる。
      expect(c.review!.pendingRows.map((i) => i.id), contains(members.last.id));
      expect(
        c.review!.approveBlocker(c.review!.byId(members.last.id)!)!.id,
        lead.id,
      );
      await expectLater(
        c
            .prepareReview(members.last.id)
            .then((ticket) => c.submitReview(ticket, 'approve')),
        throwsStateError,
      );
      expect(access.writes, 1);
      // 名前も別名も一致しない案の採用と、却下は止めない。
      expect(c.review!.approveBlocker(c.review!.byId(single.id)!), isNull);
      expect(
        (await c.submitReview(
          await c.prepareReview(single.id),
          'approve',
        )).saved,
        isTrue,
      );
      expect(
        (await c.submitReview(
          await c.prepareReview(members.last.id),
          'reject',
        )).saved,
        isTrue,
      );
      expect(access.writes, 3);
      // まとめた判断に含まれている案そのものは、依頼済みとして扱う（採用を待つ理由にはしない）。
      expect(c.review!.approveBlocker(c.review!.byId(lead.id)!), isNull);
      expect(
        c.review!.approveBlocker(c.review!.byId(members.first.id)!),
        isNull,
      );
      // まとめた判断が受け付けられなかった後は、採用を止めない。
      final other = MemoryUIAccess(),
          second = await controllerOf(other, {...waiting, ...refused(saved)});
      expect(
        second.review!.approveBlocker(second.review!.byId(members.last.id)!),
        isNull,
      );
      expect(
        (await second.submitReview(
          await second.prepareReview(members.last.id),
          'approve',
        )).saved,
        isTrue,
      );
      // まとめた案と別名が同じ案の採用も止める（半角カナと前後の空白の違いは、同じ名前として扱う）。
      ReviewRepository renamedBy(
        Map<String, String> source,
        List<String> aliases,
      ) => HubRepository(
        VaultSnapshot(
          withIndex(
            source,
            (items) =>
                items.singleWhere((i) => i['id'] == single.id)['aliases'] =
                    aliases,
          ),
        ),
      ).review;
      expect(members.first.aliases, ['読書アプリ']);
      var r = renamedBy(waiting, [' 読書ｱﾌﾟﾘ ']);
      expect(r.approveBlocker(r.byId(single.id)!)!.id, lead.id);
      // 依頼の後で内容が変わった案は、まとめた判断に含まれないので、その案と別名が同じ案の採用は止めない。
      r = renamedBy(rewritten(waiting, members.first.id), [' 読書ｱﾌﾟﾘ ']);
      expect(r.requestIdFor(members.first.id), isNull);
      expect(r.approveBlocker(r.byId(single.id)!), isNull);
      // 代表の案の内容が変わった依頼は、本体が受け付けないので、採用を止めない。
      r = HubRepository(VaultSnapshot(rewritten(waiting, lead.id))).review;
      expect(r.byId(lead.id)!.status, 'pending');
      expect(r.approveBlocker(r.byId(members.last.id)!), isNull);
      // 空白だけの別名は、名前として比べない（本体と同じ）。
      r = HubRepository(
        VaultSnapshot(
          withIndex(waiting, (items) {
            items.singleWhere((i) => i['id'] == single.id)['aliases'] = [' '];
            items.singleWhere((i) => i['id'] == members.first.id)['aliases'] = [
              '　',
              ...members.first.aliases,
            ];
          }),
        ),
      ).review;
      expect(r.warnings, isEmpty);
      expect(r.requestIdFor(members.first.id), idOf(saved));
      expect(r.approveBlocker(r.byId(single.id)!), isNull);
      // まとめた判断が反映された後は、採用を止めない。
      r = HubRepository(
        VaultSnapshot(
          withIndex({...waiting, ...accepted(saved)}, (items) {
            for (final id in [lead.id, members.first.id]) {
              items.singleWhere((i) => i['id'] == id)['status'] = 'rejected';
            }
            items.singleWhere((i) => i['id'] == members.first.id)['coveredBy'] =
                lead.id;
          }),
        ),
      ).review;
      expect(r.warnings, isEmpty);
      expect(r.byId(members.last.id)!.actionable, isTrue);
      expect(r.approveBlocker(r.byId(members.last.id)!), isNull);
      // まとめていない1件の依頼は、名前か別名が同じ案の採用を止めない（その依頼だけが受け付けられなくなる）。
      final alone = await request(7, members.last, 'reject');
      r = HubRepository(
        VaultSnapshot({...files, alone.key: alone.value}),
      ).review;
      expect(r.requestIdFor(members.last.id), idOf(alone));
      expect(r.approveBlocker(r.byId(lead.id)!), isNull);
      // 判断を依頼済みの案と、判断できない案（古い案など）には、採用を待つ理由を示さない。
      final own = await request(8, members.last, 'reject');
      r = HubRepository(VaultSnapshot({...waiting, own.key: own.value})).review;
      expect(r.requestIdFor(members.last.id), idOf(own));
      expect(r.approveBlocker(r.byId(members.last.id)!), isNull);
      r = HubRepository(
        VaultSnapshot(
          withIndex(
            waiting,
            (items) =>
                items.singleWhere((i) => i['id'] == members.last.id)['status'] =
                    'stale',
          ),
        ),
      ).review;
      expect(r.warnings, isEmpty);
      expect(r.byId(members.last.id)!.status, 'stale');
      expect(r.approveBlocker(r.byId(members.last.id)!), isNull);
      // 知識の候補の採用は、名前が同じでも止めない。
      r = HubRepository(
        VaultSnapshot(withKnowledge(waiting, lead.title)),
      ).review;
      expect(r.warnings, isEmpty);
      final knowledge = r.pending.singleWhere((i) => i.kind == 'knowledge');
      expect(knowledge.title, lead.title);
      expect(r.approveBlocker(knowledge), isNull);
    });

    test('まとめる案を選んで判断でき、確認した案と違う組は依頼しない', () async {
      final access = MemoryUIAccess(),
          files = inboxFiles(),
          c = await controllerOf(access, files),
          lead = leadOf(c.review!),
          members = c.review!.groupMembers(lead),
          single = c.review!.pendingRows.singleWhere((i) => i.id != lead.id);
      final all = await c.prepareReview(lead.id);
      expect(all.covers.map((m) => m.id), members.map((m) => m.id));
      // 確認の画面で示していない案、内容の違う案、同じ組でない案を含む依頼は保存しない。
      for (final covers in [
        [single],
        [members.first, single],
        [
          ReviewCandidate({...members.first.data, 'candidateHash': 'e' * 64}),
        ],
      ]) {
        await expectLater(
          c.submitReview(
            ReviewConfirmation(
              all.candidate,
              all.fingerprint,
              all.identity,
              all.epoch,
              covers: covers,
            ),
            'reject',
          ),
          throwsStateError,
        );
      }
      expect(access.writes, 0);
      // 別の取り組みの案を外して、残りだけをまとめて判断できる。
      final ticket = await c.prepareReview(
        lead.id,
        exclude: {members.first.id},
      );
      expect(ticket.covers.map((m) => m.id), [members.last.id]);
      final saved = await c.submitReview(ticket, 'reject');
      expect(saved.saved, isTrue);
      final raw = access.requests[saved.requestId]!,
          meta = parseMarkdown(raw).meta;
      expect(meta['cover_ids'], [members.last.id]);
      expect(meta['cover_hashes'], [members.last.candidateHash]);
      // 外した案は確認待ちに残り、1件として判断できる。
      await show(c, access, {...files, 'Input/${saved.requestId}.md': raw});
      expect(c.review!.requestIdFor(members.first.id), isNull);
      expect(
        c.review!.pendingRows.map((i) => i.id),
        contains(members.first.id),
      );
      expect((await c.prepareReview(members.first.id)).covers, isEmpty);
      // 依頼を保存した案は、内容を変えた依頼を重ねて保存しない。
      await show(c, access, files);
      await expectLater(
        c.prepareReview(lead.id).then((t) => c.submitReview(t, 'reject')),
        throwsStateError,
      );
      expect(access.writes, 1);
      // すべて外すと、代表の案だけの依頼になる（まとめの欄を付けない）。
      final other = MemoryUIAccess(),
          second = await controllerOf(other, files),
          alone = await second.submitReview(
            await second.prepareReview(
              lead.id,
              exclude: {for (final m in members) m.id},
            ),
            'reject',
          );
      expect(
        parseMarkdown(other.requests[alone.requestId]!).meta.keys,
        isNot(contains('cover_ids')),
      );
    });

    testWidgets('チェックを外した案を除いて、判断を依頼できる', (t) async {
      final files = inboxFiles(),
          a = MemoryUIAccess(),
          c = await sample(t, a, files);
      final lead = leadOf(c.review!), members = c.review!.groupMembers(lead);
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(find.text('3件をまとめて却下する'), findsOneWidget);
      // 別の取り組みの案のチェックを外すと、その案は判断から外れる。
      await t.tap(find.byKey(Key('review-include-${members.first.id}')));
      await t.pumpAndSettle();
      expect(find.text('2件をまとめて却下する'), findsOneWidget);
      await t.tap(find.text('2件をまとめて却下する'));
      await t.pumpAndSettle();
      expect(find.text('まとめた2件の案を却下しますか？'), findsOneWidget);
      expect(find.text('同じ判断にまとめる案: ${members.last.title}'), findsOneWidget);
      expect(find.text('同じ判断にまとめる案: ${members.first.title}'), findsNothing);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      // すべて外すと、代表の案だけの判断になる。
      await t.tap(find.byKey(Key('review-include-${members.last.id}')));
      await t.pumpAndSettle();
      expect(find.text('却下する'), findsOneWidget);
      // チェックを戻して依頼する。
      await t.tap(find.byKey(Key('review-include-${members.last.id}')));
      await t.pumpAndSettle();
      await t.tap(find.text('2件をまとめて却下する'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-review')));
      await t.pumpAndSettle();
      expect(a.writes, 1);
      final saved = a.requests.entries.single;
      expect(parseMarkdown(saved.value).meta['cover_ids'], [members.last.id]);
      // 保存した直後（依頼が同期される前）も、まとめる案を選び直せない。
      expect(
        t
            .widget<CheckboxListTile>(
              find.byKey(Key('review-include-${members.last.id}')),
            )
            .onChanged,
        isNull,
      );
      // 依頼が同期されると、外した案は1件として確認待ちに残る。
      a.current = VaultSnapshot({
        ...files,
        'Input/${saved.key}.md': saved.value,
      });
      await c.reload();
      await t.pumpAndSettle();
      // 依頼済みの案は、まとめる案を選び直せない。
      expect(
        t
            .widget<CheckboxListTile>(
              find.byKey(Key('review-include-${members.last.id}')),
            )
            .onChanged,
        isNull,
      );
      expect(
        find.byKey(Key('review-include-${members.first.id}')),
        findsNothing,
      );
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.text('確認待ち（3件）'), findsOneWidget);
      expect(find.byKey(Key('review-${members.first.id}')), findsOneWidget);
      // 開き直しても、依頼済みの案のまとめ方は変えられない。
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(
        t
            .widget<CheckboxListTile>(
              find.byKey(Key('review-include-${members.last.id}')),
            )
            .onChanged,
        isNull,
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('狭い画面でも、まとめる案の選択と判断のボタンがoverflowしない', (t) async {
      final a = MemoryUIAccess(),
          c = await sample(t, a, inboxFiles(), size: const Size(390, 844));
      final lead = leadOf(c.review!), members = c.review!.groupMembers(lead);
      Future<void> reach(Finder target) async {
        await t.scrollUntilVisible(
          target,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await t.pumpAndSettle();
        await t.ensureVisible(target);
        await t.pumpAndSettle();
      }

      await reach(find.byKey(const Key('home-review')));
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      await reach(find.byKey(Key('review-${lead.id}')));
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-group')), findsOneWidget);
      await reach(find.byKey(Key('review-include-${members.last.id}')));
      await t.tap(find.byKey(Key('review-include-${members.last.id}')));
      await t.pumpAndSettle();
      await reach(find.byKey(const Key('review-reject')));
      expect(find.text('2件をまとめて却下する'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('名前か別名が同じ案の採用が反映を待つ間は、まとめた判断のボタンを止めて理由を示す', (t) async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead);
      late MapEntry<String, String> approve;
      await t.runAsync(() async {
        approve = await request(1, members.last, 'approve');
      });
      final a = MemoryUIAccess();
      await sample(t, a, {...files, approve.key: approve.value});
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-group-blocked')), findsOneWidget);
      expect(find.byKey(const Key('review-approve-blocked')), findsNothing);
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('review-reject')))
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('review-approve')))
            .onPressed,
        isNull,
      );
      // まとめる案を外すと、代表の案だけを判断できる。
      await t.tap(find.byKey(Key('review-include-${members.first.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-group-blocked')), findsNothing);
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('review-reject')))
            .onPressed,
        isNotNull,
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('まとめた判断が反映を待つ間は、名前か別名が同じ案の採用のボタンを止めて理由を示す', (t) async {
      final files = inboxFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(before),
          members = before.groupMembers(lead);
      late MapEntry<String, String> grouped;
      await t.runAsync(() async {
        grouped = await request(1, lead, 'reject', covers: [members.first]);
      });
      final a = MemoryUIAccess();
      await sample(t, a, {...files, grouped.key: grouped.value});
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      // まとめた判断から外した案は、1件で並ぶ。
      await t.tap(find.byKey(Key('review-${members.last.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-approve-blocked')), findsOneWidget);
      expect(find.byKey(const Key('review-group-blocked')), findsNothing);
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('review-approve')))
            .onPressed,
        isNull,
      );
      // 却下は止めない。
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('review-reject')))
            .onPressed,
        isNotNull,
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('外した案が、ほかの端末のまとめた依頼に含まれて届いたら、依頼に含まれる案として示す', (t) async {
      final files = inboxFiles(),
          a = MemoryUIAccess(),
          c = await sample(t, a, files);
      final lead = leadOf(c.review!), members = c.review!.groupMembers(lead);
      late MapEntry<String, String> other;
      await t.runAsync(() async {
        other = await request(1, lead, 'reject', covers: members);
      });
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      CheckboxListTile box() => t.widget<CheckboxListTile>(
        find.byKey(Key('review-include-${members.first.id}')),
      );
      await t.tap(find.byKey(Key('review-include-${members.first.id}')));
      await t.pumpAndSettle();
      expect(box().value, isFalse);
      a.current = VaultSnapshot({...files, other.key: other.value});
      await c.reload();
      await t.pumpAndSettle();
      expect(box().value, isTrue);
      expect(box().onChanged, isNull);
      expect(t.takeException(), isNull);
    });

    testWidgets('この端末で読めない代表の案には、まとめた判断の表示を出さない', (t) async {
      final files = inboxFiles(),
          lead = leadOf(HubRepository(VaultSnapshot(files)).review),
          a = MemoryUIAccess();
      await sample(
        t,
        a,
        files..remove('90_system/project-confirmations/${lead.id}.json'),
      );
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(find.text('プロジェクト案 · 同期・形式の確認が必要'), findsOneWidget);
      // 判断していない案を「同じ判断にまとめた案」として示さない。
      expect(find.byKey(const Key('review-covers')), findsNothing);
      expect(find.byKey(const Key('review-group')), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('判断待ちの既読', () {
    test('代表の案を見た後で、まとめた案が1件ずつ見えても新着にしない', () {
      final files = inboxFiles(),
          repo = HubRepository(VaultSnapshot(files)),
          lead = leadOf(repo.review),
          members = repo.review.groupMembers(lead);
      // 代表の案だけが未同期になると、まとめた案が1件ずつ並ぶ。
      final partial = HubRepository(
        VaultSnapshot(
          {...files}..remove('90_system/project-confirmations/${lead.id}.json'),
        ),
      );
      expect(attentionComplete(partial), isFalse);
      final rows = attentionItems(partial);
      expect(rows.where((i) => i.kind == 'candidate'), hasLength(3));
      // はじめてのVaultでは、いまあるものを既読にする。まとめた案も同じ。
      var state = const AttentionState().sync('vault', attentionItems(repo));
      expect(state.unknown(rows), isEmpty);
      expect(state.fresh(rows), isEmpty);
      // 後から届いた組は、件数として出ただけなら未読で、通知は要らない。まとめた案も同じ。
      final single = attentionItems(repo).where(
        (i) => i.key != AttentionItem('candidate', lead.id, 'review').key,
      );
      state = const AttentionState()
          .sync('vault', single.toList())
          .sync('vault', attentionItems(repo));
      expect(state.unknown(rows), isEmpty);
      expect(
        state.fresh(rows).map((i) => i.key),
        unorderedEquals([
          for (final m in members)
            AttentionItem('candidate', m.id, 'review').key,
        ]),
      );
      // 一覧を開いて代表の案を見たら、まとめた案も見たものとして扱う。
      final seen = state.markSeen('review', attentionItems(repo));
      expect(seen.fresh(rows), isEmpty);
      expect(
        const AttentionState()
            .sync('vault', single.toList())
            .sync('vault', attentionItems(repo), visible: 'review')
            .fresh(rows),
        isEmpty,
      );
      // 判断待ちが欠けて見える間に並んだ行を覚えても、同期が済めば代表の1件に戻る。
      final restored = seen.sync('vault', rows, prune: false);
      expect(restored.fresh(attentionItems(repo)), isEmpty);
      expect(restored.unknown(attentionItems(repo)), isEmpty);
      // 先に1件ずつ見ていた案は、後から届いた代表の案にまとめられても既読のまま。
      final grouped = const AttentionState()
          .sync('vault', rows)
          .sync('vault', attentionItems(repo));
      expect(grouped.fresh(attentionItems(repo)).map((i) => i.key), [
        AttentionItem('candidate', lead.id, 'review').key,
      ]);
      expect(grouped.fresh(rows), isEmpty);
      // 端末に残す形は変えない（鍵と既読だけ）。
      expect(
        AttentionState.fromJson(jsonDecode(jsonEncode(seen.toJson()))),
        seen,
      );
    });
  });

  group('判断待ちの既読（組に加わった案）', () {
    test('代表の案を見た後で組に加わった案は、見るまで既読にしない', () {
      final files = inboxFiles(),
          repo = HubRepository(VaultSnapshot(files)),
          lead = leadOf(repo.review),
          members = repo.review.groupMembers(lead),
          // 一覧を閉じた後で、新しい案が同じ組に加わる。
          more = clones(
            1,
            of: members.first.title,
          ),
          grown = HubRepository(VaultSnapshot(more)),
          added = AttentionItem('candidate', 'PCAN-${'0' * 26}', 'review');
      expect(
        grown.review.groupMembers(leadOf(grown.review)).map((m) => m.id),
        contains('PCAN-${'0' * 26}'),
      );
      // 代表の案だけが未同期になると、まとめた案が1件ずつ並ぶ。
      final rows = attentionItems(
        HubRepository(
          VaultSnapshot(
            {...more}
              ..remove('90_system/project-confirmations/${lead.id}.json'),
          ),
        ),
      );
      expect(rows.map((i) => i.key), contains(added.key));
      final seen = const AttentionState().sync('vault', attentionItems(repo)),
          joined = seen.sync('vault', attentionItems(grown));
      // 加わった案だけを新着として示す。組の件数としては出ていたので、通知はしない。
      expect(joined.fresh(rows).map((i) => i.key), [added.key]);
      expect(joined.unknown(rows), isEmpty);
      // 一覧で代表の案を見ると、加わった案も見たものとして扱う。
      expect(
        joined.markSeen('review', attentionItems(grown)).fresh(rows),
        isEmpty,
      );
      expect(
        seen
            .sync('vault', attentionItems(grown), visible: 'review')
            .fresh(rows),
        isEmpty,
      );
    });
  });

  group('依頼の検証', () {
    test('まとめられない案を含む依頼は保存しない', () async {
      final r = HubRepository(VaultSnapshot(inboxFiles())).review,
          lead = leadOf(r),
          members = r.groupMembers(lead),
          access = MemoryUIAccess(),
          service = ReviewService(access, location);
      ReviewCandidate changed(Map<String, dynamic> data, {String? status}) =>
          ReviewCandidate({...members.first.data, ...data}, status: status);
      final many = [
        for (var n = 0; n <= maxProposalCovers; n++)
          changed({'id': 'PCAN-${n.toString().padLeft(26, '0')}'}),
      ];
      for (final (index, covers) in [
        // 確認待ちでない案、プロジェクト案でない候補、IDやhashが不正な案。
        [changed({}, status: 'stale')],
        [
          changed({'kind': 'knowledge'}),
        ],
        [
          changed({'id': 'CAN-${members.first.id.substring(5)}'}),
        ],
        [
          changed({'candidateHash': 'abc'}),
        ],
        // 上限を超える数。
        many,
      ].indexed) {
        await expectLater(
          service.submit(uuid(index), lead, 'reject', covers: covers),
          throwsFormatException,
          reason: '$index',
        );
      }
      expect(access.writes, 0);
      // 上限ちょうどは保存できる。
      expect(
        (await service.submit(
          uuid(90),
          lead,
          'reject',
          covers: many.take(maxProposalCovers).toList(),
        )).saved,
        isTrue,
      );
      // 知識の候補の判断には、まとめる案を付けられない。
      final files = reviewFiles(),
          knowledge = HubRepository(
            VaultSnapshot(files),
          ).review.pending.firstWhere((c) => c.kind != 'project');
      await expectLater(
        service.submit(uuid(91), knowledge, 'reject', covers: members),
        throwsFormatException,
      );
      expect(access.writes, 1);
    });

    test('まとめる案の欄が不正な依頼は、受付状況で形式の不備として扱う', () async {
      final files = inboxFiles(),
          r = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(r),
          members = r.groupMembers(lead),
          saved = await request(1, lead, 'reject', covers: members),
          meta = parseMarkdown(saved.value).meta,
          ids = [for (final m in members) m.id],
          hashes = [for (final m in members) m.candidateHash];
      HubRepository withRequest(Map<String, dynamic> change) => HubRepository(
        VaultSnapshot({
          ...files,
          saved.key: encodePacket(
            {...meta, ...change}..removeWhere((_, v) => v == null),
            '',
          ),
        }),
      );
      expect(withRequest({}).warnings, isEmpty);
      final extra = [
        for (var n = 0; n <= maxProposalCovers; n++)
          'PCAN-${n.toString().padLeft(26, '0')}',
      ];
      // 上限ちょうどは読める。
      expect(
        withRequest({
          'cover_ids': extra.take(maxProposalCovers).toList(),
          'cover_hashes': [
            for (var n = 0; n < maxProposalCovers; n++) hashes.first,
          ],
        }).warnings,
        isEmpty,
      );
      for (final (index, change) in <Map<String, dynamic>>[
        {'cover_ids': null},
        {'cover_hashes': null},
        {'cover_ids': ids.first, 'cover_hashes': hashes.first},
        {'cover_ids': <String>[], 'cover_hashes': <String>[]},
        {
          'cover_ids': extra,
          'cover_hashes': [for (final _ in extra) hashes.first],
        },
        {
          'cover_hashes': [hashes.first],
        },
        {
          'cover_ids': [ids.first, ids.first],
        },
        {
          'cover_ids': [ids.first, lead.id],
        },
        {
          'cover_ids': [ids.first, 'CAN-${ids.last.substring(5)}'],
        },
        {
          'cover_ids': [ids.first, 1],
        },
        {
          'cover_hashes': [hashes.first, 'abc'],
        },
        {
          'cover_hashes': [hashes.first, 1],
        },
      ].indexed) {
        final repo = withRequest(change);
        expect(repo.warnings.single, contains(saved.key), reason: '$index');
      }
      // 知識の候補の依頼には、まとめる案の欄を付けられない。
      final review = reviewFiles(),
          knowledge = HubRepository(
            VaultSnapshot(review),
          ).review.pending.firstWhere((c) => c.kind != 'project'),
          access = MemoryUIAccess(),
          result = await ReviewService(
            access,
            location,
          ).submit(uuid(2), knowledge, 'reject'),
          path = 'Input/${result.requestId}.md',
          raw = access.requests[result.requestId]!;
      expect(
        HubRepository(VaultSnapshot({...review, path: raw})).warnings,
        isEmpty,
      );
      expect(
        HubRepository(
          VaultSnapshot({
            ...review,
            path: encodePacket({
              ...parseMarkdown(raw).meta,
              'cover_ids': ids,
              'cover_hashes': hashes,
            }, ''),
          }),
        ).warnings.single,
        contains(path),
      );
    });

    test('プロジェクト案でない候補のまとめは操作対象から外す', () async {
      final files = reviewFiles(),
          before = HubRepository(VaultSnapshot(files)).review,
          knowledge = before.pending.firstWhere((c) => c.kind != 'project');
      expect(before.warnings, isEmpty);
      final r = HubRepository(
        VaultSnapshot(
          withIndex(files, (items) {
            items.singleWhere((i) => i['id'] == knowledge.id)['duplicates'] = [
              'PCAN-${knowledge.id.substring(4)}',
            ];
          }),
        ),
      ).review;
      expect(r.byId(knowledge.id), isNull);
      expect(r.warnings, isNotEmpty);
    });
  });

  group('プロジェクト未定と短いメモ', () {
    /// メモへの訂正の原文。
    Map<String, String> correction(String id, String target) => {
      '00_inbox/2026-11-08_$id.md': encodePacket({
        'schema_version': 1,
        'id': id,
        'kind': 'correction',
        'corrects_input_id': target,
        'source': 'cli',
        'source_event_id': 'correction-$id',
        'occurred_at': '2026-11-08T00:00:00Z',
        'received_at': '2026-11-08T00:00:00Z',
      }, '訂正した本文'),
    };

    /// 訂正の原文と、その訂正までを整理した記録。
    Map<String, String> organized(
      Map<String, String> files,
      String id,
      String target,
    ) {
      final added = correction(id, target),
          path = files.keys.singleWhere(
            (p) => p.startsWith('00_inbox/') && p.endsWith('_$target.md'),
          ),
          receipt =
              jsonDecode(files['90_system/receipts/$target.json']!)
                  as Map<String, dynamic>;
      return {
        ...added,
        '90_system/receipts/$id.json': jsonEncode({
          ...receipt,
          'input_id': id,
          'input_hash': digest(added.values.single),
          'root_input_id': target,
          'evidence_ids': [target, id],
          'evidence_hash': digest(
            '$target:${digest(files[path]!)}\n$id:${digest(added.values.single)}',
          ),
        }),
      };
    }

    test('訂正が届いたメモは、一覧が訂正を反映するまで載せない', () {
      const first = 'IN-00000000000000000000000001';
      final files = inboxFiles(),
          memos = HubRepository(VaultSnapshot(files)).unassignedMemos,
          long = memos.firstWhere((m) => !m.ownWords),
          short = memos.firstWhere((m) => m.ownWords);
      List<String> listed(Map<String, String> more) => [
        for (final m in HubRepository(
          VaultSnapshot({...files, ...more}),
        ).unassignedMemos)
          m.inputId,
      ];
      // 本人の言葉として載っているメモに訂正が届いたら、訂正前の言葉を示さない。
      expect(
        listed(correction(first, short.inputId)),
        isNot(contains(short.inputId)),
      );
      expect(
        listed(correction(first, short.inputId)),
        hasLength(memos.length - 1),
      );
      // AIの要約として載っているメモも、訂正の整理を待つ間は載せない。
      expect(
        listed(correction(first, long.inputId)),
        isNot(contains(long.inputId)),
      );
      // 訂正が整理された後の一覧（AIの要約）は載せる。
      final repo = HubRepository(
        VaultSnapshot({...files, ...organized(files, first, long.inputId)}),
      );
      expect(repo.warnings, isEmpty);
      expect(
        repo.unassignedMemos.map((m) => m.inputId),
        contains(long.inputId),
      );
      // 訂正が整理された後でも、本人の言葉として載っている行は訂正前の一覧なので載せない。
      expect(
        listed(organized(files, first, short.inputId)),
        isNot(contains(short.inputId)),
      );
    });

    test('一覧の件数と提案の数の上限を確かめる', () {
      Map<String, String> changed(void Function(Map<String, dynamic>) change) {
        final files = inboxFiles(),
            j = jsonDecode(files[unassignedPath]!) as Map<String, dynamic>;
        change(j);
        return {...files, unassignedPath: jsonEncode(j)};
      }

      Map<String, dynamic> firstOf(Map<String, dynamic> j) =>
          (j['memos'] as List).first as Map<String, dynamic>;
      // 提案は10件まで。
      var repo = HubRepository(
        VaultSnapshot(
          changed(
            (j) => firstOf(j)['suggestions'] = [
              for (var n = 0; n < 10; n++) '提案$n',
            ],
          ),
        ),
      );
      expect(repo.warnings, isEmpty);
      expect(repo.unassignedMemos.first.suggestions, hasLength(10));
      repo = HubRepository(
        VaultSnapshot(
          changed(
            (j) => firstOf(j)['suggestions'] = [
              for (var n = 0; n < 11; n++) '提案$n',
            ],
          ),
        ),
      );
      expect(repo.warnings.single, contains(unassignedPath));
      expect(repo.unassignedMemos, isEmpty);
      // 同じメモの行が2つある一覧は使わない。
      repo = HubRepository(
        VaultSnapshot(
          changed((j) {
            (j['memos'] as List).add(firstOf(j));
            j['total_memos'] = (j['memos'] as List).length;
          }),
        ),
      );
      expect(repo.warnings.single, contains(unassignedPath));
      expect(repo.unassignedMemos, isEmpty);
      // メモは200件まで。
      Map<String, String> many(int count) {
        final files = manyUnassigned(count),
            j = jsonDecode(files[unassignedPath]!) as Map<String, dynamic>;
        return {
          ...files,
          unassignedPath: jsonEncode({...j, 'total_memos': count}),
        };
      }

      repo = HubRepository(VaultSnapshot(many(200)));
      expect(repo.warnings, isEmpty);
      expect(repo.unassignedMemos, hasLength(200));
      repo = HubRepository(VaultSnapshot(many(201)));
      expect(repo.warnings.single, contains(unassignedPath));
      expect(repo.unassignedMemos, isEmpty);
      // 訂正の原文を指す行は載せない（一覧は元のメモを指す）。
      const id = 'IN-00000000000000000000000001';
      final files = inboxFiles(),
          target = HubRepository(VaultSnapshot(files)).unassignedMemos.last;
      repo = HubRepository(
        VaultSnapshot({
          ...changed((j) => firstOf(j)['input_id'] = id),
          ...organized(files, id, target.inputId),
        }),
      );
      expect(repo.warnings, isEmpty);
      expect(repo.unassignedMemos, hasLength(3));
      expect(repo.unassignedMemos.map((m) => m.inputId), isNot(contains(id)));
    });

    test('短いメモは、100文字までを文字数で数える', () {
      expect(shortMemoText('あ' * 100), 'あ' * 100);
      expect(shortMemoText('あ' * 101), isNull);
      // 絵文字のようにUTF-16で2単位になる文字も、1文字と数える。
      expect(shortMemoText('😀' * 100), '😀' * 100);
      expect(shortMemoText('😀' * 101), isNull);
      // 空白と改行は1つの空白にまとめてから数える。
      expect(shortMemoText('  買い物\n\n  メモ  '), '買い物 メモ');
      expect(shortMemoText('${'あ' * 50}\n\n\n${'い' * 49}'), hasLength(100));
      expect(shortMemoText(' \n '), isNull);
    });

    test('作業要約から作られたアイデアは、AIの要約を題にする', () {
      const own = '読んだ本の感想を1か所に集めたい', summary = '本の感想を一元管理する構想';
      final files = inboxFiles(),
          path = files.keys.singleWhere(
            (p) => p.startsWith('20_ideas/') && files[p]!.contains('\n$own\n'),
          );
      files[path] = reseal(
        files[path]!.replaceFirst('\n$own\n', '\n$summary\n'),
      );
      HubRecord idea(Map<String, String> files) => HubRepository(
        VaultSnapshot(files),
      ).records.values.singleWhere((r) => r.path == path);
      final input = (idea(files).metadata['input_ids'] as List).single,
          memo = files.keys.singleWhere(
            (p) => p.startsWith('00_inbox/') && p.endsWith('_$input.md'),
          );
      expect(idea(files).title, own);
      // 作業要約は抽出が要るので、短くても本人の言葉を題にしない。
      expect(
        idea({
          ...files,
          memo: files[memo]!.replaceFirst('kind: memo', 'kind: work-summary'),
        }).title,
        summary,
      );
    });

    testWidgets('ホームのプロジェクト案は3件まで出し、ホームから開くと次の一手の欄と最初の10件に戻る', (t) async {
      final files = clones(3, of: '家計の見直し', grouped: false),
          unassigned = manyUnassigned(12);
      final a = MemoryUIAccess(),
          c = await sample(t, a, {
            ...files,
            for (final e in unassigned.entries)
              if (e.key.startsWith('00_inbox/') || e.key == unassignedPath)
                e.key: e.value,
          }, size: const Size(1280, 6000));
      expect(c.repository!.warnings, isEmpty);
      expect(c.review!.pendingRows, hasLength(5));
      expect(find.text('確認待ち 5件'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('home-proposal-'),
        ),
        findsNWidgets(3),
      );
      // 「次の一手」で未解決の欄へ切り替え、プロジェクト未定のメモを追加で表示しておく。
      await t.tap(find.byKey(const Key('home-unassigned')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('unassigned-more')));
      await t.pumpAndSettle();
      expect(find.text('複製したメモ11'), findsOneWidget);
      await t.tap(find.text('未解決 0件'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('next-unassigned')), findsNothing);
      // ホームから開き直すと、次の一手の欄と最初の10件に戻る。
      await t.tap(find.byKey(const Key('nav-home')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-unassigned')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('next-unassigned')), findsOneWidget);
      expect(find.text('複製したメモ9'), findsOneWidget);
      expect(find.text('複製したメモ11'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
