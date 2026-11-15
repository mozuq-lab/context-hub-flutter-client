import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/templates.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/template_store.dart';
import 'package:context_hub_client/ui/template_view.dart';
import 'draft_test.dart' show closeForm, openForm, openSample;
import 'widget_test.dart' show MemoryUIAccess;

/// 状態ファイルの読み出しに失敗するアクセス。
class UnreadableAccess extends MemoryUIAccess {
  bool broken = false;
  @override
  Future<String?> readState(String name) async {
    if (broken && name == TemplateStore.fileName) throw StateError('読取不可');
    return super.readState(name);
  }
}

Future<void> pickTemplate(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const Key('template-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('template-item-$id')));
  await tester.pumpAndSettle();
}

String memoText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('memo-text')))
    .controller!
    .text;

String json(List<MemoTemplate> list) =>
    jsonEncode([for (final t in list) t.toJson()]);

void main() {
  final meeting = defaultTemplates.first;
  final headings = templateHeadings(defaultTemplates);

  group('ひな形の差し込み', () {
    test('本文が空なら全体を入れ、最初の見出しの次の行から書き始める', () {
      final r = insertTemplate('  \n', meeting.body);
      expect(r.text, '## 決まったこと\n\n## 次にやること\n\n## 持ち越し\n');
      expect(r.cursor, '## 決まったこと\n'.length);
    });

    test('本文があれば末尾に空行を挟んで足し、書いた文は変えない', () {
      final r = insertTemplate('先に書いたメモ\n\n\n', '## 出典\r\n\r\n## 要点\r\n');
      expect(r.text, '先に書いたメモ\n\n## 出典\n\n## 要点\n');
      expect(r.text.substring(r.cursor), '\n## 要点\n');
    });

    test('見出しのないひな形は末尾から書き始める', () {
      final r = insertTemplate('', '日付:\n場所:');
      expect(r.text, '日付:\n場所:\n');
      expect(r.cursor, r.text.length);
    });
  });

  group('空の見出しの除去', () {
    test('中身を書かなかったひな形の見出しだけを取り除く', () {
      expect(
        stripEmptyTemplateHeadings(
          '## 決まったこと\n- 来週リリース\n\n## 次にやること\n\n## 持ち越し\n  \n',
          headings,
        ),
        '## 決まったこと\n- 来週リリース\n',
      );
      expect(
        stripEmptyTemplateHeadings(
          '前置き\n\n## 決まったこと\n\n## 次にやること\n- 連絡する\n',
          headings,
        ),
        '前置き\n\n## 次にやること\n- 連絡する\n',
      );
    });

    test('取り除くものがなければ本文を1文字も変えない', () {
      const own = '# 自分の見出し\r\n\r\n## TODO\r\n';
      expect(stripEmptyTemplateHeadings(own, headings), own);
      const filled = '## 決まったこと\nA\n## 次にやること\nB\n## 持ち越し\nC';
      expect(stripEmptyTemplateHeadings(filled, headings), filled);
      expect(
        stripEmptyTemplateHeadings('## 決まったこと\n', const {}),
        '## 決まったこと\n',
      );
    });

    test('本人が書いた見出しは空でも残し、ひな形の見出しの中身として数える', () {
      expect(
        stripEmptyTemplateHeadings('## 決まったこと\n### 補足\n\n## 持ち越し\n', headings),
        '## 決まったこと\n### 補足\n',
      );
    });

    test('深い見出しに中身があれば、上の見出しを残す', () {
      final nested = templateHeadings([
        const MemoTemplate(id: 'n', name: '入れ子', body: '# 会議\n## 決定\n## 宿題\n'),
      ]);
      expect(
        stripEmptyTemplateHeadings('# 会議\n## 決定\n\n## 宿題\n- 調べる\n', nested),
        '# 会議\n## 宿題\n- 調べる\n',
      );
      expect(stripEmptyTemplateHeadings('# 会議\n## 決定\n\n## 宿題\n', nested), '');
    });

    test('コードブロックの中の同じ行は見出しとして扱わない', () {
      const text = '## 決まったこと\n```\n## 次にやること\n```\n\n## 持ち越し\n';
      expect(
        stripEmptyTemplateHeadings(text, headings),
        '## 決まったこと\n```\n## 次にやること\n```\n',
      );
    });

    test('見出しだけの本文は空になる', () {
      expect(stripEmptyTemplateHeadings(meeting.body, headings), '');
    });
  });

  group('TemplateStore', () {
    test('変えるまではファイルを作らず、最初のひな形を返す', () async {
      final access = MemoryUIAccess();
      expect(await TemplateStore(access).list(), defaultTemplates);
      expect(access.states.containsKey(TemplateStore.fileName), isFalse);
    });

    test('並び・編集・Vaultごとの既定のプロジェクトを保存し、読み直しても戻る', () async {
      final access = MemoryUIAccess();
      final store = TemplateStore(access);
      final edited = meeting
          .copyWith(name: '定例', body: '## 決定\n')
          .withProject('vault-a', 'garden');
      await store.save([defaultTemplates[1], edited]);
      final again = await TemplateStore(access).list();
      expect(again.map((t) => t.name), ['不具合', '定例']);
      expect(again[1].body, '## 決定\n');
      expect(again[1].projects, {'vault-a': 'garden'});
      await store.reset();
      expect(json(await TemplateStore(access).list()), json(defaultTemplates));
    });

    test('壊れた内容や形式の合わない記録は読み飛ばす', () async {
      final access = MemoryUIAccess();
      access.states[TemplateStore.fileName] = '{壊れ';
      expect(await TemplateStore(access).list(), defaultTemplates);
      access.states[TemplateStore.fileName] = jsonEncode({
        'version': 1,
        'templates': [
          {'id': 'ok', 'name': '残る', 'body': '## A\n'},
          {'id': 'ok', 'name': '重複', 'body': '## B\n'},
          {'id': 'BAD ID', 'name': 'x', 'body': 'y'},
          {'id': 'long', 'name': 'x', 'body': 'あ' * 1001},
          {'id': 'noname', 'name': ' ', 'body': 'y'},
          'not a map',
        ],
      });
      final list = await TemplateStore(access).list();
      expect(list.map((t) => t.name), ['残る']);
    });

    test('上限と形式に合わない保存は受け付けず、前の並びを残す', () async {
      final access = MemoryUIAccess();
      final store = TemplateStore(access);
      await store.save([meeting]);
      final many = [
        for (var i = 0; i <= maxTemplates; i++)
          MemoTemplate(id: 't$i', name: 'ひな形$i', body: '## A\n'),
      ];
      await expectLater(store.save(many), throwsA(isA<TemplateStoreError>()));
      await expectLater(
        store.save([meeting.copyWith(name: '')]),
        throwsA(isA<TemplateStoreError>()),
      );
      await expectLater(
        store.save([meeting, meeting]),
        throwsA(isA<TemplateStoreError>()),
      );
      expect(await store.list(), [meeting]);
      expect((await TemplateStore(access).list()).single.id, meeting.id);
    });

    test('読み出しに失敗したときは最初のひな形で書け、上書きはしない', () async {
      final access = UnreadableAccess();
      await TemplateStore(access).save([meeting.copyWith(name: '定例')]);
      access.broken = true;
      final store = TemplateStore(access);
      expect(await store.list(), defaultTemplates);
      await expectLater(store.save([meeting]), throwsA(anything));
      access.broken = false;
      expect((await store.list()).single.name, '定例');
    });

    test('既定のプロジェクトを覚えるVaultは上限までで、古いものから忘れる', () {
      var t = meeting;
      for (var i = 0; i < MemoTemplate.maxVaults + 2; i++) {
        t = t.withProject('vault-$i', 'p$i');
      }
      expect(t.projects.length, MemoTemplate.maxVaults);
      expect(t.projects.containsKey('vault-0'), isFalse);
      expect(
        t.withProject('vault-3', null).projects.containsKey('vault-3'),
        isFalse,
      );
    });

    test('ひな形の状態ファイルは操作journalとして数えない', () {
      expect(CaptureService.nonJournalStates, contains(TemplateStore.fileName));
    });
  });

  test('見出しの並びを1行で示す', () {
    expect(templateOutline(meeting), '決まったこと / 次にやること / 持ち越し');
    expect(
      templateOutline(
        const MemoTemplate(id: 'x', name: 'x', body: '\n日付:\n場所:'),
      ),
      '日付:',
    );
  });

  group('メモ追加フォーム', () {
    testWidgets('ひな形を選ぶと見出しが入り、書かなかった見出しを除いて保存する', (tester) async {
      final access = MemoryUIAccess();
      await openSample(tester, access);
      await openForm(tester);
      await pickTemplate(tester, 'default-meeting');
      expect(memoText(tester), meeting.body);
      final field = tester.widget<TextField>(
        find.byKey(const Key('memo-text')),
      );
      expect(field.controller!.selection.baseOffset, '## 決まったこと\n'.length);

      // 見出しだけでは保存しない。
      await tester.tap(find.byKey(const Key('save-memo')));
      await tester.pumpAndSettle();
      expect(find.textContaining('ひな形の見出しだけで、中身がありません'), findsOneWidget);
      expect(access.requests, isEmpty);
      expect(memoText(tester), meeting.body);

      await tester.enterText(
        find.byKey(const Key('memo-text')),
        '## 決まったこと\n- 月末に出す\n\n## 次にやること\n\n## 持ち越し\n',
      );
      await tester.tap(find.byKey(const Key('save-memo')));
      await tester.pumpAndSettle();
      expect(find.text('この端末のInputに保存しました'), findsOneWidget);
      final raw = access.requests.values.single;
      expect(raw, contains('## 決まったこと\n- 月末に出す\n'));
      expect(raw, isNot(contains('## 次にやること')));
      expect(raw, isNot(contains('## 持ち越し')));
      // 保存した本文を画面にも示す。
      expect(memoText(tester), '## 決まったこと\n- 月末に出す\n');
    });

    testWidgets('書いてある本文の末尾に足し、8000文字を超える差し込みは止める', (tester) async {
      final access = MemoryUIAccess();
      await openSample(tester, access);
      await openForm(tester);
      await tester.enterText(find.byKey(const Key('memo-text')), '先に書いた');
      await pickTemplate(tester, 'default-reading');
      expect(memoText(tester), '先に書いた\n\n## 出典\n\n## 要点\n\n## 自分の考え\n');
      await tester.enterText(find.byKey(const Key('memo-text')), 'あ' * 7990);
      await pickTemplate(tester, 'default-bug');
      expect(find.textContaining('ひな形を差し込むと8000文字を超えます'), findsOneWidget);
      expect(memoText(tester), 'あ' * 7990);
    });

    testWidgets('ひな形を追加・並べ替え・削除でき、既定のプロジェクトは未指定のときだけ使う', (tester) async {
      final access = MemoryUIAccess();
      final c = await openSample(tester, access);
      final project = c.repository!.projects.values.first;
      await openForm(tester);
      await tester.tap(find.byKey(const Key('template-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-manage')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('template-row-default-meeting')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('template-add')));
      await tester.pumpAndSettle();
      // 名前がなければ保存しない。
      await tester.tap(find.byKey(const Key('template-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('名前は1〜40文字'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('template-name')), '週次');
      await tester.enterText(
        find.byKey(const Key('template-body')),
        '## 今週\n\n## 来週\n',
      );
      await tester.tap(find.byKey(const Key('template-project')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(project.title).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-save')));
      await tester.pumpAndSettle();
      expect(find.text('今週 / 来週\n既定のプロジェクト: ${project.title}'), findsOneWidget);

      var stored = await TemplateStore(access).list();
      expect(stored.map((t) => t.name), ['会議', '不具合', '読んだもの', '作業の区切り', '週次']);
      final weekly = stored.last;
      expect(weekly.projects, {c.location!.identity: project.id});

      // 上へ動かし、最初のひな形を1つ削除する。
      await tester.ensureVisible(find.byKey(Key('template-up-${weekly.id}')));
      await tester.tap(find.byKey(Key('template-up-${weekly.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-delete-default-bug')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-confirm')));
      await tester.pumpAndSettle();
      stored = await TemplateStore(access).list();
      expect(stored.map((t) => t.name), ['会議', '読んだもの', '週次', '作業の区切り']);
      await tester.tap(find.byKey(const Key('template-close')));
      await tester.pumpAndSettle();

      // フォームのメニューに反映され、選ぶと既定のプロジェクトが入る。
      await pickTemplate(tester, weekly.id);
      expect(memoText(tester), '## 今週\n\n## 来週\n');
      await tester.enterText(
        find.byKey(const Key('memo-text')),
        '## 今週\n- 進んだ\n\n## 来週\n',
      );
      await tester.tap(find.byKey(const Key('save-memo')));
      await tester.pumpAndSettle();
      final raw = access.requests.values.single;
      expect(raw, contains('"project":"${project.id}"'));
      expect(raw, isNot(contains('## 来週')));
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();

      // 最初のひな形に戻せる。
      await openForm(tester);
      await tester.tap(find.byKey(const Key('template-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-confirm')));
      await tester.pumpAndSettle();
      expect(json(await TemplateStore(access).list()), json(defaultTemplates));
      await tester.tap(find.byKey(const Key('template-close')));
      await tester.pumpAndSettle();
      await closeForm(tester);
    });

    testWidgets('ひな形の見出しを入れた書きかけも、次に開いたときに戻る', (tester) async {
      final access = MemoryUIAccess();
      await openSample(tester, access);
      await openForm(tester);
      await pickTemplate(tester, 'default-checkpoint');
      await tester.pump(const Duration(seconds: 1));
      await closeForm(tester);
      await openForm(tester);
      expect(memoText(tester), defaultTemplates.last.body);
      expect(find.byKey(const Key('draft-restored')), findsOneWidget);
    });
  });
}
