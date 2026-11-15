import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'fixtures.dart';

const conflictPath =
    '00_inbox/2026-09-14_IN-01M2DSFVRRA5MFS95MKFPP2CCM.sync-conflict-20261101-120000-ABCDEFG.md';

HubRepository withWarnings(
  List<String> warnings, [
  Map<String, String>? files,
]) => HubRepository(
  VaultSnapshot(
    files ?? fixtureFiles(),
    warnings: warnings,
    loadedAt: DateTime.utc(2026, 10, 30),
  ),
);

void main() {
  test('同期の競合コピーは通常の記録から除外して注意を出し、コピーは止めない', () {
    final files = fixtureFiles();
    final base = HubRepository(fixture(files));
    final repo = HubRepository(
      fixture({...files, conflictPath: files[inputPath]!}),
    );
    expect(repo.records.length, base.records.length);
    expect(repo.conflictCopies, [conflictPath]);
    expect(repo.warnings.single, contains('競合コピー'));
    expect(repo.warnings.single, contains(conflictPath));
    expect(repo.context('context-hub'), contains('# AI Context Hub'));
    expect(repo.vaultContext(), contains('進行中のプロジェクト'));
    final memo = repo.records.values.firstWhere((r) => r.path == inputPath);
    expect(repo.bundleContext([memo.id]).included, isNotEmpty);
  });

  test('対象に関係しないファイルの読取の注意では、contextのコピーを止めない', () {
    for (final w in [
      'symlinkを除外: 20_ideas/x.md',
      '読取できないファイル: Input/REQ-0123456789abcdef0123456789abcdef.md',
      'symlinkを除外: 10_projects/other/NOW.md',
    ]) {
      final repo = withWarnings([w]);
      expect(repo.warnings, [w], reason: w);
      expect(
        repo.context('context-hub'),
        contains('# AI Context Hub'),
        reason: w,
      );
      final memo = repo.records.values.firstWhere((r) => r.path == inputPath);
      expect(repo.bundleContext([memo.id]).included, isNotEmpty, reason: w);
    }
  });

  test('対象に関係しうる・どのファイルか分からない注意では、これまでどおりコピーを止める', () {
    for (final w in [
      'symlinkを除外: 00_inbox/2026-09-20_IN-01M2DSFVRRA5MFS95MKFPP2CDD.md',
      '読取できないファイル: 90_system/receipts/IN-01M2DSFVRRA5MFS95MKFPP2CCM.json',
      '読取できないファイル: 30_knowledge/x.md',
      'symlinkを除外: 10_projects/context-hub/NOW.md',
      '読取の上限（ファイル20000件・合計64MB）に達したため、00_inboxの一部を読めませんでした。',
      '深さの上限に達しました。',
      'フォルダーの読取を中断: 00_inbox',
    ]) {
      final repo = withWarnings([w]);
      expect(
        () => repo.context('context-hub'),
        throwsA(isA<FormatException>()),
        reason: w,
      );
      expect(
        () => repo.vaultContext(),
        throwsA(isA<FormatException>()),
        reason: w,
      );
    }
    // 統合元のプロジェクトのフォルダーは、統合先のcontextに関係する。
    final memo = HubRepository(
      fixture(),
    ).records.values.firstWhere((r) => r.path == inputPath);
    expect(
      () => withWarnings([
        'symlinkを除外: 10_projects/context-hub/NOW.md',
      ]).bundleContext([memo.id]),
      throwsA(isA<FormatException>()),
    );
  });
}
