import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/related.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/draft_store.dart';
import 'draft_test.dart' show openSample, openForm;
import 'core_test.dart' show packet;
import 'fixtures.dart';
import 'widget_test.dart' show MemoryUIAccess;

const questionPath = '00_inbox/2026-09-14_IN-01M2DSFVSNCJSF7XKRPW29TM7M.md';
const draftText = '同期とバックアップの分け方を考えた。同期は端末の間、バックアップは外付けの場所へ。';

void main() {
  test('ひらがなだけの組と記号を特徴にせず、英数字は語として扱う', () {
    final f = relatedFeatures('ＳＹＮＣの設定をした。Backup と the sync!');
    expect(f, containsAll(['sync', 'backup', '設定', 'の設']));
    expect(f, isNot(contains('した')));
    expect(f, isNot(contains('the')));
    expect(f.any((x) => x.contains(' ') || x.contains('。')), isFalse);
  });

  test('書いている本文と重なる記録を、元のメモと最新の本文・帰属付きで返す', () {
    final repo = HubRepository(fixture());
    expect(relatedRecords(repo, '同期とバックアップ'), isEmpty);
    final hits = relatedRecords(repo, draftText);
    expect(hits.first.root.path, questionPath);
    expect(hits.first.owner, 'context-hub');
    expect(hits.first.shared, containsAll(['同期', 'バッ']));
    expect(hits.length, lessThanOrEqualTo(3));
    // 関係のない本文では出さない。
    expect(relatedRecords(repo, '今日は晩ごはんにカレーを作って、明日の朝の分も残しておいた。'), isEmpty);
  });

  test('長い記録は、関係のない短いメモにまで出てこない', () {
    final files = fixtureFiles(),
        original = parseMarkdown(files[questionPath]!);
    // 長い作業要約（このアプリのREADME）。よくある漢字・カタカナの組を多く含む。
    const longId = 'IN-01M2DSFVSNCJSF7XKRPW29TM80';
    files['00_inbox/2026-09-16_$longId.md'] = packet({
      ...original.meta,
      'id': longId,
      'kind': 'work-summary',
      'source_event_id': 'fixture-long',
    }, File('README.md').readAsStringSync());
    final repo = HubRepository(fixture(files));
    for (final memo in [
      '今日は晩ごはんにカレーを作って、明日の朝の分も残しておいた。',
      '新しいキーボードを買うか迷っている。打ちやすさと音の静かさで比べたい。',
      '田中さんから電話。来週の打ち合わせの日程を決めたい、とのこと。',
    ]) {
      expect(relatedRecords(repo, memo), isEmpty, reason: memo);
    }
    expect(relatedRecords(repo, draftText).first.root.path, questionPath);
  });

  test('記録が多いときは特徴を別のisolateで作り、同じ読み込みでは作り直さない', () async {
    final files = fixtureFiles(),
        original = parseMarkdown(files[questionPath]!);
    for (var i = 0; i < relatedSyncLimit + 5; i++) {
      final id = 'IN-01M2DSFVSNCJSF7XKRPW2${i.toString().padLeft(5, '0')}';
      files['00_inbox/2026-09-16_$id.md'] = packet({
        ...original.meta,
        'id': id,
        'source_event_id': 'fixture-many-$i',
      }, '関係のない記録$i。晩ごはんの献立。');
    }
    final repo = HubRepository(fixture(files));
    final index = relatedIndex(repo);
    expect(identical(index, relatedIndex(repo)), isTrue);
    final built = await index;
    expect(built.features.length, repo.relatedCandidates.length);
    expect(
      relatedRecords(repo, draftText, index: built).first.root.path,
      questionPath,
    );
  });

  test('訂正があるメモは最新の訂正の本文で比べる', () {
    final files = fixtureFiles(),
        original = parseMarkdown(files[questionPath]!);
    expect(
      relatedRecords(HubRepository(fixture(files)), draftText),
      isNotEmpty,
    );
    const fixedId = 'IN-01M2DSFVSNCJSF7XKRPW29TM7N';
    files['00_inbox/2026-09-15_$fixedId.md'] = packet({
      ...original.meta,
      'id': fixedId,
      'kind': 'correction',
      'corrects_input_id': original.meta['id'],
      'source_event_id': 'fixture-correction',
      'occurred_at': '2026-09-15T10:00:00+09:00',
      'received_at': '2026-09-15T10:00:00+09:00',
    }, '晩ごはんの献立を考える。');
    final repo = HubRepository(fixture(files));
    final candidate = repo.relatedCandidates.firstWhere(
      (c) => c.root.path == questionPath,
    );
    expect(candidate.latest.sourceId, fixedId);
    expect(
      relatedRecords(repo, draftText).map((h) => h.root.path),
      isNot(contains(questionPath)),
    );
  });

  testWidgets('メモを書いている途中に関係ありそうな記録を出し、同じプロジェクトで保存できる。設定で止められる', (
    tester,
  ) async {
    final access = MemoryUIAccess();
    await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), draftText);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    final id = recordId(questionPath);
    expect(find.byKey(const Key('related-records')), findsOneWidget);
    expect(find.byKey(const Key('related-none')), findsNothing);
    expect(find.byKey(Key('related-$id')), findsOneWidget);
    await tester.tap(find.byKey(Key('related-project-$id')));
    await tester.pumpAndSettle();
    // プロジェクトを指定すると、同じプロジェクトで保存するボタンは消える。
    expect(find.byKey(Key('related-project-$id')), findsNothing);
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    expect(
      parseMarkdown(access.requests.values.single).meta['project'],
      'context-hub',
    );
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    await openForm(tester);
    await tester.ensureVisible(find.byKey(const Key('show-related')));
    await tester.tap(find.byKey(const Key('show-related')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memo-text')), draftText);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('related-records')), findsNothing);
    expect(await DraftStore(access).relatedEnabled(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('探す長さの本文で見つからなければ、見つからなかったことと比べた件数を一言出す', (
    tester,
  ) async {
    final access = MemoryUIAccess();
    final c = await openSample(tester, access);
    await openForm(tester);
    Future<void> type(String text) async {
      await tester.enterText(find.byKey(const Key('memo-text')), text);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
    }

    // 書き始めの短い本文では、探していないので何も出さない。
    await type('晩ごはんにカレー');
    expect(find.byKey(const Key('related-none')), findsNothing);
    expect(find.byKey(const Key('related-records')), findsNothing);

    // 長くても、比べる特徴のない本文（ひらがなだけ）は比べていないので出さない。
    await type('きょうはとてもいいてんきでしたねあしたもはれるといいな');
    expect(find.byKey(const Key('related-none')), findsNothing);

    await type('今日は晩ごはんにカレーを作って、明日の朝の分も残しておいた。');
    final count = c.repository!.relatedCandidates.length;
    expect(count, greaterThan(0));
    expect(find.byKey(const Key('related-records')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('related-none'))).data,
      contains('$count件'),
    );

    // 見つかれば一覧に替わり、短くすれば消える。
    await type(draftText);
    expect(find.byKey(const Key('related-records')), findsOneWidget);
    expect(find.byKey(const Key('related-none')), findsNothing);
    await type('晩ごはん');
    expect(find.byKey(const Key('related-none')), findsNothing);
    expect(find.byKey(const Key('related-records')), findsNothing);

    // 設定で止めれば、見つからなかったことも出さない。
    await type('今日は晩ごはんにカレーを作って、明日の朝の分も残しておいた。');
    expect(find.byKey(const Key('related-none')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('show-related')));
    await tester.tap(find.byKey(const Key('show-related')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('related-none')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
