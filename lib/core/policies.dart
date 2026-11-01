import 'dart:convert';
import 'models.dart';
import 'parser.dart';

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _sameJson(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

String policyDocument(List<dynamic> entries, String scope) =>
    '# $scopeの有効な方針\n\n本人が採用したdecision/preferenceのみ。端末に揃った同期版です。正本は各知識と承認記録です。\n\n${entries.isEmpty ? '有効な方針はありません。\n' : entries.map((e) => '## ${e['id']} (${e['kind']})\n\n${e['claim']}\n\n正本: ${e['path']}\n承認: ${e['approvalId']}\n').join('\n')}';

class PolicyBundle {
  PolicyBundle(this.data, this.projectId);
  final Map<String, dynamic> data;
  final String? projectId;
  String get text {
    final warnings = projectId == null
        ? ['作業フォルダーはContextHubプロジェクトに未対応付けです。共通方針のみ適用します。']
        : <String>[];
    return '# 本人が過去に採用した継続的な方針\n\n端末に揃った同期版: ${data['revision']}\n生成: ${data['generatedAt']}\n対象: ${projectId ?? '共通のみ'}\nこの版の有効IDだけを適用し、以前の版にのみ存在するIDは適用しません。\n上位指示と本人の今回の依頼を尊重してください。方針同士の矛盾で判断が変わる場合は該当内容を示して確認してください。採用は任意の実行・承認権限を与えません。\n${warnings.join('\n')}\n\n${policyDocument(data['global'] as List, '共通')}\n${projectId == null ? '' : policyDocument(data['projects'][projectId] as List, 'プロジェクト $projectId')}';
  }
}

class PolicyReader {
  PolicyReader(this.snapshot);
  final VaultSnapshot snapshot;
  static final _sha = RegExp(r'^[a-f0-9]{64}$'),
      _knw = RegExp(r'^KNW-[0-9A-HJKMNP-TV-Z]{26}$');
  bool _inventoryPath(String p) =>
      p.endsWith('.md') &&
          (p.startsWith('30_knowledge/') ||
              p.startsWith('10_projects/') &&
                  (p.contains('/knowledge/') || p.endsWith('/project.md'))) ||
      p.endsWith('.json') &&
          (p.startsWith('90_system/approvals/') ||
              p.startsWith('90_system/knowledge-retirements/'));
  PolicyBundle read([String? projectId]) {
    try {
      if (!snapshot.recognized ||
          snapshot.warnings.isNotEmpty ||
          projectId != null && !projectIdPattern.hasMatch(projectId)) {
        throw const FormatException();
      }
      final raw = snapshot.files['90_system/policies/index.json'];
      if (raw == null) throw const FormatException();
      final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (m['schema_version'] != 1 ||
          m['revision'] is! String ||
          !_sha.hasMatch(m['revision']) ||
          timestamp(m['generatedAt']) == null) {
        throw const FormatException();
      }
      final inventory = snapshot.files.keys.where(_inventoryPath).toList()
            ..sort(),
          deps = Map<String, dynamic>.from(m['dependencies'] as Map);
      if (jsonEncode(inventory) != jsonEncode(m['inventory']) ||
          jsonEncode(deps.keys.toList()) != jsonEncode(inventory)) {
        throw const FormatException();
      }
      for (final e in deps.entries) {
        if (!_sha.hasMatch(e.value as String) ||
            digest(snapshot.files[e.key]!) != e.value) {
          throw const FormatException();
        }
      }
      final records = <String, ({String path, Map<String, dynamic> meta})>{},
          projects = <String, List<dynamic>>{};
      for (final p in inventory.where((p) => p.endsWith('.md'))) {
        final doc = parseMarkdown(snapshot.files[p]!),
            meta = doc.meta,
            id = meta['id'];
        if (p.endsWith('/project.md')) {
          if (id is! String ||
              !projectIdPattern.hasMatch(id) ||
              p != '10_projects/$id/project.md' ||
              meta['title'] is! String) {
            throw const FormatException();
          }
          projects[id] = [];
          continue;
        }
        if (id is! String ||
            !_knw.hasMatch(id) ||
            records.containsKey(id) ||
            !generatedIntact(snapshot.files[p]!, meta)) {
          throw const FormatException();
        }
        final scope = meta['scope'];
        if (scope != null && !['global', 'project'].contains(scope)) {
          throw const FormatException();
        }
        final want = scope == 'project'
            ? '10_projects/${meta['project_id']}/knowledge/$id.md'
            : '30_knowledge/$id.md';
        if (want != p) throw const FormatException();
        records[id] = (path: p, meta: meta);
      }
      final global = <dynamic>[], inactive = <String>[], approved = <String>{};
      for (final p in inventory.where(
        (p) => p.startsWith('90_system/approvals/'),
      )) {
        final d = jsonDecode(snapshot.files[p]!) as Map,
            suffix = (d['candidate_id'] as String).substring(4),
            id = 'KNW-$suffix';
        if (d['schema_version'] != 1 ||
            d['id'] != 'APR-$suffix' ||
            p != '90_system/approvals/APR-$suffix.json' ||
            d['actor'] != 'user' ||
            timestamp(d['decided_at']) == null ||
            digest(d['snapshot'] as String) != d['candidate_hash']) {
          throw const FormatException();
        }
        final c = parseMarkdown(d['snapshot'] as String).meta;
        if (c['id'] != d['candidate_id'] ||
            !generatedIntact(d['snapshot'] as String, c)) {
          throw const FormatException();
        }
        if (d['action'] == 'reject') continue;
        if (d['action'] != 'approve') throw const FormatException();
        final k = records[id];
        if (k == null) throw const FormatException();
        final a = k.meta, t = d['target'];
        if (a['verified'] != true ||
            a['approval_id'] != d['id'] ||
            a['approved_hash'] != d['candidate_hash'] ||
            a['approved_candidate'] != d['candidate_id'] ||
            a['kind'] != c['kind'] ||
            jsonEncode(a['input_ids']) != jsonEncode(c['input_ids']) ||
            a['supersedes'] != c['supersedes']) {
          throw const FormatException();
        }
        if (t == null
            ? a['scope'] != null
            : a['scope'] != t['scope'] ||
                  t['scope'] == 'project' &&
                      (a['project_id'] != t['projectId'] ||
                          a['project_hash'] != t['projectHash'])) {
          throw const FormatException();
        }
        approved.add(id);
        final stopPath = '90_system/knowledge-retirements/KRET-$suffix.json',
            stopRaw = snapshot.files[stopPath];
        if (stopRaw != null) {
          final r = jsonDecode(stopRaw) as Map,
              meta = parseMarkdown(r['snapshot'] as String).meta;
          if (r['schema_version'] != 1 ||
              r['id'] != 'KRET-$suffix' ||
              r['knowledge_id'] != id ||
              r['actor'] != 'user' ||
              timestamp(r['retired_at']) == null ||
              digest(r['snapshot'] as String) != r['knowledge_hash'] ||
              meta['id'] != id ||
              meta['approval_id'] != d['id'] ||
              meta['approved_hash'] != d['candidate_hash'] ||
              !generatedIntact(r['snapshot'] as String, meta)) {
            throw const FormatException();
          }
        }
        for (final pair in [
          ('superseded_by', 'supersedes'),
          ('supersedes', 'superseded_by'),
        ]) {
          if (a[pair.$1] != null) {
            final other = records[a[pair.$1]]?.meta;
            if (other == null ||
                other[pair.$2] != id ||
                other['scope'] != a['scope'] ||
                other['project_id'] != a['project_id']) {
              throw const FormatException();
            }
          }
        }
        if (stopRaw != null || a['superseded_by'] != null || t == null) {
          inactive.add(id);
          continue;
        }
        if (c['kind'] == 'knowledge') continue;
        if (!['decision', 'preference'].contains(c['kind']) ||
            c['claim'] is! String ||
            (c['claim'] as String).length > 1000) {
          throw const FormatException();
        }
        final entry = {
          'id': id,
          'kind': c['kind'],
          'claim': c['claim'],
          'path': k.path,
          'approvalId': d['id'],
        };
        if (a['scope'] == 'global') {
          global.add(entry);
        } else {
          final list = projects[a['project_id']];
          if (list == null) throw const FormatException();
          list.add(entry);
        }
      }
      if (!approved.containsAll(records.keys)) throw const FormatException();
      for (final p in inventory.where(
        (p) => p.startsWith('90_system/knowledge-retirements/'),
      )) {
        final match = RegExp(
          r'^90_system/knowledge-retirements/KRET-([0-9A-HJKMNP-TV-Z]{26})\.json$',
        ).firstMatch(p);
        if (match == null || !approved.contains('KNW-${match[1]}')) {
          throw const FormatException();
        }
      }
      global.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      for (final list in projects.values) {
        list.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      }
      inactive.sort();
      if (jsonEncode(global) != jsonEncode(m['global']) ||
          !_sameJson(projects, m['projects']) ||
          jsonEncode(inactive) != jsonEncode(m['inactiveIds'])) {
        throw const FormatException();
      }
      final state = {
        'global': m['global'],
        'projects': m['projects'],
        'inactiveIds': m['inactiveIds'],
        'dependencies': m['dependencies'],
        'inventory': m['inventory'],
      };
      if (digest(jsonEncode(state)) != m['revision']) {
        throw const FormatException();
      }
      final documents = {
        'POLICY.md': policyDocument(global, '共通'),
        for (final e in projects.entries)
          '10_projects/${e.key}/POLICY.md': policyDocument(
            e.value,
            'プロジェクト ${e.key}',
          ),
      };
      final projections = Map<String, dynamic>.from(m['projections'] as Map);
      if (projections.length != documents.length) throw const FormatException();
      final g = utf8.encode(documents['POLICY.md']!).length;
      if (g > 32 * 1024) throw const FormatException();
      for (final e in documents.entries) {
        if (snapshot.files[e.key] != e.value ||
            projections[e.key] != digest(e.value) ||
            utf8.encode(e.value).length > 32 * 1024 ||
            e.key != 'POLICY.md' &&
                g + utf8.encode(e.value).length > 64 * 1024) {
          throw const FormatException();
        }
      }
      if (projectId != null && !projects.containsKey(projectId)) {
        throw const FormatException();
      }
      return PolicyBundle(m, projectId);
    } catch (_) {
      throw const FormatException('有効方針が未同期・未初期化・不整合です。Miniで集約し同期して再読込してください。');
    }
  }
}
