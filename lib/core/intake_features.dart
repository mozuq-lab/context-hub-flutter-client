import 'dart:convert';

import 'happened.dart' show defaultMaxBackdateDays;
import 'models.dart' show askQuestionChars;

/// 本体が書く、受け付ける依頼の種類とメモの任意の欄の一覧。
const intakeFeaturesPath = '90_system/intake-features.json';

/// 本体が受け付ける依頼の種類（operation）と、メモ（capture）の任意の欄。
/// 一覧がない・読めない本体は対応前として扱い、新しい依頼や欄を送らない（送ると受付で拒否されるため）。
class IntakeFeatures {
  const IntakeFeatures._(
    this.operations,
    this.captureFields, {
    this.maxBackdateDays = defaultMaxBackdateDays,
    this.calendarTitles = 'item',
    this.itemScheduleFields = const {},
    this.askEnabled = false,
    this.askMaxChars = askQuestionChars,
    this.captureKinds = const {},
  });
  static const none = IntakeFeatures._({}, {});
  final Set<String> operations, captureFields;

  /// 出来事の日付をさかのぼれる日数（本体の`capture.maxBackdateDays`）。書かれていなければ本体の既定と同じ365日。
  final int maxBackdateDays;

  /// 期日のカレンダーの件名の設定（本体の`calendar.titles`）。`project`なら予定に項目の本文を入れない。
  final String calendarTitles;

  /// 期日の依頼（item-schedule）に添えられる欄。`repeat`は定例の繰り返し。
  final Set<String> itemScheduleFields;

  /// 本人が本体の設定で「記録に聞く」を有効にしているか（`ask.enabled`）と、問いの上限の文字数。
  final bool askEnabled;
  final int askMaxChars;

  /// 送れる入力の種類（`capture_kinds`）。書かれていなければメモと作業要約だけ。
  final Set<String> captureKinds;

  bool get happenedOn => captureFields.contains('happened_on');

  /// 本人が次の一手に直接足す行動（`kind: action`）を送れる。
  bool get actions => captureKinds.contains('action');
  bool get policyKeep => operations.contains('policy-keep');

  /// 人の登録・名前と呼び名の変更・外す依頼（人ごとの見返し）。
  bool get people => operations.contains('person-definition');

  /// 期日に繰り返しを付けられ、定例の今の回を完了・見送りにできる。
  bool get repeat => itemScheduleFields.contains('repeat') && occurrence;
  bool get occurrence => operations.contains('item-occurrence');

  /// 「記録に聞く」の問いを送れる（本体が受け付け、設定で有効）。
  bool get ask => operations.contains('ask') && askEnabled;

  /// アプリの好みを端末間でそろえられる。
  bool get preferences => operations.contains('client-preferences');

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
      final days = m['max_backdate_days'], titles = m['calendar_titles'];
      final schedule = m['item_schedule_fields'], ask = m['ask'];
      final kinds = m['capture_kinds'];
      final askMax = ask is Map ? ask['max_question_chars'] : null;
      return IntakeFeatures._(
        itemScheduleFields: {
          if (schedule is List)
            for (final v in schedule)
              if (v is String) v,
        },
        captureKinds: {
          if (kinds is List)
            for (final v in kinds)
              if (v is String) v,
        },
        askEnabled: ask is Map && ask['enabled'] == true,
        askMaxChars: askMax is int && askMax > 0 && askMax <= askQuestionChars
            ? askMax
            : askQuestionChars,
        maxBackdateDays: days is int && days >= 1 && days <= 3650
            ? days
            : defaultMaxBackdateDays,
        // 知らない値は、本文を出さない側に倒す。
        calendarTitles: titles == null || titles == 'item' ? 'item' : 'project',
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
