import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/ai/claude_client.dart';
import 'package:context_hub_client/ai/guided_services.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/storage/guided_store.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'fixtures.dart';
import 'guided_test.dart'
    show FakeModel, MemorySecrets, question, recordSummary;
import 'widget_test.dart' show MemoryUIAccess;

/// 読み戻しを失敗させ、保存結果が不明な保存を作る（Inputには書く）。
class UncertainUIAccess extends MemoryUIAccess {
  bool failRead = false;
  @override
  Future<String?> readRequest(VaultLocation l, String id) async {
    if (failRead) throw StateError('読めない');
    return super.readRequest(l, id);
  }
}

void main() {
  late UncertainUIAccess access;
  late HubController c;
  late FakeModel model;
  late MemorySecrets secrets;

  Future<void> openApp(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    access = UncertainUIAccess();
    await access.init();
    model = FakeModel();
    secrets = MemorySecrets();
    c = HubController(
      access,
      sampleLoader: () async => fixture().files,
      guided: GuidedServices(model: model, secrets: secrets),
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

  testWidgets('キーを登録し、選んで答え、直したまとめをInputへ保存できる', (tester) async {
    await openApp(tester);
    await tapKey(tester, 'open-guided');
    expect(find.byKey(const Key('guided-no-key')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('guided-start')))
          .onPressed,
      isNull,
    );

    await tapKey(tester, 'guided-settings');
    await tester.enterText(find.byKey(const Key('guided-key')), 'short');
    await tapKey(tester, 'guided-key-save');
    expect(find.text('APIキーの長さを確かめてください。'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('guided-key')),
      ' sk-ant-test-key-0000000000 ',
    );
    await tapKey(tester, 'guided-key-save');
    expect(secrets.value, 'sk-ant-test-key-0000000000');
    expect(find.text('APIキー: 登録済み'), findsOneWidget);
    await tapKey(tester, 'guided-settings-close');
    expect(find.byKey(const Key('guided-no-key')), findsNothing);

    // 送る資料は始める前に見せ、そのまま送る。
    await tapKey(tester, 'guided-context-preview');
    expect(find.textContaining('# 進行中のプロジェクト'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('guided-seed')), '今日の作業');
    model.replies.addAll([
      question('何をしましたか？', ['読取を直した', '画面を作った'], understanding: '今日の作業の記録'),
      question('当てはまるものは？', ['テスト', '文書', 'レビュー'], multi: true),
      question('次に何をしますか？', ['計測', '後回し']),
      recordSummary(),
    ]);
    await tapKey(tester, 'guided-start');
    expect(find.text('何をしましたか？'), findsOneWidget);
    expect(model.prompts.single.context, contains('# 進行中のプロジェクト'));
    expect(model.prompts.single.turn, contains('「今日の作業」'));
    await tapKey(tester, 'guided-option-0');
    expect(find.text('当てはまるものは？'), findsOneWidget);
    expect(find.text('今日の作業の記録'), findsOneWidget);
    await tapKey(tester, 'guided-option-0');
    await tapKey(tester, 'guided-option-2');
    await tapKey(tester, 'guided-next');
    expect(find.text('次に何をしますか？'), findsOneWidget);
    expect(find.byKey(const Key('guided-step-1')), findsOneWidget);
    await tapKey(tester, 'guided-other');
    await tester.enterText(
      find.byKey(const Key('guided-other-text')),
      '計測してから決める',
    );
    model.replies.insert(0, question('いつまでに？', ['今週', '来週']));
    await tapKey(tester, 'guided-other-send');
    expect(find.text('いつまでに？'), findsOneWidget);
    expect(
      model.prompts.last.turn,
      contains('3. 次に何をしますか？ → 「計測してから決める」（自由入力）'),
    );

    await tapKey(tester, 'guided-wrap');
    expect(find.byKey(const Key('guided-summary')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('guided-summary')),
      '## まとめ\n読取を直し、テストとレビューをした。',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tapKey(tester, 'guided-log');
    expect(find.textContaining('2. 当てはまるものは？ → テスト、レビュー（選択）'), findsOneWidget);
    await tapKey(tester, 'guided-save');
    expect(find.byKey(const Key('guided-saved')), findsOneWidget);
    final raw = access.requests.values.single;
    final packet = parseMarkdown(raw);
    expect(packet.meta['kind'], 'memo');
    expect((packet.meta['meta'] as Map)['capture_mode'], 'guided');
    expect((packet.meta['meta'] as Map)['guided_context'], 'vault');
    expect(packet.body, startsWith('## まとめ\n読取を直し、テストとレビューをした。\n\n## 問答の記録'));
    expect(packet.body, contains('1. 何をしましたか？ → 読取を直した（選択）'));
    final stored = jsonDecode(access.states[GuidedStore.fileName]!) as Map;
    expect(stored.containsKey('session'), isFalse);
    await tapKey(tester, 'guided-close');
    expect(find.byKey(const Key('new-memo')), findsOneWidget);
  });

  testWidgets('プロジェクト画面から始め、答え直しと再開ができる', (tester) async {
    await openApp(tester);
    secrets.value = 'sk-ant-test-key-0000000000';
    await tester.tap(find.byKey(const Key('project-context-hub')).first);
    await tester.pumpAndSettle();
    await tapKey(tester, 'project-guided');
    final dropdown = find.byKey(const Key('guided-project'));
    expect(
      find.descendant(of: dropdown, matching: find.text('AI Context Hub')),
      findsWidgets,
    );
    await tapKey(tester, 'guided-include-context');
    expect(find.byKey(const Key('guided-context-preview')), findsNothing);
    expect(find.textContaining('プロジェクトの名前などVaultの内容は送りません'), findsOneWidget);
    await tester.tap(find.text('壁打ち'));
    await tester.pumpAndSettle();
    model.replies.addAll([
      question('何に迷っていますか？', ['順番', '範囲']),
      question('どちらが先？', ['A', 'B']),
    ]);
    await tapKey(tester, 'guided-start');
    expect(model.prompts.single.context, contains('資料は送っていません'));
    expect(model.prompts.single.turn, contains('壁打ち'));
    // 資料を送らないときは、プロジェクトの名前とIDも送らない。
    expect(model.prompts.single.turn, isNot(contains('context-hub')));
    expect(model.prompts.single.turn, isNot(contains('AI Context Hub')));
    await tapKey(tester, 'guided-option-1');
    expect(find.text('どちらが先？'), findsOneWidget);
    await tapKey(tester, 'guided-step-0');
    await tapKey(tester, 'guided-confirm-action');
    expect(find.text('何に迷っていますか？'), findsOneWidget);
    expect(find.byKey(const Key('guided-step-0')), findsNothing);
    // 閉じても、次に開くと続きから再開できる。
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(c.composing, isFalse);
    await tapKey(tester, 'project-guided');
    expect(find.byKey(const Key('guided-resume')), findsOneWidget);
    await tapKey(tester, 'guided-resume-continue');
    expect(find.text('何に迷っていますか？'), findsOneWidget);
    expect(model.prompts, hasLength(2));
  });

  testWidgets('狭い画面ではナビゲーションから開き、Claudeの失敗を案内してやり直せる', (tester) async {
    await openApp(tester, size: const Size(360, 800));
    secrets.value = 'sk-ant-test-key-0000000000';
    // 題名の幅を残すため、AppBarには置かない。
    expect(find.byKey(const Key('open-guided')), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'nav-guided');
    model.replies.add(
      const ModelException('Claudeが混み合っているか、一時的に使えません（529）。', retryable: true),
    );
    await tapKey(tester, 'guided-start');
    expect(find.textContaining('混み合っている'), findsOneWidget);
    model.replies.add(question('何を思いつきましたか？', ['道具', '仕組み']));
    await tapKey(tester, 'guided-retry');
    expect(find.text('何を思いつきましたか？'), findsOneWidget);
  });

  testWidgets('保存結果が不明なまま破棄するときは、保存済みの可能性を伝える', (tester) async {
    await openApp(tester);
    secrets.value = 'sk-ant-test-key-0000000000';
    await tapKey(tester, 'open-guided');
    model.replies.addAll([
      question('何をしましたか？', ['読取を直した', '画面を作った']),
      question('次に何をしますか？', ['計測', '後回し']),
      recordSummary(),
    ]);
    await tapKey(tester, 'guided-start');
    await tapKey(tester, 'guided-option-0');
    await tapKey(tester, 'guided-wrap');
    access.failRead = true;
    await tapKey(tester, 'guided-save');
    expect(find.byKey(const Key('guided-uncertain')), findsOneWidget);
    expect(access.requests, hasLength(1));
    // 確かめるまでは破棄できない。
    expect(find.byKey(const Key('guided-discard')), findsNothing);
    await tapKey(tester, 'guided-confirm');
    await tapKey(tester, 'guided-discard');
    expect(find.textContaining('保存済みの可能性があるため'), findsOneWidget);
    expect(find.textContaining('Vaultには何も書いていません'), findsNothing);
    await tapKey(tester, 'guided-confirm-action');
    expect(find.byKey(const Key('guided-start')), findsOneWidget);
    // 操作の記録は残り、受付状況で確かめられる。
    expect(c.pending, hasLength(1));
  });

  testWidgets('APIキーを読み出せないときは理由を示し、読み出し直せる', (tester) async {
    await openApp(tester);
    secrets
      ..value = 'sk-ant-test-key-0000000000'
      ..fail = true;
    await tapKey(tester, 'open-guided');
    expect(find.byKey(const Key('guided-key-problem')), findsOneWidget);
    expect(find.byKey(const Key('guided-no-key')), findsNothing);
    secrets.fail = false;
    await tapKey(tester, 'guided-key-retry');
    expect(find.byKey(const Key('guided-key-problem')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('guided-start')))
          .onPressed,
      isNotNull,
    );
    expect(secrets.reads, 2);
  });
}
