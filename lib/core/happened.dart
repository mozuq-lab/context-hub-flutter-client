import 'models.dart';

/// 出来事の日付（本体の`happened_on`）。昨日の会議を今日書くように、後から記録するメモの「いつのことか」。
/// 本体は、記録した日より後の日付と、設定の上限（既定365日）より前の日付を受け付けない。
const maxBackdateDays = 365;

/// 本体と同じ形（YYYY-MM-DD）。実在する日かどうかは[validHappenedOn]で確かめる。
final happenedOnPattern = scheduleDatePattern;

/// 今日（本体と同じ日本時間の暦日）から[maxBackdateDays]日前までの、今日を除く実在する日。
bool validHappenedOn(Object? value, [DateTime? now]) {
  if (!validScheduleDate(value)) return false;
  final today = hubToday(now), date = value as String;
  return date.compareTo(today) < 0 &&
      date.compareTo(addScheduleDays(today, -maxBackdateDays)) >= 0;
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

/// 入力の画面に出す「いつのこと」の選択肢の名前。
String happenedChoiceLabel(String? date, [DateTime? now]) {
  if (date == null) return '今日';
  final today = hubToday(now);
  if (date == addScheduleDays(today, -1)) return '昨日';
  if (date == addScheduleDays(today, -2)) return 'おととい';
  return date;
}
