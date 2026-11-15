import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'fixtures.dart';
import 'next_actions_test.dart' show multiProjectFiles, withProject;
import 'widget_test.dart' show MemoryUIAccess;

/// ホーム画面の機能を持つ端末（Android）の代わり。渡された内容と起動時の操作を記録する。
class HomeScreenAccess extends MemoryUIAccess {
  final sent = <String?>[];
  String? action;
  void Function()? onAction;
  bool failUpdate = false;
  @override
  bool get homeScreenSupported => true;
  @override
  Future<void> updateHomeWidget(String? content) async {
    if (failUpdate) throw StateError('更新できません');
    sent.add(content);
  }

  @override
  Future<String?> takeLaunchAction() async {
    final value = action;
    action = null;
    return value;
  }

  @override
  void listenLaunchActions(void Function() onAction) =>
      this.onAction = onAction;
}

void main() {
  const key = 'sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123';

  test('既定では件数と読込時刻だけを出し、本文とプロジェクト名は出さない', () {
    final repo = HubRepository(fixture(multiProjectFiles()));
    final content = homeWidgetContent(repo);
    expect(content['title'], 'ContextHub');
    expect(content['counts'], '次の一手 2件 · 確認待ち ${repo.review.pending.length}件');
    expect(content['lines'], isEmpty);
    expect(content['footer'], '読込 2026-10-30 09:00 JST');
    final raw = encodeHomeWidget(content);
    expect(raw, isNot(contains('設定画面')));
    expect(raw, isNot(contains('別のアプリ')));
  });

  test('本文を出す設定では進行中の次の一手を3件まで出し、秘密情報らしい文字列は伏せる', () {
    var files = multiProjectFiles();
    for (final (i, id) in ['p-one', 'p-two', 'p-three'].indexed) {
      files = withProject(
        files,
        id,
        '追加$i',
        lastEvidence: '2026-10-2${i + 1}T09:00:00+09:00',
        next: i == 2 ? '本番キー $key を差し替える。' : '作業$iを進める。',
      );
    }
    final content = homeWidgetContent(
      HubRepository(fixture(files)),
      settings: const HomeWidgetSettings(showText: true),
    );
    final lines = content['lines'] as List;
    expect(lines, hasLength(homeWidgetMaxLines));
    // 最新の根拠が新しいプロジェクトから並べ、休止中は出さない。
    expect(lines.first, '本番キー [伏せ字:APIキー] を差し替える。（追加2）');
    expect(jsonEncode(content), isNot(contains(key)));
    expect(jsonEncode(content), isNot(contains('休止中')));
    expect(content['counts'], startsWith('次の一手 5件'));
  });

  test('プロジェクトを選ぶとその件数に絞り、進行中でなくなってもほかのプロジェクトは出さない', () {
    final repo = HubRepository(fixture(multiProjectFiles()));
    final scoped = homeWidgetContent(
      repo,
      settings: const HomeWidgetSettings(showText: true, projectId: 'side-app'),
    );
    expect(scoped['title'], '別のアプリ');
    expect(scoped['counts'], startsWith('次の一手 1件'));
    expect(scoped['lines'], ['設定画面を作る。']);
    // 本文を出さない設定では、プロジェクト名も出さない。
    final hidden = homeWidgetContent(
      repo,
      settings: const HomeWidgetSettings(projectId: 'side-app'),
    );
    expect(hidden['title'], '選んだプロジェクト');
    expect(hidden['lines'], isEmpty);
    // 選んだプロジェクトが進行中でなくなっても、ほかのプロジェクトの内容へ広げない。
    for (final (id, title) in [
      ('old-plan', '休止中の計画'),
      ('missing', '選んだプロジェクト'),
    ]) {
      final none = homeWidgetContent(
        repo,
        settings: HomeWidgetSettings(showText: true, projectId: id),
      );
      expect(none['title'], title);
      expect(none['counts'], startsWith('進行中ではありません'));
      expect(none['lines'], isEmpty);
      expect(jsonEncode(none), isNot(contains('設定画面')));
      expect(jsonEncode(none), isNot(contains('サンプルの検索')));
    }
  });

  test('長い本文は切り、上限を超える内容は件数だけにする', () {
    final files = withProject(
      fixtureFiles(),
      'long',
      '長いプロジェクト',
      lastEvidence: '2026-10-29T09:00:00+09:00',
      next: '${'あ' * 200}。',
    );
    final content = homeWidgetContent(
      HubRepository(fixture(files)),
      settings: const HomeWidgetSettings(showText: true),
    );
    final first = (content['lines'] as List).first as String;
    expect(first, startsWith('${'あ' * homeWidgetLineChars}…'));
    expect(
      utf8.encode(encodeHomeWidget(content)).length,
      lessThanOrEqualTo(homeWidgetMaxBytes),
    );
    final big = {
      ...content,
      'lines': ['あ' * 2000],
    };
    expect(jsonDecode(encodeHomeWidget(big))['lines'], isEmpty);
    expect(
      HomeWidgetSettings.fromJson({'showText': 'yes', 'project': 3}),
      const HomeWidgetSettings(),
    );
  });

  test('読込のたびにウィジェットへ内容を渡し、設定は端末に保存して次の起動で使う', () async {
    final access = HomeScreenAccess();
    final c = HubController(
      access,
      sampleLoader: () async => multiProjectFiles(),
    );
    access.current = fixture(multiProjectFiles());
    await c.useSample();
    expect(access.sent, hasLength(1));
    expect(jsonDecode(access.sent.single!)['lines'], isEmpty);
    // 同じ内容は渡し直さない。
    await c.reload();
    expect(access.sent, hasLength(1));
    await c.setHomeWidget(
      const HomeWidgetSettings(showText: true, projectId: 'side-app'),
    );
    expect(jsonDecode(access.sent.last!)['lines'], ['設定画面を作る。']);
    // 設定はVaultごとに保存する。
    expect(jsonDecode(access.states['settings.json']!)['homeWidget'], {
      'sample': {'showText': true, 'project': 'side-app'},
    });
    // 別のVaultへ切り替えると、そのVaultの設定（既定は件数だけ）で渡す。
    await c.activate(const VaultLocation('other', '別のVault'));
    expect(c.homeWidget, const HomeWidgetSettings());
    expect(jsonDecode(access.sent.last!)['lines'], isEmpty);
    expect(jsonDecode(access.sent.last!)['title'], 'ContextHub');
    await c.useSample();
    expect(jsonDecode(access.sent.last!)['title'], '別のアプリ');
    c.dispose();
    // 次の起動では保存した設定で渡す。
    final next = HomeScreenAccess()..states.addAll(access.states);
    final restored = HubController(
      next,
      sampleLoader: () async => multiProjectFiles(),
    );
    next.current = fixture(multiProjectFiles());
    await restored.restore();
    expect(restored.homeWidget.projectId, 'side-app');
    expect(jsonDecode(next.sent.single!)['title'], '別のアプリ');
    // 渡せなくても読込は続ける。
    next.failUpdate = true;
    await restored.setHomeWidget(const HomeWidgetSettings());
    expect(restored.error, isNull);
    restored.dispose();
  });

  test('ホーム画面の機能がない端末（Mac）では何も渡さない', () async {
    final access = MemoryUIAccess();
    final c = HubController(access, sampleLoader: () async => fixtureFiles());
    await c.useSample();
    expect(c.homeScreenSupported, isFalse);
    expect(access.states['settings.json'], isNot(contains('homeWidget')));
    c.dispose();
  });

  testWidgets('ショートカットで選んだ操作を、読込の後に開く', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final access = HomeScreenAccess();
    access.current = fixture(multiProjectFiles());
    access.states['settings.json'] = jsonEncode({
      'handle': 'sample',
      'name': '架空サンプル',
      'identity': 'sample',
    });
    access.action = 'capture';
    final c = HubController(access, sampleLoader: () async => fixtureFiles());
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    // 起動時の指定でメモの入力が開く。保存はしていない。
    expect(find.byKey(const Key('memo-text')), findsOneWidget);
    expect(access.requests, isEmpty);
    // 入力を開いている間に届いた操作は割り込まず、開けなかったことを知らせる。
    access.action = 'next';
    access.onAction!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memo-text')), findsOneWidget);
    expect(find.text('開いている入力や確認を閉じてから、もう一度お試しください。'), findsOneWidget);
    await tester.tap(find.text('フォームを閉じる'));
    await tester.pumpAndSettle();
    // 記録の詳細を開いていても、その上にメモの入力を開く。
    await tester.ensureVisible(
      find.byKey(const Key('project-context-hub')).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-context-hub')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('source-record')).first);
    await tester.pumpAndSettle();
    expect(find.text('出典・日時'), findsOneWidget);
    expect(find.byKey(const Key('memo-text')), findsNothing);
    access.action = 'capture';
    access.onAction!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memo-text')), findsOneWidget);
    await tester.tap(find.text('フォームを閉じる'));
    await tester.pumpAndSettle();
    // 「次の一手」は、開いていた記録の詳細を閉じて一覧へ戻る。
    access.action = 'next';
    access.onAction!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('next-section')), findsOneWidget);
    expect(find.text('出典・日時'), findsNothing);
    // 確認の画面（ここではアプリの情報）を開いている間は割り込まない。
    await tester.tap(find.byTooltip('このアプリについて'));
    await tester.pumpAndSettle();
    access.action = 'capture';
    access.onAction!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memo-text')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    // お知らせの表示が消えるのを待つ。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    // 表示設定を開いて保存できる。
    await tester.tap(find.byKey(const Key('home-widget-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-widget-text')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-widget-save')));
    await tester.pumpAndSettle();
    expect(c.homeWidget.showText, isTrue);
    expect(jsonDecode(access.sent.last!)['lines'], isNotEmpty);
  });

  testWidgets('Vaultを選ぶ前のショートカットは、選ぶよう知らせるだけにする', (tester) async {
    final access = HomeScreenAccess()..action = 'capture';
    final c = HubController(access, sampleLoader: () async => fixtureFiles());
    addTearDown(c.dispose);
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('先にVaultフォルダーを選んでください。'), findsOneWidget);
    expect(find.byKey(const Key('memo-text')), findsNothing);
    expect(access.sent, isEmpty);
  });
}
