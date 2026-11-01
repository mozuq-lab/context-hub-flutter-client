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
            final actual = snapshot.files[entry.key];
            if ((actual == null ? null : digest(actual)) != entry.value) {
              valid = false;
            }
          }
          // indexの生成後に到着した訂正も調べる。正本の最終判定はMiniが行う。
          final found = <String>{};
          var historyCorrection = false;
          for (final entry in snapshot.files.entries.where(
            (e) => e.key.startsWith('00_inbox/') && e.key.endsWith('.md'),
          )) {
            try {
              final m = parseMarkdown(entry.value).meta;
              if (c.inputIds.contains(m['id'])) found.add(m['id'] as String);
              if (c.inputIds.contains(m['corrects_input_id']) &&
                  !c.inputIds.contains(m['id'])) {
                if (c.actionable) {
                  valid = false;
                } else if (['approved', 'rejected'].contains(c.status)) {
                  historyCorrection = true;
                }
              }
            } catch (_) {
              if (c.inputIds.isNotEmpty) valid = false;
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
      warnings.add('確認待ち一覧を読み取れません。同期後、MiniでHOMEを更新してください。');
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
  String? requestIdFor(String candidateId) {
    for (final e in snapshot.files.entries.where(
      (e) => e.key.startsWith('Input/') && e.key.endsWith('.md'),
    )) {
      try {
        final m = parseMarkdown(e.value).meta, id = m['request_id'];
        if (m['candidate_id'] == candidateId &&
            m['candidate_hash'] == byId(candidateId)?.candidateHash &&
            id is String &&
            requestIdPattern.hasMatch(id) &&
            e.key == 'Input/$id.md' &&
            m['confirmed'] == true &&
            [
              'knowledge-approve',
              'knowledge-reject',
              'project-approve',
              'project-reject',
            ].contains(m['operation'])) {
          return id;
        }
      } catch (_) {
        /* 不正な受付は既存の受付画面で報告する。 */
      }
    }
    return null;
  }

  List<ReviewCandidate> get pending =>
      items.where((i) => i.status == 'pending').toList();
  List<ReviewCandidate> get attention =>
      items.where((i) => ['stale', 'unavailable'].contains(i.status)).toList();
  List<ReviewCandidate> get history =>
      items.where((i) => ['approved', 'rejected'].contains(i.status)).toList();
  ReviewCandidate? byId(String id) =>
      items.where((i) => i.id == id).firstOrNull;
}
