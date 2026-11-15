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
    this.meta,
  });
  final String operationId;
  final String text;
  final String kind;
  final String? project;

  /// 入力に付ける補足（選んで深掘りの目的・問数など）。作業記録の下書きの入力とは同時に使わない。
  final Map<String, String>? meta;

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

  /// 保存を確かめた（saved）journalの名前。journalはこのアプリだけが書き、書くときはここから
  /// 外すので、一度検証したものは再読込のたびに読み直さない（journalは消さずに残るため、
  /// 読み直すと保存の数だけネイティブ呼び出しが増える）。アプリを起動し直すと1回ずつ検証する。
  static final _savedJournals = Expando<Set<String>>();
  Set<String> get _saved => _savedJournals[access] ??= <String>{};
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

  /// 書き終える前に止まったjournal（空・NULと空白だけ）。以前のAndroidは最終名へ直接書いており、
  /// 作成とfsyncの間で止まるとこの形で残った。Inputへの書込はjournalのfsyncが終わってから行うため、
  /// この操作は何も送っていない。新規保存を止めず、同じ操作IDで書き直せる。
  static bool _incomplete(String raw) =>
      raw.replaceAll(RegExp(r'[\s\u0000]'), '').isEmpty;

  Future<Map<String, dynamic>> _journal(String name) async =>
      await _readJournal(name) ??
      (throw StateError(
        '保存確認情報（${_requestOf(name)}）が書き終わっていません。この操作は保存されていません。',
      ));

  static String _requestOf(String name) =>
      'REQ-${name.replaceFirst(RegExp(r'\.json$'), '').replaceAll('-', '')}';

  /// journalを読む。書き終える前に止まったもの（[_incomplete]）はnull。壊れていればStateError。
  Future<Map<String, dynamic>?> _readJournal(String name) async {
    final valid =
        _uuid.hasMatch(name.replaceFirst(RegExp(r'\.json$'), '')) &&
        name.endsWith('.json');
    try {
      if (!valid) throw const FormatException();
      final raw = await access.readState(name);
      if (raw == null || raw.length > 8192) {
        throw const FormatException();
      }
      if (_incomplete(raw)) return null;
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
      if (j['state'] == 'saved') _saved.add(name);
      return j;
    } catch (_) {
      // どの操作の記録かを示し、Vaultの受付状況で同じREQ IDを確かめられるようにする。
      throw StateError(
        '保存確認情報${valid ? '（${_requestOf(name)}）' : ''}が壊れています。新規保存を停止しました。アプリ専用領域のバックアップを保持して復旧してください。',
      );
    }
  }

  /// 操作journalとして扱わない状態ファイル。
  static const nonJournalStates = {
    'settings.json',
    'drafts.json',
    'guided.json',
    'basket.json',
    'templates.json',
  };
  Future<List<String>> _journalNames() async => [
    for (final name in await access.listJournals())
      if (!nonJournalStates.contains(name)) name,
  ];

  Future<void> _checkJournals() async {
    for (final name in await _journalNames()) {
      if (_saved.contains(name)) continue;
      await _readJournal(name);
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
    _saved.remove('${j['operationId']}.json');
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
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(draft.gitDraftHash!)) ||
        (draft.meta != null && !_validMeta(draft.meta!, draft.gitDraftId))) {
      throw const FormatException('本文は1〜8000文字、種別とprojectは有効な値を指定してください。');
    }
    // 本体の入力形式と同じく、キーの順を固定して記録とfingerprintを決める。
    final meta = draft.meta == null
        ? null
        : {
            for (final k in draft.meta!.keys.toList()..sort())
              k: draft.meta![k]!,
          };
    return _saveRequest(
      draft.operationId,
      digest(
        jsonEncode([
          draft.text,
          draft.kind,
          draft.project,
          if (draft.gitDraftId != null) draft.gitDraftId,
          if (draft.gitDraftHash != null) draft.gitDraftHash,
          if (meta != null)
            [
              for (final e in meta.entries) [e.key, e.value],
            ],
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
          }
        else
          'meta': ?meta,
      },
      draft.text,
    );
  });

  /// metaは本体の入力形式（キー100字・値2000字の文字列）に収め、本体が意味を持つ下書きのキーは使わない。
  static bool _validMeta(Map<String, String> meta, String? gitDraftId) =>
      gitDraftId == null &&
      meta.isNotEmpty &&
      meta.length <= 20 &&
      meta.entries.every(
        (e) =>
            RegExp(r'^[a-z][a-z0-9_]{0,99}$').hasMatch(e.key) &&
            !e.key.startsWith('git_draft') &&
            e.value.isNotEmpty &&
            e.value.length <= 2000,
      );

  /// 原文を残したまま、訂正チェーンの最新の入力（targetId）を訂正する依頼。本文は訂正後の全文。
  Future<CaptureResult> saveCorrection(
    String operationId,
    String targetId,
    String text,
  ) => _serial(() async {
    if (!_uuid.hasMatch(operationId) ||
        !inputIdPattern.hasMatch(targetId) ||
        text.trim().isEmpty ||
        text.length > 8000 ||
        utf8.encode(text).length > 32000) {
      throw const FormatException('訂正文は1〜8000文字で入力してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'correct',
      'target_id': targetId,
    };
    return _saveRequest(
      operationId,
      digest(jsonEncode(['correct', targetId, text])),
      fields,
      text,
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

  /// プロジェクトの統合（[unmerge]なら取り消し）の依頼。確認した統合元と統合先の定義hashに結び付ける。
  Future<CaptureResult> saveProjectMerge(
    String operationId,
    HubProject from,
    HubProject into, {
    bool unmerge = false,
  }) => _serial(() async {
    final fromHash = from.definitionHash, intoHash = into.definitionHash;
    final sha = RegExp(r'^[a-f0-9]{64}$');
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(from.id) ||
        !projectIdPattern.hasMatch(into.id) ||
        from.id == into.id ||
        fromHash == null ||
        intoHash == null ||
        !sha.hasMatch(fromHash) ||
        !sha.hasMatch(intoHash) ||
        (unmerge
            ? from.mergedInto != into.id
            : from.mergedInto != null || into.mergedInto != null)) {
      throw const FormatException('統合元と統合先のプロジェクトを確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': unmerge ? 'project-unmerge' : 'project-merge',
      'project_id': from.id,
      'project_hash': fromHash,
      'into_id': into.id,
      'into_hash': intoHash,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });

  /// 新しいプロジェクトの作成依頼。本文は任意の最初のメモで、作ったプロジェクトの入力になる。
  Future<CaptureResult> saveProjectCreate(NewProjectRequest request) =>
      _serial(() async {
        final problem = request.formatError;
        if (!_uuid.hasMatch(request.operationId) || problem != null) {
          throw FormatException(problem ?? '操作IDが不正です。');
        }
        final fields = request.fields;
        return _saveRequest(
          request.operationId,
          digest(jsonEncode([fields, request.firstMemo])),
          fields,
          request.firstMemo,
        );
      });

  /// 手で書き換えて止まったNOWを、確認したNOW.mdのhashに結び付けて生成版へ戻す依頼。
  Future<CaptureResult> saveConflictResolve(
    String operationId,
    HubProject project,
  ) => _serial(() async {
    final conflict = project.nowConflict;
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(project.id) ||
        conflict == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(conflict.nowHash)) {
      throw const FormatException('戻す対象のNOWを確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'conflict-resolve',
      'target': nowTargetPath(project.id),
      'target_hash': conflict.nowHash,
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

  /// NOWの項目を完了・解決（resolve）、誤りとして外す（exclude）、または未解決へ戻す（reopen）報告。
  /// 誤りとして外すときは理由（[exclusionReasons]）が要り、一言は任意。
  Future<CaptureResult> saveItemResolution(
    String operationId,
    String projectId,
    NowItemRef item,
    String action, {
    String? reason,
    String? note,
  }) => _serial(() async {
    final exclude = action == 'exclude';
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(projectId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(item.key) ||
        !['resolve', 'reopen', 'exclude'].contains(action) ||
        (action != 'reopen') == item.resolved ||
        (exclude
            ? !exclusionReasons.contains(reason) ||
                  (note != null && !validExclusionNote(note))
            : reason != null || note != null)) {
      throw const FormatException('項目と操作を確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'item-resolution',
      'project_id': projectId,
      'item_key': item.key,
      'action': action,
      'reason': ?reason,
      'note': ?note,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });

  /// 似ているアイデアの組を束ねる（link）か、別の話とする（separate）依頼。
  /// 本体が索引を作ったときのIDEAファイルのhashに結び付け、束ねるときは本体が一致を確かめる。
  Future<CaptureResult> saveIdeaLink(
    String operationId,
    String ideaA,
    String hashA,
    String ideaB,
    String hashB,
    String action,
  ) => _serial(() async {
    final hash = RegExp(r'^[a-f0-9]{64}$');
    if (!_uuid.hasMatch(operationId) ||
        !ideaIdPattern.hasMatch(ideaA) ||
        !ideaIdPattern.hasMatch(ideaB) ||
        ideaA == ideaB ||
        !hash.hasMatch(hashA) ||
        !hash.hasMatch(hashB) ||
        !ideaLinkActions.contains(action)) {
      throw const FormatException('アイデアと操作を確認してください。');
    }
    final first = ideaA.compareTo(ideaB) < 0;
    final fields = <String, dynamic>{
      'operation': 'idea-link',
      'idea_ids': first ? [ideaA, ideaB] : [ideaB, ideaA],
      'idea_hashes': first ? [hashA, hashB] : [hashB, hashA],
      'action': action,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });

  /// NOWの項目に期日・次に見直す日を付ける依頼。変更後の全体を送り、両方nullで外す。
  Future<CaptureResult> saveItemSchedule(
    String operationId,
    String projectId,
    NowItemRef item,
    String? due,
    String? reviewAfter,
  ) => _serial(() async {
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(projectId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(item.key) ||
        item.resolved ||
        (due != null && !validScheduleDate(due)) ||
        (reviewAfter != null && !validScheduleDate(reviewAfter)) ||
        (due == item.due && reviewAfter == item.reviewAfter)) {
      throw const FormatException('項目と日付を確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'item-schedule',
      'project_id': projectId,
      'item_key': item.key,
      'due': due,
      'review_after': reviewAfter,
      'confirmed': true,
    };
    return _saveRequest(operationId, digest(jsonEncode(fields)), fields, '');
  });

  /// 「片付いたかも」が違うとき、そのメモからの候補を見送る依頼。項目は未解決のまま。
  Future<CaptureResult> saveHintDismiss(
    String operationId,
    String projectId,
    NowItemRef item,
    String inputId,
  ) => _serial(() async {
    if (!_uuid.hasMatch(operationId) ||
        !projectIdPattern.hasMatch(projectId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(item.key) ||
        !inputIdPattern.hasMatch(inputId) ||
        item.resolved ||
        !item.hints.any((h) => h.inputId == inputId)) {
      throw const FormatException('項目と候補を確認してください。');
    }
    final fields = <String, dynamic>{
      'operation': 'item-hint-dismiss',
      'project_id': projectId,
      'item_key': item.key,
      'input_id': inputId,
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
    // 書き終える前に止まったjournalは、同じ操作IDで書き直す（何も送っていないため）。
    var incomplete = false;
    if (await access.readState(name) != null) {
      final old = await _readJournal(name);
      if (old != null) {
        if (old['fingerprint'] != fingerprint) {
          throw StateError('この操作IDの内容は変更できません。まず保存状況を確認してください。');
        }
        return _confirm(old);
      }
      incomplete = true;
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
    _saved.remove(name);
    await access.writeState(name, jsonEncode(j), exclusive: !incomplete);
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
    final j = await _readJournal('$operationId.json');
    if (j == null || j['rootHash'] != digest(location.identity)) return null;
    return j['state'] as String;
  });
  Future<List<CaptureResult>> pending() => _serial(() async {
    final results = <CaptureResult>[];
    for (final name in await _journalNames()) {
      if (_saved.contains(name)) continue;
      final j = await _readJournal(name);
      if (j == null) continue;
      if (j['rootHash'] == digest(location.identity) && j['state'] != 'saved') {
        results.add(
          CaptureResult(j['operationId'], j['requestId'], 'uncertain'),
        );
      }
    }
    return results;
  });
}
