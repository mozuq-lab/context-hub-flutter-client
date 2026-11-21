import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// 端末のカレンダーへ入れる、期日の予定1件。日付は本人が付けた期日だけで、AIが推測した日付は使わない。
/// UIDは本体の書き出し（90_system/calendar/contexthub.ics）と同じ決め方にし、後で本体のファイルを読み込んでも同じ予定として置き換わる。
class CalendarEvent {
  const CalendarEvent({
    required this.uid,
    required this.date,
    required this.title,
    required this.description,
  });
  final String uid, date, title, description;

  /// 終日の予定1件のiCalendar（RFC 5545）。Macでは、このファイルをカレンダーで開いて取り込む。
  String get ics {
    final lines = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//ContextHub//Flutter//JA',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
      'BEGIN:VEVENT',
      'UID:$uid',
      'DTSTAMP:${_stamp(DateTime.now())}',
      'DTSTART;VALUE=DATE:${date.replaceAll('-', '')}',
      'DTEND;VALUE=DATE:${addScheduleDays(date, 1).replaceAll('-', '')}',
      'SUMMARY:${_escape(title)}',
      'DESCRIPTION:${_escape(description)}',
      'TRANSP:TRANSPARENT',
      'END:VEVENT',
      'END:VCALENDAR',
    ];
    return '${lines.map(foldIcsLine).join('\r\n')}\r\n';
  }
}

const _titleChars = 30, _descriptionChars = 500;
String _clip(String text, int limit) {
  final runes = text.replaceAll(RegExp(r'\s+'), ' ').trim().runes.toList();
  return runes.length > limit
      ? '${String.fromCharCodes(runes.take(limit))}…'
      : String.fromCharCodes(runes);
}

String _escape(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll(RegExp(r'\r\n|\r|\n'), r'\n');
String _stamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
}

/// 1行を75オクテット以内に折り返す。UTF-8の文字の途中では切らず、続きの行は空白1文字で始める。
String foldIcsLine(String line) {
  final parts = <String>[];
  var current = StringBuffer(), size = 0, limit = 75;
  for (final rune in line.runes) {
    final ch = String.fromCharCode(rune), bytes = utf8.encode(ch).length;
    if (size + bytes > limit) {
      parts.add(current.toString());
      current = StringBuffer();
      size = 0;
      limit = 74;
    }
    current.write(ch);
    size += bytes;
  }
  parts.add(current.toString());
  return parts.join('\r\n ');
}

/// 本体と同じUID（プロジェクトID・項目キー・種類のSHA-256の先頭32桁）。
String calendarUid(String projectId, String itemKey, String kind) =>
    '${sha256.convert(utf8.encode('$projectId\n$itemKey\n$kind')).toString().substring(0, 32)}-$kind@context-hub';

/// 期日の予定。カレンダーはクラウドへ同期されることが多いため、本文は[hide]（伏せ字）を当ててから切る。
CalendarEvent? dueEvent(
  HubProject project,
  NowItemRef item, {
  required String Function(String) hide,
}) {
  final due = item.due;
  if (due == null || !validScheduleDate(due) || item.resolved) return null;
  final section = item.section == 'next' ? '次の一手' : '未解決';
  final body = hide('${item.label}${item.text}');
  return CalendarEvent(
    uid: calendarUid(project.id, item.key, 'due'),
    date: due,
    title: hide('[期日] ${project.title}: ${_clip(body, _titleChars)}'),
    description: hide(
      [
        'ContextHubの$sectionに本人が付けた期日です。',
        _clip(body, _descriptionChars),
        if (item.reviewAfter != null) '見直す日: ${item.reviewAfter}',
        'プロジェクト: ${project.id}',
      ].join('\n'),
    ),
  );
}
