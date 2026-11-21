import 'models.dart';

/// 出来事の日付（本体の`happened_on`）。昨日の会議を今日書くように、後から記録するメモの「いつのことか」。
/// 本体は、記録した日より後の日付と、設定の上限（既定365日、本体が`intake-features.json`に書く）より前の日付を受け付けない。
const defaultMaxBackdateDays = 365;

/// 本体と同じ形（YYYY-MM-DD）。実在する日かどうかは[validHappenedOn]で確かめる。
final happenedOnPattern = scheduleDatePattern;

/// 今日（本体と同じ日本時間の暦日）から[maxDays]日前までの、今日を除く実在する日。
bool validHappenedOn(
  Object? value, {
  DateTime? now,
  int maxDays = defaultMaxBackdateDays,
}) {
  if (!validScheduleDate(value)) return false;
  final today = hubToday(now), date = value as String;
  return date.compareTo(today) < 0 &&
      date.compareTo(addScheduleDays(today, -maxDays)) >= 0;
}

/// 原文の出来事の日付と、実際に書いた日時。本体は両方をそろえて書く。どちらかが欠けていれば出来事の日付はないものとする。
({String date, DateTime recordedAt})? happenedOf(HubRecord record) {
  final date = record.metadata['happened_on'],
      recorded = record.metadata['recorded_at'];
  if (!validScheduleDate(date) || recorded is! String) return null;
  final at = DateTime.tryParse(recorded);
  if (at == null) return null;
  return (date: date as String, recordedAt: at);
}
