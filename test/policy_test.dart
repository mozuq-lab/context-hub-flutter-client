import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/core/policies.dart';
import 'package:context_hub_client/core/review_candidates.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/storage/review_service.dart';
import 'capture_test.dart' show TempAccess, location, op;

Map<String, dynamic> scopedFixture() =>
    jsonDecode(File('assets/scoped-policy.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, String> scopedFiles() =>
    Map<String, String>.from(scopedFixture()['files'] as Map);
void main() {
  test('本体と同じ全文・有効範囲を読みproject内の知識を閲覧できる', () {
    final repo = HubRepository(VaultSnapshot(scopedFiles())),
        bundle = PolicyReader(repo.snapshot).read('example');
    expect(bundle.text, scopedFixture()['expected']['text']);
    expect(bundle.text, contains('共通の採用方針'));
    expect(bundle.text, contains('対象固有の採用方針'));
    expect(bundle.text, isNot(contains('必要時に参照する知識')));
    expect(bundle.text, isNot(contains('停止した古い方針')));
    expect(
      repo.records.values.any((r) => r.path.contains('/knowledge/')),
      isTrue,
    );
    expect(repo.context('example').startsWith(bundle.text), isTrue);
    expect(() => repo.context('example', maxChars: 200), throwsFormatException);
  });
  test('正本・停止・manifest・POLICYの部分同期を空方針として使わない', () {
    for (final mode in ['missing', 'stop', 'knw', 'projection', 'new']) {
      final files = scopedFiles();
      if (mode == 'missing') files.remove('90_system/policies/index.json');
      if (mode == 'stop') {
        files.removeWhere(
          (p, _) => p.startsWith('90_system/knowledge-retirements/'),
        );
      }
      if (mode == 'knw') {
        final p = files.keys.firstWhere((p) => p.startsWith('30_knowledge/'));
        files[p] = '${files[p]}変更';
      }
      if (mode == 'projection') files['POLICY.md'] = '変更';
      if (mode == 'new') {
        files['90_system/approvals/APR-${'0' * 26}.json'] = '{}';
      }
      expect(
        () => PolicyReader(VaultSnapshot(files)).read('example'),
        throwsFormatException,
        reason: mode,
      );
    }
  });
  test('手で変更された採用済み知識は、本体と同じくその知識だけを方針から外して読む', () async {
    final dir = await Directory.systemTemp.createTemp('ctx-modified-knw-');
    addTearDown(() => dir.delete(recursive: true));
    final out = File('${dir.path}/out.json');
    // 本体で、採用済みの共通方針のファイルを1行手で直してから方針を集約し直す。
    const script = r'''
import {mkdtemp,readFile,writeFile,readdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';
const core=resolve('vendor/context-hub/packages/core/dist/index.js');
const {defaultConfig,Vault,rebuildDashboard,readPolicies,formatPolicies}=await import(core);
async function filesAt(dir,prefix=''){const out={};for(const e of await readdir(dir,{withFileTypes:true})){if(e.name.startsWith('.'))continue;const p=prefix+e.name;if(e.isDirectory())Object.assign(out,await filesAt(join(dir,e.name),p+'/'));else out[p]=await readFile(join(dir,e.name),'utf8');}return out;}
const fx=JSON.parse(await readFile('assets/scoped-policy.json','utf8'));
const root=await mkdtemp(join(tmpdir(),'modknw-'));
try{
 const config=defaultConfig(join(root,'vault'),join(root,'state')),vault=new Vault(config);await vault.init();
 for(const[p,raw]of Object.entries(fx.files))await vault.write(p,raw);
 const p=Object.keys(fx.files).find(p=>p.startsWith('30_knowledge/')&&fx.files[p].includes('共通の採用方針'));
 await vault.write(p,fx.files[p].replace('共通の採用方針','共通の採用方針（手で直した）'));
 await rebuildDashboard(config,{now:new Date('2026-11-02T00:00:00Z')});
 const b=await readPolicies(config,'example'),c=await readPolicies(config);
 await writeFile(process.argv[1],JSON.stringify({files:await filesAt(config.vaultPath),text:formatPolicies(b),common:formatPolicies(c),inactive:b.inactiveIds,modified:p}));
}finally{await rm(root,{recursive:true,force:true});}
''';
    final result = await Process.run('node', [
      '--input-type=module',
      '-e',
      script,
      out.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final core = jsonDecode(await out.readAsString()) as Map<String, dynamic>;
    final files = Map<String, String>.from(core['files'] as Map);
    final id = (core['modified'] as String)
        .split('/')
        .last
        .replaceAll('.md', '');
    expect(core['inactive'], contains(id));
    final bundle = PolicyReader(VaultSnapshot(files)).read('example');
    expect(bundle.modified, [id]);
    expect(bundle.text, core['text']);
    expect(PolicyReader(VaultSnapshot(files)).read().text, core['common']);
    expect(bundle.text, contains(modifiedKnowledgeWarning([id])));
    expect(bundle.text, isNot(contains('共通の採用方針')));
    expect(bundle.text, contains('対象固有の採用方針'));
    // 外した知識のファイルをさらに書き換えても、集約し直すまでは依存のhashで止まる。
    final p = core['modified'] as String;
    files[p] = '${files[p]}さらに変更';
    expect(
      () => PolicyReader(VaultSnapshot(files)).read('example'),
      throwsFormatException,
    );
  });
  test('採用先なしを拒否しscope付きREQと停止REQを先行journalで保存する', () async {
    final a = TempAccess();
    await a.init();
    addTearDown(() => a.directory.delete(recursive: true));
    final repo = HubRepository(VaultSnapshot(scopedFiles())),
        candidate = repo.review.pending.single,
        s = ReviewService(a, location);
    await expectLater(
      s.submit(op, candidate, 'approve'),
      throwsFormatException,
    );
    final target = AdoptionTarget.fromJson(
      Map<String, dynamic>.from(scopedFixture()['expected']['target'] as Map),
    );
    final result = await s.submit(op, candidate, 'approve', target: target),
        raw = (await a.readRequest(location, result.requestId))!;
    expect(parseMarkdown(raw).meta, containsPair('project_id', 'example'));
    expect(
      (await s.submit(op, candidate, 'approve', target: target)).saved,
      isTrue,
    );
    expect(a.writes, 1);
    await expectLater(
      s.submit(op, candidate, 'approve', target: AdoptionTarget.global()),
      throwsStateError,
    );
    final old = repo.review.history.firstWhere(
      (i) => !i.retired && i.kind != 'project',
    );
    final stop = await s.retire('11111111-1111-1111-1111-111111111111', old);
    expect(
      parseMarkdown(
        (await a.readRequest(location, stop.requestId))!,
      ).meta['operation'],
      'knowledge-retire',
    );
  });
  for (final mode in ['project', 'global', 'retire', 'keep']) {
    test('Dartの$mode要求を本体で受理し方針と停止履歴を再同期する', () async {
      final a = TempAccess();
      await a.init();
      addTearDown(() => a.directory.delete(recursive: true));
      final before = HubRepository(VaultSnapshot(scopedFiles())),
          service = ReviewService(a, location);
      final candidate = mode == 'retire'
          ? before.review.history.firstWhere(
              (i) => i.retirable && i.kind == 'decision',
            )
          : mode == 'keep'
          ? before.review.history.firstWhere(
              (i) => i.keepable && i.kind == 'decision',
            )
          : before.review.pending.single;
      final target = mode == 'global'
          ? AdoptionTarget.global()
          : AdoptionTarget.fromJson(
              Map<String, dynamic>.from(
                scopedFixture()['expected']['target'] as Map,
              ),
            );
      final result = mode == 'retire'
              ? await service.retire(op, candidate)
              : mode == 'keep'
              ? await service.keep(op, candidate)
              : await service.submit(op, candidate, 'approve', target: target),
          out = '${a.directory.path}/after.json';
      final node = await Process.run('node', [
        'scripts/check_policy_protocol.mjs',
        a.request(location, result.requestId).path,
        'assets/scoped-policy.json',
        out,
      ]);
      expect(node.exitCode, 0, reason: '${node.stdout}\n${node.stderr}');
      final files = Map<String, String>.from(
            jsonDecode(await File(out).readAsString()) as Map,
          ),
          after = HubRepository(VaultSnapshot(files));
      expect(after.review.byId(candidate.id)!.retired, mode == 'retire');
      expect(after.intake.single.state, 'accepted');
      expect(
        after.intake.single.detail,
        contains(
          mode == 'retire'
              ? '適用停止'
              : mode == 'keep'
              ? 'まだ有効'
              : '承認済み',
        ),
      );
      if (mode == 'keep') {
        expect(candidate.policyReview!.confirmedAt, isNull);
        expect(
          after.review.byId(candidate.id)!.policyReview!.confirmedAt,
          isNotNull,
        );
        // 受け付けた後もInputに依頼が残るが、記録待ちとしては数えず、次の見直しで確かめ直せる。
        expect(after.snapshot.files['Input/${result.requestId}.md'], isNotNull);
        expect(after.review.policyKeepRequestIdFor(candidate.id), isNull);
      }
      final policy = PolicyReader(after.snapshot).read('example').text;
      expect(policy.contains(candidate.claim), mode != 'retire');
    });
  }
  test('数字だけと英数字のproject IDが混在しても本体と同じ方針を読む', () {
    final fixture =
            jsonDecode(
                  File('test/fixtures/numeric-policy.json').readAsStringSync(),
                )
                as Map,
        files = Map<String, String>.from(fixture['files'] as Map),
        bundle = PolicyReader(VaultSnapshot(files)).read('100');
    expect(bundle.text, fixture['expected']['text']);
    expect(bundle.text, contains('対象100の方針'));
    expect(bundle.text, isNot(contains('対象20の方針')));
  });
}
