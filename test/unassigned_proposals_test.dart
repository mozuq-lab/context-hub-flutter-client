import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/attention.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/review_candidates.dart';
import 'package:context_hub_client/storage/review_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location, op;
import 'controller_test.dart' show UIAccess;
import 'review_test.dart' show nativeReviewFiles;
import 'widget_test.dart' show MemoryUIAccess;

/// 本体が生成した、プロジェクト未定のメモと同じ対象を指すプロジェクト案の組を含む架空のVault。
Map<String, dynamic> inboxFixture() =>
    jsonDecode(
          File(
            'test/fixtures/unassigned-and-proposals.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
Map<String, String> inboxFiles() =>
    Map<String, String>.from(inboxFixture()['files'] as Map);
Map<String, dynamic> get expected =>
    inboxFixture()['expected'] as Map<String, dynamic>;
const unassignedPath = '90_system/unassigned-actions.json';

/// 生成物の本文を書き換えたあと、整合性の印（generated_hash）を付け直す。
String reseal(String raw) {
  final line = RegExp(
    r'^generated_hash: sha256:[a-f0-9]{64}\n',
    multiLine: true,
  );
  return raw.replaceFirst(
    line,
    'generated_hash: sha256:${digest(raw.replaceFirst(line, ''))}\n',
  );
}

/// 一覧の先頭のメモを複製して、プロジェクト未定のメモを[count]件にする。
Map<String, String> manyUnassigned(int count) {
  final files = inboxFiles(),
      list = jsonDecode(files[unassignedPath]!) as Map<String, dynamic>,
      first = Map<String, dynamic>.from((list['memos'] as List).first as Map),
      id = first['input_id'] as String,
      path = first['path'] as String,
      memos = <Map<String, dynamic>>[];
  for (var n = 0; n < count; n++) {
    final copy = 'IN-${n.toString().padLeft(26, '0')}',
        copyPath = '00_inbox/2026-11-07_$copy.md';
    files[copyPath] = files[path]!.replaceAll(id, copy);
    memos.add({
      ...first,
      'input_id': copy,
      'path': copyPath,
      'text': '複製したメモ$n',
      'own_words': true,
    });
  }
  files[unassignedPath] = jsonEncode({
    ...list,
    'total_memos': count + 3,
    'memos': memos,
  });
  return files;
}

ReviewCandidate leadOf(ReviewRepository r) =>
    r.pendingRows.singleWhere((i) => i.title == expected['lead']);

Future<HubController> sample(
  WidgetTester t,
  MemoryUIAccess a,
  Map<String, String> files, {
  Size size = const Size(1280, 4000),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  a.current = VaultSnapshot(files);
  final c = HubController(a, sampleLoader: () async => files);
  addTearDown(() {
    c.dispose();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(ContextHubApp(controller: c));
  await t.pumpAndSettle();
  await c.useSample();
  await t.pumpAndSettle();
  return c;
}

void main() {
  group('プロジェクト未定の次の一手', () {
    test('本体の一覧から、タスクの分類とAIの提案を新しい順に読む', () {
      final repo = HubRepository(VaultSnapshot(inboxFiles()));
      expect(repo.warnings, isEmpty);
      expect(repo.unassignedTotal, expected['unassigned']);
      expect(repo.unassignedMemos.map((m) => m.text), expected['texts']);
      // 長いメモはAIの一行要約、短いメモは本人の言葉。
      final long = repo.unassignedMemos.first;
      expect(long.ownWords, isFalse);
      expect(long.task, isTrue);
      expect(long.suggestions, hasLength(4));
      expect(repo.unassignedMemos.last.ownWords, isTrue);
      expect(repo.unassignedMemos.last.suggestions, isEmpty);
      for (final memo in repo.unassignedMemos) {
        expect(repo.inputRecord(memo.inputId)!.kind, 'memo');
      }
      // プロジェクトに結び付いたメモは載らない。
      expect(
        repo.unassignedMemos.map((m) => m.text),
        isNot(contains('家庭菜園の土を入れ替える')),
      );
    });

    test('原文が届いていないメモは載せず、全体の件数は本体の値を示す', () {
      final files = inboxFiles(),
          first = HubRepository(VaultSnapshot(files)).unassignedMemos.first;
      files.removeWhere(
        (path, _) =>
            path.startsWith('00_inbox/') &&
            path.endsWith('_${first.inputId}.md'),
      );
      final repo = HubRepository(VaultSnapshot(files));
      expect(
        repo.unassignedMemos.map((m) => m.inputId),
        isNot(contains(first.inputId)),
      );
      expect(repo.unassignedMemos, hasLength(4));
      expect(repo.unassignedTotal, 5);
    });

    test('形式が不正な一覧は注意を出して使わず、資料のコピーは止めない', () {
      final changes = <void Function(Map<String, dynamic>)>[
        (j) => j.remove('total_memos'),
        (j) => j['total_memos'] = 1,
        (j) => ((j['memos'] as List).first as Map).remove('own_words'),
        (j) => ((j['memos'] as List).first as Map)['text'] = ' ',
        (j) => ((j['memos'] as List).first as Map)['suggestions'] = [1],
        (j) => (j['memos'] as List).add((j['memos'] as List).first),
      ];
      for (final (index, change) in changes.indexed) {
        final files = inboxFiles(),
            j = jsonDecode(files[unassignedPath]!) as Map<String, dynamic>;
        change(j);
        files[unassignedPath] = jsonEncode(j);
        final repo = HubRepository(VaultSnapshot(files));
        expect(repo.unassignedMemos, isEmpty, reason: '$index');
        expect(repo.unassignedTotal, 0, reason: '$index');
        expect(
          repo.warnings.single,
          contains(unassignedPath),
          reason: '$index',
        );
        expect(repo.copyBlocked(), isFalse, reason: '$index');
      }
      // 本体が新しい形式で書いた一覧は、アプリの更新を案内する。
      final files = inboxFiles(),
          j = jsonDecode(files[unassignedPath]!) as Map<String, dynamic>;
      files[unassignedPath] = jsonEncode({...j, 'schema_version': 2});
      final newer = HubRepository(VaultSnapshot(files));
      expect(newer.unassignedMemos, isEmpty);
      expect(newer.newerFormat, isTrue);
      // 本体が一覧を書いていない（対応前の本体）ときは、何も出さない。
      final old = HubRepository(
        VaultSnapshot(inboxFiles()..remove(unassignedPath)),
      );
      expect(old.unassignedMemos, isEmpty);
      expect(old.warnings, isEmpty);
    });

    testWidgets('ホームに新しい3件を出し、「次の一手」の画面でメモと提案を並べて元のメモを開ける', (t) async {
      final a = MemoryUIAccess(), c = await sample(t, a, inboxFiles());
      final memos = c.repository!.unassignedMemos;
      expect(find.text('プロジェクト未定の次の一手 メモ5件'), findsOneWidget);
      for (final (index, memo) in memos.indexed) {
        expect(
          find.byKey(Key('home-unassigned-${memo.inputId}')),
          index < 3 ? findsOneWidget : findsNothing,
        );
      }
      await t.tap(find.byKey(const Key('home-unassigned')));
      await t.pumpAndSettle();
      expect(find.text('プロジェクト未定（メモ5件）'), findsOneWidget);
      for (final memo in memos) {
        final entry = find.byKey(Key('unassigned-${memo.inputId}'));
        expect(
          find.descendant(of: entry, matching: find.text(memo.text)),
          findsOneWidget,
        );
        // 完了の報告や期日の対象ではない。
        expect(
          find.descendant(of: entry, matching: find.textContaining('完了にする')),
          findsNothing,
        );
        expect(
          find.descendant(of: entry, matching: find.textContaining('日付')),
          findsNothing,
        );
      }
      // 長いメモはAIの要約として、短いメモは本人のメモとして示す。提案はすべて並べる。
      expect(find.text('2026-11-07 · AIの要約・未検証 · AIがタスクと分類'), findsOneWidget);
      expect(find.text('2026-11-04 · 本人のメモ'), findsOneWidget);
      expect(find.text('AI提案: 荷造りの日を決める'), findsOneWidget);
      await t.tap(find.byKey(Key('unassigned-open-${memos.last.inputId}')));
      await t.pumpAndSettle();
      expect(find.text('出典・日時'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      // 「未解決」の欄には出さない。
      await t.tap(find.text('未解決 0件'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('next-unassigned')), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('メモが多いときは10件ずつ出し、載せていない件数を示す', (t) async {
      final a = MemoryUIAccess();
      await sample(t, a, manyUnassigned(12), size: const Size(1280, 6000));
      await t.tap(find.byKey(const Key('home-unassigned')));
      await t.pumpAndSettle();
      expect(find.text('プロジェクト未定（メモ15件）'), findsOneWidget);
      expect(find.text('複製したメモ9'), findsOneWidget);
      expect(find.text('複製したメモ10'), findsNothing);
      expect(find.text('さらに表示（残り2件）'), findsOneWidget);
      await t.tap(find.byKey(const Key('unassigned-more')));
      await t.pumpAndSettle();
      expect(find.text('複製したメモ11'), findsOneWidget);
      expect(find.byKey(const Key('unassigned-more')), findsNothing);
      expect(find.byKey(const Key('unassigned-rest')), findsOneWidget);
      expect(find.textContaining('ほか3件'), findsOneWidget);
    });

    testWidgets('狭い画面でもホームと「次の一手」がoverflowしない', (t) async {
      final a = MemoryUIAccess();
      await sample(t, a, inboxFiles(), size: const Size(390, 844));
      await t.scrollUntilVisible(
        find.byKey(const Key('home-digest')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(
        find.byKey(const Key('home-unassigned')),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-unassigned')));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('AI提案: 荷造りの日を決める'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });

  group('短いメモの題', () {
    test('訂正のない短いメモ1件から作られたアイデアは、AIの言い換えではなく本人の言葉を題にする', () {
      const own = '読んだ本の感想を1か所に集めたい', summary = '本の感想を一元管理する構想';
      final files = inboxFiles(),
          path = files.keys.singleWhere(
            (p) => p.startsWith('20_ideas/') && files[p]!.contains('\n$own\n'),
          );
      // 対応前の本体が整理したアイデアは、本文にAIの要約を持つ。
      files[path] = reseal(
        files[path]!.replaceFirst('\n$own\n', '\n$summary\n'),
      );
      HubRecord idea(Map<String, String> files) => HubRepository(
        VaultSnapshot(files),
      ).records.values.singleWhere((r) => r.path == path);
      final record = idea(files);
      expect(record.warnings, isNot(contains('生成物の整合性を確認できません。')));
      expect(record.title, own);
      expect(record.body, contains(summary));
      // 訂正が届いたメモは、訂正を重ねた解釈（AIの要約）を題にする。
      final input = record.metadata['input_ids'] as List;
      const correction = 'IN-00000000000000000000000001';
      expect(
        idea({
          ...files,
          '00_inbox/2026-11-08_$correction.md': encodePacket({
            'schema_version': 1,
            'id': correction,
            'kind': 'correction',
            'corrects_input_id': input.single,
            'source': 'cli',
            'source_event_id': 'correction',
            'occurred_at': '2026-11-08T00:00:00Z',
            'received_at': '2026-11-08T00:00:00Z',
          }, '感想ではなく引用を集めたい'),
        }).title,
        summary,
      );
      // 長いメモから作られたアイデアは、AIの要約を題にする。
      final memo = files.keys.singleWhere(
        (p) => p.startsWith('00_inbox/') && p.endsWith('_${input.single}.md'),
      );
      expect(
        idea({
          ...files,
          memo: files[memo]!.replaceFirst(own, '長い思いつきを書き連ねる。' * 10),
        }).title,
        summary,
      );
    });
  });

  group('同じ対象を指すプロジェクト案', () {
    test('本体がまとめた案を、代表の1件として数える', () {
      final repo = HubRepository(VaultSnapshot(inboxFiles())), r = repo.review;
      expect(r.warnings, isEmpty);
      expect(r.pending, hasLength(expected['pending']));
      expect(r.pendingRows, hasLength(expected['rows']));
      final lead = leadOf(r), members = r.groupMembers(lead);
      expect(members.map((m) => m.title), expected['members']);
      expect(r.groupLead(lead), isNull);
      for (final member in members) {
        expect(r.groupLead(member)!.id, lead.id);
        expect(r.groupMembers(member), isEmpty);
        // まとめを知らない版のアプリでも1件ずつ判断できるよう、確認情報は残っている。
        expect(member.actionable, isTrue);
        expect(member.confirmationToken, isNotNull);
      }
      // 判断待ちの件数とホーム画面ウィジェットも、1組を1件と数える。
      expect(
        attentionItems(repo).where((i) => i.kind == 'candidate'),
        hasLength(expected['rows']),
      );
      expect(homeWidgetContent(repo)['counts'], contains('確認待ち 2件'));
    });

    test('代表の案やまとめた案をこの端末で読めないときは、読めている案だけをまとめる', () {
      final all = HubRepository(VaultSnapshot(inboxFiles())).review,
          lead = leadOf(all),
          members = all.groupMembers(lead);
      // 代表の案が読めなければ、まとめずに1件ずつ示す。
      var files = inboxFiles()
        ..remove('90_system/project-confirmations/${lead.id}.json');
      var r = HubRepository(VaultSnapshot(files)).review;
      expect(r.byId(lead.id)!.status, 'unavailable');
      expect(
        r.pendingRows.map((i) => i.id),
        containsAll(members.map((m) => m.id)),
      );
      expect(r.pendingRows, hasLength(3));
      expect(r.groupLead(r.byId(members.first.id)!), isNull);
      // まとめた案の1件が読めなければ、残りだけをまとめる。
      files = inboxFiles()
        ..remove('90_system/project-confirmations/${members.first.id}.json');
      r = HubRepository(VaultSnapshot(files)).review;
      expect(r.groupMembers(r.byId(lead.id)!).map((m) => m.id), [
        members.last.id,
      ]);
      expect(r.pendingRows, hasLength(2));
      expect(r.attention.map((i) => i.id), [members.first.id]);
    });

    test('まとめの形式が不正な候補は操作対象から外す', () {
      final changes = <void Function(Map<String, dynamic>, String)>[
        (item, other) => item['duplicateOf'] = item['id'],
        (item, other) => item['duplicateOf'] = 'CAN-${other.substring(5)}',
        (item, other) => item['duplicates'] = <String>[],
        (item, other) => item['duplicates'] = [other, other],
        (item, other) => item
          ..['duplicates'] = [other]
          ..['duplicateOf'] = other,
        (item, other) => item['coveredBy'] = 1,
      ];
      for (final (index, change) in changes.indexed) {
        final files = inboxFiles(),
            root =
                jsonDecode(files['90_system/review/index.json']!)
                    as Map<String, dynamic>,
            items = (root['items'] as List).cast<Map<String, dynamic>>(),
            single = items.singleWhere((i) => i['title'] == '家計の見直し'),
            other =
                items.firstWhere((i) => i['title'] == expected['lead'])['id']
                    as String;
        change(single, other);
        files['90_system/review/index.json'] = jsonEncode(root);
        final r = HubRepository(VaultSnapshot(files)).review;
        expect(r.byId(single['id'] as String), isNull, reason: '$index');
        expect(r.warnings, isNotEmpty, reason: '$index');
        // ほかの候補はそのまま読める。
        expect(r.pendingRows, hasLength(1), reason: '$index');
      }
    });

    test('まとめた案を含めて却下を依頼し、反映を待つ間も1件として示す', () async {
      final access = TempAccess();
      await access.init();
      addTearDown(() => access.directory.delete(recursive: true));
      final files = inboxFiles(),
          r = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(r),
          covers = r.groupMembers(lead),
          service = ReviewService(access, location);
      // 代表の案そのものと、同じ案の重複は、まとめられない（ほかの条件は proposal_requests_test.dart）。
      await expectLater(
        service.submit(op, lead, 'reject', covers: [lead]),
        throwsFormatException,
      );
      await expectLater(
        service.submit(
          op,
          lead,
          'reject',
          covers: [covers.first, covers.first],
        ),
        throwsFormatException,
      );
      expect(access.writes, 0);
      final result = await service.submit(op, lead, 'reject', covers: covers);
      expect(result.saved, isTrue);
      final raw = (await access.readRequest(location, result.requestId))!,
          packet = parseMarkdown(raw);
      expect(packet.body, '');
      expect(packet.meta['operation'], 'project-reject');
      expect(packet.meta['candidate_id'], lead.id);
      expect(packet.meta['cover_ids'], [for (final c in covers) c.id]);
      expect(packet.meta['cover_hashes'], [
        for (final c in covers) c.candidateHash,
      ]);
      // まとめる案がない依頼には、まとめの欄を付けない（対応前の本体でも受理できる）。
      const second = '22222222-2222-4333-8444-555555555555';
      final single = r.pendingRows.singleWhere((i) => i.id != lead.id),
          alone = await service.submit(second, single, 'reject');
      expect(
        parseMarkdown(
          (await access.readRequest(location, alone.requestId))!,
        ).meta.keys,
        isNot(contains('cover_ids')),
      );
      // 依頼を保存した後も、まとめた案は代表の行に含めたまま、依頼済みとして扱う。
      final after = HubRepository(
        VaultSnapshot({...files, 'Input/${result.requestId}.md': raw}),
      );
      expect(after.warnings, isEmpty);
      expect(after.review.requestIdFor(lead.id), result.requestId);
      for (final c in covers) {
        expect(after.review.requestIdFor(c.id), result.requestId);
      }
      expect(after.review.pendingRows, hasLength(2));
      expect(
        after.review.groupMembers(after.review.byId(lead.id)!),
        hasLength(covers.length),
      );
      expect(
        attentionItems(after).where((i) => i.kind == 'candidate'),
        hasLength(1),
      );
      expect(after.intake.single.title, contains('同じ対象の案2件をまとめて判断'));
      // まとめる案の欄が不正な依頼は、受付状況で形式の不備として扱う。
      final broken = HubRepository(
        VaultSnapshot({
          ...files,
          'Input/${result.requestId}.md': encodePacket({
            ...packet.meta,
            'cover_hashes': [covers.first.candidateHash],
          }, ''),
        }),
      );
      expect(broken.warnings.single, contains('Input/${result.requestId}.md'));
    });

    test('その案だけの判断を依頼済みの案は、まとめから外す', () async {
      final access = TempAccess();
      await access.init();
      addTearDown(() => access.directory.delete(recursive: true));
      final files = inboxFiles(),
          r = HubRepository(VaultSnapshot(files)).review,
          lead = leadOf(r),
          members = r.groupMembers(lead),
          result = await ReviewService(
            access,
            location,
          ).submit(op, members.first, 'reject');
      final raw = (await access.readRequest(location, result.requestId))!;
      expect(parseMarkdown(raw).meta.keys, isNot(contains('cover_ids')));
      final after = HubRepository(
        VaultSnapshot({...files, 'Input/${result.requestId}.md': raw}),
      ).review;
      expect(after.groupMembers(after.byId(lead.id)!).map((m) => m.id), [
        members.last.id,
      ]);
      expect(after.pendingRows.map((i) => i.id), contains(members.first.id));
      expect(after.requestIdFor(lead.id), isNull);
    });

    for (final action in ['approve', 'reject']) {
      test(
        'Dartのまとめた$actionを固定上流で受理し、まとめた案にも同じ判断を記録する',
        () async {
          final access = TempAccess();
          await access.init();
          addTearDown(() => access.directory.delete(recursive: true));
          final r = HubRepository(VaultSnapshot(inboxFiles())).review,
              lead = leadOf(r),
              covers = r.groupMembers(lead);
          final result = await ReviewService(
            access,
            location,
          ).submit(op, lead, action, covers: covers);
          final output = '${access.directory.path}/after.json';
          final node = await Process.run('node', [
            'scripts/check_grouped_review_protocol.mjs',
            access.request(location, result.requestId).path,
            'test/fixtures/unassigned-and-proposals.json',
            output,
          ]);
          expect(node.exitCode, 0, reason: '${node.stdout}\n${node.stderr}');
          final files = Map<String, String>.from(
            jsonDecode(await File(output).readAsString()) as Map,
          );
          final repo = HubRepository(VaultSnapshot(nativeReviewFiles(files))),
              status = action == 'approve' ? 'approved' : 'rejected',
              decided = repo.review.byId(lead.id)!;
          expect(repo.review.warnings, isEmpty);
          expect(repo.review.pendingRows.map((i) => i.title), ['家計の見直し']);
          expect(decided.status, status);
          expect(decided.reflected, isTrue);
          expect(decided.duplicates, [for (final c in covers) c.id]);
          for (final c in covers) {
            final covered = repo.review.byId(c.id)!;
            expect(covered.status, status);
            expect(covered.coveredBy, lead.id);
            expect(covered.decisionId, decided.decisionId);
            expect(covered.reflected, isTrue);
          }
          expect(repo.intake.single.state, 'accepted');
          if (action == 'approve') {
            expect(
              repo.projects.values.map((p) => p.title),
              contains(lead.title),
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }

    test('確認した組のまま依頼し、確認の後に組が変わったら依頼しない', () async {
      final access = UIAccess();
      await access.init();
      final files = inboxFiles();
      access.current = VaultSnapshot(files);
      final c = HubController(access, sampleLoader: () async => files);
      addTearDown(() async {
        c.dispose();
        await access.directory.delete(recursive: true);
      });
      await c.useSample();
      final lead = leadOf(c.review!),
          members = c.review!.groupMembers(lead),
          ticket = await c.prepareReview(lead.id);
      expect(ticket.covers.map((m) => m.id), members.map((m) => m.id));
      // まとめた案だけを開いたときは、その案だけの判断になる。
      expect((await c.prepareReview(members.first.id)).covers, isEmpty);
      // 確認の後で、まとめた案の1件が読めなくなった。
      access.current = VaultSnapshot(
        {...files}
          ..remove('90_system/project-confirmations/${members.first.id}.json'),
      );
      await expectLater(c.submitReview(ticket, 'reject'), throwsStateError);
      expect(access.writes, 0);
      access.current = VaultSnapshot(files);
      await c.reload();
      final saved = await c.submitReview(
        await c.prepareReview(lead.id),
        'reject',
      );
      expect(saved.saved, isTrue);
      final meta = parseMarkdown(
        (await access.readRequest(c.location!, saved.requestId))!,
      ).meta;
      expect(meta['cover_ids'], members.map((m) => m.id));
    });

    testWidgets('ホームの並びと、まとめた案の確認から却下の依頼までを操作できる', (t) async {
      final files = inboxFiles(),
          a = MemoryUIAccess(),
          c = await sample(t, a, files);
      final lead = leadOf(c.review!), members = c.review!.groupMembers(lead);
      // ホームは、次の一手、プロジェクト未定、プロジェクト、確認待ち、ふりかえり、最近のメモの順。
      double top(String key) => t.getTopLeft(find.byKey(Key(key))).dy;
      final order = [
        'home-next',
        'home-unassigned',
        'project-status-garden',
        'home-review',
        'home-digest',
        'home-recent',
      ].map(top).toList();
      expect(order, [...order]..sort());
      // 受付がなければ、状況の行は出さない。
      expect(find.byKey(const Key('home-status')), findsNothing);
      // 確認待ちは1組を1件と数え、根拠のメモが多いプロジェクト案を先に出す。
      expect(find.text('確認待ち 2件'), findsOneWidget);
      expect(find.text('プロジェクト案: 読書ノート'), findsOneWidget);
      expect(find.text('採用するとプロジェクトを作ります · 元のメモ3件'), findsOneWidget);
      expect(
        top('home-proposal-${lead.id}'),
        lessThan(
          top(
            'home-proposal-${c.review!.pendingRows.singleWhere((i) => i.id != lead.id).id}',
          ),
        ),
      );
      for (final member in members) {
        expect(find.byKey(Key('home-proposal-${member.id}')), findsNothing);
      }
      // 一覧でも、まとめた案は代表の行に含める。
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      expect(find.text('確認待ち（2件）'), findsOneWidget);
      expect(
        find.text('プロジェクト案 · 未承認 · 根拠のメモ3件（同じ対象の案をまとめて表示）'),
        findsOneWidget,
      );
      for (final member in members) {
        expect(find.byKey(Key('review-${member.id}')), findsNothing);
      }
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-group')), findsOneWidget);
      for (final member in members) {
        expect(find.text('まとめた案: ${member.title}'), findsOneWidget);
      }
      // まとめた案の元のメモも、判断の前に確かめられる。
      expect(find.byKey(const Key('review-source')), findsNWidgets(3));
      // まとめた案だけを開くと、その案だけの判断になる。
      await t.tap(find.byKey(Key('review-member-${members.first.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-grouped')), findsOneWidget);
      expect(find.text('却下する'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      await t.tap(find.text('3件をまとめて却下する'));
      await t.pumpAndSettle();
      expect(find.text('まとめた3件の案を却下しますか？'), findsOneWidget);
      expect(find.byKey(const Key('review-covers-note')), findsOneWidget);
      for (final member in members) {
        expect(find.text('同じ判断にまとめる案: ${member.title}'), findsOneWidget);
      }
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(a.writes, 0);
      await t.tap(find.text('3件をまとめて却下する'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-review')));
      await t.pumpAndSettle();
      expect(a.writes, 1);
      final request = a.requests.entries.single,
          meta = parseMarkdown(request.value).meta;
      expect(meta['operation'], 'project-reject');
      expect(meta['candidate_id'], lead.id);
      expect(meta['cover_ids'], [for (final m in members) m.id]);
      // 依頼が同期されると、代表の行は依頼済みになり、ホームの問いかけから外れる。
      a.current = VaultSnapshot({
        ...files,
        'Input/${request.key}.md': request.value,
      });
      await c.reload();
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.text('確認待ち（2件）'), findsOneWidget);
      expect(
        find.textContaining('根拠のメモ3件（同じ対象の案をまとめて表示）\n依頼保存済み・Mac miniの判断待ち'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('nav-home')));
      await t.pumpAndSettle();
      expect(find.byKey(Key('home-proposal-${lead.id}')), findsNothing);
      expect(find.text('保存と反映: 反映待ち 1件'), findsOneWidget);
      await t.tap(find.byKey(const Key('home-status')));
      await t.pumpAndSettle();
      expect(find.textContaining('同じ対象の案2件をまとめて判断'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('まとめて判断された案は、履歴で代表の案を示す', (t) async {
      final access = TempAccess();
      await t.runAsync(() async {
        await access.init();
      });
      addTearDown(() => access.directory.deleteSync(recursive: true));
      late Map<String, String> files;
      final before = HubRepository(VaultSnapshot(inboxFiles())).review,
          lead = leadOf(before),
          members = before.groupMembers(lead);
      await t.runAsync(() async {
        final result = await ReviewService(
          access,
          location,
        ).submit(op, lead, 'reject', covers: members);
        final output = '${access.directory.path}/after.json';
        final node = await Process.run('node', [
          'scripts/check_grouped_review_protocol.mjs',
          access.request(location, result.requestId).path,
          'test/fixtures/unassigned-and-proposals.json',
          output,
        ]);
        expect(node.exitCode, 0, reason: '${node.stdout}\n${node.stderr}');
        files = nativeReviewFiles(
          Map<String, String>.from(
            jsonDecode(await File(output).readAsString()) as Map,
          ),
        );
      });
      final a = MemoryUIAccess();
      await sample(t, a, files);
      await t.tap(find.byKey(const Key('home-review')));
      await t.pumpAndSettle();
      expect(find.text('確認待ち（1件）'), findsOneWidget);
      expect(find.text('判断履歴（3件）'), findsOneWidget);
      expect(find.text('プロジェクト案 · 却下済み · 「読書ノート」とまとめて判断'), findsNWidgets(2));
      await t.tap(find.byKey(Key('review-${members.first.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('review-covered')), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('review-${lead.id}')));
      await t.pumpAndSettle();
      expect(
        find.text('同じ判断にまとめた案: ${members.map((m) => m.title).join('、')}'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
