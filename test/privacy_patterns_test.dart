import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/ai/guided_services.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/app/guided_controller.dart';
import 'package:context_hub_client/core/guided.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/secrets.dart';
import 'package:context_hub_client/storage/guided_store.dart';
import 'package:context_hub_client/ui/app.dart';
import 'fixtures.dart';
import 'guided_test.dart'
    show FakeModel, MemorySecrets, UncertainAccess, question;
import 'widget_test.dart' show MemoryUIAccess;

/// 本体が書く追加規則のファイル（取り決めの形式）。
String patternsFile({
  int version = 1,
  bool redact = true,
  List<Map<String, Object?>> patterns = const [
    {'label': '顧客名', 'pattern': r'山田\p{Script=Han}{1,3}'},
    {'label': '案件番号', 'pattern': r'PRJ-\d{4}'},
  ],
}) => jsonEncode({
  'schema_version': version,
  'redact_secrets': redact,
  'patterns': patterns,
});

/// サンプルの原文の本文を差し替え、追加規則のファイルを置いたVault。
Map<String, String> filesWith({String? patterns, String? body}) {
  final files = fixtureFiles();
  if (patterns != null) files[privacyPatternsPath] = patterns;
  if (body != null) {
    final raw = files[inputPath]!;
    final end = raw.indexOf('\n---\n', 4) + 5;
    files[inputPath] = '${raw.substring(0, end)}$body\n';
  }
  return files;
}

void main() {
  group('追加規則のファイル', () {
    test('ファイルがなければ組み込み規則だけを使う', () {
      final policy = SecretPolicy.fromSnapshot(const {}, const []);
      expect(policy.usable, isTrue);
      expect(policy.extra, isEmpty);
      expect(policy.redact('山田太郎 PRJ-1234'), '山田太郎 PRJ-1234');
    });

    test('追加規則を組み込み規則に足し、本体と同じ伏せ字の形にする', () {
      final policy = SecretPolicy.parse(patternsFile());
      expect(policy.usable, isTrue);
      expect(policy.extra.map((r) => r.id), ['custom-1', 'custom-2']);
      expect(
        policy.redact('山田太郎さんの PRJ-1234 と password=hunter2pass'),
        '[伏せ字:顧客名]さんの [伏せ字:案件番号] と password=[伏せ字:パスワード等]',
      );
      expect(describeSecrets(policy.find('PRJ-0001 と PRJ-0002')), '案件番号×2');
      // 伏せ字にしたものは、もう一度伏せない。
      final once = policy.redact('山田太郎 PRJ-1234');
      expect(policy.redact(once), once);
      // 組み込みの関数は、追加規則を渡さなければ今までと同じ。
      expect(redactSecrets('PRJ-1234'), 'PRJ-1234');
    });

    test('本体がredact_secretsをfalseにしていても、アプリは追加規則を当てる', () {
      final policy = SecretPolicy.parse(patternsFile(redact: false));
      expect(policy.redact('PRJ-1234'), '[伏せ字:案件番号]');
    });

    test('JavaScriptのuフラグと同じく、補助面の文字とUnicodeの性質を扱う', () {
      final policy = SecretPolicy.parse(
        patternsFile(
          patterns: [
            {'label': '絵文字', 'pattern': r'\u{1F511}+'},
            {'label': '社名', 'pattern': r'\p{Script=Katakana}+社'},
          ],
        ),
      );
      expect(policy.usable, isTrue);
      expect(policy.redact('鍵🔑🔑 と カブシキ社'), '鍵[伏せ字:絵文字] と [伏せ字:社名]');
    });

    test('壊れている・版が未知・解釈できない規則があれば、理由を示して使わない', () {
      final cases = <String, String>{
        '{': 'JSONとして読めません',
        '[]': '形式が不正です',
        patternsFile(version: 2): 'アプリを更新してください',
        jsonEncode({'schema_version': 1, 'patterns': []}): '形式が不正です',
        patternsFile(
          patterns: [
            {'label': '壊れた', 'pattern': '['},
          ],
        ): '1件目の規則「壊れた」をこのアプリで解釈できません',
        // JavaScriptのuフラグでも使えない書き方は、Dartでも使えない。
        patternsFile(
          patterns: [
            {'label': 'a', 'pattern': 'x'},
            {'label': '大小', 'pattern': '(?i)x'},
          ],
        ): '2件目の規則「大小」',
        patternsFile(
          patterns: [
            {'label': 'a]b', 'pattern': 'x'},
          ],
        ): '1件目の規則の形式が不正です',
        patternsFile(
          patterns: [
            {'label': 'a', 'pattern': 'x', 'flags': 'i'},
          ],
        ): '1件目の規則の形式が不正です',
        patternsFile(
          patterns: [
            {'label': 'a', 'pattern': ''},
          ],
        ): '1件目の規則の形式が不正です',
        patternsFile(
          patterns: [
            for (var i = 0; i < 51; i++) {'label': 'a$i', 'pattern': 'x'},
          ],
        ): '形式が不正です',
      };
      cases.forEach((raw, reason) {
        final policy = SecretPolicy.parse(raw);
        expect(policy.usable, isFalse, reason: raw);
        expect(policy.problem, contains(reason), reason: raw);
        expect(policy.problem, contains(privacyPatternsPath));
      });
    });

    test('読取が途中で止まってファイルを確かめられなければ使わない', () {
      for (final warning in [
        '読取の上限（ファイル20000件・合計64MB）に達したため、90_systemの一部を読めませんでした。',
        '読取できないファイル: 90_system/privacy/patterns.json',
        'symlinkを除外: 90_system/privacy/patterns.json',
        'フォルダーの読取を中断: 90_system',
        '深さの上限に達しました。',
      ]) {
        expect(
          SecretPolicy.fromSnapshot(const {}, [warning]).usable,
          isFalse,
          reason: warning,
        );
      }
      expect(
        SecretPolicy.fromSnapshot(const {}, [
          '読取できないファイル: 00_inbox/a.md',
        ]).usable,
        isTrue,
      );
    });
  });

  group('別AIへ渡すcontext', () {
    test('追加規則でも伏せる', () {
      final repo = HubRepository(
        fixture(
          filesWith(patterns: patternsFile(), body: '山田太郎さんと PRJ-1234 の件'),
        ),
      );
      expect(repo.warnings, isEmpty);
      for (final text in [
        repo.context('context-hub'),
        repo.vaultContext(),
        repo.bundleContext([
          repo.records.values.firstWhere((r) => r.path == inputPath).id,
        ]).text,
      ]) {
        expect(text, isNot(contains('山田太郎')));
        expect(text, isNot(contains('PRJ-1234')));
        expect(text, contains('[伏せ字:案件番号]'));
      }
    });

    test('追加規則を確かめられなければ作らない', () {
      final repo = HubRepository(
        fixture(filesWith(patterns: patternsFile(version: 2))),
      );
      for (final make in <String Function()>[
        () => repo.context('context-hub'),
        () => repo.vaultContext(),
        () => repo.bundleContext([
          repo.records.values.firstWhere((r) => r.path == inputPath).id,
        ]).text,
      ]) {
        expect(
          make,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('アプリを更新してください'),
            ),
          ),
        );
      }
    });
  });

  group('選んで深掘り', () {
    final secrets = SecretPolicy.parse(patternsFile());
    GuidedSession session() => GuidedSession(
      id: '11111111-2222-4333-8444-555555555555',
      vault: 'vault-identity',
      purpose: GuidedPurpose.record,
      seed: '山田太郎さんの件',
      context: '資料: PRJ-1234 の行',
      contextLabel: 'vault',
      startedAt: DateTime.utc(2026, 11, 12),
      steps: [
        GuidedStep(
          GuidedQuestion(
            text: 'どこで使う？',
            options: const [GuidedOption('本番'), GuidedOption('検証')],
          ),
          const GuidedAnswer.free('PRJ-9999 で使う'),
        ),
      ],
    );

    test('送る依頼と、伏せ字にして保存する本文に追加規則を当てる', () {
      for (final p in [
        guidedQuestionPrompt(session(), secrets: secrets),
        guidedSummaryPrompt(session(), secrets: secrets),
      ]) {
        final sent = '${p.context}\n${p.turn}';
        expect(sent, isNot(contains('山田太郎')));
        expect(sent, isNot(contains('PRJ-1234')));
        expect(sent, isNot(contains('PRJ-9999')));
        expect(p.turn, contains('「[伏せ字:顧客名]さんの件」'));
      }
      final body = guidedBody(
        'PRJ-1234 を直した',
        session(),
        redact: true,
        secrets: secrets,
      );
      expect(body, startsWith('[伏せ字:案件番号] を直した'));
      expect(body, isNot(contains('山田太郎')));
    });

    test('確かめられない規則では依頼を組み立てない', () {
      final broken = SecretPolicy.parse('{');
      expect(
        () => guidedQuestionPrompt(session(), secrets: broken),
        throwsStateError,
      );
      expect(
        () => guidedSummaryPrompt(session(), secrets: broken),
        throwsStateError,
      );
    });

    group('進行', () {
      late UncertainAccess access;
      late HubController hub;
      late FakeModel model;
      late Map<String, String> files;
      final now = DateTime(2026, 11, 7, 10);
      setUp(() async {
        access = UncertainAccess();
        await access.init();
        model = FakeModel();
        files = filesWith(patterns: patternsFile());
        access.current = fixture(files);
        hub = HubController(
          access,
          sampleLoader: () async => files,
          guided: GuidedServices(
            model: model,
            secrets: MemorySecrets('sk-ant-test-key-0000000000'),
            clock: () => now,
          ),
        );
        await hub.useSample();
      });
      tearDown(() async {
        hub.dispose();
        await access.directory.delete(recursive: true);
      });

      test('追加規則を確かめられなくなったら呼ばず、回数も数えない', () async {
        model.replies.add(question('何をしましたか？', ['読取', '画面']));
        final g = GuidedController(hub);
        addTearDown(g.dispose);
        await g.load();
        expect(g.secretPolicy.usable, isTrue);
        await g.start(
          GuidedPurpose.record,
          project: 'context-hub',
          seed: '山田太郎さんの件',
          context: g.buildContext('context-hub'),
        );
        expect(model.prompts, hasLength(1));
        expect(model.prompts.single.turn, isNot(contains('山田太郎')));
        // 本体の設定が壊れた状態で同期された。
        hub.repository = HubRepository(
          VaultSnapshot({...files, privacyPatternsPath: '{'}),
        );
        expect(g.secretPolicy.usable, isFalse);
        await g.answer(const GuidedAnswer.selected(['読取']));
        expect(model.prompts, hasLength(1));
        expect(g.error, contains(privacyPatternsPath));
        final state = await GuidedStore(access).read(now);
        expect(state.usage.calls, 1);
      });
    });

    group('画面', () {
      late MemoryUIAccess access;
      late HubController c;
      late FakeModel model;

      Future<void> openApp(WidgetTester tester, String patterns) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        access = MemoryUIAccess()
          ..current = fixture(filesWith(patterns: patterns));
        model = FakeModel();
        c = HubController(
          access,
          sampleLoader: () async => filesWith(patterns: patterns),
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

      testWidgets('確かめられない規則があれば、理由を示して始めさせない', (tester) async {
        await openApp(tester, patternsFile(version: 2));
        await tapKey(tester, 'open-guided');
        expect(find.byKey(const Key('guided-secret-problem')), findsOneWidget);
        expect(find.textContaining('アプリを更新してください'), findsWidgets);
        final start = tester.widget<FilledButton>(
          find.byKey(const Key('guided-start')),
        );
        expect(start.onPressed, isNull);
        expect(model.prompts, isEmpty);
      });

      testWidgets('メモの保存の前に、追加規則に当たる文字列も知らせて伏せ字にできる', (tester) async {
        await openApp(tester, patternsFile());
        await tapKey(tester, 'new-memo');
        await tester.enterText(
          find.byKey(const Key('memo-text')),
          '案件 PRJ-1234 の打ち合わせ',
        );
        await tapKey(tester, 'save-memo');
        expect(find.byKey(const Key('secret-warning')), findsOneWidget);
        expect(find.textContaining('案件番号に見える文字列があります'), findsOneWidget);
        await tapKey(tester, 'secret-redact');
        final body = parseMarkdown(access.requests.values.single).body;
        expect(body, '案件 [伏せ字:案件番号] の打ち合わせ');
      });
    });
  });
}
