import '../app/controller.dart';
import '../core/happened.dart';
import '../core/models.dart';
import '../core/repository.dart';

/// 空の文字列をnullにする（表示を省く判定に使う）。
extension BlankToNull on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// ホームに出す「前回見てからの変化」。記録がない・変化がなければnull。
const sectionLabels = {'current': '現在地', 'next': '次の一手', 'open': '未解決'};

String? changeLabel(ProjectChanges? changes) {
  if (changes == null || changes.isEmpty) return null;
  return [
    if (changes.added.isNotEmpty) '新着${changes.added.length}',
    if (changes.removed.isNotEmpty) '外れた${changes.removed.length}',
  ].join(' · ');
}

String timeLabel(DateTime? value) => value == null ? '未取得' : displayTime(value);

/// 一覧に出す記録の日時。出来事の日付があれば「YYYY-MM-DDのこと（…に記録）」とし、正午に置いた時刻は出さない。
String recordWhen(HubRecord record) {
  final h = happenedOf(record);
  return h == null
      ? timeLabel(record.at ?? record.generatedAt)
      : '${h.date}のこと（${displayTime(h.recordedAt)}に記録）';
}

/// 一覧の1行に収める短い日時。今日・昨日はそう書き、今年の日付は年と時間帯（JST）を省く。
/// 出来事の日付があれば「M月D日のこと」とする（正午に置いた時刻は出さない）。
String compactWhen(HubRecord record, [String? today]) {
  final h = happenedOf(record);
  final now = today ?? hubToday();
  String day(String date) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(date);
    if (m == null) return date;
    final md = '${int.parse(m[2]!)}月${int.parse(m[3]!)}日';
    return m[1] != now.substring(0, 4) ? '${m[1]}年$md' : md;
  }

  String stamp(String label) {
    final m = RegExp(r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})').firstMatch(label);
    if (m == null) return label;
    final date = m[1]!, time = m[2]!;
    if (date == now) return '今日 $time';
    if (date == addScheduleDays(now, -1)) return '昨日 $time';
    return '${day(date)} $time';
  }

  // 出来事の日付は今日より前しか指定できない。一覧は書いた順に並ぶので、書いた日時も添える。
  if (h != null) {
    final when = h.date == addScheduleDays(now, -1) ? '昨日' : day(h.date);
    return '$whenのこと · ${stamp(displayTime(h.recordedAt))}に記録';
  }
  return stamp(timeLabel(record.at ?? record.generatedAt));
}

/// 記録の詳細の日時。出来事の日付があれば、その日と実際に書いた日時を示す（発生日時はその日の正午に置いた値なので出さない）。
String recordTimeLines(HubRecord record) {
  final h = happenedOf(record);
  return h == null
      ? '発生: ${timeLabel(record.at)}'
      : '出来事の日付: ${h.date}（本人が指定）\n記録: ${displayTime(h.recordedAt)}';
}

String originLabel(String origin) => switch (origin) {
  'user-note' => '本人のメモ',
  'ai-self-report' => 'AIの作業自己報告・未検証',
  'ai-generated' => 'AI生成・未検証',
  _ => origin,
};
String stateLabel(String state) => switch (state) {
  'waiting' => 'Mac miniの受け取り待ち',
  'accepted' => 'Mac miniが受け取り',
  'organized' => '読み取り済み',
  'failed' => '読み取り失敗',
  'rejected' => '受け付けられず',
  'conflict' => '競合',
  'uncertain' => '保存確認待ち',
  'unknown' => '整合性未確認',
  'action' => '本人が追加した行動（AIは書き換えません）',
  _ => state,
};

/// 「保存と反映」の段階。保存済み → Mac miniが受け取り済み → 反映済み／失敗。
String intakeStateLabel(String state) => switch (state) {
  'waiting' => '保存済み · Mac miniの受け取り待ち',
  'accepted' => 'Mac miniが受け取り済み',
  'organized' => '反映済み',
  'failed' => '失敗 · AIの読み取りがうまくいきませんでした',
  'rejected' => '失敗 · 受け付けられませんでした',
  'conflict' => '失敗 · 同期が競合しています',
  'uncertain' => '保存確認待ち',
  'unknown' => '状態を確認できません',
  _ => stateLabel(state),
};

/// 失敗したときに次にすること。
String? intakeNextStep(String state) => switch (state) {
  'rejected' => '次に: 理由を読み、必要なら元の画面から操作し直してください。',
  'conflict' ||
  'unknown' => '次に: 同期が終わるのを待って再読込してください。続くときはMac miniの同期を確認してください。',
  'failed' => '次に: Mac miniの本体が動いているか確認してください。元のメモは残っています。',
  _ => null,
};
