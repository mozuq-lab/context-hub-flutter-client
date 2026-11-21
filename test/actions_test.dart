import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/home_widget.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/ui/views.dart' show stateLabel;
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'fixtures.dart';

/// 端末に保存した依頼を、同期前のVaultに足す。
Future<HubRepository> withRequest(
  TempAccess access,
  Map<String, String> files,
  String requestId,
) async => HubRepository(
  fixture({
    ...files,
    'Input/$requestId.md': (await access.readRequest(location, requestId))!,
  }),
);

void main() {
  test('行動の文面は本体と同じ決まり（1行・200文字以内・前後の空白なし）で確かめる', () {
    expect(validActionText('資料を読む'), isTrue);
    expect(validActionText('あ' * 200), isTrue);
    expect(validActionText('あ' * 201), isFalse);
    // 絵文字は本体と同じくUTF-16の単位で2文字と数える。
    expect(validActionText('😀' * 101), isFalse);
    expect(validActionText(''), isFalse);
    expect(validActionText(' 資料を読む'), isFalse);
    expect(validActionText('資料を\n読む'), isFalse);
    expect(validActionText('資料を\t読む'), isFalse);
    // 行区切り・段落区切りと、文字の向きを変える制御も本体と同じく断る。
    for (final c in ['\u2028', '\u2029', '\u202E', '\u2066']) {
      expect(validActionText('資料を$c読む'), isFalse);
    }
  });

  test('本人が追加した行動の依頼を本体が受理し、次の一手に本人の言葉のまま載る', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles();
      final service = CaptureService(access, location);
      // 1行でない・プロジェクトIDが不正な依頼は保存しない。
      for (final (project, text) in [
        (projectId, '資料を\n読む'),
        (projectId, ' 資料を読む'),
        ('Bad Id', '資料を読む'),
      ]) {
        await expectLater(
          service.saveAction(
            '11111111-2222-4333-8444-666666666666',
            project,
            text,
          ),
          throwsFormatException,
        );
      }
      final saved = await service.saveAction(
        '11111111-2222-4333-8444-666666666666',
        projectId,
        '検索の結果を本人が確かめる',
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      final meta = parseMarkdown(raw).meta;
      expect(meta['operation'], 'capture');
      expect(meta['kind'], 'action');
      expect(meta['project'], projectId);
      expect(meta.containsKey('tool'), isFalse);
      expect(meta.containsKey('meta'), isFalse);
      // 同期前は、反映待ちの行動として次の一手に数える。
      final pending = await withRequest(access, files, saved.requestId);
      final before = pending.projects[projectId]!;
      expect(before.pendingActions.single.text, '検索の結果を本人が確かめる');
      expect(before.pendingActions.single.state, 'waiting');
      expect(before.nextCount, 2);
      expect(
        pending.intake.firstWhere((i) => i.id == saved.requestId).title,
        contains('次の一手への追加: 検索の結果を本人が確かめる'),
      );
      expect(
        homeWidgetContent(pending, now: DateTime.utc(2026, 11, 1))['counts'],
        startsWith('次の一手 2件'),
      );
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, 'assets/sample.json', 'one'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final p = synced.projects[projectId]!;
      expect(p.pendingActions, isEmpty);
      // 項目一覧だけに載り、NOWの本文にまだ載っていない（手編集で作り直せなかった・同期の途中）ときは、反映待ちのまま示す。
      final halfway = HubRepository(
        fixture({...synced.snapshot.files, nowPath: files[nowPath]!}),
      ).projects[projectId]!;
      expect(halfway.pendingActions.single.text, '検索の結果を本人が確かめる');
      expect(halfway.nextCount, 2);
      final item = p.nowItems.firstWhere((i) => i.action);
      expect(item.text, '検索の結果を本人が確かめる');
      expect(item.label, actionLabel);
      expect(item.fromInputId, isNull);
      // 本人が追加した行動を先に、作業要約の次の一手を後に並べ、どちらも項目キーで操作できる。
      final next = p.sections['next']!;
      expect(next.first.text, startsWith('本人が追加: 検索の結果を本人が確かめる'));
      expect(next.first.itemKey, item.key);
      expect(next.last.itemKey, isNotNull);
      expect(p.nextCount, 2);
      expect(
        synced.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '次の一手にMiniが追加しました。',
      );
      // 行動の原文は、整理しない行動として読み、検索の種類で絞れる。
      final record = synced.records.values.firstWhere(
        (r) => r.sourceId == item.inputId,
      );
      expect(record.kind, 'action');
      expect(stateLabel(record.status), '本人が追加した行動（整理しません）');
      // 行動の文面の訂正は、行動と同じく1行・200文字以内に限る（本体が断るため）。
      final ui = MemoryUIAccess();
      await ui.init();
      ui.current = VaultSnapshot(synced.snapshot.files);
      final c = HubController(
        ui,
        sampleLoader: () async => synced.snapshot.files,
      );
      addTearDown(c.dispose);
      await c.useSample();
      await expectLater(
        c.requestCorrection(
          '41111111-2222-4333-8444-666666666666',
          record.id,
          record.sourceId,
          '検索の結果を\n本人が確かめる',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('行動の文面'),
          ),
        ),
      );
      final fixed = await c.requestCorrection(
        '41111111-2222-4333-8444-666666666666',
        record.id,
        record.sourceId,
        '検索の結果を自分で確かめる',
      );
      expect(fixed.saved, isTrue);
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('作業要約の次の一手と「提案」の行を行動にすると、元の行は欄から外れる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = fixtureFiles();
      final repo = HubRepository(fixture(files)),
          project = repo.projects[projectId]!;
      final next = project.nowItems.firstWhere((i) => i.section == 'next');
      final service = CaptureService(access, location);
      final fromNext = ActionSource(
        inputId: next.inputId,
        text: next.text,
        key: next.key,
      );
      final saved = await service.saveAction(
        '21111111-2222-4333-8444-666666666666',
        projectId,
        '検索を自分で試す',
        from: fromNext,
      );
      final meta = parseMarkdown(
        (await access.readRequest(location, saved.requestId))!,
      ).meta;
      expect(meta['meta'], {
        'action_from_input': next.inputId,
        'action_from_text': next.text,
        'action_from_key': next.key,
      });
      final pending = await withRequest(access, files, saved.requestId);
      expect(
        pending.pendingActionFrom(next.inputId, next.text),
        isTrue,
      );
      final out = await protocol(
        access,
        saved.requestId,
        'assets/sample.json',
        'one',
      );
      final synced = HubRepository(fixture(out)).projects[projectId]!;
      expect(synced.nowItems.where((i) => i.key == next.key), isEmpty);
      final item = synced.nowItems.firstWhere((i) => i.action);
      expect(
        (item.fromInputId, item.fromText, item.fromKey),
        (next.inputId, next.text, next.key),
      );
      expect(synced.sections['next']!.single.itemKey, item.key);
      // 「提案」の行は、処理記録から元の本文を探して元の行にする。
      final proposal = synced.sections['proposals']!.single;
      final source = HubRepository(fixture(out)).proposalSource(proposal)!;
      expect(source.inputId, next.inputId);
      expect(source.text, '同期導入は後日検討する。');
      expect(source.key, isNull);
      final fixtureFile = File('${access.directory.path}/after-next.json')
        ..writeAsStringSync(jsonEncode(out));
      final second = await service.saveAction(
        '31111111-2222-4333-8444-666666666666',
        projectId,
        '同期の導入を来月に決める',
        from: source,
      );
      final after = HubRepository(
        fixture(
          await protocol(access, second.requestId, fixtureFile.path, 'two'),
        ),
      ).projects[projectId]!;
      expect(
        after.sections['proposals']!.map((e) => e.text),
        isNot(contains(contains('同期導入は後日検討する。'))),
      );
      expect(
        after.nowItems.where((i) => i.action).map((i) => i.text),
        ['検索を自分で試す', '同期の導入を来月に決める'],
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  test('「提案」の行の形が合わないときは行動にしない。処理記録がないときは表示の本文を使う', () {
    final files = fixtureFiles();
    final repo = HubRepository(fixture(files));
    expect(repo.proposalSource(NowEntry('提案はありません', raw: '提案はありません')), isNull);
    final noReceipt = HubRepository(
      fixture({
        for (final e in files.entries)
          if (!e.key.startsWith('90_system/receipts/')) e.key: e.value,
      }),
    );
    final entry = NowEntry(
      'x',
      raw:
          'AI提案: 表示の本文 [IN-01M2DSFVRRA5MFS95MKFPP2CCM](../../00_inbox/x.md) [出典]',
    );
    expect(noReceipt.proposalSource(entry)?.text, '表示の本文');
    // 無害化した印を含む行は、元の本文が分からないので行動にしない。
    final escaped = NowEntry(
      'x',
      raw:
          'AI提案: a &lt;!-- b [IN-01M2DSFVRRA5MFS95MKFPP2CCM](../../00_inbox/x.md) [出典]',
    );
    expect(noReceipt.proposalSource(escaped), isNull);
  });

  test('行動の依頼は、文面・項目の状態・二重の引き取りを確かめてから保存する', () async {
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
    access.current = VaultSnapshot(files);
    final c = HubController(access, sampleLoader: () async => files);
    addTearDown(c.dispose);
    await c.useSample();
    expect(
      () => c.requestAction(projectId, '二行\nの行動'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      c.requestAction('missing-project', '行動'),
      throwsA(isA<StateError>()),
    );
    final next = c.repository!.projects[projectId]!.nowItems.first;
    final from = ActionSource(
      inputId: next.inputId,
      text: next.text,
      key: next.key,
    );
    // NOWにない項目キーは断る（表示が古い）。
    await expectLater(
      c.requestAction(
        projectId,
        '行動',
        from: ActionSource(inputId: next.inputId, text: next.text, key: 'f' * 64),
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('NOW')),
      ),
    );
    // 今のNOWに載っていない「提案」の行は断る。
    await expectLater(
      c.requestAction(
        projectId,
        '行動',
        from: const ActionSource(
          inputId: 'IN-01M2DSFVRRA5MFS95MKFPP2CCM',
          text: '載っていない提案',
        ),
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('NOW')),
      ),
    );
    final first = await c.requestAction(projectId, '検索を自分で試す', from: from);
    expect(first.saved, isTrue);
    access.current = VaultSnapshot({
      ...files,
      'Input/${first.requestId}.md': access.requests[first.requestId]!,
    });
    await c.reload();
    // 反映待ちの間に、同じ行をもう一度行動にはしない。
    await expectLater(
      c.requestAction(projectId, '別の言い方', from: from),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('既に')),
      ),
    );
    // 元の行のない行動は、同じ文面でも改めて足せる。
    final again = await c.requestAction(projectId, '検索を自分で試す');
    expect(again.saved, isTrue);
    expect(access.requests, hasLength(2));
  });

  testWidgets('プロジェクトの画面と「次の一手」画面から行動を追加し、反映待ちとして示す', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    final files = fixtureFiles();
    access.current = VaultSnapshot(files);
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
    expect(find.text('次の一手 1件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-context-hub')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-add-action')));
    await tester.pumpAndSettle();
    FilledButton submit() =>
        tester.widget<FilledButton>(find.byKey(const Key('action-submit')));
    expect(submit().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('action-text')), 'あ' * 201);
    await tester.pumpAndSettle();
    expect(find.text('201 / 200'), findsOneWidget);
    expect(submit().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('action-text')), ' 発表資料を作る ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-submit')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single);
    expect(request.meta['kind'], 'action');
    expect(request.meta['project'], projectId);
    expect(request.body.trim(), '発表資料を作る');
    access.current = VaultSnapshot({
      ...files,
      'Input/${request.meta['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('pending-action-${request.meta['request_id']}')),
      findsOneWidget,
    );
    expect(find.text('本人が追加: 発表資料を作る'), findsOneWidget);
    // 作業要約の次の一手を行動にする。元の行を初期値にし、本人が直してから保存する。
    final next = c.repository!.projects[projectId]!.nowItems.first;
    final short = digest('${next.inputId}\n${next.text}').substring(0, 12);
    await tester.tap(find.byKey(Key('take-action-$short')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-from')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('action-text')))
          .controller!
          .text,
      next.text,
    );
    await tester.enterText(find.byKey(const Key('action-text')), '検索を自分で試す');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-submit')));
    await tester.pumpAndSettle();
    final converted = parseMarkdown(access.requests.values.last).meta;
    expect(converted['meta'], containsPair('action_from_key', next.key));
    access.current = VaultSnapshot({
      ...files,
      for (final e in access.requests.entries) 'Input/${e.key}.md': e.value,
    });
    await c.reload();
    await tester.pumpAndSettle();
    // 反映待ちの間は、引き取った元の行を次の一手に並べず、数えない（本体も反映すると外す）。
    expect(find.byKey(Key('take-action-$short')), findsNothing);
    expect(find.text('本人が追加: 検索を自分で試す'), findsOneWidget);
    expect(
      c.repository!.projects[projectId]!.sections['next']!.map((e) => e.text),
      isNot(contains(contains(next.text))),
    );
    // 「次の一手」画面でも、反映待ちの行動を数えて示し、プロジェクトを選んで追加できる。
    await tester.tap(find.byKey(const Key('nav-next')).last);
    await tester.pumpAndSettle();
    expect(find.text('次の一手 2件'), findsOneWidget);
    expect(find.text('本人が追加: 発表資料を作る'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next-add-action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-dialog')), findsOneWidget);
    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('行動の原文から文面を1行で直せる。誤りとして外す理由は「もう古い」だけ', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final files = (await tester.runAsync(() async {
      final temp = TempAccess();
      await temp.init();
      try {
        final saved = await CaptureService(temp, location).saveAction(
          '51111111-2222-4333-8444-666666666666',
          projectId,
          '検索の結果を本人が確かめる',
        );
        return await protocol(
          temp,
          saved.requestId,
          'assets/sample.json',
          'one',
        );
      } finally {
        await temp.directory.delete(recursive: true);
      }
    }))!;
    final access = MemoryUIAccess();
    await access.init();
    access.current = VaultSnapshot(files);
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
    await tester.tap(find.byKey(const Key('project-context-hub')).last);
    await tester.pumpAndSettle();
    final item = c.repository!.projects[projectId]!.nowItems.firstWhere(
      (i) => i.action,
    );
    await tester.tap(find.byKey(Key('exclude-${item.key.substring(0, 12)}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('exclude-reason-outdated')), findsOneWidget);
    expect(find.byKey(const Key('exclude-reason-misread')), findsNothing);
    expect(find.byKey(const Key('exclude-reason-wrong-project')), findsNothing);
    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text('検索の結果を本人が確かめる'),
        matching: find.byKey(const Key('source-record')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本人が追加した行動（整理しません）'), findsWidgets);
    await tester.tap(find.byKey(const Key('write-correction')));
    await tester.pumpAndSettle();
    expect(find.text('行動の文面を直す'), findsWidgets);
    final field = tester.widget<TextField>(
      find.byKey(const Key('correction-text')),
    );
    expect(field.maxLines, 1);
    await tester.enterText(
      find.byKey(const Key('correction-text')),
      '検索の結果を自分で確かめる',
    );
    await tester.tap(find.byKey(const Key('save-correction')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'correct');
    expect(request['target_id'], item.inputId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('行動に対応していない本体では、追加と引き取りの入口を出さず、依頼も保存しない', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    // 本体の対応表に入力の種類（capture_kinds）がない、行動を知らない本体。
    final files = fixtureFiles();
    final features =
        jsonDecode(files['90_system/intake-features.json']!)
            as Map<String, dynamic>
          ..remove('capture_kinds');
    files['90_system/intake-features.json'] = jsonEncode(features);
    access.current = VaultSnapshot(files);
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
    expect(c.repository!.intakeFeatures.actions, isFalse);
    await tester.tap(find.byKey(const Key('project-context-hub')).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-add-action')), findsNothing);
    expect(find.text('自分の行動にする'), findsNothing);
    await expectLater(
      c.requestAction(projectId, '発表資料を作る'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('対応していません')),
      ),
    );
    expect(access.requests, isEmpty);
  });
}
