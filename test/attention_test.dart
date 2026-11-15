import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/attention_check.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/attention.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'fixtures.dart';
import 'review_test.dart' show reviewFiles;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show draftJson, draftPath, draftId;

const project = 'project:context-hub';
const conflictPath =
    '90_system/conflicts/NOW.context-hub.01M2DSFVRRA5MFS95MKFPP2CCZ.md';

/// 確認待ちの候補（4件）のあるVault。
Map<String, String> baseFiles() => {...fixtureFiles(), ...reviewFiles()};

/// 作業記録の下書きを1件足す。
Map<String, String> withDraft(Map<String, String> files) => {
  ...files,
  draftPath: draftJson(),
};

/// NOWを手で書き換えて更新が止まった状態にする。
Map<String, String> withConflict(Map<String, String> files) => {
  ...files,
  conflictPath: files[nowPath]!,
  nowPath: files[nowPath]!.replaceFirst('- サンプルの検索を確認する。', '- 手で直した次の一手'),
};

/// ドックのバッジ（Mac）と確認待ちの通知（Android）の代わり。渡された内容を記録する。
class AttentionAccess extends MemoryUIAccess {
  AttentionAccess({this.mac = false, this.android = false});
  final bool mac, android;
  final badges = <int>[];
  final notices = <(String, String, String)>[];
  final toggles = <({bool enabled, bool request})>[];
  int cleared = 0, snapshots = 0, finished = 0;
  bool granted = true;
  String? action;
  void Function()? onAction;
  @override
  void listenLaunchActions(void Function() onAction) =>
      this.onAction = onAction;

  /// 保存した依頼を次の読込に含める（同期済みの端末のInputと同じ見え方）。
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) async {
    snapshots++;
    return VaultSnapshot({
      ...current.files,
      for (final e in requests.entries) 'Input/${e.key}.md': e.value,
    }, warnings: current.warnings);
  }

  @override
  bool get dockBadgeSupported => mac;
  @override
  Future<void> setDockBadge(int count) async => badges.add(count);
  @override
  bool get attentionNotificationsSupported => android;
  @override
  bool get homeScreenSupported => android;
  @override
  Future<String?> takeLaunchAction() async {
    final value = action;
    action = null;
    return value;
  }

  @override
  Future<bool> setAttentionNotifications({
    required bool enabled,
    bool request = false,
  }) async {
    toggles.add((enabled: enabled, request: request));
    return enabled && granted;
  }

  @override
  Future<void> showAttentionNotification({
    required String key,
    required String title,
    required String text,
  }) async => notices.add((key, title, text));
  @override
  Future<void> clearAttentionNotification() async => cleared++;
  @override
  Future<void> finishBackgroundCheck() async => finished++;
}

Map<String, dynamic> settingsOf(AttentionAccess access) =>
    jsonDecode(access.states['settings.json']!) as Map<String, dynamic>;

void main() {
  test('確認待ちの候補・作業記録の下書き・止まったNOWを、判断できる画面ごとに数える', () {
    final repo = HubRepository(fixture(withConflict(withDraft(baseFiles()))));
    final items = attentionItems(repo);
    expect(items.where((i) => i.kind == 'candidate'), hasLength(4));
    expect(
      items.where((i) => i.kind == 'candidate').map((i) => i.page).toSet(),
      {'review'},
    );
    expect(items.where((i) => i.page == project).map((i) => i.kind), [
      'draft',
      'conflict',
    ]);
    // 要確認（古い根拠・未同期）や判断済みの候補は数えない。
    expect(repo.review.attention, isNotEmpty);
    expect(repo.review.history, isNotEmpty);
    // 鍵は短いhashで、IDそのものを端末に残さない。
    for (final i in items) {
      expect(i.key, matches(RegExp(r'^[a-f0-9]{12}$')));
    }
    expect(items.map((i) => i.key).toSet(), hasLength(items.length));
    expect(
      jsonEncode(items.map((i) => i.key).toList()),
      isNot(contains('CAN-')),
    );
    // 手で書き換え直すと、新しい判断待ちとして扱う。
    final edited = withConflict(withDraft(baseFiles()));
    edited[nowPath] = edited[nowPath]!.replaceFirst('手で直した', 'もう一度直した');
    final again = attentionItems(HubRepository(fixture(edited)));
    expect(
      again.firstWhere((i) => i.kind == 'conflict').key,
      isNot(items.firstWhere((i) => i.kind == 'conflict').key),
    );
    expect(
      again.firstWhere((i) => i.kind == 'draft').key,
      items.firstWhere((i) => i.kind == 'draft').key,
    );
  });

  test('初めてのVaultではすべて既読にし、後から増えた分だけを新着・通知の対象にする', () {
    final a = AttentionItem('candidate', 'CAN-A', 'review'),
        b = AttentionItem('draft', 'GDR-B', project),
        c = AttentionItem('candidate', 'CAN-C', 'review');
    final first = const AttentionState().sync('vault-1', [a]);
    expect(first.fresh([a]), isEmpty);
    expect(first.unknown([a]), isEmpty);
    // まだ読み込んでいない判断待ちは、新着で、通知の対象。
    expect(first.fresh([a, b]), [b]);
    expect(first.unknown([a, b]), [b]);
    // アプリで読み込むと通知の対象から外れるが、画面を開くまでは新着のまま。
    final loaded = first.sync('vault-1', [a, b]);
    expect(loaded.unknown([a, b]), isEmpty);
    expect(loaded.fresh([a, b]), [b]);
    // 判断できる画面を開くと既読になる。別の画面の分は変えない。
    final other = loaded.sync('vault-1', [a, b, c]);
    expect(other.markSeen(project, [a, b, c]).fresh([a, b, c]), [c]);
    // その画面を開いたまま読み込んだ分は、見たものとして既読にする。
    expect(
      loaded.sync('vault-1', [a, b, c], visible: 'review').fresh([a, b, c]),
      [b],
    );
    // 片付いたものは記録から消し、もう一度現れたら新着に戻す。
    final gone = loaded.markSeen(project, [a, b]).sync('vault-1', [a]);
    expect(gone.keys.keys, [a.key]);
    expect(gone.fresh([a, b]), [b]);
    // 読取が途中で終わったときは、見つからない記録を消さない。
    final partial = loaded.markSeen(project, [a, b]).sync('vault-1', [
      a,
    ], prune: false);
    expect(partial.fresh([a, b]), isEmpty);
    // 別のVaultを開いたら、記録を作り直す。
    final switched = loaded.sync('vault-2', [c]);
    expect(switched.identity, 'vault-2');
    expect(switched.keys.keys, [c.key]);
    expect(switched.fresh([c]), isEmpty);
  });

  test('覚えきれない数になったら、覚えていない分を新着・通知の対象にしない', () {
    final many = [
      for (var i = 0; i < attentionMaxKeys + 20; i++)
        AttentionItem('candidate', 'CAN-$i', 'review'),
    ];
    final base = const AttentionState().sync('vault-1', many.take(3).toList());
    final full = base.sync('vault-1', many);
    expect(full.full, isTrue);
    expect(full.keys, hasLength(attentionMaxKeys));
    expect(full.unknown(many), isEmpty);
    // 覚えている分は、見たかどうかを保つ。
    expect(full.fresh(many).length, lessThanOrEqualTo(attentionMaxKeys));
    expect(full.fresh(many.take(3)), isEmpty);
    expect(
      utf8.encode(jsonEncode(full.toJson())).length,
      lessThan(8 * 1024),
      reason: '設定ファイルの容量を圧迫しない',
    );
    // 覚えられる数に戻ったら、通常の扱いに戻す。
    final few = full.sync('vault-1', many.take(5).toList());
    expect(few.full, isFalse);
    expect(few.unknown([many.last]), [many.last]);
  });

  test('既読の記録は設定ファイルから復元し、読めない値は記録なしとして扱う', () {
    final a = AttentionItem('candidate', 'CAN-A', 'review'),
        b = AttentionItem('draft', 'GDR-B', project);
    final state = const AttentionState().sync('vault-1', [a]).sync('vault-1', [
      a,
      b,
    ]);
    final restored = AttentionSettings.fromJson(
      jsonDecode(jsonEncode(AttentionSettings(state, true).toJson())),
    );
    expect(restored.notify, isTrue);
    expect(restored.state, state);
    expect(restored.state.fresh([a, b]), [b]);
    for (final broken in [
      null,
      'x',
      {'vault': 1, 'keys': {}},
      {'vault': 'v', 'keys': []},
    ]) {
      final value = AttentionSettings.fromJson(broken);
      expect(value.notify, isFalse);
      expect(value.state.identity, isNull);
      expect(value.state.keys, isEmpty);
    }
    // 形式の違う鍵は捨て、通知の設定は保つ。
    final odd = AttentionSettings.fromJson({
      'vault': 'v',
      'notify': true,
      'keys': {'CAN-RAW-ID': 1, a.key: 1},
    });
    expect(odd.notify, isTrue);
    expect(odd.state.keys.keys, [a.key]);
  });

  test('通知の文は件数と種類だけで、同じ内容には同じ鍵を付ける', () {
    expect(attentionNotice(const []), isNull);
    final items = attentionItems(
      HubRepository(fixture(withConflict(withDraft(baseFiles())))),
    );
    final notice = attentionNotice(items)!;
    expect(notice.title, '確認待ちが6件増えています');
    expect(notice.text, '候補 4件 · 作業記録の下書き 1件 · 止まったNOW 1件（この端末に同期済みの内容）');
    expect(notice.key, attentionNotice(items.reversed.toList())!.key);
    expect(notice.key, isNot(attentionNotice(items.skip(1).toList())!.key));
    // 端末側の上限（題名80字・本文200字・鍵64字）に収まる。
    expect(notice.title.length, lessThanOrEqualTo(80));
    expect(notice.text.length, lessThanOrEqualTo(200));
    expect(notice.key.length, lessThanOrEqualTo(64));
  });

  group('アプリを閉じている間の確認', () {
    late AttentionAccess access;
    late HubController c;
    setUp(() async {
      access = AttentionAccess(android: true)..current = fixture(baseFiles());
      c = HubController(access, sampleLoader: () async => baseFiles());
      await c.useSample();
      access.snapshots = 0;
    });
    tearDown(() => c.dispose());

    test('通知の設定が無効なら、Vaultを読まない', () async {
      expect(await runAttentionCheck(access), isFalse);
      expect(access.snapshots, 0);
      expect(access.notices, isEmpty);
    });

    test('アプリで出していない判断待ちが増えたときだけ、件数と種類を通知する', () async {
      expect(await c.setAttentionNotify(true), isTrue);
      expect(access.toggles.last, (enabled: true, request: true));
      expect(settingsOf(access)['attention']['notify'], isTrue);
      // 増えていなければ通知しない。
      expect(await runAttentionCheck(access), isFalse);
      expect(access.snapshots, 1);
      expect(access.notices, isEmpty);
      // 下書きが同期されてきたら通知する。本文は出さない。
      access.current = fixture(withDraft(baseFiles()));
      final before = access.states['settings.json'];
      expect(await runAttentionCheck(access), isTrue);
      final (key, title, text) = access.notices.single;
      expect(title, '確認待ちが1件増えています');
      expect(text, '作業記録の下書き 1件（この端末に同期済みの内容）');
      expect('$title$text', isNot(contains('画面を追加')));
      expect('$title$text', isNot(contains(draftId)));
      // 確認は設定ファイルを書き換えない。同じ内容なら同じ鍵で、端末側が出し直さない。
      expect(access.states['settings.json'], before);
      expect(await runAttentionCheck(access), isTrue);
      expect(access.notices.last.$1, key);
      // アプリで読み込むと通知を消し、次の確認では通知しない。
      final cleared = access.cleared;
      await c.reload();
      expect(access.cleared, greaterThan(cleared));
      access.notices.clear();
      expect(await runAttentionCheck(access), isFalse);
      expect(access.notices, isEmpty);
    });

    test('読取が途中で終わって候補が欠けて見えても、戻ったときに通知しない', () async {
      await c.setAttentionNotify(true);
      access.current = VaultSnapshot(
        baseFiles(),
        warnings: const ['読取できないファイル: 00_inbox/x.md'],
      );
      await c.reload();
      expect(c.attentionCount('review'), 0);
      access.current = fixture(baseFiles());
      expect(await runAttentionCheck(access), isFalse);
      expect(access.notices, isEmpty);
    });

    test('設定が壊れている・アプリでまだ開いていないVaultでは通知しない', () async {
      await c.setAttentionNotify(true);
      access.current = fixture(withDraft(baseFiles()));
      final settings = settingsOf(access);
      access.states['settings.json'] = jsonEncode({
        ...settings,
        'identity': 'another-vault',
      });
      expect(await runAttentionCheck(access), isFalse);
      access.states['settings.json'] = '[]';
      expect(await runAttentionCheck(access), isFalse);
      access.states.remove('settings.json');
      expect(await runAttentionCheck(access), isFalse);
      expect(access.notices, isEmpty);
    });

    test('端末で通知が許可されていなければ、設定を有効にしない', () async {
      access.granted = false;
      expect(await c.setAttentionNotify(true), isFalse);
      expect(c.attentionNotify, isFalse);
      expect(settingsOf(access)['attention']['notify'], isNull);
      // 無効にするときは、確認の登録を消す。
      access.granted = true;
      await c.setAttentionNotify(true);
      expect(await c.setAttentionNotify(false), isTrue);
      expect(access.toggles.last, (enabled: false, request: false));
      expect(settingsOf(access)['attention']['notify'], isNull);
    });

    test('次の起動で設定を復元し、許可画面を出さずに確認を登録し直す', () async {
      await c.setAttentionNotify(true);
      access.toggles.clear();
      final next = HubController(access, sampleLoader: () async => baseFiles());
      addTearDown(next.dispose);
      await next.restore();
      expect(next.attentionNotify, isTrue);
      expect(access.toggles, [(enabled: true, request: false)]);
      // 再読込のたびには登録し直さない。
      await next.reload();
      expect(access.toggles, hasLength(1));
    });
  });

  group('件数と既読', () {
    late AttentionAccess access;
    late HubController c;
    setUp(() async {
      access = AttentionAccess(mac: true)..current = fixture(baseFiles());
      c = HubController(access, sampleLoader: () async => baseFiles());
      await c.useSample();
    });
    tearDown(() => c.dispose());

    test('初回は既読として記録し、ドックに判断待ちの件数を出す', () async {
      expect(c.attentionCount('review'), 4);
      expect(c.attentionFresh('review'), 0);
      expect(access.badges.last, 4);
      final saved = settingsOf(access)['attention'] as Map;
      expect(saved['vault'], c.location!.identity);
      expect((saved['keys'] as Map).values.toSet(), {1});
      // Macでは通知の操作をしない。
      expect(access.cleared, 0);
      expect(access.toggles, isEmpty);
    });

    test('増えた分を新着として示し、判断できる画面を開くと既読にして次の起動でも保つ', () async {
      access.current = fixture(withConflict(withDraft(baseFiles())));
      await c.reload();
      expect(access.badges.last, 6);
      expect(c.attentionCount(project), 2);
      expect(c.attentionFresh(project), 2);
      expect(c.attentionFresh('review'), 0);
      // 別の画面を開いても既読にしない。
      await c.showPage('review');
      expect(c.attentionFresh(project), 2);
      await c.showPage(project);
      expect(c.attentionFresh(project), 0);
      expect(c.attentionCount(project), 2);
      final next = HubController(access, sampleLoader: () async => baseFiles());
      addTearDown(next.dispose);
      await next.restore();
      expect(next.attentionCount(project), 2);
      expect(next.attentionFresh(project), 0);
    });

    test('開いている画面に届いた分は既読にし、片付いたら件数から外す', () async {
      await c.showPage(project);
      access.current = fixture(withDraft(baseFiles()));
      await c.reload();
      expect(c.attentionCount(project), 1);
      expect(c.attentionFresh(project), 0);
      access.current = fixture(baseFiles());
      await c.reload();
      expect(c.attentionCount(project), 0);
      expect(access.badges.last, 4);
    });

    test('この端末から採用・却下を依頼した候補は、反映を待つ間は数えない', () async {
      final item = c.review!.pending.first;
      await c.submitReview(await c.prepareReview(item.id), 'reject');
      await c.reload();
      expect(c.review!.pending, hasLength(4));
      expect(c.attentionCount('review'), 3);
      expect(access.badges.last, 3);
    });

    test('Vaultを開けなかった後の再読込でも、残した既読と通知の設定を上書きしない', () async {
      access.current = fixture(withDraft(baseFiles()));
      await c.reload();
      final saved = settingsOf(access);
      (saved['attention'] as Map)['notify'] = true;
      access.states['settings.json'] = jsonEncode(saved);
      // 起動時の読込に失敗し、その後の再読込で読めた場合。
      final failing = _FailOnce(access);
      final next = HubController(
        failing,
        sampleLoader: () async => baseFiles(),
      );
      addTearDown(next.dispose);
      await next.restore();
      expect(next.error, isNotNull);
      await next.reload();
      expect(next.error, isNull);
      expect(next.attentionNotify, isTrue);
      expect(next.attentionFresh(project), 1);
      expect(settingsOf(access)['attention']['notify'], isTrue);
    });
  });

  testWidgets('メニューに判断待ちの件数を出し、増えた分は新着として示して開くと消える', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = AttentionAccess(mac: true)..current = fixture(baseFiles());
    final c = HubController(access, sampleLoader: () async => baseFiles());
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    Finder badge(String name) => find.descendant(
      of: find.byKey(Key('badge-$name')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(badge('review')).data, '4');
    expect(find.byKey(const Key('badge-$project')), findsNothing);
    expect(find.byKey(const Key('badge-intake')), findsNothing);
    // 下書きと止まったNOWが同期されてきたら、プロジェクトに新着として出す。
    access.current = fixture(withConflict(withDraft(baseFiles())));
    await tester.tap(find.byTooltip('再読込'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(badge(project)).data, '2 · 新着2');
    expect(tester.widget<Text>(badge('review')).data, '4');
    // プロジェクトを開くと既読になり、件数だけが残る。
    await tester.tap(find.byKey(const Key('project-context-hub')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now-conflict')), findsOneWidget);
    expect(tester.widget<Text>(badge(project)).data, '2');
    // 生成版に戻す依頼を送ると、反映を待つ間は判断待ちに数えない。
    await tester.tap(find.byKey(const Key('conflict-resolve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('再読込'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(badge(project)).data, '1');
    expect(access.badges.last, 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通知から確認待ちを開き、通知の設定は許可されなければ有効にしない', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = AttentionAccess(android: true)
      ..current = fixture(baseFiles());
    final c = HubController(access, sampleLoader: () async => baseFiles());
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await c.useSample();
    // 下書きが増えた後に通知を押すと、その下書きのあるプロジェクトを開く。
    access.current = fixture(withDraft(baseFiles()));
    await c.reload();
    expect(c.attentionLanding, project);
    access.action = 'attention';
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('作業記録の下書き'), findsWidgets);
    expect(c.attentionFresh(project), 0);
    // 新しい判断待ちがなければ、確認待ちの一覧を開く。
    expect(c.attentionLanding, 'review');
    access.action = 'attention';
    access.onAction!();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '確認待ち'), findsOneWidget);
    // Macのドックの件数は出さない。
    expect(access.badges, isEmpty);
    await tester.tap(find.byKey(const Key('attention-settings')));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文は出しません'), findsOneWidget);
    access.granted = false;
    await tester.tap(find.byKey(const Key('attention-notify')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attention-problem')), findsOneWidget);
    expect(c.attentionNotify, isFalse);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('attention-notify')))
          .value,
      isFalse,
    );
    access.granted = true;
    await tester.tap(find.byKey(const Key('attention-notify')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attention-problem')), findsNothing);
    expect(c.attentionNotify, isTrue);
    expect(access.toggles.last, (enabled: true, request: true));
    expect(tester.takeException(), isNull);
  });
}

/// 最初の読込だけ失敗する（起動時にVaultへ届かなかった場合）。状態ファイルは元の端末と共有する。
class _FailOnce extends AttentionAccess {
  _FailOnce(this.inner) : super(mac: true) {
    current = inner.current;
  }
  final AttentionAccess inner;
  bool failed = false;
  @override
  Future<String?> readState(String name) => inner.readState(name);
  @override
  Future<void> writeState(String name, String raw, {bool exclusive = false}) =>
      inner.writeState(name, raw, exclusive: exclusive);
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) {
    if (!failed) {
      failed = true;
      throw StateError('Vaultへ届きません');
    }
    return super.readSnapshot(location);
  }
}
