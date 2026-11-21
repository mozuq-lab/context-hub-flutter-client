import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/core/calendar.dart';
import 'package:context_hub_client/core/happened.dart';
import 'package:context_hub_client/core/intake_features.dart';
import 'package:context_hub_client/core/models.dart';
import 'package:context_hub_client/core/review_candidates.dart';

void main() {
  test('出来事の日付は今日を除く365日前までの実在する日だけ', () {
    final now = DateTime.utc(2026, 11, 20, 3); // 東京では11月20日の正午。
    expect(validHappenedOn('2026-11-19', now), isTrue);
    expect(validHappenedOn('2025-11-20', now), isTrue);
    expect(validHappenedOn('2025-11-19', now), isFalse);
    expect(validHappenedOn('2026-11-20', now), isFalse);
    expect(validHappenedOn('2026-11-21', now), isFalse);
    expect(validHappenedOn('2026-02-30', now), isFalse);
    expect(validHappenedOn(null, now), isFalse);
    // 東京の暦日で数える。UTCでは11月19日でも、東京で11月20日なら11月19日は昨日。
    final late = DateTime.utc(2026, 11, 19, 16);
    expect(happenedChoiceLabel('2026-11-19', late), '昨日');
    expect(happenedChoiceLabel('2026-11-18', late), 'おととい');
    expect(happenedChoiceLabel(null, late), '今日');
  });

  test('本体が書いた対応一覧だけで、新しい依頼を使えるか決める', () {
    expect(IntakeFeatures.parse(null).happenedOn, isFalse);
    expect(IntakeFeatures.parse('{').policyKeep, isFalse);
    final features = IntakeFeatures.parse(
      '{"schema_version":1,"operations":["capture","policy-keep"],"capture_fields":["happened_on"]}',
    );
    expect(features.happenedOn, isTrue);
    expect(features.policyKeep, isTrue);
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
