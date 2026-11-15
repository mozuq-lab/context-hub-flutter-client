import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/ai/guided_services.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/guided.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/secrets.dart';
import 'package:context_hub_client/ui/app.dart';
import 'fixtures.dart';
import 'guided_test.dart'
    show FakeModel, MemorySecrets, q, question, recordSummary;
import 'widget_test.dart' show MemoryUIAccess;

const key = 'sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123';
const header = '-----BEGIN RSA PRIVATE KEY-----';

void main() {
  group('選んで深掘りでClaude APIへ送る内容', () {
    GuidedSession secretSession() => GuidedSession(
      id: 'GS-01M2DSFVQMH65989604KSVE1PV',
      vault: 'vault-identity',
      purpose: GuidedPurpose.record,
      seed: '鍵は $key で、$header から始まる',
      context: '資料: password=hunter2pass の行\n次の行',
      contextLabel: 'vault',
      startedAt: DateTime.utc(2026, 11, 12),
      steps: [
        GuidedStep(
          q('どこで使う？', ['本番', '検証']),
          const GuidedAnswer.free('token=Zk3p9QwErTyUiOp で本番'),
        ),
        GuidedStep(q('次は？', ['差し替え', '確認']), const GuidedAnswer.unknown()),
      ],
    );

    test('きっかけ・回答・資料の秘密情報らしい文字列を伏せ、後ろの問答と依頼は残す', () {
      for (final p in [
        guidedQuestionPrompt(secretSession()),
        guidedSummaryPrompt(secretSession()),
      ]) {
        final sent = '${p.context}\n${p.turn}';
        expect(sent, isNot(contains(key)));
        expect(sent, isNot(contains('hunter2pass')));
        expect(sent, isNot(contains('Zk3p9QwErTyUiOp')));
        expect(p.turn, contains('[伏せ字:APIキー]'));
        expect(p.context, contains('password=[伏せ字:パスワード等] の行\n次の行'));
        // 終わりのない秘密鍵の見出しがあっても、その後ろを消さない。
        expect(p.turn, contains('[伏せ字:秘密鍵]'));
        expect(p.turn, contains('1. どこで使う？ → 「token=[伏せ字:パスワード等] で本番」（自由入力）'));
        expect(p.turn, contains('2. 次は？ → わからない'));
        expect(p.turn, contains('# 依頼'));
      }
    });

    test('保存する本文は、選んだときだけ伏せ字にする', () {
      final s = secretSession();
      final plain = guidedBody('まとめ $key', s);
      expect(plain, contains(key));
      final hidden = guidedBody('まとめ $key', s, redact: true);
      expect(hidden, isNot(contains(key)));
      expect(hidden, isNot(contains('Zk3p9QwErTyUiOp')));
      expect(hidden, startsWith('まとめ [伏せ字:APIキー]\n\n## 問答の記録'));
      expect(hidden, contains('2. 次は？ → わからない'));
    });
  });

  group('コピーするcontext', () {
    Map<String, String> withBody(String body) {
      final files = fixtureFiles();
      final raw = files[inputPath]!;
      final end = raw.indexOf('\n---\n', 4) + 5;
      return {...files, inputPath: '${raw.substring(0, end)}$body\n'};
    }

    test('メモの本文に紛れた値を出さず、切る位置をまたぐ値も伏せる', () {
      final repo = HubRepository(
        fixture(
          withBody('接続先 postgres://admin:s3cr3tPass@db.example.com と $key'),
        ),
      );
      for (final text in [repo.context('context-hub'), repo.vaultContext()]) {
        expect(text, isNot(contains(key)));
        expect(text, isNot(contains('s3cr3tPass')));
        expect(text, contains('[伏せ字:'));
        expect(text, contains('秘密情報らしい文字列は[伏せ字:種類]に置き換えています'));
      }
      final straddle = HubRepository(fixture(withBody('${'あ' * 190} $key')));
      for (final text in [
        straddle.context('context-hub'),
        straddle.vaultContext(),
      ]) {
        expect(text, isNot(contains('sk-ant-api03')));
      }
    });

    test('終わりのない秘密鍵の見出しが要約にあっても、後ろの内容は残す', () {
      final files = fixtureFiles();
      const receiptPath = '90_system/receipts/$inputId.json';
      final receipt = jsonDecode(files[receiptPath]!) as Map<String, dynamic>;
      (receipt['result'] as Map)['summary'] = '鍵は $header で始まる';
      files[receiptPath] = jsonEncode(receipt);
      final text = HubRepository(fixture(files)).context('context-hub');
      final at = text.indexOf('有効解釈: 鍵は [伏せ字:秘密鍵]');
      expect(at, greaterThan(0));
      expect(text, isNot(contains(header)));
      // 見出しより後ろにある記録が残っている。
      expect(text.indexOf('- [IN-', at), greaterThan(at));
    });

    test('長い記録は先頭だけを検査し、切る前に伏せる', () {
      final long = '${'a_' * 200000}password=hunter2pass';
      final started = DateTime.now();
      expect(redactSecretsHead(long, 300), 'a_' * 2198);
      expect(
        redactSecretsHead('${'あ' * 290} $key ${'い' * 9000}', 300),
        startsWith('${'あ' * 290} [伏せ字:APIキー] '),
      );
      expect(
        redactSecretLines('a\n$header\nb $key'),
        'a\n[伏せ字:秘密鍵]\nb [伏せ字:APIキー]',
      );
      // 区切りでつないだ長い名前でも時間がかからない。
      expect(findSecrets('a_' * 4000), isEmpty);
      expect(DateTime.now().difference(started).inSeconds, lessThan(5));
    });
  });

  group('保存の前の確認', () {
    late MemoryUIAccess access;
    late HubController c;
    late FakeModel model;

    Future<void> openApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      access = MemoryUIAccess();
      model = FakeModel();
      c = HubController(
        access,
        sampleLoader: () async => fixture().files,
        guided: GuidedServices(
          model: model,
          secrets: MemorySecrets('sk-ant-test-key-0000000000'),
        ),
      );
      addTearDown(() {
        c.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ContextHubApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('サンプルで試す'));
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('メモの保存前に種類を知らせ、戻る・伏せ字にする・そのまま保存を選べる', (tester) async {
      await openApp(tester);
      await tapKey(tester, 'new-memo');
      await tester.enterText(
        find.byKey(const Key('memo-text')),
        '本番のキーは $key です',
      );
      await tapKey(tester, 'save-memo');
      // 値そのものは出さず、種類だけを知らせる。
      expect(find.byKey(const Key('secret-warning')), findsOneWidget);
      expect(find.textContaining('APIキーに見える文字列があります'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('secret-warning')),
          matching: find.textContaining('sk-ant-api03'),
        ),
        findsNothing,
      );
      // 戻って直すと保存しない。
      await tester.tap(find.text('戻って直す'));
      await tester.pumpAndSettle();
      expect(access.requests, isEmpty);
      await tapKey(tester, 'save-memo');
      await tapKey(tester, 'secret-redact');
      expect(find.text('この端末のInputに保存しました'), findsOneWidget);
      final body = parseMarkdown(access.requests.values.single).body;
      expect(body, '本番のキーは [伏せ字:APIキー] です');
    });

    testWidgets('そのまま保存を選ぶと原文のまま保存する', (tester) async {
      await openApp(tester);
      await tapKey(tester, 'new-memo');
      await tester.enterText(find.byKey(const Key('memo-text')), 'キーは $key');
      await tapKey(tester, 'save-memo');
      await tapKey(tester, 'secret-keep');
      expect(parseMarkdown(access.requests.values.single).body, 'キーは $key');
    });

    testWidgets('秘密情報らしい文字列がなければ確認を出さない', (tester) async {
      await openApp(tester);
      await tapKey(tester, 'new-memo');
      await tester.enterText(find.byKey(const Key('memo-text')), 'パスワードは後で変える');
      await tapKey(tester, 'save-memo');
      expect(find.byKey(const Key('secret-warning')), findsNothing);
      expect(access.requests, hasLength(1));
    });

    testWidgets('選んで深掘りの保存でも、自分の言葉に紛れた値を知らせて伏せ字にできる', (tester) async {
      await openApp(tester);
      await tapKey(tester, 'open-guided');
      await tester.enterText(find.byKey(const Key('guided-seed')), '今日の作業');
      model.replies.addAll([
        question('何をしましたか？', ['読取を直した', '画面を作った']),
        question('次に何をしますか？', ['計測', '後回し']),
        recordSummary(),
      ]);
      await tapKey(tester, 'guided-start');
      await tapKey(tester, 'guided-other');
      await tester.enterText(
        find.byKey(const Key('guided-other-text')),
        'キー $key を差し替えた',
      );
      await tapKey(tester, 'guided-other-send');
      // Claudeへ送る問答では伏せている。
      expect(model.prompts.last.turn, isNot(contains(key)));
      expect(model.prompts.last.turn, contains('[伏せ字:APIキー]'));
      await tapKey(tester, 'guided-wrap');
      expect(model.prompts.last.turn, isNot(contains(key)));
      await tapKey(tester, 'guided-save');
      expect(find.byKey(const Key('secret-warning')), findsOneWidget);
      expect(access.requests, isEmpty);
      await tapKey(tester, 'secret-redact');
      expect(find.byKey(const Key('guided-saved')), findsOneWidget);
      final body = parseMarkdown(access.requests.values.single).body;
      expect(body, isNot(contains(key)));
      expect(body, contains('1. 何をしましたか？ → 「キー [伏せ字:APIキー] を差し替えた」（自由入力）'));
    });
  });
}
