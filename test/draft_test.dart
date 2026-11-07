import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/draft_store.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'fixtures.dart';
import 'widget_test.dart' show MemoryUIAccess;

/// Inputへの書き込みを止めておけるアクセス。
class BlockingAccess extends MemoryUIAccess {
  Completer<void>? gate;
  @override
  Future<void> writeRequest(VaultLocation l, String id, String raw) async {
    await gate?.future;
    await super.writeRequest(l, id, raw);
  }
}

/// 書き込み後に応答が失われ、確認の読取もできない（保存結果が不明になる）アクセス。
class LosingAccess extends MemoryUIAccess {
  bool lose = false;
  @override
  Future<void> writeRequest(VaultLocation l, String id, String raw) async {
    await super.writeRequest(l, id, raw);
    if (lose) throw StateError('応答消失');
  }

  @override
  Future<String?> readRequest(VaultLocation l, String id) async {
    if (lose) throw StateError('読取不可');
    return super.readRequest(l, id);
  }
}

WritingDraft draft(String text, {DateTime? at, String? op}) =>
    WritingDraft(text: text, updatedAt: at ?? DateTime.now(), operationId: op);

Future<HubController> openSample(
  WidgetTester tester,
  MemoryUIAccess access,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  await access.init();
  final c = HubController(access, sampleLoader: () async => fixture().files);
  addTearDown(() {
    c.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(ContextHubApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(find.text('サンプルで試す'));
  await tester.pumpAndSettle();
  return c;
}

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('new-memo')));
  await tester.pumpAndSettle();
}

Future<void> closeForm(WidgetTester tester) async {
  await tester.tap(find.text('フォームを閉じる'));
  await tester.pumpAndSettle();
}

void main() {
  group('DraftStore', () {
    test('Vaultと種類ごとに残し、読み直しても戻る', () async {
      final access = MemoryUIAccess();
      final store = DraftStore(access);
      final a = DraftStore.keyFor('vault-a'),
          b = DraftStore.keyFor('vault-b'),
          g = DraftStore.keyFor('vault-a', gitDraftId: 'GDR-X');
      await store.write(a, draft('Aのメモ'));
      await store.write(b, draft('Bのメモ'));
      await store.write(g, draft('下書きの続き'));
      final again = DraftStore(access);
      expect((await again.read(a))!.text, 'Aのメモ');
      expect((await again.read(b))!.text, 'Bのメモ');
      expect((await again.read(g))!.text, '下書きの続き');
      await again.remove(a);
      expect(await DraftStore(access).read(a), isNull);
    });

    test('空の本文は残さない', () async {
      final access = MemoryUIAccess();
      final store = DraftStore(access);
      final key = DraftStore.keyFor('v');
      await store.write(key, draft('途中'));
      await store.write(key, draft('  '));
      expect(await DraftStore(access).read(key), isNull);
    });

    test('容量を超えると古い書きかけから捨てる', () async {
      final access = MemoryUIAccess();
      final store = DraftStore(access);
      final long = 'あ' * 8000; // UTF-8で24000バイト
      final base = DateTime.utc(2026, 11, 1);
      for (var i = 0; i < 4; i++) {
        await store.write(
          DraftStore.keyFor('v$i'),
          draft(long, at: base.add(Duration(hours: i))),
        );
      }
      final raw = access.states[DraftStore.fileName]!;
      expect(utf8.encode(raw).length, lessThanOrEqualTo(DraftStore.budget));
      final again = DraftStore(access);
      expect(await again.read(DraftStore.keyFor('v0')), isNull);
      expect(await again.read(DraftStore.keyFor('v3')), isNotNull);
    });

    test('容量が足りなくても保存結果が不明な書きかけは捨てず、本文だけを外す', () async {
      final access = MemoryUIAccess();
      final store = DraftStore(access);
      final long = 'あ' * 8000;
      final base = DateTime.utc(2026, 11, 1);
      final locked = DraftStore.keyFor('locked');
      await store.write(locked, draft(long, at: base, op: 'op-1'));
      await store.write(
        DraftStore.keyFor('old'),
        draft(long, at: base.add(const Duration(hours: 1))),
      );
      await store.write(
        DraftStore.keyFor('a'),
        draft(long, at: base.add(const Duration(hours: 2))),
      );
      final again = DraftStore(access);
      // 保存を試みていない古い書きかけを先に捨て、保存結果が不明な書きかけは本文ごと残る。
      expect(await again.read(DraftStore.keyFor('old')), isNull);
      expect((await again.read(locked))!.text.length, 8000);
      // 保存結果が不明な書きかけが2件と最新の書きかけで容量を超えると、古い方の本文だけを外す。
      await store.write(
        DraftStore.keyFor('locked2'),
        draft(long, at: base.add(const Duration(hours: 3)), op: 'op-2'),
      );
      await store.write(
        DraftStore.keyFor('c'),
        draft(long, at: base.add(const Duration(hours: 4))),
      );
      final last = DraftStore(access);
      final kept = await last.read(locked);
      expect(kept!.operationId, 'op-1');
      expect(kept.text.isEmpty, isTrue);
      expect(
        (await last.read(DraftStore.keyFor('locked2')))!.text.length,
        8000,
      );
      expect(await last.read(DraftStore.keyFor('a')), isNull);
      expect(await last.read(DraftStore.keyFor('c')), isNotNull);
      expect(
        utf8.encode(access.states[DraftStore.fileName]!).length,
        lessThanOrEqualTo(DraftStore.budget),
      );
    });

    test('残さない設定でも、保存結果が不明な操作は本文を消して操作IDだけを残す', () async {
      final access = MemoryUIAccess();
      final store = DraftStore(access);
      final key = DraftStore.keyFor('v'), memo = DraftStore.keyFor('w');
      await store.write(key, draft('送った内容', op: 'op-1'));
      await store.write(memo, draft('途中'));
      await store.setEnabled(false);
      final again = DraftStore(access);
      expect(await again.read(memo), isNull);
      final kept = await again.read(key);
      expect(kept!.operationId, 'op-1');
      expect(kept.text, isEmpty);
      expect(access.states[DraftStore.fileName], isNot(contains('送った内容')));
    });

    test('残さない設定にすると書きかけを消し、以後も残さない', () async {
      final access = MemoryUIAccess();
      final store = DraftStore(access);
      final key = DraftStore.keyFor('v');
      await store.write(key, draft('途中'));
      await store.setEnabled(false);
      await store.write(key, draft('また書いた'));
      final again = DraftStore(access);
      expect(await again.enabled(), isFalse);
      expect(await again.read(key), isNull);
      expect(access.states[DraftStore.fileName], isNot(contains('途中')));
    });

    test('壊れた記録は空として扱い、操作journalの検査にも含めない', () async {
      final access = MemoryUIAccess();
      access.states[DraftStore.fileName] = '{壊れた';
      expect(await DraftStore(access).read(DraftStore.keyFor('v')), isNull);
      final service = CaptureService(
        access,
        const VaultLocation('sample', '架空'),
      );
      expect(await service.pending(), isEmpty);
    });
  });

  testWidgets('閉じた書きかけを次に開いたときに戻し、保存したら消す', (tester) async {
    final access = MemoryUIAccess();
    await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), '書きかけの思いつき');
    await tester.pump(const Duration(seconds: 1));
    await closeForm(tester);
    expect(access.states[DraftStore.fileName], contains('書きかけの思いつき'));

    await openForm(tester);
    expect(find.byKey(const Key('draft-restored')), findsOneWidget);
    expect(find.text('書きかけの思いつき'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに保存しました'), findsOneWidget);
    expect(access.writes, 1);
    expect(access.states[DraftStore.fileName], isNot(contains('書きかけの思いつき')));
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();

    await openForm(tester);
    expect(find.byKey(const Key('draft-restored')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('memo-text')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('アプリが一時停止したら待たずに書きかけを残す', (tester) async {
    final access = MemoryUIAccess();
    await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), '止まる直前');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(access.states[DraftStore.fileName], contains('止まる直前'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  });

  testWidgets('破棄すると書きかけを消して空のフォームにする', (tester) async {
    final access = MemoryUIAccess();
    await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), '要らないメモ');
    await tester.pump(const Duration(seconds: 1));
    await closeForm(tester);
    await openForm(tester);
    await tester.tap(find.byKey(const Key('draft-discard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('draft-restored')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('memo-text')))
          .controller!
          .text,
      isEmpty,
    );
    expect(access.states[DraftStore.fileName], isNot(contains('要らないメモ')));
  });

  testWidgets('保存結果が不明なまま閉じた書きかけは、再送せず同じ操作の確認へ戻す', (tester) async {
    final access = LosingAccess()..lose = true;
    await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), '結果不明のメモ');
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    expect(find.text('保存確認待ちです。再送せず同じ操作を確認してください。'), findsOneWidget);
    await closeForm(tester);

    access.lose = false;
    await openForm(tester);
    expect(find.byKey(const Key('draft-restored')), findsOneWidget);
    expect(find.byKey(const Key('save-memo')), findsNothing);
    expect(find.byKey(const Key('confirm-same')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-same')));
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに保存しました'), findsOneWidget);
    expect(access.writes, 1);
    expect(access.states[DraftStore.fileName], isNot(contains('結果不明のメモ')));
  });

  testWidgets('保存を始める前に、操作IDを書きかけへ残す', (tester) async {
    final access = BlockingAccess()..gate = Completer<void>();
    await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), '保存中のメモ');
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final raw = jsonDecode(access.states[DraftStore.fileName]!) as Map;
    final stored = (raw['drafts'] as Map).values.single as Map;
    expect(stored['t'], '保存中のメモ');
    expect(stored['o'], isA<String>());
    access.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('この端末のInputに保存しました'), findsOneWidget);
  });

  testWidgets('保存結果が不明な書きかけは、同じ操作を確認するまで閉じられない', (tester) async {
    final access = LosingAccess()..lose = true;
    await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), 'まだ不明なメモ');
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    await closeForm(tester);

    await openForm(tester);
    expect(find.byKey(const Key('draft-restored')), findsOneWidget);
    expect(find.byKey(const Key('draft-discard')), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-same')));
    await tester.pumpAndSettle();
    // 確認しても結果が分からないときは、書きかけを閉じて新しく書ける。
    expect(find.byKey(const Key('draft-discard')), findsOneWidget);
    await tester.tap(find.byKey(const Key('draft-discard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-memo')), findsOneWidget);
    expect(access.writes, 1);
  });

  testWidgets('受付状況で保存が確かめられた書きかけは戻さない', (tester) async {
    final access = LosingAccess()..lose = true;
    final c = await openSample(tester, access);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('memo-text')), '後で確認されたメモ');
    await tester.tap(find.byKey(const Key('save-memo')));
    await tester.pumpAndSettle();
    await closeForm(tester);
    // フォームの外（受付状況）で同じ操作を確認する。
    access.lose = false;
    final op = c.pending.single.operationId;
    expect((await c.confirm(op)).saved, isTrue);
    await tester.pumpAndSettle();

    await openForm(tester);
    expect(find.byKey(const Key('draft-restored')), findsNothing);
    expect(find.byKey(const Key('save-memo')), findsOneWidget);
    expect(access.states[DraftStore.fileName], isNot(contains('後で確認されたメモ')));
  });
}
