import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol;
import 'fixtures.dart';

const projectId = 'context-hub';

/// 固定参照の本体で、サンプルに「完了: <次の一手>」のメモを足して整理した後のファイル。
Map<String, String>? _hintFiles;
Future<Map<String, String>> hintFiles() async {
  if (_hintFiles != null) return Map.of(_hintFiles!);
  final dir = await Directory.systemTemp.createTemp('context-hub-hint-');
  try {
    final out = File('${dir.path}/hint.json');
    final result = await Process.run('node', [
      'scripts/prepare_hint_state.mjs',
      'assets/sample.json',
      out.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    _hintFiles = Map<String, String>.from(
      jsonDecode(await out.readAsString()) as Map,
    );
    return Map.of(_hintFiles!);
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  test('本体が示した「片付いたかも」を項目と根拠のメモに結び付ける', () async {
    final repo = HubRepository(fixture(await hintFiles()));
    expect(repo.warnings, isEmpty);
    final project = repo.projects[projectId]!;
    final hinted = project.nowItems.where((i) => i.hints.isNotEmpty).toList();
    expect(hinted, hasLength(1));
    final item = hinted.single, hint = item.hints.single;
    expect(item.resolved, isFalse);
    expect(hint.quote, '完了: ${item.display}');
    expect(repo.inputRecord(hint.inputId)?.kind, 'memo');
    // NOWの行との対応は崩れず、候補の付いた項目にもキーが付く。
    expect(
      project.sections[item.section]!.map((e) => e.itemKey),
      contains(item.key),
    );
  });

  test('形の崩れた候補は記録の問題として示す', () async {
    final files = fixtureFiles(),
        path = '90_system/now-items/$projectId.json',
        items = jsonDecode(files[path]!) as Map<String, dynamic>;
    (items['items'] as List).first['hints'] = [
      {'input_id': 'not-an-id', 'quote': 'x'},
    ];
    final repo = HubRepository(fixture({...files, path: jsonEncode(items)}));
    expect(repo.projects[projectId]!.nowItems, isEmpty);
    expect(repo.warnings, isNotEmpty);
  });

  test('「違う」の見送りを本体が受理し、項目は未解決のまま候補だけ消える', () async {
    final access = TempAccess();
    await access.init();
    try {
      final files = await hintFiles(),
          project = HubRepository(fixture(files)).projects[projectId]!,
          item = project.nowItems.firstWhere((i) => i.hints.isNotEmpty),
          hint = item.hints.single;
      final service = CaptureService(access, location);
      // 示されていないメモからの見送りは保存しない。
      await expectLater(
        service.saveHintDismiss(
          '81111111-2222-4333-8444-555555555555',
          projectId,
          item,
          'IN-01M7AAAAAAAAAAAAAAAAAAAAAA',
        ),
        throwsFormatException,
      );
      final saved = await service.saveHintDismiss(
        '81111111-2222-4333-8444-555555555555',
        projectId,
        item,
        hint.inputId,
      );
      final raw = (await access.readRequest(location, saved.requestId))!;
      expect(
        parseMarkdown(raw).meta,
        containsPair('operation', 'item-hint-dismiss'),
      );
      final pending = HubRepository(
        fixture({...files, 'Input/${saved.requestId}.md': raw}),
      );
      expect(pending.warnings, isEmpty);
      expect(
        pending.hintDismissRequestIdFor(item.key, hint.inputId),
        saved.requestId,
      );
      expect(
        pending.intake.firstWhere((i) => i.id == saved.requestId).title,
        startsWith('「片付いたかも」の見送り: '),
      );
      // Miniが受け付けても、NOWの同期が届くまでは反映待ちとして扱う。
      final accepted = HubRepository(
        fixture({
          ...files,
          'Input/${saved.requestId}.md': raw,
          '90_system/intake/${saved.requestId}.json': jsonEncode({
            'schema_version': 1,
            'request_id': saved.requestId,
            'request_hash': digest(raw),
            'path': 'Input/${saved.requestId}.md',
            'operation': 'item-hint-dismiss',
            'status': 'accepted',
            'received_at': '2026-11-15T00:00:00.000Z',
            'result': {
              'projectId': projectId,
              'itemKey': item.key,
              'hintInputId': hint.inputId,
              'dismissalId': 'HDM-01M7AAAAAAAAAAAAAAAAAAAAAA',
              'deduped': false,
            },
          }),
        }),
      );
      expect(accepted.warnings, isEmpty);
      expect(
        accepted.hintDismissRequestIdFor(item.key, hint.inputId),
        saved.requestId,
      );
      expect(
        accepted.intake.firstWhere((i) => i.id == saved.requestId).detail,
        'Mac miniが受け取り済み。現状の同期を待っています。',
      );
      final fixtureFile = File('${access.directory.path}/with-hint.json')
        ..writeAsStringSync(jsonEncode(files));
      final synced = HubRepository(
        fixture(
          await protocol(access, saved.requestId, fixtureFile.path, 'hint'),
        ),
      );
      expect(synced.warnings, isEmpty);
      final after = synced.projects[projectId]!.nowItems.firstWhere(
        (i) => i.key == item.key,
      );
      expect(after.hints, isEmpty);
      expect(after.resolved, isFalse);
      expect(synced.hintDismissRequestIdFor(item.key, hint.inputId), isNull);
      expect(
        synced.intake.firstWhere((i) => i.id == saved.requestId).detail,
        '見送りをMac miniが反映しました。',
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('次の一手の画面で「片付いたかも」を示し、「違う」で見送りを依頼する', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    final files = await tester.runAsync(hintFiles);
    final access = MemoryUIAccess();
    await access.init();
    access.current = VaultSnapshot(files!);
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
    await tester.tap(find.byKey(const Key('home-next')));
    await tester.pumpAndSettle();
    final item = c.repository!.projects[projectId]!.nowItems.firstWhere(
      (i) => i.hints.isNotEmpty,
    );
    final prefix = item.key.substring(0, 12);
    expect(find.text('片付いたかも（AIの推定・未確認）'), findsOneWidget);
    expect(find.text('「${item.hints.single.quote}」'), findsOneWidget);
    // 完了にする操作は、これまでどおり項目の行にある。
    expect(find.byKey(Key('resolve-$prefix')), findsOneWidget);
    await tester.tap(find.byKey(Key('dismiss-hint-$prefix')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    final request = parseMarkdown(access.requests.values.single).meta;
    expect(request['operation'], 'item-hint-dismiss');
    expect(request['project_id'], projectId);
    expect(request['item_key'], item.key);
    expect(request['input_id'], item.hints.single.inputId);
    access.current = VaultSnapshot({
      ...files,
      'Input/${request['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(find.text('見送り済み（反映待ち）'), findsOneWidget);
    expect(find.byKey(Key('dismiss-hint-$prefix')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('NowItemHintは解決済みの項目に付かない', () {
    final files = fixtureFiles(),
        path = '90_system/now-items/$projectId.json',
        items = jsonDecode(files[path]!) as Map<String, dynamic>;
    final first = (items['items'] as List).first as Map<String, dynamic>;
    first['resolution'] = {
      'id': 'RES-01M7AAAAAAAAAAAAAAAAAAAAAA',
      'at': '2026-11-01T00:00:00.000Z',
      'source': 'cli',
    };
    first['hints'] = [
      {
        'input_id': 'IN-01M7AAAAAAAAAAAAAAAAAAAAAA',
        'quote': 'x',
        'at': '2026-11-01T00:00:00.000Z',
      },
    ];
    final repo = HubRepository(fixture({...files, path: jsonEncode(items)}));
    final item = repo.projects[projectId]!.nowItems.first;
    expect(item.resolved, isTrue);
    expect(item.hints, isEmpty);
    expect(const NowItemHint(inputId: 'IN-x', quote: 'q').at, isNull);
  });
}
