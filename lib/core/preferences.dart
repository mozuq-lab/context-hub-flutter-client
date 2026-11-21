import 'dart:convert';
import 'parser.dart' show projectIdPattern, timestamp;
import 'templates.dart';

/// 端末間でそろえるアプリの好み（ピン留めと並び順・メモのひな形・文脈かごの上限）。
///
/// アプリは変えたまとまりを受付ファイル（`operation: client-preferences`、本文がJSON）で送り、
/// 本体がまとまりごとに新しい方を残して[clientPreferencesPath]へ書く。ほかの端末は読込のときに、
/// 自分が覚えている日時より新しいまとまりを取り込む。既読・ウインドウ・通知・APIキーのような端末ごとの状態は送らない。
const clientPreferencesPath = '90_system/client-preferences.json';
const preferenceGroups = ['pins', 'templates', 'basket'];
const preferenceGroupLabels = {
  'pins': 'ピン留めと並び順',
  'templates': 'メモのひな形',
  'basket': '文脈かごの上限',
};

/// 受付ファイルの本文の上限（本体のPREFERENCES_MAX_BYTESと同じ）。
const preferencesMaxBytes = 32 * 1024;
final _device = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// 本体が記録した、1つのまとまりの好み。
class SharedPreference {
  const SharedPreference({
    required this.updatedAt,
    required this.device,
    required this.requestId,
    required this.value,
  });
  final DateTime updatedAt;
  final String device, requestId;
  final Map<String, dynamic> value;
}

/// ピン留めの値（プロジェクトIDの並び）。形式が合わなければnull。
List<String>? pinsValue(Map<String, dynamic> value) {
  final ids = value['ids'];
  if (value.length != 1 ||
      ids is! List ||
      ids.length > 30 ||
      !ids.every((i) => i is String && projectIdPattern.hasMatch(i)) ||
      ids.toSet().length != ids.length) {
    return null;
  }
  return List<String>.from(ids);
}

/// ひな形の値。既定のプロジェクトは、送った端末が開いていたVaultのものだけを持つ。形式が合わなければnull。
List<({MemoTemplate template, String? project})>? templatesValue(
  Map<String, dynamic> value,
) {
  final items = value['items'];
  if (value.length != 1 || items is! List || items.length > maxTemplates) {
    return null;
  }
  final out = <({MemoTemplate template, String? project})>[];
  final seen = <String>{};
  for (final item in items) {
    if (item is! Map ||
        item.keys.any(
          (k) => !const ['id', 'name', 'body', 'project'].contains(k),
        )) {
      return null;
    }
    final project = item['project'];
    final template = MemoTemplate.fromJson({
      'id': item['id'],
      'name': item['name'],
      'body': item['body'],
    });
    if (template == null ||
        !seen.add(template.id) ||
        (project != null &&
            (project is! String || !projectIdPattern.hasMatch(project)))) {
      return null;
    }
    out.add((template: template, project: project as String?));
  }
  return out;
}

/// かごの文字数上限。形式が合わなければnull。
int? basketValue(Map<String, dynamic> value) {
  final max = value['max_chars'];
  if (value.length != 1 ||
      max is! int ||
      !const [6000, 12000, 30000].contains(max)) {
    return null;
  }
  return max;
}

bool _validValue(String group, Object? value) =>
    value is Map<String, dynamic> &&
    switch (group) {
      'pins' => pinsValue(value) != null,
      'templates' => templatesValue(value) != null,
      'basket' => basketValue(value) != null,
      _ => false,
    };

/// 本体の記録を読む。形式が合わなければFormatException（どのまとまりも使わない）。
Map<String, SharedPreference> parseSharedPreferences(Object? json) {
  if (json is! Map ||
      json['schema_version'] != 1 ||
      json['groups'] is! Map ||
      json.length != 2) {
    throw const FormatException();
  }
  final out = <String, SharedPreference>{};
  for (final e in (json['groups'] as Map).entries) {
    final v = e.value;
    final at = v is Map ? timestamp(v['updated_at']) : null;
    if (!preferenceGroups.contains(e.key) ||
        v is! Map ||
        at == null ||
        v['device'] is! String ||
        !_device.hasMatch(v['device']) ||
        v['request_id'] is! String ||
        (v['request_id'] as String).isEmpty ||
        !_validValue(e.key as String, v['value'])) {
      throw const FormatException();
    }
    out[e.key as String] = SharedPreference(
      updatedAt: at,
      device: v['device'] as String,
      requestId: v['request_id'] as String,
      value: v['value'] as Map<String, dynamic>,
    );
  }
  return out;
}

/// 受付ファイルの本文（JSON）を作る。[groups]はまとまり名 → (変えた日時, 値)。
String encodePreferencesPayload(
  String device,
  Map<String, ({DateTime at, Map<String, Object?> value})> groups,
) => jsonEncode({
  'schema_version': 1,
  'device': device,
  'groups': {
    for (final g in preferenceGroups)
      if (groups[g] case final entry?)
        g: {
          'updated_at': entry.at.toUtc().toIso8601String(),
          'value': entry.value,
        },
  },
});

/// 受付ファイルの本文を読み、送ったまとまりを返す。形式が合わなければnull。
List<String>? preferenceGroupsOf(String body) {
  try {
    if (utf8.encode(body).length > preferencesMaxBytes) return null;
    final j = jsonDecode(body);
    if (j is! Map ||
        j.length != 3 ||
        j['schema_version'] != 1 ||
        j['device'] is! String ||
        !_device.hasMatch(j['device']) ||
        j['groups'] is! Map ||
        (j['groups'] as Map).isEmpty) {
      return null;
    }
    final groups = <String>[];
    for (final e in (j['groups'] as Map).entries) {
      final v = e.value;
      if (!preferenceGroups.contains(e.key) ||
          v is! Map ||
          v.length != 2 ||
          timestamp(v['updated_at']) == null ||
          !_validValue(e.key as String, v['value'])) {
        return null;
      }
      groups.add(e.key as String);
    }
    return groups;
  } catch (_) {
    return null;
  }
}
