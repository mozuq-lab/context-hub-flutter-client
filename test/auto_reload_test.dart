import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/capture_progress.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

/// 再読込の回数と、読込中かどうかを記録する端末。
class CountingAccess extends MemoryUIAccess {
  int reads = 0;
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) {
    reads++;
    return super.readSnapshot(location);
  }
}

/// ドックに件数を出せる（Macの）端末。
class DockAccess extends CountingAccess {
  @override
  bool get dockBadgeSupported => true;
  @override
  Future<void> setDockBadge(int count) async {}
}

const newInput = 'IN-01M9ZZZZZZZZZZZZZZZZZZZZZZ';
const nowPathOf = '10_projects/context-hub/NOW.md';

/// 表示の更新（refreshSnapshot）の読取を、テストが渡すまで止めておく端末。
class HeldRefreshAccess extends MemoryUIAccess {
  Completer<VaultSnapshot>? hold;
  @override
  Future<VaultSnapshot> refreshSnapshot(
    VaultLocation location,
    VaultSnapshot previous,
  ) {
    final held = hold;
    if (held != null) {
      hold = null;
      return held.future;
    }
    return super.refreshSnapshot(location, previous);
  }
}

/// Miniがこの端末の依頼を受け付けた（[organized]なら整理まで終えた）ときのVault。
Map<String, String> processed(
  Map<String, String> base,
  String requestId,
  String raw, {
  bool organized = false,
}) {
  final files = {...base, 'Input/$requestId.md': raw};
  files['90_system/intake/$requestId.json'] = jsonEncode({
    'schema_version': 1,
    'request_id': requestId,
    'request_hash': digest(raw),
    'path': 'Input/$requestId.md',
    'operation': 'capture',
    'status': 'accepted',
    'received_at': '2026-11-21T00:00:01.000Z',
    'result': {
      'inputId': newInput,
      'path': '00_inbox/2026-11-21_$newInput.md',
      'receivedAt': '2026-11-21T00:00:01.000Z',
      'deduped': false,
    },
  });
  files['00_inbox/2026-11-21_$newInput.md'] =
      '---\nschema_version: 1\nid: $newInput\nkind: memo\nsource: context-hub-client\nsource_event_id: $requestId\noccurred_at: 2026-11-21T09:00:00+09:00\nreceived_at: 2026-11-21T00:00:01.000Z\norigin: user-note\n---\n帰りに牛乳を買う\n';
  if (organized) {
    final receipt =
        jsonDecode(
              base['90_system/receipts/IN-01M2DSFVQMH65989604KSVE1PV.json']!,
            )
            as Map<String, dynamic>;
    receipt['input_id'] = newInput;
    receipt['writes'] = [];
    receipt['organized_at'] = '2026-11-21T00:01:00.000Z';
    (receipt['result'] as Map)['summary'] = '帰りに牛乳を買う';
    (receipt['result'] as Map)['project_candidates'] = [];
    files['90_system/receipts/$newInput.json'] = jsonEncode(receipt);
  }
  return files;
}

void main() {
  test('変わっていなければ表示を差し替えず、同期で届いた変更だけを、読込中にせずに読み込む', () async {
    final access = CountingAccess();
    final files = fixtureFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final first = c.repository;
    var sawLoading = false;
    c.addListener(() => sawLoading |= c.loading);
    expect(await c.refreshQuietly(), isFalse);
    expect(identical(c.repository, first), isTrue);
    // 同期で新しいメモが届いた。
    access.current = fixture({
      ...files,
      '00_inbox/2026-11-21_$newInput.md':
          '---\nschema_version: 1\nid: $newInput\nkind: memo\nsource: cli\nsource_event_id: x\noccurred_at: 2026-11-21T09:00:00+09:00\nreceived_at: 2026-11-21T00:00:01.000Z\norigin: user-note\n---\n届いたメモ\n',
    });
    expect(await c.refreshQuietly(), isTrue);
    expect(c.repository!.inputRecord(newInput) != null, isTrue);
    expect(sawLoading, isFalse);
    expect(c.error, isNull);
  });

  test('自動の読込は重ねて始めず、読んでいる間に確認の読み直しで新しくなった表示を古い内容で戻さない', () async {
    final access = HeldRefreshAccess();
    final files = fixtureFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final older = fixture({...files, 'notes/older.md': '古い'});
    final hold = access.hold = Completer<VaultSnapshot>();
    final first = c.refreshQuietly();
    // 実行中は次を始めない。
    expect(await c.refreshQuietly(), isFalse);
    // 読んでいる間に、確認のための読み直しなどで新しい記録が入った。
    final newer = fixture({...files, 'notes/newer.md': '新しい'});
    access.current = newer;
    await c.reload();
    expect(identical(c.repository!.snapshot, newer), isTrue);
    hold.complete(older);
    expect(await first, isFalse);
    expect(identical(c.repository!.snapshot, newer), isTrue);
  });

  test('更新時刻の付かない（書き込まれた直後の）ファイルは、本文で変化を確かめる', () async {
    final access = MemoryUIAccess();
    final files = fixtureFiles();
    final stamps = {for (final p in files.keys) p: '1:1'}..remove(nowPathOf);
    access.current = VaultSnapshot(files, stamps: stamps);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    expect(await c.refreshQuietly(), isFalse);
    access.current = VaultSnapshot({
      ...files,
      nowPathOf: '${files[nowPathOf]!}\n- 追記\n',
    }, stamps: stamps);
    expect(await c.refreshQuietly(), isTrue);
  });

  test('入力・保存の途中や、読込に失敗している間は自動で読み込まない', () async {
    final access = CountingAccess();
    final files = fixtureFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final reads = access.reads;
    c.composing = true;
    expect(await c.refreshQuietly(), isFalse);
    c.composing = false;
    c.saving = true;
    expect(await c.refreshQuietly(), isFalse);
    c.saving = false;
    expect(access.reads, reads);
    // 自動の読込は、設定で止められ、端末に残す。
    await c.setAutoReload(false);
    expect(jsonDecode(access.states['settings.json']!)['autoReload'], false);
    await c.setAutoReload(true);
    expect(
      (jsonDecode(access.states['settings.json']!) as Map).containsKey(
        'autoReload',
      ),
      isFalse,
    );
  });

  test('この端末から保存したメモが、Mac miniで受け付けられ、整理されたことを1回ずつ知らせる', () async {
    final access = MemoryUIAccess();
    final files = fixtureFiles();
    access.current = fixture(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    final saved = await c.save(
      const CaptureDraft(
        operationId: '0b9d4c3a-1111-4222-8333-444455556666',
        text: '帰りに牛乳を買う',
      ),
    );
    expect(saved.saved, isTrue);
    final raw = access.requests[saved.requestId]!;
    // 保存しただけでは知らせない。
    expect(c.hasCaptureNotices, isFalse);
    access.current = fixture(processed(files, saved.requestId, raw));
    expect(await c.refreshQuietly(), isTrue);
    expect(captureStage(c.repository!, saved.requestId), CaptureStage.accepted);
    var notices = c.takeCaptureNotices();
    expect(notices.map((n) => n.stage), [CaptureStage.accepted]);
    expect(
      captureNoticeText(notices).text,
      'メモをMac miniが受け取りました（AIの読み取りはこれから）',
    );
    expect(c.takeCaptureNotices(), isEmpty);
    access.current = fixture(
      processed(files, saved.requestId, raw, organized: true),
    );
    await c.reload();
    notices = c.takeCaptureNotices();
    expect(notices.map((n) => n.stage), [CaptureStage.organized]);
    expect(captureNoticeText(notices), (text: 'メモをAIが読み取りました', page: 'recent'));
    // 見届けたものは、もう知らせない。
    await c.reload();
    expect(c.hasCaptureNotices, isFalse);
  });

  test('知らせの文は件数と段階をまとめ、受け付けられなかったものがあれば保存と反映へ案内する', () {
    expect(
      captureNoticeText(const [
        CaptureNotice('a', CaptureStage.organized),
        CaptureNotice('b', CaptureStage.organized),
      ]),
      (text: '2件のメモをAIが読み取りました', page: 'recent'),
    );
    expect(
      captureNoticeText(const [
        CaptureNotice('a', CaptureStage.organized),
        CaptureNotice('b', CaptureStage.failed),
      ]),
      (text: 'メモをAIが読み取りました。メモの受け取りかAIの読み取りがうまくいきませんでした', page: 'intake'),
    );
    final repo = HubRepository(fixture());
    expect(captureStage(repo, 'REQ-unknown'), CaptureStage.saved);
  });

  testWidgets('前面に戻ると同期で届いた変更を読み込み、整理されたメモを画面下で知らせる', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
    access.current = VaultSnapshot(files, loadedAt: DateTime(2000));
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    final saved = await tester.runAsync(
      () => c.save(
        const CaptureDraft(
          operationId: '0b9d4c3a-1111-4222-8333-444455556667',
          text: '帰りに牛乳を買う',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final raw = access.requests[saved!.requestId]!;
    access.current = VaultSnapshot(
      processed(files, saved.requestId, raw, organized: true),
      loadedAt: DateTime(2000),
    );
    // しばらく前に確かめたきりで、いったん背後に回り、前面に戻る。
    c.lastCheckedAt = DateTime(2000);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    // 端末の状態ファイルの読み書きを終わらせる。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(c.repository!.inputRecord(newInput) != null, isTrue);
    expect(find.text('メモをAIが読み取りました'), findsOneWidget);
    await tester.tap(find.text('最近のメモ').last);
    await tester.pumpAndSettle();
    expect(find.text('雑な思いつきも、作業の記録も、そのまま残せます。'), findsOneWidget);
  });

  /// サンプルを開いた画面を出し、ウインドウを閉じた（隠れた）状態にして、読込の回数を返す。
  Future<int> hideAfterOpening(
    WidgetTester tester,
    CountingAccess access,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = fixtureFiles();
    access.current = fixture(files);
    final c = HubController(
      access,
      sampleLoader: () async => files,
      autoReloadInterval: const Duration(seconds: 60),
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    return access.reads;
  }

  testWidgets('Macではウインドウを閉じている間も、数分おきに読み直してドックの件数を新しくする', (
    tester,
  ) async {
    final access = DockAccess();
    final before = await hideAfterOpening(tester, access);
    // 閉じている間は、前面にあるときより間隔を空ける。
    await tester.pump(const Duration(seconds: 61));
    expect(access.reads, before);
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(access.reads, greaterThan(before));
    // 開き直すと、前面にあるときの間隔に戻す。
    final reopened = access.reads;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(access.reads, greaterThan(reopened));
  });

  testWidgets('Macでウインドウが見えるようになれば、前面に戻らなくても1分おきに戻す', (tester) async {
    final access = DockAccess();
    await hideAfterOpening(tester, access);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final shown = access.reads;
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(access.reads, greaterThan(shown));
  });

  testWidgets('ドックに件数を出さない端末では、隠れている間は読み直さない', (tester) async {
    final access = CountingAccess();
    final before = await hideAfterOpening(tester, access);
    await tester.pump(const Duration(minutes: 11));
    await tester.pumpAndSettle();
    expect(access.reads, before);
  });
}
