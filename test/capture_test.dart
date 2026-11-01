import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/storage/capture_service.dart';

class TempAccess extends VaultAccess {
  late Directory directory;
  int writes = 0;
  bool loseResponse = false;
  Future<void> init() async {
    directory = await Directory.systemTemp.createTemp(
      'context-hub-flutter-test-',
    );
    await Directory('${directory.path}/state').create();
  }

  File request(VaultLocation l, String id) =>
      File('${directory.path}/${l.handle}/Input/$id.md');
  File state(String name) => File('${directory.path}/state/$name');
  @override
  Future<String?> readRequest(VaultLocation l, String id) async {
    final f = request(l, id);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> writeRequest(VaultLocation l, String id, String raw) async {
    final f = request(l, id);
    await f.parent.create(recursive: true);
    if (await f.exists()) {
      throw StateError('既存');
    }
    await f.writeAsString(raw, flush: true);
    writes++;
    if (loseResponse) {
      throw StateError('応答消失');
    }
  }

  @override
  Future<String?> readState(String name) async =>
      await state(name).exists() ? state(name).readAsString() : null;
  @override
  Future<void> writeState(
    String name,
    String raw, {
    bool exclusive = false,
  }) async {
    if (exclusive && await state(name).exists()) {
      throw StateError('既存');
    }
    await state(name).writeAsString(raw, flush: true);
  }

  @override
  Future<List<String>> listJournals() async =>
      (await Directory('${directory.path}/state').list().toList())
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n != 'settings.json')
          .toList();
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) async =>
      VaultSnapshot({});
  @override
  Future<VaultLocation?> pickVault() async => null;
  @override
  Future<VaultLocation> sampleVault(Map<String, String> files) async =>
      const VaultLocation('sample', 'サンプル');
  @override
  Future<void> openExternal(String url) async {}
}

const location = VaultLocation('one', 'テスト');
const op = '11111111-2222-4333-8444-555555555555';
const draft = CaptureDraft(
  operationId: op,
  text: ' 思いつき\n\n- そのまま\n',
  project: 'context-hub',
);

class BookmarkAccess extends TempAccess {
  @override
  File request(VaultLocation l, String id) =>
      super.request(const VaultLocation('same-directory', '同じ実フォルダー'), id);
}

void main() {
  late TempAccess access;
  late CaptureService service;
  setUp(() async {
    access = TempAccess();
    await access.init();
    service = CaptureService(access, location);
  });
  tearDown(() async {
    await access.directory.delete(recursive: true);
  });
  test('同じ操作の二重実行・再起動でInputは1件、本文と出典は不変', () async {
    final results = await Future.wait([
      service.save(draft),
      service.save(draft),
    ]);
    expect(results.every((r) => r.saved), isTrue);
    final result = await CaptureService(access, location).save(draft);
    expect(access.writes, 1);
    final packet = parseMarkdown(
      (await access.readRequest(location, result.requestId))!,
    );
    expect(packet.body, draft.text);
    expect(packet.meta['source'], 'flutter-client/$op');
    expect(packet.meta['operation'], 'capture');
    expect(
      (await access.state('$op.json').readAsString()).contains(draft.text),
      isFalse,
    );
  });
  test('同じ操作の内容を変えると拒否し保存を増やさない', () async {
    await service.save(draft);
    await expectLater(
      service.save(const CaptureDraft(operationId: op, text: '変更')),
      throwsA(anything),
    );
    expect(access.writes, 1);
  });
  test('応答消失は同じREQのreadbackで保存を確認する', () async {
    access.loseResponse = true;
    expect((await service.save(draft)).saved, isTrue);
    expect((await service.confirm(op)).saved, isTrue);
    expect(access.writes, 1);
  });
  test('保存後に欠損・改変があっても再送せず確認待ち', () async {
    final result = await service.save(draft);
    await access.request(location, result.requestId).writeAsString('改変');
    expect((await service.confirm(op)).state, 'uncertain');
    await access.request(location, result.requestId).delete();
    expect((await service.save(draft)).state, 'uncertain');
    expect(access.writes, 1);
    expect((await service.pending()).single.operationId, op);
  });
  test('別Vaultの操作IDを利用できない', () async {
    await service.save(draft);
    await expectLater(
      CaptureService(access, const VaultLocation('two', '別')).save(draft),
      throwsA(anything),
    );
    expect(access.writes, 1);
  });
  test('同一Vaultを移動・再選択してhandleが変わっても確認操作を維持する', () async {
    final linked = BookmarkAccess();
    await linked.init();
    try {
      const old = VaultLocation(
        'old-bookmark',
        '旧名',
        identity: 'same-physical-vault',
      );
      const moved = VaultLocation(
        'new-bookmark',
        '新名',
        identity: 'same-physical-vault',
      );
      final result = await CaptureService(linked, old).save(draft);
      await linked.request(old, result.requestId).delete();
      expect(
        (await CaptureService(linked, old).confirm(op)).state,
        'uncertain',
      );
      final restarted = CaptureService(linked, moved);
      expect((await restarted.pending()).single.operationId, op);
      expect((await restarted.save(draft)).state, 'uncertain');
      expect(linked.writes, 1);
    } finally {
      await linked.directory.delete(recursive: true);
    }
  });
  test('壊れたjournalは新規保存を止め、本文をログへ出さない', () async {
    await access.writeState('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json', '{');
    await expectLater(service.save(draft), throwsA(anything));
    expect(access.writes, 0);
  });
  test('journalを先に書き、Input欠損でも新規書込をしない', () async {
    await service.save(draft);
    final journal = jsonDecode((await access.readState('$op.json'))!);
    await access.request(location, journal['requestId']).delete();
    final restarted = CaptureService(access, location);
    expect((await restarted.confirm(op)).state, 'uncertain');
    expect((await restarted.save(draft)).state, 'uncertain');
    expect(access.writes, 1);
  });
  test('空・超過・不正project/UUIDを保存しない', () async {
    for (final bad in [
      const CaptureDraft(operationId: op, text: '  '),
      CaptureDraft(operationId: op, text: 'あ' * 8001),
      const CaptureDraft(operationId: '../', text: '本文'),
      const CaptureDraft(operationId: op, text: '本文', project: '../outside'),
    ]) {
      await expectLater(service.save(bad), throwsA(anything));
    }
    expect(access.writes, 0);
  });
}
