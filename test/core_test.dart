import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'fixtures.dart';

String packet(Map<String, dynamic> meta, String text) =>
    '---\n${jsonEncode(meta)}\n---\n$text';

void main() {
  test('サンプルのNOW・原文・出典・AI自己報告を読み、元のmapを変更しない', () {
    final files = fixtureFiles(),
        before = Map.of(files),
        repo = HubRepository(fixture(files));
    final project = repo.projects['context-hub']!;
    expect(project.title, 'AI Context Hub');
    expect(project.sections['current']!.first.text, 'サンプルで原文保存を確認した。');
    expect(project.sections['next']!.first.text, 'サンプルの検索を確認する。');
    final source =
        repo.records[project.sections['current']!.first.references.first]!;
    expect(source.sourceId, inputId);
    expect(source.origin, 'ai-self-report');
    expect(source.title, contains('サンプルで原文保存'));
    expect(repo.recent.length, 3);
    expect(repo.ideas.length, 1);
    expect(repo.ideas.first.warnings.join(' '), contains('未検証'));
    expect(repo.ideas.first.warnings.join(' '), isNot(contains('整合性')));
    expect(repo.context(project.id), contains('出典付き資料'));
    expect(repo.context(project.id), contains(inputId));
    expect(files, before);
  });
  test('本文とタイトルから複数語で検索する', () {
    final repo = HubRepository(fixture());
    expect(repo.search('同期'), isNotEmpty);
    expect(
      repo.search('AI Context Hub').any((r) => r.kind == 'project'),
      isTrue,
    );
    expect(repo.search('存在しない言葉'), isEmpty);
  });
  test('NOW欠損でもプロジェクトを残し、進捗を創作しない', () {
    final files = fixtureFiles()..remove(nowPath),
        project = HubRepository(fixture(files)).projects['context-hub']!;
    expect(project.nowRecordId, isNull);
    expect(project.sections['current'], isEmpty);
    expect(project.warnings.join(' '), contains('未生成'));
  });
  test('空の認識済みVaultは空状態で、未知のフォルダーは拒否する', () {
    expect(HubRepository(fixture({})).records, isEmpty);
    expect(
      () => HubRepository(VaultSnapshot({}, recognized: false)),
      throwsFormatException,
    );
  });
  test('壊れた記録があっても原文を残し、contextコピーを停止する', () {
    final files = fixtureFiles()..['00_inbox/broken.md'] = '壊れたfrontmatter';
    final repo = HubRepository(fixture(files));
    expect(repo.recent.length, 3);
    expect(repo.warnings.join(' '), contains('broken.md'));
    expect(() => repo.context('context-hub'), throwsFormatException);
  });
  test('生成ハッシュが変わったNOWを検証済みと表示せずコピーも止める', () {
    final files = fixtureFiles();
    files[nowPath] = files[nowPath]!.replaceFirst('原文保存を確認した', '原文保存は未確認');
    final repo = HubRepository(fixture(files));
    expect(repo.projects['context-hub']!.warnings.join(' '), contains('整合性'));
    expect(() => repo.context('context-hub'), throwsFormatException);
  });
  for (final mode in ['last', 'first', 'all']) {
    test('複数の訂正は全チェーンの反映状態からコピーを判定する（$mode）', () {
      final reverse = mode == 'first';
      final files = fixtureFiles();
      const second = 'IN-01M2DSFVSNCJSF7XKRPW29TM7M';
      const secondCorrection = 'IN-01M2DSFVSNCJSF7XKRPW29TM7N';
      final pairs = [(inputId, correctionId), (second, secondCorrection)];
      for (final pair in pairs) {
        final oldPath = '00_inbox/2026-09-14_${pair.$1}.md';
        final newPath = '00_inbox/2026-09-15_${pair.$2}.md';
        final old = parseMarkdown(files[oldPath]!);
        files[newPath] = packet({
          ...old.meta,
          'id': pair.$2,
          'kind': 'correction',
          'corrects_input_id': pair.$1,
          'source_event_id': 'correction-${pair.$2}',
          'occurred_at': '2026-09-15T00:00:00Z',
          'received_at': '2026-09-15T00:00:00Z',
        }, '訂正本文');
        final receipt =
            jsonDecode(files['90_system/receipts/${pair.$1}.json']!)
                as Map<String, dynamic>;
        receipt.addAll({
          'input_id': pair.$2,
          'input_hash': digest(files[newPath]!),
          'organized_at': '2026-09-15T00:05:00Z',
          'root_input_id': pair.$1,
          'evidence_ids': [pair.$1, pair.$2],
          'evidence_hash': digest(
            '${pair.$1}:${digest(files[oldPath]!)}\n${pair.$2}:${digest(files[newPath]!)}',
          ),
        });
        files['90_system/receipts/${pair.$2}.json'] = jsonEncode(receipt);
      }
      final oldNow = parseMarkdown(files[nowPath]!);
      var body = oldNow.body;
      for (final reflected
          in mode == 'all' ? pairs : [reverse ? pairs.first : pairs.last]) {
        body = body.replaceAll(
          '[${reflected.$1}](../../00_inbox/2026-09-14_${reflected.$1}.md)',
          '[${reflected.$2}](../../00_inbox/2026-09-15_${reflected.$2}.md)',
        );
      }
      files[nowPath] = packet({
        ...oldNow.meta,
        'generated_at': '2026-09-15T00:10:00Z',
        'generated_hash': 'sha256:${digest(autoRegion(body)!.auto)}',
      }, body);
      final ordered = reverse
          ? Map<String, String>.fromEntries(files.entries.toList().reversed)
          : files;
      final repo = HubRepository(fixture(ordered));
      if (mode == 'all') {
        expect(
          repo.projects['context-hub']!.warnings.join(' '),
          isNot(contains('反映未確認')),
        );
        expect(repo.context('context-hub'), contains(correctionId));
      } else {
        expect(
          repo.projects['context-hub']!.warnings.join(' '),
          contains('反映未確認'),
        );
        expect(() => repo.context('context-hub'), throwsFormatException);
      }
    });
  }
  test('未反映の訂正を原文とNOWの両方へ示し、最新原文を辿れる', () {
    final files = fixtureFiles(), original = parseMarkdown(files[inputPath]!);
    files[correctionPath] = packet({
      ...original.meta,
      'id': correctionId,
      'kind': 'correction',
      'corrects_input_id': inputId,
      'source_event_id': 'fixture-correction',
      'occurred_at': '2026-09-15T10:00:00+09:00',
      'received_at': '2026-09-15T10:00:00+09:00',
    }, '検証は未完了です。');
    final repo = HubRepository(fixture(files)),
        project = repo.projects['context-hub']!;
    expect(project.warnings.join(' '), contains('訂正未反映'));
    final originalRecord = repo.records.values.firstWhere(
      (r) => r.sourceId == inputId,
    );
    expect(originalRecord.warnings.join(' '), contains('訂正'));
    expect(
      originalRecord.references.map((id) => repo.records[id]!.sourceId),
      contains(correctionId),
    );
    expect(() => repo.context('context-hub'), throwsFormatException);
  });
  test('訂正receiptだけが先に届いた旧NOWを反映済みと扱わない', () {
    final files = fixtureFiles(), original = parseMarkdown(files[inputPath]!);
    files[correctionPath] = packet({
      ...original.meta,
      'id': correctionId,
      'kind': 'correction',
      'corrects_input_id': inputId,
      'source_event_id': 'fixture-correction',
      'occurred_at': '2026-09-15T10:00:00+09:00',
      'received_at': '2026-09-15T10:00:00+09:00',
    }, '検証は未完了です。');
    final receipt =
        jsonDecode(files['90_system/receipts/$inputId.json']!)
            as Map<String, dynamic>;
    receipt.addAll({
      'input_id': correctionId,
      'input_hash': digest(files[correctionPath]!),
      'organized_at': '2026-09-15T10:05:00+09:00',
      'root_input_id': inputId,
      'evidence_ids': [inputId, correctionId],
      'evidence_hash': digest(
        '$inputId:${digest(files[inputPath]!)}\n$correctionId:${digest(files[correctionPath]!)}',
      ),
    });
    files['90_system/receipts/$correctionId.json'] = jsonEncode(receipt);
    final repo = HubRepository(fixture(files));
    expect(repo.projects['context-hub']!.warnings.join(' '), contains('反映未確認'));
    expect(() => repo.context('context-hub'), throwsFormatException);
  });
  for (final status in ['error', 'conflict']) {
    test('受付の$statusを本文hashで照合して状態表示する', () {
      final files = fixtureFiles(),
          id = 'REQ-${'a' * 32}',
          path = 'Input/$id.md';
      files[path] = packet({
        'schema_version': 1,
        'request_id': id,
        'operation': 'capture',
        'source': 'fixture',
        'occurred_at': '2026-10-30T00:00:00Z',
        'kind': 'memo',
      }, '確認用メモ');
      files['90_system/intake-errors/${digest(path)}.json'] = jsonEncode({
        'schema_version': 1,
        'path': path,
        'file_hash': digest(files[path]!),
        'status': status,
        'code': 'capture-error',
        'updated_at': '2026-10-30T00:00:01Z',
      });
      expect(
        HubRepository(fixture(files)).intake.first.state,
        status == 'error' ? 'rejected' : 'conflict',
      );
    });
  }
  test('原文と処理記録のhash不一致を検出する', () {
    final files = fixtureFiles(),
        path = '90_system/receipts/$inputId.json',
        receipt = jsonDecode(fixtureFiles()[path]!) as Map<String, dynamic>;
    receipt['input_hash'] = digest('old');
    files[path] = jsonEncode(receipt);
    final repo = HubRepository(fixture(files));
    expect(repo.warnings.join(' '), contains('整合性'));
    expect(() => repo.context('context-hub'), throwsFormatException);
  });
  test('不完全な整理結果のreceiptを採用せず注意する', () {
    final files = fixtureFiles(), path = '90_system/receipts/$inputId.json';
    final receipt = jsonDecode(files[path]!) as Map<String, dynamic>;
    receipt['result'] = {'project_candidates': []};
    files[path] = jsonEncode(receipt);
    final repo = HubRepository(fixture(files));
    expect(repo.warnings, isNotEmpty);
    expect(() => repo.context('context-hub'), throwsFormatException);
  });
  test('NOWの根拠原文が未到着ならコピーを停止する', () {
    final files = fixtureFiles()..remove(inputPath),
        repo = HubRepository(fixture(files));
    expect(() => repo.context('context-hub'), throwsFormatException);
  });
  test('受付を発生日時の降順にし、乱数IDで直近を落とさない', () {
    final files = fixtureFiles();
    for (final item in [
      ('z', '2026-09-14T00:00:00Z'),
      ('a', '2026-10-30T00:00:00Z'),
    ]) {
      final id = 'REQ-${item.$1 * 32}';
      files['Input/$id.md'] = packet({
        'schema_version': 1,
        'request_id': id,
        'operation': 'capture',
        'source': 'fixture',
        'occurred_at': item.$2,
        'kind': 'memo',
      }, item.$1);
    }
    expect(HubRepository(fixture(files)).intake.first.title, 'a');
  });
  test('snapshotの不正パスを拒否し、外部データを表示しない', () {
    final files = fixtureFiles()..['../../outside.md'] = '外部データ';
    final repo = HubRepository(fixture(files));
    expect(repo.warnings, isNotEmpty);
    expect(repo.search('外部データ'), isEmpty);
  });
  test('contextは上限と省略表示を守る', () {
    final repo = HubRepository(fixture());
    final text = repo.context('context-hub', maxChars: 1200);
    expect(text.length, lessThanOrEqualTo(1200));
    expect(text, contains('省略'));
  });
  test('frontmatterの循環・多重aliasを許可しない', () {
    expect(
      () => parseMarkdown('---\nx: &a [*a]\n---\n本文'),
      throwsFormatException,
    );
  });
}
