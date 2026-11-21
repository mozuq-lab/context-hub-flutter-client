import 'dart:convert';

/// 本体が書く、受け付ける依頼の種類とメモの任意の欄の一覧。
const intakeFeaturesPath = '90_system/intake-features.json';

/// 本体が受け付ける依頼の種類（operation）と、メモ（capture）の任意の欄。
/// 一覧がない・読めない本体は対応前として扱い、新しい依頼や欄を送らない（送ると受付で拒否されるため）。
class IntakeFeatures {
  const IntakeFeatures._(this.operations, this.captureFields);
  static const none = IntakeFeatures._({}, {});
  final Set<String> operations, captureFields;

  bool get happenedOn => captureFields.contains('happened_on');
  bool get policyKeep => operations.contains('policy-keep');

  static IntakeFeatures parse(String? raw) {
    if (raw == null) return none;
    try {
      final m = jsonDecode(raw);
      if (m is! Map ||
          m['schema_version'] != 1 ||
          m['operations'] is! List ||
          m['capture_fields'] is! List) {
        return none;
      }
      return IntakeFeatures._(
        {
          for (final v in m['operations'] as List)
            if (v is String) v,
        },
        {
          for (final v in m['capture_fields'] as List)
            if (v is String) v,
        },
      );
    } catch (_) {
      return none;
    }
  }
}
