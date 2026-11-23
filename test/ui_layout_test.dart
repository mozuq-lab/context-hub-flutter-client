import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'fixtures.dart';
import 'insights_test.dart' show insightsFiles, expected;
import 'unassigned_proposals_test.dart' show sample;
import 'widget_test.dart' show MemoryUIAccess;

/// 画面の作り直しで決めた、押しやすさと見分けやすさの約束。
void main() {
  testWidgets('Androidでは、行の操作と今週の気づきの反応を指で押せる大きさにする', (t) async {
    final c = await sample(t, MemoryUIAccess(), insightsFiles());
    final items = c.repository!.insights!.items;
    // 反応の札は、隣の札と押し間違えない高さ（40以上）にする。
    final reacted = (expected['reaction'] as Map)['key'] as String;
    expect(
      t.getSize(find.byKey(Key('home-insight-useful-$reacted'))).height,
      greaterThanOrEqualTo(40),
    );
    // 文字だけのボタン（行の操作）は、見た目を小さくしても押せる範囲を48にする。
    final question = items.firstWhere(
      (i) => insightAnswerSections.contains(i.section),
    );
    expect(
      t.getSize(find.byKey(Key('home-insight-answer-${question.key}'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('プロジェクトの呼び名とキーワードには、何のためのものかを画面に書いておく', (t) async {
    await sample(t, MemoryUIAccess(), fixture().files);
    await t.tap(find.byKey(const Key('project-context-hub')).first);
    await t.pumpAndSettle();
    // 長押しで選べる文字なので、説明を吹き出しに隠さず、文字として出す。
    expect(find.textContaining('メモを見分ける手がかり'), findsOneWidget);
  });

  testWidgets('複数を選べる検索の札は、色だけでなく印でも選んだことを示す', (t) async {
    await sample(t, MemoryUIAccess(), fixture().files);
    await t.tap(find.byKey(const Key('nav-search')).first);
    await t.pumpAndSettle();
    final chip = find.byKey(const Key('search-kind-memo'));
    expect(t.widget<FilterChip>(chip).showCheckmark, isTrue);
  });

  testWidgets('メモの種類は、たたまずに2つの切り替えで選び、作業要約として保存できる', (t) async {
    final a = MemoryUIAccess();
    await sample(t, a, fixture().files);
    await t.tap(find.byKey(const Key('new-memo')).first);
    await t.pumpAndSettle();
    // 「種類」を開いた中にさらに選択欄がある形にしない。
    expect(find.byType(ExpansionTile), findsNothing);
    final kind = find.byKey(const Key('memo-kind'));
    expect(t.widget<SegmentedButton<String>>(kind).selected, {'memo'});
    expect(find.byKey(const Key('memo-kind-note')), findsNothing);
    await t.tap(find.byKey(const Key('memo-kind-work-summary')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('memo-kind-note')), findsOneWidget);
    await t.enterText(find.byKey(const Key('memo-text')), 'AIの作業の報告を貼る');
    await t.ensureVisible(find.byKey(const Key('save-memo')));
    await t.tap(find.byKey(const Key('save-memo')));
    await t.pumpAndSettle();
    expect(find.text('この端末に保存しました'), findsOneWidget);
    expect(a.requests.values.single, contains('work-summary'));
  });

  testWidgets('狭い画面のダイアログは、画面の端から16だけ空けて本文の幅を広く取る', (t) async {
    // 種類の切り替えは、狭い画面では印を外して文字を折り返させない。
    await sample(
      t,
      MemoryUIAccess(),
      fixture().files,
      size: const Size(400, 860),
    );
    await t.tap(find.byKey(const Key('new-memo')).first);
    await t.pumpAndSettle();
    final surface = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Material),
        )
        .first;
    expect(t.getSize(surface).width, greaterThanOrEqualTo(400 - 32 - 0.5));
    final label = find.byKey(const Key('memo-kind-work-summary'));
    expect(t.getSize(label).height, lessThan(24));
  });
}
