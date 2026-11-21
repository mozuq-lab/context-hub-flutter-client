import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/people.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/ui/app.dart';
import 'capture_test.dart' show TempAccess, location;
import 'widget_test.dart' show MemoryUIAccess;
import 'fixtures.dart';

const addOp = '51111111-2222-4333-8444-555555555555',
    editOp = '51111111-2222-4333-8444-555555555556',
    removeOp = '51111111-2222-4333-8444-555555555557';

/// 本体が作る形のperson.mdと、生成済みの一覧（SUMMARY.md）。
Map<String, String> personFiles({
  String id = 'tanaka',
  String name = '田中さん',
  List<String> aliases = const ['田中'],
  String body =
      '# 田中さん\n\n## 最近の記録（1件）\n- 11-15 メモ — 田中さんから電話 — [IN-01M2DSFVQMH65989604KSVE1PV](../../00_inbox/2026-09-14_IN-01M2DSFVQMH65989604KSVE1PV.md)\n',
}) {
  final meta =
      'schema_version: 1\nperson: $id\ngenerated_by:\n  model: deterministic-writer\n  prompt_version: 1\ngenerated_at: 2026-11-16T00:00:00.000Z\nsource_hash: sha256:${'0' * 64}\nverified: false\nrecords: 1\nopen_items: 2\nlast_seen: 2026-11-15T01:00:00Z\n';
  final unsigned = '---\n$meta---\n$body';
  return {
    personDefinitionPath(
      id,
    ): '---\nid: $id\nname: $name\naliases:${aliases.isEmpty ? ' []\n' : '\n${aliases.map((a) => '  - $a\n').join()}'}---\n# $name\n',
    personPagePath(id):
        '---\n${meta}generated_hash: sha256:${digest(unsigned)}\n---\n$body',
  };
}

void main() {
  test('名前と呼び名を本体と同じ規則で整え、短すぎる名前と重なりを知らせる', () {
    final draft = PersonDraft(
      name: ' 田中さん\n',
      aliases: ['田中', ' 田中 ', 'ＴＡＮＡＫＡ', 'tanaka', '', '田中さん'],
    );
    expect(draft.name, '田中さん');
    expect(draft.aliases, ['田中', 'ＴＡＮＡＫＡ']);
    expect(draft.problem, isNull);
    expect(PersonDraft(name: '', aliases: []).problem, contains('名前'));
    expect(PersonDraft(name: '田', aliases: []).problem, contains('2文字以上'));
    expect(
      PersonDraft(
        name: '田中',
        aliases: [for (var i = 0; i < 21; i++) '呼び名$i'],
      ).problem,
      contains('20件'),
    );
    expect(PersonDraft.splitNames('田中、Tanaka,\n田中部長'), [
      '田中',
      'Tanaka',
      '田中部長',
    ]);
    final repo = HubRepository(fixture({...fixtureFiles(), ...personFiles()}));
    expect(
      PersonDraft(
        name: '佐藤',
        aliases: ['ﾀﾅｶ', '田中'],
      ).overlap(repo.people.values)?.id,
      'tanaka',
    );
    expect(
      PersonDraft(
        name: '田中さん',
        aliases: [],
      ).overlap(repo.people.values, except: 'tanaka'),
      isNull,
    );
  });

  test('登録した人と本体の一覧を読み、読めない定義は注意に出す', () {
    final repo = HubRepository(
      fixture({
        ...fixtureFiles(),
        ...personFiles(),
        ...personFiles(
          id: 'sato',
          name: '佐藤さん',
          aliases: [],
        ).map((k, v) => MapEntry(k, k.endsWith('SUMMARY.md') ? '壊れた' : v)),
        personDefinitionPath('bad'):
            '---\nid: other\nname: x\naliases: []\n---\n',
        // 本体が読まない定義（ほかの項目・1文字の呼び名）は、一覧待ちのまま出さない。
        personDefinitionPath('extra'):
            '---\nid: extra\nname: 山田さん\naliases: []\nnote: x\n---\n',
        personDefinitionPath('short'):
            '---\nid: short\nname: 山田さん\naliases:\n  - 山\n---\n',
      }),
    );
    expect(repo.people.keys, isNot(contains('extra')));
    expect(repo.people.keys, isNot(contains('short')));
    // 人の画面を開く前から注意に出し、別のAIへ渡す文脈のコピーは止めない。
    expect(repo.warnings.join('\n'), contains(personDefinitionPath('extra')));
    expect(repo.copyBlocked(), isFalse);
    final tanaka = repo.people['tanaka']!;
    expect(tanaka.name, '田中さん');
    expect(tanaka.aliases, ['田中']);
    expect(tanaka.page!.body, contains('田中さんから電話'));
    expect(tanaka.page!.warnings.join(), isNot(contains('整合性')));
    expect(tanaka.records, 1);
    expect(tanaka.openItems, 2);
    expect(tanaka.lastSeen, DateTime.utc(2026, 11, 15, 1));
    expect(repo.people['sato']!.page, isNull);
    expect(repo.people.containsKey('bad'), isFalse);
    expect(repo.warnings.join('\n'), contains(personPagePath('sato')));
    expect(repo.warnings.join('\n'), contains(personDefinitionPath('bad')));
    expect(repo.orderedPeople.map((p) => p.id), ['tanaka', 'sato']);
  });

  test('反映待ちの登録と重なる名前は送れず、受け付けられなかった理由を依頼に合わせて示す', () async {
    final files = {...fixtureFiles(), ...personFiles()};
    Map<String, dynamic> request(String id, Map<String, dynamic> fields) => {
      'schema_version': 1,
      'request_id': id,
      'source': 'flutter-client/x',
      'occurred_at': '2026-11-20T10:00:00Z',
      'operation': 'person-definition',
      'confirmed': true,
      ...fields,
    };
    const pending = 'REQ-0123456789abcdef0123456789abcde0',
        rejected = 'REQ-0123456789abcdef0123456789abcde1',
        same = 'REQ-0123456789abcdef0123456789abcde2';
    files['Input/$pending.md'] = encodePacket(
      request(pending, {
        'person_id': 'person-01jabcdefghjkmnpqrstvwxyz0',
        'action': 'add',
        'name': '佐藤さん',
        'aliases': ['佐藤'],
      }),
      '',
    );
    for (final (id, reason) in [
      (rejected, {'code': 'person-overlap', 'person_id': 'tanaka'}),
      (same, {'code': 'person-unchanged'}),
    ]) {
      final path = 'Input/$id.md';
      files[path] = encodePacket(
        request(id, {
          'person_id': 'tanaka',
          'action': 'edit',
          'person_hash': '0' * 64,
          'name': '田中さん',
          'aliases': ['田中'],
        }),
        '',
      );
      files['90_system/intake-errors/${digest(path)}.json'] = jsonEncode({
        'schema_version': 1,
        'path': path,
        'file_hash': digest(files[path]!),
        'status': 'error',
        'code': 'x',
        'updated_at': '2026-11-20T10:00:00Z',
        'reason': reason,
      });
    }
    final repo = HubRepository(fixture(files));
    expect(
      PersonDraft(name: '佐藤', aliases: []).overlap(repo.peopleForOverlap)?.name,
      '佐藤さん',
    );
    expect(
      repo.intake.firstWhere((i) => i.id == rejected).detail,
      contains('（tanaka）と重なる'),
    );
    expect(
      repo.intake.firstWhere((i) => i.id == same).detail,
      contains('変更がなかった'),
    );
    // 受け付けられなかった依頼は、次の依頼を妨げない。
    expect(repo.personRequestIdFor('tanaka'), isNull);
    // 受け付け待ちの変更があれば、同じ人への依頼を重ねない。
    const waiting = 'REQ-0123456789abcdef0123456789abcde3';
    files['Input/$waiting.md'] = encodePacket(
      request(waiting, {
        'person_id': 'tanaka',
        'action': 'remove',
        'person_hash': repo.people['tanaka']!.definitionHash,
      }),
      '',
    );
    expect(HubRepository(fixture(files)).personRequestIdFor('tanaka'), waiting);
  });

  test('Dartの人の登録・変更・外す依頼を本体が受理し、同期後に反映待ちが外れる', () async {
    final access = TempAccess();
    await access.init();
    try {
      final service = CaptureService(access, location);
      await expectLater(
        service.savePersonDefinition(
          addOp,
          personId: 'person-01jabcdefghjkmnpqrstvwxyz0',
          action: 'add',
          expectedHash: '0' * 64,
          draft: PersonDraft(name: '鈴木さん', aliases: []),
        ),
        throwsFormatException,
      );
      final personId = newPersonId();
      expect(personIdPattern.hasMatch(personId), isTrue);
      final added = await service.savePersonDefinition(
        addOp,
        personId: personId,
        action: 'add',
        draft: PersonDraft(name: '鈴木さん', aliases: ['鈴木']),
      );
      expect(added.saved, isTrue);
      final raw = await access.readRequest(location, added.requestId);
      final meta = parseMarkdown(raw!).meta;
      expect(meta, containsPair('operation', 'person-definition'));
      expect(meta.containsKey('person_hash'), isFalse);
      // 同期前は登録依頼中として示す。
      final waiting = HubRepository(
        fixture({...fixtureFiles(), 'Input/${added.requestId}.md': raw}),
      );
      expect(waiting.pendingPersonAdds.single.name, '鈴木さん');
      expect(
        waiting.intake.firstWhere((i) => i.id == added.requestId).title,
        '人の登録依頼: 鈴木さん',
      );
      Future<HubRepository> accept(String requestId, String fixturePath) async {
        final out = File('${access.directory.path}/snapshot.json');
        final result = await Process.run('node', [
          'scripts/check_person_protocol.mjs',
          access.request(location, requestId).path,
          fixturePath,
          out.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        await File(fixturePath).writeAsString(await out.readAsString());
        return HubRepository(
          fixture(
            Map<String, String>.from(
              jsonDecode(await out.readAsString()) as Map,
            ),
          ),
        );
      }

      final state = '${access.directory.path}/vault.json';
      await File(state).writeAsString(jsonEncode(fixtureFiles()));
      var synced = await accept(added.requestId, state);
      expect(synced.warnings, isEmpty);
      final person = synced.people[personId]!;
      expect(person.aliases, ['鈴木']);
      expect(person.page, isNotNull);
      expect(synced.pendingPersonAdds, isEmpty);
      expect(
        synced.intake.firstWhere((i) => i.id == added.requestId).detail,
        '人の登録をMiniが反映しました。',
      );
      final edited = await service.savePersonDefinition(
        editOp,
        personId: personId,
        action: 'edit',
        expectedHash: person.definitionHash,
        draft: PersonDraft(name: '鈴木さん', aliases: ['鈴木', 'Suzuki']),
      );
      synced = await accept(edited.requestId, state);
      expect(synced.people[personId]!.aliases, ['鈴木', 'Suzuki']);
      expect(synced.personRequestIdFor(personId), isNull);
      final removed = await service.savePersonDefinition(
        removeOp,
        personId: personId,
        action: 'remove',
        expectedHash: synced.people[personId]!.definitionHash,
      );
      synced = await accept(removed.requestId, state);
      expect(synced.people, isEmpty);
      expect(
        synced.intake.firstWhere((i) => i.id == removed.requestId).detail,
        '人を外す操作をMiniが反映しました。',
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  testWidgets('メニューの「人」から登録を依頼し、一覧から人ごとの画面を開ける', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    final access = MemoryUIAccess();
    await access.init();
    access.current = VaultSnapshot({...fixture().files, ...personFiles()});
    final c = HubController(access, sampleLoader: () async => fixture().files);
    addTearDown(() async {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ContextHubApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('サンプルで試す'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-people')));
    await tester.pumpAndSettle();
    expect(find.textContaining('最後に出てきた日: 2026-11-15'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person-add')));
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key('person-submit'));
    await tester.enterText(find.byKey(const Key('person-name')), '田中');
    await tester.pumpAndSettle();
    // 登録済みの人と重なる名前は送れない。
    expect(find.textContaining('と重なります'), findsOneWidget);
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('person-name')), '佐藤さん');
    await tester.enterText(find.byKey(const Key('person-aliases')), '佐藤\nSato');
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('「佐藤さん」の登録を依頼しました'), findsOneWidget);
    final meta = parseMarkdown(access.requests.values.single).meta;
    expect(meta['operation'], 'person-definition');
    expect(meta['action'], 'add');
    expect(meta['aliases'], ['佐藤', 'Sato']);
    // 同期されると、登録依頼中として一覧に出る。
    access.current = VaultSnapshot({
      ...fixture().files,
      ...personFiles(),
      'Input/${meta['request_id']}.md': access.requests.values.single,
    });
    await c.reload();
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('pending-person-${meta['person_id']}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('person-tanaka')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('person-body')), findsOneWidget);
    expect(find.textContaining('田中さんから電話'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person-edit')));
    await tester.pumpAndSettle();
    // 変更がないうちは依頼できない。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('person-submit')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('person-aliases')),
      '田中\nTanaka',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('person-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('名前と呼び名の変更を依頼しました'), findsOneWidget);
    final edit = access.requests.values
        .map((r) => parseMarkdown(r).meta)
        .firstWhere((m) => m['action'] == 'edit');
    expect(
      edit['person_hash'],
      digest(personFiles()[personDefinitionPath('tanaka')]!),
    );
    expect(tester.takeException(), isNull);
  });
}
