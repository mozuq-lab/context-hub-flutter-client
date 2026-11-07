import 'dart:async';
import 'dart:convert';
import '../core/models.dart';
import '../core/review_candidates.dart';
import '../core/parser.dart';
import 'vault_access.dart';

class CaptureDraft {
  const CaptureDraft({
    required this.operationId,
    required this.text,
    this.kind = 'memo',
    this.project,
    this.gitDraftId,
    this.gitDraftHash,
  });
  final String operationId;
  final String text;
  final String kind;
  final String? project;

  /// 作業記録の下書きから作った入力なら、その下書きID。本体は使用済みとして扱う。
  final String? gitDraftId;

  /// 本人が確認した下書きのhash。本体は一致するときだけ下書きを使用済みにする。
  final String? gitDraftHash;
}

/// アプリで編集した名前・別名・キーワード。整えた値を持ち、上限は本体と同じにする。
class ProjectDefinitionDraft {
  ProjectDefinitionDraft({
    required String title,
    required List<String> aliases,
    required List<String> keywords,
  }) : title = _clean(title),
       aliases = normalizeTerms(aliases),
       keywords = normalizeTerms(keywords);
  final String title;
  final List<String> aliases, keywords;
  static const maxTerms = 50, maxTermChars = 100, maxTitleChars = 200;

  static String _clean(String value) =>
      value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

  /// 前後の空白を除き、空の語と大文字小文字だけが違う重複を除く（全角・半角の違いは本体がまとめる）。
  static List<String> normalizeTerms(List<String> values) {
    final seen = <String>{}, result = <String>[];
    for (final value in values) {
      final term = _clean(value);
      if (term.isEmpty || !seen.add(term.toLowerCase())) continue;
      result.add(term);
    }
    return result;
  }

  /// 上限を超えていれば利用者向けの説明。問題がなければnull。
  String? get problem {
    if (title.isEmpty || title.length > maxTitleChars) {
      return '名前は1〜$maxTitleChars文字で入力してください。';
    }
    for (final (label, list) in [('別名', aliases), ('キーワード', keywords)]) {
      if (list.length > maxTerms) return '$labelは$maxTerms件までにしてください。';
      if (list.any((t) => t.length > maxTermChars)) {
        return '$labelは1件$maxTermChars文字までにしてください。';
      }
    }
    return null;
  }

  bool sameAs(HubProject project) =>
      title == project.title &&
      listEquals(aliases, project.aliases) &&
      listEquals(keywords, project.keywords);

  static bool listEquals(List<String> a, List<String> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}

class CaptureResult {
  const CaptureResult(this.operationId, this.requestId, this.state);
  final String operationId;
  final String requestId;
  final String state;
  bool get saved => state == 'saved';
}

class _CaptureQueue {
  Future<void> tail = Future.value();
}

class CaptureService {
  CaptureService(this.access, this.location);
  final VaultAccess access;
  final VaultLocation location;
  static final _queues = Expando<_CaptureQueue>();
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  Future<T> _serial<T>(Future<T> Function() action) {
    final queue = _queues[access] ??= _CaptureQueue();
    final next = queue.tail.then((_) => action());
    queue.tail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<Map<String, dynamic>> _journal(String name) async {
    try {
      if (!_uuid.hasMatch(name.replaceFirst(RegExp(r'\.json$'), '')) ||
          !name.endsWith('.json')) {
        throw const FormatException();
      }
      final raw = await access.readState(name);
      if (raw == null || raw.length > 8192) {
        throw const FormatException();
      }
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['version'] != 1 ||
          '${j['operationId']}.json' != name ||
          !_uuid.hasMatch(j['operationId'] as String) ||
          j['requestId'] !=
              'REQ-${(j['operationId'] as String).replaceAll('-', '')}' ||
          !['saved', 'uncertain', 'prepared'].contains(j['state']) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(j['rootHash'] as String) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(j['fingerprint'] as String) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(j['rawHash'] as String) ||
          DateTime.tryParse(j['occurredAt'] as String) == null) {
        throw const FormatException();
      }
      return j;
    } catch (_) {
      throw StateError(
        '保存確認情報が壊れています。新規保存を停止しました。アプリ専用領域のバックアップを保持して復旧してください。',
      );
    }
  }

  /// 操作journalとして扱わない状態ファイル。
  static const nonJournalStates = {'settings.json', 'drafts.json'};
  Future<List<String>> _journalNames() async => [
    for (final name in await access.listJournals())
      if (!nonJournalStates.contains(name)) name,
  ];

  Future<void> _checkJournals() async {
    for (final name in await _journalNames()) {
      await _journal(name);
    }
  }

  Future<CaptureResult> _confirm(Map<String, dynamic> j) async {
    if (j['rootHash'] != digest(location.identity)) {
      throw StateError('この操作は別のVaultに属しています。元のVaultを選択してください。');
    }
    var state = 'uncertain';
    try {
      final raw = await access.readRequest(location, j['requestId'] as String);
      if (raw != null && digest(raw) == j['rawHash']) {
        state = 'saved';
      }
    } catch (_) {
      /* 不明な結果は再送しない。 */
    }
    j['state'] = state;
    try {
      await access.writeState('${j['operationId']}.json', jsonEncode(j));
    } catch (_) {
      state = 'uncertain';
    }
    return CaptureResult(j['operationId'], j['requestId'], state);
  }

  Future<CaptureResult> save(CaptureDraft draft) => _serial(() async {
    if (!_uuid.hasMatch(draft.operationId) ||
        draft.text.trim().isEmpty ||
        draft.text.length > 8000 ||
        utf8.encode(draft.text).length > 32000 ||
        !['memo', 'work-summary'].contains(draft.kind) ||
        (draft.project != null && !projectIdPattern.hasMatch(draft.project!)) ||
        (draft.gitDraftId != null &&
            !RegExp(
              r'^GDR-[0-9A-HJKMNP-TV-Z]{26}$',
            ).hasMatch(draft.gitDraftId!)) ||
        (draft.gitDraftId != null) != (draft.gitDraftHash != null) ||
        (draft.gitDraftHash != null &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(draft.gitDraftHash!))) {
      throw const FormatException('本文は1〜8000文字、種別とprojectは有効な値を指定してください。');
    }
    return _saveRequest(
      draft.operationId,
      digest(
        jsonEncode([
          draft.text,
          draft.kind,
          draft.project,
          if (draft.gitDraftId != null) draft.gitDraftId,
          if (draft.gitDraftHash != null) draft.gitDraftHash,
        ]),
      ),
      {
        'operation': 'capture',
        'kind': draft.kind,
        if (draft.project != null) 'project': draft.project,
        'tool': 'context-hub-flutter',
        if (draft.gitDraftId != null)
          'meta': {
            'git_draft': draft.gitDraftId,
            'git_draft_hash': draft.gitDraftHash,
          },
      },
      draft.text,
    );
  });
  Future<CaptureResult> saveReview(
    String operationId,
    ReviewCandidate candidate,
    String action, {
    AdoptionTarget? target,
  }) => _serial(() async {
    if (!_uuid.hasMatch(operationId) ||
        !candidate.actionable ||
        !['approve', 'reject'].contains(action) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(candidate.candidateHash)) {
      throw const FormatException('候補と操作内容を確認してください。');
    }
    final project = candidate.kind == 'project';
    if (!project && action == 'approve' && target == null) {
      throw const FormatException('採用先を選択してください。');
    }
    if (!RegExp(
          project
              ? r'^PCAN-[0-9A-HJKMNP-TV-Z]{26}$'
              : r'^CAN-[0-9A-HJKMNP-TV-Z]{26}$',
        ).hasMatch(candidate.id) ||
        (!project &&
            ![
              'knowledge',
              'decision',
              'preference',
            ].contains(candidate.kind)) ||
        (project &&
            (candidate.confirmationToken == null ||
                !RegExp(
                  r'^[a-f0-9]{64}$',
                ).hasMatch(candidate.confirmationToken!)))) {
      throw const FormatException('候補のID・種別・確認情報が不正です。');
    }
    final fields = <String, dynamic>{
      'operation': '${project ? 'project' : 'knowledge'}-$action',
      'candidate_id': candidate.id,
      'candidate_hash': candidate.candidateHash,
      'confirmed': true,
      if (project) 'confirmation_token': candidate.confirmationToken,
      if (!project && action == 'approve') ...target!.fields,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });
  Future<CaptureResult> saveRetirement(
    String operationId,
    ReviewCandidate candidate,
  ) => _serial(() async {
    final targetHash = candidate.dependencies[candidate.targetPath];
    if (!_uuid.hasMatch(operationId) ||
        !candidate.retirable ||
        !RegExp(r'^CAN-[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(candidate.id) ||
        targetHash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(targetHash)) {
      throw const FormatException('適用停止の対象を再確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'knowledge-retire',
      'target_id': 'KNW-${candidate.id.substring(4)}',
      'target_hash': targetHash,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });
  Future<CaptureResult> saveProjectStatus(
    String operationId,
    HubProject project,
    String status,
  ) => _serial(() async {
    final hash = project.definitionHash;
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(project.id) ||
        hash == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !projectLifecycles.contains(status) ||
        status == project.lifecycle) {
      throw const FormatException('プロジェクトと新しい状態を確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'project-status',
      'project_id': project.id,
      'project_hash': hash,
      'status': status,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });

  /// 名前・別名・キーワードの変更依頼。変更後の全体を、表示中の定義hashに結び付けて送る。
  Future<CaptureResult> saveProjectDefinition(
    String operationId,
    HubProject project,
    ProjectDefinitionDraft next,
  ) => _serial(() async {
    final hash = project.definitionHash;
    final problem = next.problem;
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(project.id) ||
        hash == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        problem != null ||
        next.sameAs(project)) {
      throw FormatException(problem ?? '名前・別名・キーワードの変更を確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'project-definition',
      'project_id': project.id,
      'project_hash': hash,
      'title': next.title,
      'aliases': next.aliases,
      'keywords': next.keywords,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });

  /// NOWの項目を完了・解決（resolve）または未解決へ戻す（reopen）報告。
  Future<CaptureResult> saveItemResolution(
    String operationId,
    String projectId,
    NowItemRef item,
    String action,
  ) => _serial(() async {
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(projectId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(item.key) ||
        !['resolve', 'reopen'].contains(action) ||
        (action == 'resolve') == item.resolved) {
      throw const FormatException('項目と操作を確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'item-resolution',
      'project_id': projectId,
      'item_key': item.key,
      'action': action,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });

  /// 作業記録の下書きを見送る依頼。
  Future<CaptureResult> saveGitDraftDismiss(
    String operationId,
    GitDraft draft,
  ) => _serial(() async {
    if (!_uuid.hasMatch(operationId) ||
        !RegExp(r'^GDR-[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(draft.id) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(draft.hash)) {
      throw const FormatException('下書きを確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'git-draft-dismiss',
      'draft_id': draft.id,
      'draft_hash': draft.hash,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });
  Future<CaptureResult> _saveRequest(
    String operationId,
    String fingerprint,
    Map<String, dynamic> fields,
    String text,
  ) async {
    await _checkJournals();
    final name = '$operationId.json';
    if (await access.readState(name) != null) {
      final old = await _journal(name);
      if (old['fingerprint'] != fingerprint) {
        throw StateError('この操作IDの内容は変更できません。まず保存状況を確認してください。');
      }
      return _confirm(old);
    }
    final requestId = 'REQ-${operationId.replaceAll('-', '')}';
    final occurredAt = DateTime.now().toUtc().toIso8601String();
    final raw = encodePacket({
      'schema_version': 1,
      'request_id': requestId,
      'source': 'flutter-client/$operationId',
      'occurred_at': occurredAt,
      ...fields,
    }, text);
    final j = <String, dynamic>{
      'version': 1,
      'operationId': operationId,
      'requestId': requestId,
      'rootHash': digest(location.identity),
      'fingerprint': fingerprint,
      'rawHash': digest(raw),
      'occurredAt': occurredAt,
      'state': 'prepared',
    };
    // 排他journal公開に失敗した場合、Inputへの書込へ進まない。
    await access.writeState(name, jsonEncode(j), exclusive: true);
    try {
      await access.writeRequest(location, requestId, raw);
    } catch (_) {
      /* readbackでのみ確定する。 */
    }
    return _confirm(j);
  }

  Future<CaptureResult> confirm(String operationId) => _serial(() async {
    if (!_uuid.hasMatch(operationId)) {
      throw const FormatException('操作IDが不正です。');
    }
    return _confirm(await _journal('$operationId.json'));
  });

  /// 操作journalの状態（saved・uncertain・prepared）。journalがなければnull。別のVaultの操作は対象外。
  Future<String?> journalState(String operationId) => _serial(() async {
    if (!_uuid.hasMatch(operationId)) return null;
    if (await access.readState('$operationId.json') == null) return null;
    final j = await _journal('$operationId.json');
    if (j['rootHash'] != digest(location.identity)) return null;
    return j['state'] as String;
  });
  Future<List<CaptureResult>> pending() => _serial(() async {
    final results = <CaptureResult>[];
    for (final name in await _journalNames()) {
      final j = await _journal(name);
      if (j['rootHash'] == digest(location.identity) && j['state'] != 'saved') {
        results.add(
          CaptureResult(j['operationId'], j['requestId'], 'uncertain'),
        );
      }
    }
    return results;
  });
}
