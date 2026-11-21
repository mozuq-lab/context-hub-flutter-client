import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/calendar.dart';
import 'package:context_hub_client/core/happened.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/review_candidates.dart';

void main() {
  test('出来事の日付は今日を除く365日前までの実在する日だけ', () {
    final now = DateTime.utc(2026, 11, 20, 3); // 東京では11月20日の正午。
    expect(validHappenedOn('2026-11-19', now: now), isTrue);
    expect(validHappenedOn('2025-11-20', now: now), isTrue);
    expect(validHappenedOn('2025-11-19', now: now), isFalse);
    expect(validHappenedOn('2026-11-20', now: now), isFalse);
    expect(validHappenedOn('2026-11-21', now: now), isFalse);
    expect(validHappenedOn('2026-02-30', now: now), isFalse);
    expect(validHappenedOn(null, now: now), isFalse);
    // 東京の暦日で数える。UTCでは11月19日でも、東京で11月20日なら11月19日は昨日まで。
    final late = DateTime.utc(2026, 11, 19, 16);
    expect(validHappenedOn('2026-11-19', now: late), isTrue);
    expect(validHappenedOn('2026-11-20', now: late), isFalse);
    // 本体の設定でさかのぼれる日数を縮めたときは、それに合わせる。
    expect(validHappenedOn('2026-11-10', now: now, maxDays: 10), isTrue);
    expect(validHappenedOn('2026-11-09', now: now, maxDays: 10), isFalse);
  });

  test('本体が書いた対応一覧だけで、新しい依頼を使えるか決める', () {
    expect(IntakeFeatures.parse(null).happenedOn, isFalse);
    expect(IntakeFeatures.parse('{').policyKeep, isFalse);
    final features = IntakeFeatures.parse(
      '{"schema_version":1,"operations":["capture","policy-keep"],"capture_fields":["happened_on"]}',
    );
    expect(features.happenedOn, isTrue);
    expect(features.policyKeep, isTrue);
    // 古い本体は日数と件名の設定を書かない。本体の既定と同じに扱う。
    expect(features.maxBackdateDays, 365);
    expect(features.calendarTitles, 'item');
    final tuned = IntakeFeatures.parse(
      '{"schema_version":1,"operations":[],"capture_fields":[],"max_backdate_days":30,"calendar_titles":"project"}',
    );
    expect(tuned.maxBackdateDays, 30);
    expect(tuned.calendarTitles, 'project');
    expect(
      IntakeFeatures.parse(
        '{"schema_version":1,"operations":["capture"],"capture_fields":[]}',
      ).policyKeep,
      isFalse,
    );
  });

  test('期日の予定は本体の書き出しと同じUID・件名で、伏せ字を当てる', () {
    final project = HubProject(id: 'hub', title: '集約ツール');
    NowItemRef item({String? due, String text = '利用者に見せる'}) => NowItemRef(
      key: 'a' * 64,
      section: 'next',
      label: '[確認済み] ',
      text: text,
      inputId: 'IN-1',
      due: due,
    );
    expect(dueEvent(project, item(), hide: (s) => s), isNull);
    final event = dueEvent(project, item(due: '2026-12-01'), hide: (s) => s)!;
    // 本体のcalendarEventsが同じ項目に付けるUIDと件名。
    expect(event.uid, '3a75aaee8e55a55bd9aea17e1e68ca00-due@context-hub');
    expect(event.title, '[期日] 集約ツール: [確認済み] 利用者に見せる');
    final ics = event.ics;
    expect(ics, contains('DTSTART;VALUE=DATE:20261201\r\n'));
    expect(ics, contains('DTEND;VALUE=DATE:20261202\r\n'));
    expect(ics.endsWith('\r\n'), isTrue);
    final hidden = dueEvent(
      project,
      item(due: '2026-12-01', text: 'token abc'),
      hide: (s) => s.replaceAll('abc', '[伏せ字]'),
    )!;
    expect('${hidden.title}${hidden.description}', isNot(contains('abc')));
    // 本体の`calendar.titles: project`と同じく、本文を入れない。
    final bare = dueEvent(
      project,
      item(due: '2026-12-01'),
      hide: (s) => s,
      withText: false,
    )!;
    expect(bare.title, '[期日] 集約ツール: 次の一手');
    expect(bare.description, isNot(contains('利用者に見せる')));
    // 本体のfoldLineと同じく、UTF-8の文字の途中で切らずに75オクテットで折り返す。
    expect(
      foldIcsLine('DESCRIPTION:${'あ' * 40}'),
      'DESCRIPTION:${'あ' * 21}\r\n ${'あ' * 19}',
    );
  });

  test('方針の見直しの状態を読み、形式が違えば見直しの表示を出さない', () {
    expect(PolicyReviewState.parse(null), isNull);
    expect(
      PolicyReviewState.parse({
        'due': true,
        'since': 'x',
        'days': 1,
        'reviewDays': 90,
      }),
      isNull,
    );
    final state = PolicyReviewState.parse({
      'due': true,
      'since': '2026-08-01T00:00:00Z',
      'days': 100,
      'reviewDays': 90,
      'confirmedAt': '2026-08-01T00:00:00Z',
    })!;
    expect(state.due, isTrue);
    expect(state.confirmedAt, DateTime.utc(2026, 8));
  });
}
