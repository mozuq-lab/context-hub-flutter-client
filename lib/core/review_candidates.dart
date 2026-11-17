import 'dart:convert';
import 'models.dart';
import 'parser.dart';

class AdoptionTarget {
  AdoptionTarget.global()
    : scope = 'global',
      projectId = null,
      projectHash = null;
  AdoptionTarget.project(this.projectId, this.projectHash) : scope = 'project' {
    if (projectId == null ||
        !projectIdPattern.hasMatch(projectId!) ||
        projectHash == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(projectHash!)) {
      throw const FormatException('採用先が不正です。');
    }
  }
  factory AdoptionTarget.fromJson(Map<String, dynamic> value) {
    if (value['scope'] == 'global' && value.length == 1) {
      return AdoptionTarget.global();
    }
    if (value['scope'] == 'project' && value.length == 3) {
      return AdoptionTarget.project(
        value['projectId'] as String?,
        value['projectHash'] as String?,
      );
    }
    throw const FormatException('採用先が不正です。');
  }
  final String scope;
  final String? projectId, projectHash;
  Map<String, dynamic> toJson() => {
    'scope': scope,
    if (scope == 'project') 'projectId': projectId,
    if (scope == 'project') 'projectHash': projectHash,
  };
  Map<String, dynamic> get fields => {
    'scope': scope,
    if (scope == 'project') 'project_id': projectId,
    if (scope == 'project') 'project_hash': projectHash,
  };
  String get label => scope == 'global' ? '全ての作業に共通' : 'プロジェクト: $projectId';
}

/// 1回の判断でまとめられるプロジェクト案の上限（本体のPROJECT_COVERS_MAXと同じ）。
const maxProposalCovers = 20;

class ReviewCandidate {
  ReviewCandidate(
    this.data, {
    String? status,
    List<String>? warnings,
    bool? reflected,
  }) : status = status ?? data['status'] as String,
       warnings = warnings ?? List<String>.from(data['warnings'] as List),
       reflected = reflected ?? data['reflected'] as bool;
  final Map<String, dynamic> data;
  final String status;
  final List<String> warnings;
  final bool reflected;
  bool get retired => data['retired'] == true;
  bool get retirable =>
      status == 'approved' &&
      reflected &&
      !retired &&
      kind != 'project' &&
      targetPath != null &&
      dependencies[targetPath] is String;
  String? get retiredAt => data['retiredAt'] as String?;
  AdoptionTarget? get adoptedTarget => data['adoptedTarget'] is Map
      ? AdoptionTarget.fromJson(
          Map<String, dynamic>.from(data['adoptedTarget'] as Map),
        )
      : null;
  AdoptionTarget? get suggestedTarget => data['suggestedTarget'] is Map
      ? AdoptionTarget.fromJson(
          Map<String, dynamic>.from(data['suggestedTarget'] as Map),
        )
      : null;
  List<Map<String, dynamic>> get projectSuggestions =>
      (data['projectSuggestions'] as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  String get id => data['id'] as String;
  String get kind => data['kind'] as String;
  String get path => data['path'] as String;
  String get title => data['title'] as String;
  String get claim => data['claim'] as String;
  String get rationale => data['rationale'] as String;
  String get candidateHash => data['candidateHash'] as String;
  String? get confirmationToken => data['confirmationToken'] as String?;
  String? get supersedes => data['supersedes'] as String?;
  String? get targetPath => data['targetPath'] as String?;
  String? get decisionId => data['decisionId'] as String?;
  String? get generatedAt => data['generatedAt'] as String?;
  List<String> get aliases =>
      List<String>.from(data['aliases'] as List? ?? const []);
  List<String> get keywords =>
      List<String>.from(data['keywords'] as List? ?? const []);
  List<String> get inputIds => List<String>.from(data['inputIds'] as List);

  /// プロジェクト案だけ。同じ対象を指す確認待ちの案をまとめたとき、まとめられた側の案に付く代表の案のID。
  String? get duplicateOf => data['duplicateOf'] as String?;

  /// プロジェクト案だけ。代表の案に付く、まとめた案のID。判断済みの案では、同じ判断としてまとめた案のID。
  List<String> get duplicates =>
      List<String>.from(data['duplicates'] as List? ?? const []);

  /// プロジェクト案だけ。代表の案とまとめて判断された案に付く、代表の案のID。
  String? get coveredBy => data['coveredBy'] as String?;
  Map<String, dynamic> get dependencies =>
      Map<String, dynamic>.from(data['dependencies'] as Map);
  bool get actionable => status == 'pending';
  String get label => switch (kind) {
    'project' => 'プロジェクト案',
    'knowledge' => '知識',
    'decision' => '判断・方針',
    'preference' => '好み',
    _ => '要確認',
  };
}

class ReviewRepository {
  ReviewRepository(this.snapshot, Iterable<HubRecord> records) {
    final raw = snapshot.files['90_system/review/index.json'];
    if (raw == null) {
      warnings.add('確認待ち一覧が未同期です。同期後、MiniでHOMEを更新して再読込してください。');
      return;
    }
    try {
      final root = jsonDecode(raw) as Map;
      if (root['schema_version'] != 1 ||
          timestamp(root['generated_at']) == null ||
          root['items'] is! List) {
        throw const FormatException();
      }
      for (final value in root['projects'] as List? ?? []) {
        final p = Map<String, dynamic>.from(value as Map), id = p['id'];
        if (id is! String ||
            !projectIdPattern.hasMatch(id) ||
            p['title'] is! String ||
            p['path'] != '10_projects/$id/project.md' ||
            p['hash'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(p['hash']) ||
            projects.any((v) => v['id'] == id)) {
          throw const FormatException();
        }
        final raw = snapshot.files[p['path']];
        if (raw == null || digest(raw) != p['hash']) {
          throw const FormatException();
        }
        projects.add(p);
      }
      final rows = List<dynamic>.from(root['items'] as List);
      if (root.containsKey('pages')) {
        final pages = root['pages'] as List, seen = <String>{};
        if (rows.isNotEmpty || pages.length > 5000) {
          throw const FormatException();
        }
        for (final page in pages) {
          try {
            final path = page['path'] as String;
            if (!RegExp(
                  r'^90_system/review/page-\d{5}\.json$',
                ).hasMatch(path) ||
                !seen.add(path)) {
              throw const FormatException();
            }
            final value = snapshot.files[path];
            if (value == null || digest(value) != page['hash']) {
              throw const FormatException();
            }
            final parsed = jsonDecode(value) as Map;
            if (parsed['schema_version'] != 1 || parsed['items'] is! List) {
              throw const FormatException();
            }
            rows.addAll(parsed['items'] as List);
          } catch (_) {
            warnings.add('一覧の一部が未同期です。同期後に再読込してください。');
          }
        }
      }
      if (rows.length > 5000) throw const FormatException();
      // 候補ごとに読み直さないよう、未整理のメモのmetaとファイルのhashは1回だけ求める。
      // 読めないメモはnullとして残す（根拠のあるすべての候補を未同期扱いにする）。
      final inbox = <Map<String, dynamic>?>[
        for (final entry in snapshot.files.entries)
          if (entry.key.startsWith('00_inbox/') && entry.key.endsWith('.md'))
            _metaOf(entry.value),
      ];
      final hashes = <String, String?>{};
      String? hashOf(String path) => hashes.putIfAbsent(path, () {
        final actual = snapshot.files[path];
        return actual == null ? null : digest(actual);
      });
      final ids = <String>{};
      for (final row in rows) {
        try {
          final data = Map<String, dynamic>.from(row as Map);
          _validate(data);
          final c = ReviewCandidate(data);
          if (!ids.add(c.id)) {
            items.removeWhere((i) => i.id == c.id);
            warnings.add('一覧に重複した候補があります。Miniで再生成してください。');
            continue;
          }
          var valid = snapshot.recognized && snapshot.warnings.isEmpty;
          for (final entry in c.dependencies.entries) {
            if (hashOf(entry.key) != entry.value) valid = false;
          }
          // indexの生成後に到着した訂正も調べる。正本の最終判定はMiniが行う。
          final found = <String>{};
          var historyCorrection = false;
          for (final m in inbox) {
            if (m == null) {
              if (c.inputIds.isNotEmpty) valid = false;
              continue;
            }
            if (c.inputIds.contains(m['id'])) found.add(m['id'] as String);
            if (c.inputIds.contains(m['corrects_input_id']) &&
                !c.inputIds.contains(m['id'])) {
              if (c.actionable) {
                valid = false;
              } else if (['approved', 'rejected'].contains(c.status)) {
                historyCorrection = true;
              }
            }
          }
          if (!found.containsAll(c.inputIds)) valid = false;
          if (historyCorrection && !c.warnings.any((w) => w.contains('訂正'))) {
            c.warnings.add('判断後に元のメモが訂正されています。判断時点の内容を表示しています。');
          }
          items.add(
            valid
                ? c
                : ReviewCandidate(
                    data,
                    status: 'unavailable',
                    reflected: false,
                    warnings: [
                      ...c.warnings,
                      '候補・根拠・判断・反映先が未同期か変更されています。同期して再読込してください。',
                    ],
                  ),
          );
        } catch (_) {
          warnings.add('形式が不正な候補を操作対象から除外しました。Miniで一覧を再生成してください。');
        }
      }
    } catch (_) {
      warnings.add(
        _newer(raw)
            ? '確認待ち一覧を本体が新しい形式で書いています。アプリを更新してください。'
            : '確認待ち一覧を読み取れません。同期後、MiniでHOMEを更新してください。',
      );
    }
  }
  static bool _newer(String raw) {
    try {
      return newerSchema(jsonDecode(raw));
    } catch (_) {
      return false;
    }
  }

  static void _validate(Map<String, dynamic> d) {
    if (d['retired'] != null && d['retired'] is! bool) {
      throw const FormatException();
    }
    for (final key in ['suggestedTarget', 'adoptedTarget']) {
      if (d[key] != null) {
        AdoptionTarget.fromJson(Map<String, dynamic>.from(d[key] as Map));
      }
    }
    for (final value in d['projectSuggestions'] as List? ?? []) {
      final p = value as Map;
      if (p['projectId'] is! String ||
          !projectIdPattern.hasMatch(p['projectId']) ||
          p['title'] is! String ||
          !['explicit', 'inferred'].contains(p['source']) ||
          p['confidence'] != null &&
              (p['confidence'] is! num ||
                  p['confidence'] < 0 ||
                  p['confidence'] > 1)) {
        throw const FormatException();
      }
    }

    final id = d['id'] as String,
        kind = d['kind'] as String,
        status = d['status'] as String,
        path = d['path'] as String;
    if (!RegExp(r'^(?:P?CAN)-[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(id) ||
        ![
          'project',
          'knowledge',
          'decision',
          'preference',
          'unknown',
        ].contains(kind) ||
        ![
          'pending',
          'approved',
          'rejected',
          'stale',
          'unavailable',
        ].contains(status) ||
        path !=
            '90_system/${id.startsWith('PCAN-') ? 'project-candidates' : 'candidates'}/$id.md') {
      throw const FormatException();
    }
    for (final key in ['title', 'claim', 'rationale', 'candidateHash']) {
      if (d[key] is! String) throw const FormatException();
    }
    for (final key in [
      'supersedes',
      'targetPath',
      'decisionId',
      'confirmationToken',
      'generatedAt',
    ]) {
      if (d[key] != null && d[key] is! String) throw const FormatException();
    }
    for (final key in ['aliases', 'keywords']) {
      if (d[key] != null) {
        final values = List<String>.from(d[key] as List);
        if (values.length > 100 || values.any((s) => s.length > 1000)) {
          throw const FormatException();
        }
      }
    }
    if (d['supersedes'] != null &&
        !RegExp(
          r'^KNW-[0-9A-HJKMNP-TV-Z]{26}$',
        ).hasMatch(d['supersedes'] as String)) {
      throw const FormatException();
    }
    // 同じ対象を指すプロジェクト案のまとめ。代表の案（duplicates）とまとめられた案（duplicateOf）は両立しない。
    final proposal = RegExp(r'^PCAN-[0-9A-HJKMNP-TV-Z]{26}$');
    for (final key in ['duplicateOf', 'coveredBy']) {
      final other = d[key];
      if (other != null &&
          (kind != 'project' ||
              other is! String ||
              !proposal.hasMatch(other) ||
              other == id)) {
        throw const FormatException();
      }
    }
    if (d['duplicates'] != null) {
      final others = List<String>.from(d['duplicates'] as List);
      if (kind != 'project' ||
          d['duplicateOf'] != null ||
          others.isEmpty ||
          others.length > 5000 ||
          others.toSet().length != others.length ||
          others.any((o) => !proposal.hasMatch(o) || o == id)) {
        throw const FormatException();
      }
    }
    if (d['targetPath'] != null && !validPath(d['targetPath'] as String)) {
      throw const FormatException();
    }
    final inputs = List<String>.from(d['inputIds'] as List),
        warn = List<String>.from(d['warnings'] as List),
        deps = Map<String, dynamic>.from(d['dependencies'] as Map);
    if (inputs.length > 33 ||
        inputs.any((i) => !inputIdPattern.hasMatch(i)) ||
        warn.length > 100 ||
        d['reflected'] is! bool) {
      throw const FormatException();
    }
    final sha = RegExp(r'^[a-f0-9]{64}$');
    for (final e in deps.entries) {
      if (!validPath(e.key) ||
          !RegExp(
            r'^(00_inbox|10_projects|30_knowledge|90_system)/',
          ).hasMatch(e.key) ||
          (e.value != null &&
              (e.value is! String || !sha.hasMatch(e.value as String)))) {
        throw const FormatException();
      }
    }
    if (status == 'pending') {
      final project = kind == 'project',
          apr =
              '90_system/${project ? 'project-approvals/PAPR-' : 'approvals/APR-'}${id.substring(project ? 5 : 4)}.json';
      if (kind == 'unknown' ||
          (project && (d['aliases'] is! List || d['keywords'] is! List)) ||
          id.startsWith('PCAN-') != project ||
          !sha.hasMatch(d['candidateHash'] as String) ||
          deps[path] != d['candidateHash'] ||
          !deps.containsKey(apr) ||
          deps[apr] != null ||
          (project &&
              (d['confirmationToken'] is! String ||
                  !sha.hasMatch(d['confirmationToken'] as String)))) {
        throw const FormatException();
      }
    }
  }

  final List<Map<String, dynamic>> projects = [];
  void validateTarget(AdoptionTarget target) {
    if (target.scope == 'global') return;
    final p = projects.where((p) => p['id'] == target.projectId).firstOrNull;
    if (p == null ||
        p['hash'] != target.projectHash ||
        digest(snapshot.files[p['path']] ?? '') != target.projectHash) {
      throw const FormatException('採用先が変更・未同期です。');
    }
  }

  String? retirementRequestIdFor(String candidateId) {
    final c = byId(candidateId);
    if (c == null) return null;
    for (final e in snapshot.files.entries.where(
      (e) => e.key.startsWith('Input/') && e.key.endsWith('.md'),
    )) {
      try {
        final m = parseMarkdown(e.value).meta;
        if (m['operation'] == 'knowledge-retire' &&
            m['target_id'] == 'KNW-${candidateId.substring(4)}' &&
            m['target_hash'] == c.dependencies[c.targetPath] &&
            m['confirmed'] == true &&
            m['request_id'] is String &&
            requestIdPattern.hasMatch(m['request_id']) &&
            e.key == 'Input/${m['request_id']}.md') {
          return m['request_id'];
        }
      } catch (_) {}
    }
    return null;
  }

  final List<ReviewCandidate> items = [];
  final List<String> warnings = [];
  final VaultSnapshot snapshot;

  /// 候補のID → 候補。読み込んだ後は変わらないので、1回だけ作る。
  late final Map<String, ReviewCandidate> _byId = {
    for (final i in items) i.id: i,
  };

  /// 保存済みの採用・却下の依頼（Input）。snapshotは変わらないので、1回だけ読む。
  late final List<_DecisionRequest> _requests = [
    for (final e in snapshot.files.entries.where(
      (e) => e.key.startsWith('Input/') && e.key.endsWith('.md'),
    ))
      ?_DecisionRequest.read(e.key, e.value, snapshot),
  ];

  /// 候補のID → その候補そのものを対象にした依頼。
  late final Map<Object?, List<_DecisionRequest>> _own = () {
    final map = <Object?, List<_DecisionRequest>>{};
    for (final r in _requests) {
      (map[r.candidateId] ??= []).add(r);
    }
    return map;
  }();

  /// 候補のID → その候補を、代表の案とまとめて判断する依頼（cover_ids）。
  late final Map<Object?, List<_DecisionRequest>> _covering = () {
    final map = <Object?, List<_DecisionRequest>>{};
    for (final r in _requests) {
      for (final id in r.covers.keys) {
        (map[id] ??= []).add(r);
      }
    }
    return map;
  }();

  /// この候補の、いまの内容を確認して保存した依頼。候補そのものを対象にした依頼を先に、
  /// 代表の案とまとめて判断する依頼を後に返す。
  Iterable<_DecisionRequest> _requestsFor(ReviewCandidate c) => [
    ...?_own[c.id]?.where((r) => r.candidateHash == c.candidateHash),
    ...?_covering[c.id]?.where((r) => r.covers[c.id] == c.candidateHash),
  ];

  /// この候補そのものを対象にした、判断を待っている依頼。まとめて判断する依頼に含まれているだけの案は対象外。
  _DecisionRequest? _ownRequest(ReviewCandidate c) => _own[c.id]
      ?.where((r) => !r.failed && r.candidateHash == c.candidateHash)
      .firstOrNull;

  /// この候補の、判断を待っている依頼。本体が受け付けられなかった依頼は含めない。
  _DecisionRequest? _request(ReviewCandidate c) =>
      _requestsFor(c).where((r) => !r.failed).firstOrNull;

  /// この候補の採用・却下の依頼が保存済みで、判断を待っているなら、そのREQ ID。
  /// 代表の案とまとめて判断する依頼（cover_ids）に含まれている案も、依頼済みとして扱う。
  /// 本体が受け付けられなかった依頼は、依頼済みとして扱わない（もう一度判断できる）。
  String? requestIdFor(String candidateId) {
    final c = byId(candidateId);
    return c == null ? null : _request(c)?.id;
  }

  /// 本体が受け付けられなかった、この候補の採用・却下の依頼のREQ ID（ID順）。
  /// 判断を待っている依頼があるとき（依頼し直した後）は示さない。
  List<String> failedRequestIdsFor(String candidateId) {
    final c = byId(candidateId);
    if (c == null || _request(c) != null) return const [];
    return {
      for (final r in _requestsFor(c))
        if (r.failed) r.id,
    }.toList()..sort();
  }

  /// 本体が受け付けられなかった、この候補の採用・却下の依頼のREQ ID。なければnull。
  String? failedRequestIdFor(String candidateId) =>
      failedRequestIdsFor(candidateId).firstOrNull;

  List<ReviewCandidate> get pending =>
      items.where((i) => i.status == 'pending').toList();

  /// 代表の案にまとめる、同じ対象を指す確認待ちの案（本体の一覧の順）。
  ///
  /// 代表の案もまとめる案も、この端末で確認待ちとして読めているものだけをまとめる。
  /// 判断を依頼済みの案（その案だけの依頼も、ほかの案とまとめた依頼も）はまとめない。
  /// 代表の案の判断を依頼済みのときは、その依頼に含めた案だけをまとめる（含めなかった案は、1件ずつ判断を待つ）。
  /// 代表の案がほかの案の依頼に含まれているときは、残りの案を依頼済みの行に隠さないよう、まとめない。
  /// 1回の判断でまとめられる上限（[maxProposalCovers]）を超える分も、1件ずつ示す。
  List<ReviewCandidate> groupMembers(ReviewCandidate lead) =>
      identical(_byId[lead.id], lead)
      ? _groups[lead.id] ??= _groupMembers(lead)
      : _groupMembers(lead);
  final Map<String, List<ReviewCandidate>> _groups = {};
  List<ReviewCandidate> _groupMembers(ReviewCandidate lead) {
    if (lead.status != 'pending' || lead.duplicates.isEmpty) return const [];
    final request = _ownRequest(lead), members = <ReviewCandidate>[];
    if (request == null && _request(lead) != null) return const [];
    for (final id in lead.duplicates) {
      final member = byId(id);
      if (member != null &&
          member.status == 'pending' &&
          member.duplicateOf == lead.id &&
          (request == null
              ? _request(member) == null
              : _ownRequest(member) == null &&
                    request.covers[member.id] == member.candidateHash)) {
        members.add(member);
        if (members.length == maxProposalCovers) break;
      }
    }
    return List.unmodifiable(members);
  }

  /// この案をまとめている、確認待ちの代表の案。まとめられていなければnull。
  ReviewCandidate? groupLead(ReviewCandidate member) {
    final id = member.duplicateOf;
    if (id == null) return null;
    final lead = byId(id);
    return lead != null && groupMembers(lead).any((m) => m.id == member.id)
        ? lead
        : null;
  }

  /// まとめた判断を待つ理由になっている案。なければnull。
  ///
  /// 本体が同じ組にまとめた案のどれかに、採用の依頼が反映を待っているものがあれば、その案を返す。
  /// 採用でプロジェクトができると、名前の重なる残りの案は古い案になり、まとめた依頼の全体が
  /// 受け付けられなくなる。反映を待ってから、残った案をまとめて判断する（1件ずつの判断は止めない）。
  ReviewCandidate? groupBlocker(ReviewCandidate lead) {
    // 判断を依頼済みの代表の案は、もう判断しないので待つ理由がない。
    if (lead.status != 'pending' || _request(lead) != null) return null;
    for (final id in lead.duplicates) {
      final other = byId(id);
      if (other != null && _request(other)?.approves == true) return other;
    }
    return null;
  }

  /// 確認待ちの一覧に並べる候補。代表の案にまとめた案は、代表の行に含めて1件と数える。
  late final List<ReviewCandidate> pendingRows = List.unmodifiable(
    pending.where((i) => groupLead(i) == null),
  );
  List<ReviewCandidate> get attention =>
      items.where((i) => ['stale', 'unavailable'].contains(i.status)).toList();
  List<ReviewCandidate> get history =>
      items.where((i) => ['approved', 'rejected'].contains(i.status)).toList();
  ReviewCandidate? byId(String id) => _byId[id];
}

/// 保存済みの採用・却下の依頼（Input/REQ-*.md）の、候補との照合に使う部分。
class _DecisionRequest {
  _DecisionRequest(
    this.id,
    this.candidateId,
    this.candidateHash,
    this.covers, {
    required this.approves,
    required this.failed,
  });
  final String id;
  final Object? candidateId, candidateHash;

  /// 代表の案とまとめて判断する案のID → 確認した内容のhash。
  final Map<Object?, Object?> covers;

  /// 採用の依頼か（却下の依頼ならfalse）。
  final bool approves;

  /// 本体が受け付けられなかった依頼か。受け付けた記録がなく、この内容の依頼への失敗の記録がある。
  /// 本体は実行のたびに受け付け直すので、後で受け付けられれば、受け付けた記録ができて依頼済みに戻る。
  final bool failed;

  /// 採用・却下の依頼でなければnull。不正な受付は既存の受付画面で報告する。
  static _DecisionRequest? read(
    String path,
    String raw,
    VaultSnapshot snapshot,
  ) {
    try {
      final m = parseMarkdown(raw).meta, id = m['request_id'];
      if (id is! String ||
          !requestIdPattern.hasMatch(id) ||
          path != 'Input/$id.md' ||
          m['confirmed'] != true ||
          ![
            'knowledge-approve',
            'knowledge-reject',
            'project-approve',
            'project-reject',
          ].contains(m['operation'])) {
        return null;
      }
      final ids = m['cover_ids'], hashes = m['cover_hashes'];
      return _DecisionRequest(
        id,
        m['candidate_id'],
        m['candidate_hash'],
        {
          if (ids is List && hashes is List && ids.length == hashes.length)
            for (final (i, cover) in ids.indexed) cover: hashes[i],
        },
        approves: (m['operation'] as String).endsWith('-approve'),
        failed: _refused(path, raw, id, snapshot),
      );
    } catch (_) {
      return null;
    }
  }

  /// 本体がこの内容の依頼を受け付けられなかった記録（90_system/intake-errors）があり、受け付けた記録がない。
  static bool _refused(
    String path,
    String raw,
    String id,
    VaultSnapshot snapshot,
  ) {
    if (snapshot.files.containsKey('90_system/intake/$id.json')) return false;
    final record =
        snapshot.files['90_system/intake-errors/${digest(path)}.json'];
    if (record == null) return false;
    try {
      final error = jsonDecode(record) as Map;
      return error['schema_version'] == 1 &&
          error['path'] == path &&
          ['error', 'conflict'].contains(error['status']) &&
          error['file_hash'] == digest(raw);
    } catch (_) {
      return false;
    }
  }
}

/// 未整理のメモのmeta。読めなければnull。
Map<String, dynamic>? _metaOf(String raw) {
  try {
    return parseMarkdown(raw).meta;
  } catch (_) {
    return null;
  }
}
