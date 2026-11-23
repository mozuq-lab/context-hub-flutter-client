import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/core/attachments.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/parser.dart';
import 'package:context_hub_client/core/repository.dart';
import 'package:context_hub_client/storage/capture_service.dart';
import 'package:context_hub_client/storage/draft_store.dart';
import 'package:context_hub_client/storage/vault_access.dart';
import 'package:context_hub_client/ui/app.dart';
import 'package:context_hub_client/ui/reference_shelf.dart';
import 'package:context_hub_client/ui/views.dart' show RecordView;

import 'capture_test.dart' show TempAccess, location;
import 'draft_test.dart' show closeForm, openForm, openSample;
import 'widget_test.dart' show MemoryUIAccess;
import 'work_records_test.dart' show protocol, projectId;
import 'fixtures.dart';

/// 選んだファイルを`Input/files/<受付ID>`へ写す端末（実フォルダー）。
class FileAccess extends TempAccess {
  final picked = <String, List<int>>{};
  @override
  bool get attachmentsSupported => true;
  @override
  Future<StagedAttachment> stageAttachment(
    VaultLocation l,
    String requestId,
    PickedAttachment file, {
    required int maxBytes,
  }) async {
    final data = picked[file.token]!;
    if (data.length > maxBytes) throw StateError('上限を超えています');
    final target = File('${directory.path}/${l.handle}/Input/files/$requestId');
    await target.parent.create(recursive: true);
    await target.writeAsBytes(data, flush: true);
    return StagedAttachment(data.length, sha256.convert(data).toString());
  }
}

/// ファイルを選べる・開ける端末（画面の検査用、メモリ上）。
class AttachUIAccess extends MemoryUIAccess {
  AttachUIAccess({this.supported = true});
  final bool supported;
  final data = List<int>.filled(1500, 65);
  final staged = <String, List<int>>{}, opened = <String>[];
  bool failOpen = false, failStage = false;
  @override
  bool get attachmentsSupported => supported;
  @override
  Future<PickedAttachment?> pickAttachment() async =>
      PickedAttachment('t1', '見積書.pdf', data.length);
  @override
  Future<StagedAttachment> stageAttachment(
    VaultLocation l,
    String requestId,
    PickedAttachment file, {
    required int maxBytes,
  }) async {
    if (failStage) {
      throw StateError(attachmentFailureMessages['attachment_unreadable']!);
    }
    staged[requestId] = data;
    return StagedAttachment(data.length, sha256.convert(data).toString());
  }

  @override
  Future<void> openVaultFile(VaultLocation l, String path) async {
    if (failOpen) throw StateError(attachmentFailureMessages['file_missing']!);
    opened.add(path);
  }
}

/// JSONの文字列を、ASCIIだけで書く（単独のサロゲートもそのまま渡せる）。
String asciiJson(Object? value) => jsonEncode(value).replaceAllMapped(
  RegExp(r'[^\x20-\x7e]'),
  (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
);

/// 対応表からファイルの添付を外す（対応前の本体）。
Map<String, String> withoutAttachments(Map<String, String> files) {
  final features = jsonDecode(files[intakeFeaturesPath]!) as Map;
  features['capture_fields'] = [
    for (final f in features['capture_fields'] as List)
      if (f != 'attachment') f,
  ];
  features.remove('attachments');
  return {...files, intakeFeaturesPath: jsonEncode(features)};
}

/// 実際のVault（架空サンプルでない保存先）を開いた画面。
Future<HubController> openVault(
  WidgetTester tester,
  MemoryUIAccess access,
  Map<String, String> files,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  await access.init();
  access.current = fixture(files);
  final c = HubController(access, sampleLoader: () async => files);
  addTearDown(() {
    c.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(ContextHubApp(controller: c));
  await tester.pumpAndSettle();
  await c.activate(const VaultLocation('vault', 'テスト'));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  test('ファイル名の整え方と、受け付ける名前は本体と同じ', () async {
    final names = [
      '/tmp/見積書 (A社).pdf',
      'C:\u005cUsers\u005c報告.docx',
      'a:b*c?"d"<e>|f.png',
      '.hidden',
      '...',
      '名前. ',
      '  spaced  .pdf',
      'x.sync-conflict-20261123.pdf',
      '改\u000a行\u202Eです.txt',
      'a\u200Bb\u2060c.pdf',
      '\uFEFFbom.txt',
      'a\u2028b.txt',
      '',
      '${'資料' * 80}.pdf',
      '${'😀' * 60}.jpeg',
      'a.verylongextension12345',
      'x.tar.gz',
      '名前.PDF',
      '\uD800壊れ.txt',
      'ｶﾀｶﾅ.pdf',
      'e\u0301.txt',
      'a/b.pdf',
      '.x',
      'x.',
      ' x',
      'a\u0000b',
      'x.sync-conflict-1.pdf',
    ];
    final dir = await Directory.systemTemp.createTemp('ctx-attach-names-');
    try {
      final input = File('${dir.path}/names.json'),
          out = File('${dir.path}/out.json'),
          script = File('${dir.path}/check.mjs');
      await input.writeAsString(asciiJson(names));
      final core = Uri.file(
        '${Directory.current.path}/vendor/context-hub/packages/core/dist/attachments.js',
      );
      await script.writeAsString(
        "import {readFileSync,writeFileSync} from 'node:fs';\n"
        "import {sanitizeFileName,fileNameSchema} from '$core';\n"
        "const names=JSON.parse(readFileSync(process.argv[2],'utf8'));\n"
        "import {attachmentMessage} from '$core';\n"
        'const limits=[1,500,1023,1024,1500,1048575,1048576,1572864,26214400,26214401,209715200];\n'
        'writeFileSync(process.argv[3],JSON.stringify({names:names.map(n=>[sanitizeFileName(n),fileNameSchema.safeParse(n).success]),limits:limits.map(b=>[b,attachmentMessage({cause:"too-large",max_bytes:b})])}));\n',
      );
      final run = await Process.run('node', [
        script.path,
        input.path,
        out.path,
      ]);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final parsed = jsonDecode(await out.readAsString()) as Map,
          expected = parsed['names'] as List;
      for (var i = 0; i < names.length; i++) {
        final name = names[i], reason = asciiJson(name);
        expect(sanitizeFileName(name), expected[i][0], reason: reason);
        expect(validFileName(name), expected[i][1], reason: reason);
        // 整えた名前は本体が必ず受け付ける。
        expect(validFileName(sanitizeFileName(name)), isTrue, reason: reason);
        expect(
          utf8.encode(sanitizeFileName(name)).length,
          lessThanOrEqualTo(fileNameMaxBytes),
        );
      }
      // 上限の表示は、本体が断るときの文と同じにする。
      for (final pair in (parsed['limits'] as List).cast<List>()) {
        final bytes = pair[0] as int, message = pair[1] as String;
        expect(
          message,
          contains('上限${fileLimitLabel(bytes)}）'),
          reason: '$bytes',
        );
      }
      // Macの分解した形（NFD）の名前は、合成済みの形にそろえる。
      expect(sanitizeFileName('e\u0301.txt'), 'é.txt');
      expect(fileSizeLabel(10), '1KB');
      expect(fileSizeLabel(1536), '2KB');
      expect(fileSizeLabel(25 * 1024 * 1024), '25.0MB');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('開くとプログラムとして動く種類のファイルは、名前で見分ける', () {
    for (final name in [
      'run.command',
      'x.APK',
      'a.sh',
      'リンク.webloc',
      'setup.exe',
    ]) {
      expect(launchableFileName(name), isTrue, reason: name);
    }
    for (final name in [
      '見積書.pdf',
      '画面.PNG',
      'command',
      'notes.txt',
      'x.docx',
    ]) {
      expect(launchableFileName(name), isFalse, reason: name);
    }
  });

  test('本体の対応表からファイルの上限を読み、なければ添えない', () {
    final files = fixtureFiles();
    final features = HubRepository(fixture(files)).intakeFeatures;
    expect(features.attachments, isTrue);
    expect(features.attachmentLimits, (
      maxBytes: 25 * 1024 * 1024,
      nameMaxBytes: 200,
    ));
    final old = HubRepository(fixture(withoutAttachments(files)));
    expect(old.intakeFeatures.attachments, isFalse);
    // 資料棚に対応していない本体には、ファイルも添えない。
    final raw = jsonDecode(files[intakeFeaturesPath]!) as Map;
    raw.remove('references');
    final noShelf = HubRepository(
      fixture({...files, intakeFeaturesPath: jsonEncode(raw)}),
    );
    expect(noShelf.intakeFeatures.attachments, isFalse);
    // 壊れた添付の記録は読まない。
    expect(
      HubFile.fromJson({'path': '05_files/x', 'name': 'x', 'bytes': 1}),
      isNull,
    );
    expect(
      HubFile.fromJson({
        'path': '05_files/2026-11/${'a' * 24}/b.pdf',
        'name': 'a.pdf',
        'bytes': 1,
      }),
      isNull,
    );
  });

  test('Dartがファイルを添えた依頼を本体が受理し、資料棚と記録からファイルを読める', () async {
    final access = FileAccess();
    await access.init();
    try {
      final data = utf8.encode('%PDF-1.4 架空の見積書');
      access.picked['t1'] = data;
      final service = CaptureService(access, location);
      final file = PickedAttachment('t1', '見積書 (A社).pdf', data.length);
      CaptureDraft draft({
        String kind = 'memo',
        bool reference = true,
        PickedAttachment? attachment,
        int max = 1024,
      }) => CaptureDraft(
        operationId: 'b1111111-2222-4333-8444-555555555555',
        text: 'A社の見積書',
        kind: kind,
        project: projectId,
        reference: reference,
        attachment: attachment ?? file,
        attachmentMaxBytes: max,
      );
      // ファイルは資料として保存するメモにだけ添え、名前・大きさを確かめてから送る。
      for (final bad in [
        draft(kind: 'action'),
        draft(reference: false),
        draft(attachment: PickedAttachment('t1', 'a/b.pdf', data.length)),
        draft(attachment: PickedAttachment('t1', '空.pdf', 0)),
        draft(max: data.length - 1),
        draft(max: 0),
      ]) {
        await expectLater(service.save(bad), throwsFormatException);
      }
      expect(access.writes, 0);

      final saved = await service.save(draft());
      expect(saved.saved, isTrue);
      final raw = (await access.readRequest(location, saved.requestId))!;
      final meta = parseMarkdown(raw).meta;
      expect(meta['attachment'], {
        'name': '見積書 (A社).pdf',
        'bytes': data.length,
        'sha256': sha256.convert(data).toString(),
      });
      expect(meta['reference'], isTrue);
      expect(
        await File(
          '${access.directory.path}/${location.handle}/Input/files/${saved.requestId}',
        ).readAsBytes(),
        data,
      );
      // 同じ操作の再実行では、写し直しも依頼の書き直しもしない。
      expect((await service.save(draft())).requestId, saved.requestId);
      expect(access.writes, 1);
      // 依頼の一覧では、ファイル名を添えて示す。
      final captured = HubRepository(
        fixture({...fixtureFiles(), 'Input/${saved.requestId}.md': raw}),
      );
      expect(
        captured.intake.firstWhere((i) => i.id == saved.requestId).title,
        endsWith('（ファイル: 見積書 (A社).pdf）'),
      );

      final files = await protocol(
        access,
        saved.requestId,
        'assets/sample.json',
        'attachment',
      );
      final repo = HubRepository(fixture(files));
      expect(repo.warnings, isEmpty);
      final entry = repo
          .referencesFor(projectId)
          .singleWhere((e) => e.file != null);
      expect(
        (entry.file!.name, entry.file!.bytes, entry.file!.label),
        ('見積書 (A社).pdf', data.length, '見積書 (A社).pdf（1KB）'),
      );
      expect(entry.file!.path, matches(attachmentPathPattern));
      final record = repo.inputRecord(entry.inputId)!;
      expect(
        (record.attachment?.path, record.body.trim()),
        (entry.file!.path, 'A社の見積書'),
      );
    } finally {
      await access.directory.delete(recursive: true);
    }
  });

  group('画面', () {
    late Map<String, String> attachedFiles;
    late String attachedInput;
    setUpAll(() async {
      final access = FileAccess();
      await access.init();
      try {
        final data = utf8.encode('%PDF-1.4 架空の見積書');
        access.picked['t1'] = data;
        final saved = await CaptureService(access, location).save(
          CaptureDraft(
            operationId: 'c1111111-2222-4333-8444-555555555555',
            text: 'A社の見積書',
            project: projectId,
            reference: true,
            attachment: PickedAttachment('t1', '見積書 (A社).pdf', data.length),
            attachmentMaxBytes: 1024,
          ),
        );
        attachedFiles = await protocol(
          access,
          saved.requestId,
          'assets/sample.json',
          'attachment-ui',
        );
        attachedInput = HubRepository(fixture(attachedFiles))
            .referencesFor(projectId)
            .singleWhere((e) => e.file != null)
            .inputId;
      } finally {
        await access.directory.delete(recursive: true);
      }
    });

    testWidgets('ファイルを選ぶと資料として保存するメモにし、空の本文はファイル名にして依頼に添える', (tester) async {
      final access = AttachUIAccess();
      await openVault(tester, access, fixtureFiles());
      await openForm(tester);
      await tester.ensureVisible(find.byKey(const Key('capture-attach')));
      await tester.tap(find.byKey(const Key('capture-attach')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('capture-attachment')), findsOneWidget);
      expect(find.text('見積書.pdf（1KB）'), findsOneWidget);
      expect(find.byKey(const Key('capture-attachment-note')), findsOneWidget);
      // ファイルを添えたメモは、資料として保存する（外せない）。
      final box = tester.widget<CheckboxListTile>(
        find.byKey(const Key('capture-reference')),
      );
      expect((box.value, box.onChanged), (true, null));
      await tester.ensureVisible(find.byKey(const Key('save-memo')));
      await tester.tap(find.byKey(const Key('save-memo')));
      await tester.pumpAndSettle();
      final packet = parseMarkdown(access.requests.values.single);
      expect(packet.meta['attachment'], {
        'name': '見積書.pdf',
        'bytes': 1500,
        'sha256': sha256.convert(access.data).toString(),
      });
      expect(packet.meta['reference'], isTrue);
      expect(packet.body.trim(), '見積書.pdf');
      expect(access.staged.keys.single, packet.meta['request_id']);
    });

    testWidgets('書きかけを戻したときは、ファイルを選び直すよう示す', (tester) async {
      final access = AttachUIAccess();
      await openVault(tester, access, fixtureFiles());
      await openForm(tester);
      await tester.enterText(find.byKey(const Key('memo-text')), 'A社の見積書');
      await tester.ensureVisible(find.byKey(const Key('capture-attach')));
      await tester.tap(find.byKey(const Key('capture-attach')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      // 書きかけにはファイルの名前だけを残す（ファイルはアプリを閉じると選び直しになる）。
      expect(access.states[DraftStore.fileName], contains('"an":"見積書.pdf"'));
      await closeForm(tester);
      await openForm(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('capture-attachment')), findsNothing);
      expect(find.byKey(const Key('capture-attachment-lost')), findsOneWidget);
      expect(find.textContaining('（見積書.pdf）は戻せません'), findsOneWidget);
    });

    testWidgets('架空サンプルでは、ファイルを添える操作を出さない', (tester) async {
      await openSample(tester, AttachUIAccess());
      await openForm(tester);
      expect(find.byKey(const Key('capture-reference')), findsOneWidget);
      expect(find.byKey(const Key('capture-attach')), findsNothing);
    });

    testWidgets('対応前の本体では、ファイルを添える操作を出さない', (tester) async {
      await openVault(
        tester,
        AttachUIAccess(),
        withoutAttachments(fixtureFiles()),
      );
      await openForm(tester);
      expect(find.byKey(const Key('capture-reference')), findsOneWidget);
      expect(find.byKey(const Key('capture-attach')), findsNothing);
    });

    testWidgets('ファイルを扱えない端末では、ファイルを添える操作を出さない', (tester) async {
      await openVault(tester, AttachUIAccess(supported: false), fixtureFiles());
      await openForm(tester);
      expect(find.byKey(const Key('capture-reference')), findsOneWidget);
      expect(find.byKey(const Key('capture-attach')), findsNothing);
    });

    testWidgets('資料棚と記録の画面から、添えたファイルを開く', (tester) async {
      final access = AttachUIAccess();
      final c = await openVault(tester, access, attachedFiles);
      final file = c.repository!.referenceEntryOf(attachedInput)!.file!;
      await tester.pumpWidget(
        MaterialApp(
          home: ReferenceShelfPage(
            controller: c,
            projectId: projectId,
            title: c.repository!.projects[projectId]!.title,
            onRecord: (context, record) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final link = find.byKey(Key('reference-file-$attachedInput'));
      expect(link, findsOneWidget);
      expect(find.textContaining('見積書 (A社).pdf（1KB）'), findsOneWidget);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(access.opened, [file.path]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecordView(
              controller: c,
              record: c.repository!.inputRecord(attachedInput)!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('record-attachment')), findsOneWidget);
      expect(find.textContaining('添えたファイル: 見積書 (A社).pdf'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('record-attachment-open')),
      );
      await tester.tap(find.byKey(const Key('record-attachment-open')));
      await tester.pumpAndSettle();
      expect(access.opened, [file.path, file.path]);
      // 開けないときは、端末が返した理由（まだ届いていないなど）を示す。
      access.failOpen = true;
      await tester.tap(find.byKey(const Key('record-attachment-open')));
      await tester.pump();
      expect(find.textContaining('まだこの端末に届いていません'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 10));
    });

    testWidgets('ファイルを写せなかったときは理由を示し、そのまま保存し直せる', (tester) async {
      final access = AttachUIAccess();
      await openVault(tester, access, fixtureFiles());
      await openForm(tester);
      await tester.enterText(find.byKey(const Key('memo-text')), 'A社の見積書');
      await tester.ensureVisible(find.byKey(const Key('capture-attach')));
      await tester.tap(find.byKey(const Key('capture-attach')));
      await tester.pumpAndSettle();
      access.failStage = true;
      await tester.ensureVisible(find.byKey(const Key('save-memo')));
      await tester.tap(find.byKey(const Key('save-memo')));
      await tester.pumpAndSettle();
      expect(find.textContaining('選んだファイルを読めません'), findsOneWidget);
      expect(access.requests, isEmpty);
      // 保存の記録を作る前に止まったため、フォームは閉じずに保存し直せる（確認待ちにしない）。
      access.failStage = false;
      await tester.ensureVisible(find.byKey(const Key('save-memo')));
      await tester.tap(find.byKey(const Key('save-memo')));
      await tester.pumpAndSettle();
      final packet = parseMarkdown(access.requests.values.single);
      expect((packet.meta['attachment'] as Map)['name'], '見積書.pdf');
      expect(access.staged.keys.single, packet.meta['request_id']);
    });

    testWidgets('写す途中で止まった書きかけは、ファイルを選び直すよう示す', (tester) async {
      final access = AttachUIAccess();
      final c = await openVault(tester, access, fixtureFiles());
      await c.drafts.write(
        c.draftKey()!,
        WritingDraft(
          text: 'A社の見積書',
          reference: true,
          attachmentName: '見積書.pdf',
          operationId: 'd1111111-2222-4333-8444-555555555555',
          updatedAt: DateTime.now(),
        ),
      );
      await openForm(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('capture-attachment-lost')), findsOneWidget);
      expect(find.byKey(const Key('save-memo')), findsOneWidget);
    });

    testWidgets('開くとプログラムとして動く種類のファイルは開かない', (tester) async {
      final access = AttachUIAccess();
      final c = await openVault(tester, access, attachedFiles);
      await expectLater(
        c.openVaultFile(
          HubFile(
            '05_files/2026-11/${'a' * 24}/run.command',
            'run.command',
            10,
          ),
        ),
        throwsA(isA<StateError>()),
      );
      // 開けないときは、端末が返した理由をそのまま示す。
      access.failOpen = true;
      final file = c.repository!.referenceEntryOf(attachedInput)!.file!;
      await expectLater(c.openVaultFile(file), throwsA(isA<StateError>()));
      expect(access.opened, isEmpty);
    });

    testWidgets('ファイルを扱えない端末では、資料棚にファイルの名前だけを示す', (tester) async {
      final access = AttachUIAccess(supported: false);
      final c = await openVault(tester, access, attachedFiles);
      await tester.pumpWidget(
        MaterialApp(
          home: RecordView(
            controller: c,
            record: c.repository!.inputRecord(attachedInput)!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('添えたファイル: 見積書 (A社).pdf'), findsOneWidget);
      expect(find.byKey(const Key('record-attachment-open')), findsNothing);
    });
  });
}
