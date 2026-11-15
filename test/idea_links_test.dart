import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'capture_test.dart' show TempAccess, location;

const linkOp = '61111111-2222-4333-8444-555555555555';
const separateOp = '71111111-2222-4333-8444-555555555555';
const staleOp = '81111111-2222-4333-8444-555555555555';

Future<Map<String, String>> runNode(List<String> args, Directory dir) async {
  final out = File(
    '${dir.path}/out-${args.first}-${args.length}-${DateTime.now().microsecondsSinceEpoch}.json',
  );
  final result = await Process.run('node', [
    'scripts/check_idea_protocol.mjs',
    ...args,
    out.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return Map<String, String>.from(jsonDecode(await out.readAsString()) as Map);
}

Future<File> writeFixture(Directory dir, Map<String, String> files) async {
  final f = File(
    '${dir.path}/fixture-${DateTime.now().microsecondsSinceEpoch}.json',
  );
  await f.writeAsString(jsonEncode(files));
  return f;
}

void main() {
  late TempAccess access;
  setUp(() async {
    access = TempAccess();
    await access.init();
  });
  tearDown(() => access.directory.delete(recursive: true));

  /// Dartで依頼を保存し、本体に受理させた後のVaultを返す。保存直後（未同期）のVaultも返す。
  Future<(Map<String, String>, Map<String, String>)> send(
    Map<String, String> files,
    String op,
    String a,
    String hashA,
    String b,
    String hashB,
    String action,
  ) async {
    final saved = await CaptureService(
      access,
      location,
    ).saveIdeaLink(op, a, hashA, b, hashB, action);
    final req = access.request(location, saved.requestId);
    final waiting = {
      ...files,
      'Input/${saved.requestId}.md': await req.readAsString(),
    };
    final after = await runNode([
      'ingest',
      req.path,
      (await writeFixture(access.directory, files)).path,
    ], access.directory);
    return (waiting, after);
  }

  test('本体の索引から似ているアイデアを読み、束ねる依頼が受理されると束として表示する', () async {
    final prepared = await runNode(['prepare'], access.directory);
    var repo = HubRepository(VaultSnapshot(prepared));
    expect(repo.warnings, isEmpty);
    expect(repo.ideaCandidates, hasLength(1));
    final c = repo.ideaCandidates.single;
    expect(repo.similarIdeas(c.a).single.other(c.a), c.b);
    expect(repo.ideaRecord(c.a)?.kind, 'idea');
    expect(repo.ideaGroupOf(c.a), isNull);

    final (waiting, linked) = await send(
      prepared,
      linkOp,
      c.b,
      c.hashB,
      c.a,
      c.hashA,
      'link',
    );
    final pending = HubRepository(VaultSnapshot(waiting));
    expect(pending.ideaLinkRequestIdFor(c.a, c.b), isNotNull);
    expect(pending.intake.first.title, startsWith('アイデアを束ねる依頼: '));

    repo = HubRepository(VaultSnapshot(linked));
    expect(repo.warnings, isEmpty);
    expect(repo.ideaCandidates, isEmpty);
    final group = repo.ideaGroupOf(c.a)!;
    expect(group.ideas.toSet(), {c.a, c.b});
    expect(group.linksDirectly(c.b, c.a), isTrue);
    expect(repo.ideaLinkRequestIdFor(c.a, c.b), isNull);
    expect(repo.intake.single.state, anyOf('accepted', 'organized'));
    expect(repo.intake.single.detail, 'Miniがアイデアを束ねました。');

    // 束から外す（別の話）と、束も候補もなくなる。
    final aHash = digestOf(linked, c.a), bHash = digestOf(linked, c.b);
    final (_, separated) = await send(
      linked,
      separateOp,
      c.a,
      aHash,
      c.b,
      bHash,
      'separate',
    );
    repo = HubRepository(VaultSnapshot(separated));
    expect(repo.warnings, isEmpty);
    expect(repo.ideaGroupOf(c.a), isNull);
    expect(repo.ideaCandidates, isEmpty);
    expect(repo.ideaLinkRequestIdFor(c.a, c.b), isNull);
  });

  test('確認した後にアイデアが作り直されていたら、受付の失敗として理由を示す', () async {
    final prepared = await runNode(['prepare'], access.directory);
    final c = HubRepository(VaultSnapshot(prepared)).ideaCandidates.single;
    final (_, after) = await send(
      prepared,
      staleOp,
      c.a,
      'a' * 64,
      c.b,
      c.hashB,
      'link',
    );
    final repo = HubRepository(VaultSnapshot(after));
    final item = repo.intake.single;
    expect(item.state, 'rejected');
    expect(item.detail, contains('作り直されていました'));
    expect(repo.ideaLinkRequestIdFor(c.a, c.b), isNull);
    expect(repo.ideaCandidates, hasLength(1));
  });

  test('依頼の形式を保存前に検査する', () async {
    final service = CaptureService(access, location);
    const id = 'IDEA-01M2DSFVQMH65989604KSVE1PV';
    final hash = 'a' * 64;
    expect(
      () => service.saveIdeaLink(linkOp, id, hash, id, hash, 'link'),
      throwsFormatException,
    );
    expect(
      () => service.saveIdeaLink(linkOp, id, hash, 'IDEA-x', hash, 'link'),
      throwsFormatException,
    );
    expect(
      () => service.saveIdeaLink(
        linkOp,
        id,
        hash,
        'IDEA-01M2DSFVRRA5MFS95MKFPP2CCM',
        'x',
        'link',
      ),
      throwsFormatException,
    );
    expect(
      () => service.saveIdeaLink(
        linkOp,
        id,
        hash,
        'IDEA-01M2DSFVRRA5MFS95MKFPP2CCM',
        hash,
        'merge',
      ),
      throwsFormatException,
    );
    expect(ideaPairKey('IDEA-B', 'IDEA-A'), 'IDEA-A/IDEA-B');
  });

  test('索引の形式が不正なら一覧を出さず、読めない記録として示す', () {
    final repo = HubRepository(
      VaultSnapshot({
        '90_system/idea-index.json':
            '{"schema_version":1,"candidates":[{"ideas":["x"]}],"groups":[]}',
      }),
    );
    expect(repo.ideaCandidates, isEmpty);
    expect(repo.warnings.join('\n'), contains('idea-index.json'));
  });
}

String digestOf(Map<String, String> files, String ideaId) =>
    digest(files['20_ideas/$ideaId.md']!);
