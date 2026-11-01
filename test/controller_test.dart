import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'capture_test.dart' show TempAccess;
import 'fixtures.dart';

class UIAccess extends TempAccess {
  VaultSnapshot current = fixture();
  Completer<VaultSnapshot>? delayed;
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) {
    if (location.handle == 'slow') {
      return delayed!.future;
    }
    return Future.value(current);
  }
}

void main() {
  late UIAccess access;
  late HubController c;
  setUp(() async {
    access = UIAccess();
    await access.init();
    c = HubController(access, sampleLoader: () async => fixture().files);
  });
  tearDown(() async {
    c.dispose();
    await access.directory.delete(recursive: true);
  });
  test('切替前の遅い応答は別Vaultに反映しない', () async {
    access.delayed = Completer();
    final slow = c.activate(const VaultLocation('slow', '古い'));
    await c.activate(const VaultLocation('new', '新しい'));
    access.delayed!.complete(VaultSnapshot({}));
    await slow;
    expect(c.location!.handle, 'new');
    expect(c.repository!.projects, isNotEmpty);
  });
  test('context直前にsnapshotが変わると再表示してコピーを止める', () async {
    await c.useSample();
    expect(await c.context('context-hub'), contains('IN-'));
    access.current = VaultSnapshot({
      ...fixture().files,
      'Input/changed.md': '同期途中',
    });
    await expectLater(c.context('context-hub'), throwsStateError);
    expect(c.repository!.snapshot.files, contains('Input/changed.md'));
  });
  test('フォーム中はVault切替を拒否し保存先を固定する', () async {
    await c.useSample();
    c.composing = true;
    await expectLater(
      c.activate(const VaultLocation('other', '別')),
      throwsStateError,
    );
    expect(c.location!.handle, 'sample');
  });
  test('本文リンクは出典から解決し、既知の取得済み記録だけを返す', () async {
    await c.useSample();
    expect(c.resolveLink(nowPath, '../../$inputPath'), isNotNull);
    for (final href in [
      'javascript:alert(1)',
      'file:///etc/hosts',
      '../../unknown.md',
      '../../../secret',
      'https://example.com',
    ]) {
      expect(c.resolveLink(nowPath, href), isNull);
    }
  });
  test('壊れたjournalでも読取画面を残し保存を止める', () async {
    await access.writeState('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json', '{');
    await c.useSample();
    expect(c.repository!.projects, isNotEmpty);
    expect(c.captureWarning, isNotNull);
  });
}
