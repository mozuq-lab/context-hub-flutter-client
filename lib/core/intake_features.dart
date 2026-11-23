import 'dart:convert';

import 'happened.dart' show defaultMaxBackdateDays;
import 'models.dart' as models show itemEfforts;
import 'models.dart' show askQuestionChars, somedayReviewDaysDefault;

/// 本体の「プロジェクト未定」の行を指す、項目の置き場（記録と依頼の`project_id`に入る）。
const unassignedScope = '_unassigned';

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
    this.itemScopes = const {},
    this.actionScopes = const {},
    this.reviewRejects = const {},
    this.itemEfforts = const {},
    this.itemRecordScopes = const {},
    this.somedayReviewDays = somedayReviewDaysDefault,
    this.actionMoveSupport = false,
    this.projectOutcome,
    this.actionFields = const {},
    this.contextLimits,
    this.areaLimits,
    this.stepLimits,
    this.referenceTitleMax,
    this.attachmentLimits,
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

  /// 完了・却下を受け付ける、プロジェクト以外の項目の置き場（`item_scopes`）。
  final Set<String> itemScopes;

  /// プロジェクトを指定せずに行動（`kind: action`）を足せる置き場（`action_scopes`）。
  final Set<String> actionScopes;

  /// 確認待ち以外で却下を受け付ける候補の状態（`review_rejects`）。`stale`は古くなった候補。
  final Set<String> reviewRejects;

  /// 手間の目安の依頼（item-effort）で選べる値（`item_efforts`）。
  final Set<String> itemEfforts;

  /// 期日・定例の回・手間の目安・連絡待ちの依頼を受け付ける、プロジェクト以外の置き場（`item_record_scopes`）。
  final Set<String> itemRecordScopes;

  /// 本人が追加した行動を別の置き場へ移す依頼を、本体が元の行動を一覧から外して扱う（`action_moves`）。
  final bool actionMoveSupport;

  /// プロジェクトの望む結果（`outcome`）を、定義の変更・作成・案の採用の依頼で送れるときの上限（`project_outcome`）。
  /// 対応前の本体はnull。対応前の本体へ送ると依頼ごと断られるので、望む結果の欄を出さない。
  final ({int maxChars, int maxLines})? projectOutcome;

  /// 行動の追加（kind: action）に添えて、行動の記録として一緒に付けられる欄（`action_fields`）。
  /// `effort`は手間の目安、`contexts`は場所・道具の札。
  final Set<String> actionFields;

  /// 場所・道具の札の上限（`item_contexts`）。1項目の札の数・札の文字数・語彙の数。対応前の本体はnull。
  final ({int maxTags, int maxChars, int vocabularyMax})? contextLimits;

  /// プロジェクトの領域の上限（`project_areas`）。領域の文字数と、好みに置く語彙の数。対応前の本体はnull。
  final ({int maxChars, int vocabularyMax})? areaLimits;

  /// 次の一手の手順の数の下限・上限と、1つの文字数（`item_steps`）。対応前の本体はnull。
  final ({int min, int max, int maxChars})? stepLimits;

  /// 資料の名前の文字数の上限（`references.title_max_chars`）。対応前の本体はnull。
  final int? referenceTitleMax;

  /// メモに添えられるファイルの大きさの上限（バイト）とファイル名の上限（UTF-8のバイト数）（`attachments`）。対応前の本体はnull。
  final ({int maxBytes, int nameMaxBytes})? attachmentLimits;

  /// PDF・画像などのファイルをメモに添えて、資料として保存できる（captureの`attachment`。ファイルはInput/filesに置く）。
  bool get attachments =>
      references &&
      captureFields.contains('attachment') &&
      attachmentLimits != null;

  /// メモを資料として保存し（captureの`reference`・`reference_title`）、保存済みのメモを資料棚に加える・外す・名前を変えられる（reference-mark）。
  bool get references =>
      operations.contains('reference-mark') &&
      captureFields.contains('reference') &&
      captureFields.contains('reference_title') &&
      referenceTitleMax != null;

  /// プロジェクトに領域を付け外しでき（project-area）、作成と一緒に付けられ、領域の語彙を好みとしてVaultに置ける。
  bool get areas =>
      operations.contains('project-area') &&
      areaLimits != null &&
      operations.contains('client-preferences');

  /// 次の一手を手順に分け、終えた手順を進める・戻すことを依頼できる（item-steps）。
  /// プロジェクト未定の行動に付けられるかは[unassignedRecords]で決まる。
  bool get steps => operations.contains('item-steps') && stepLimits != null;

  /// 整理（AIの読み取り）に失敗したメモ1件のやり直しを頼める（organize-retry）。
  bool get organizeRetry => operations.contains('organize-retry');

  /// 次の一手・未解決に場所・道具の札を付け外しでき、札の語彙を好みとしてVaultに置ける（item-contexts）。
  bool get contexts =>
      operations.contains('item-contexts') &&
      contextLimits != null &&
      operations.contains('client-preferences');

  /// 行動を追加するときに、手間の目安を一緒に付けられる。
  bool get actionEffort => actions && effort && actionFields.contains('effort');

  /// 行動を追加するときに、場所・道具の札を一緒に付けられる。
  bool get actionContexts =>
      actions && contexts && actionFields.contains('contexts');

  /// 本人が追加した行動を、別のプロジェクト・プロジェクト未定へ移せる（移す先へ元の行動を指す行動を足す）。
  /// 対応前の本体は元の行動を一覧から外さず二重に並ぶため、移す操作を出さない。
  bool get actionMoves => actions && actionMoveSupport;

  /// 次の一手・未解決に手間の目安を付けられる。
  bool get effort =>
      operations.contains('item-effort') &&
      itemEfforts.containsAll(models.itemEfforts);

  /// 「いつかやる」で見直していないとみなす日数（`someday_review_days`）。書かれていなければ30日。
  final int somedayReviewDays;

  /// 次の一手・未解決を「いつかやる」へ移し・戻し、アイデアを置き、一覧で見直せる（item-someday・someday-review）。
  /// プロジェクト未定の行動を移せるかは[unassignedRecords]で決まる。
  bool get someday =>
      operations.contains('item-someday') &&
      operations.contains('someday-review');

  /// 週次レビューを終えたと報告できる（weekly-review）。点検の一覧（weekly-review.json）も書く本体。
  bool get weeklyReview => operations.contains('weekly-review');

  /// 次の一手・未解決に連絡待ちの印（相手・頼んだ日）を付け外しできる（item-wait）。
  /// プロジェクト未定の行動に付けられるかは[unassignedRecords]で決まる。
  bool get wait => operations.contains('item-wait');

  /// メモ・作業要約を、前のメモの続きとして送れる（`continues`）。
  bool get continues => captureFields.contains('continues');

  /// 古くなった候補を却下できる。
  bool get staleReject => reviewRejects.contains('stale');

  bool get happenedOn => captureFields.contains('happened_on');

  /// 「プロジェクト未定」の行を完了・却下にでき、「今日の3つ」に選べる（行に項目キーがある）。
  bool get unassignedItems => itemScopes.contains(unassignedScope);

  /// 本人が次の一手に直接足す行動（`kind: action`）を送れる。
  bool get actions => captureKinds.contains('action');

  /// プロジェクトを決めずに行動を足せる（プロジェクト未定の次の一手に載り、完了・却下・今日やるが使える）。
  bool get unassignedActions =>
      actions && unassignedItems && actionScopes.contains(unassignedScope);

  /// プロジェクトを決めずに追加した行動に、期日・見直す日・定例の繰り返し・手間の目安を付けられる（AIの行には付けない）。
  bool get unassignedRecords =>
      unassignedActions && itemRecordScopes.contains(unassignedScope);
  bool get policyKeep => operations.contains('policy-keep');

  /// 人の登録・名前と呼び名の変更・外す依頼（人ごとの見返し）。
  bool get people => operations.contains('person-definition');

  /// 期日に繰り返しを付けられ、定例の今の回を完了・見送りにできる。
  bool get repeat => itemScheduleFields.contains('repeat') && occurrence;
  bool get occurrence => operations.contains('item-occurrence');

  /// 「記録に聞く」の問いを送れる（本体が受け付け、設定で有効）。
  bool get ask => operations.contains('ask') && askEnabled;

  /// 「記録に聞く」に対応した本体で、本人が設定で無効にしているか。受け付け済みの問いは有効に戻すまで答え待ちのまま残る。
  bool get askOff => operations.contains('ask') && !askEnabled;

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
      final kinds = m['capture_kinds'],
          scopes = m['item_scopes'],
          actionScopes = m['action_scopes'],
          rejects = m['review_rejects'],
          efforts = m['item_efforts'],
          recordScopes = m['item_record_scopes'];
      final askMax = ask is Map ? ask['max_question_chars'] : null;
      final reviewDays = m['someday_review_days'];
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
        itemScopes: {
          if (scopes is List)
            for (final v in scopes)
              if (v is String) v,
        },
        actionScopes: {
          if (actionScopes is List)
            for (final v in actionScopes)
              if (v is String) v,
        },
        reviewRejects: {
          if (rejects is List)
            for (final v in rejects)
              if (v is String) v,
        },
        itemEfforts: {
          if (efforts is List)
            for (final v in efforts)
              if (v is String) v,
        },
        itemRecordScopes: {
          if (recordScopes is List)
            for (final v in recordScopes)
              if (v is String) v,
        },
        somedayReviewDays:
            reviewDays is int && reviewDays >= 1 && reviewDays <= 3650
            ? reviewDays
            : somedayReviewDaysDefault,
        askEnabled: ask is Map && ask['enabled'] == true,
        askMaxChars: askMax is int && askMax > 0 && askMax <= askQuestionChars
            ? askMax
            : askQuestionChars,
        maxBackdateDays: days is int && days >= 1 && days <= 3650
            ? days
            : defaultMaxBackdateDays,
        // 知らない値は、本文を出さない側に倒す。
        calendarTitles: titles == null || titles == 'item' ? 'item' : 'project',
        actionMoveSupport: m['action_moves'] == true,
        projectOutcome: switch (m['project_outcome']) {
          {'max_chars': final int chars, 'max_lines': final int lines}
              when chars >= 1 && lines >= 1 =>
            (maxChars: chars, maxLines: lines),
          _ => null,
        },
        actionFields: {
          if (m['action_fields'] case final List fields)
            for (final v in fields)
              if (v is String) v,
        },
        contextLimits: switch (m['item_contexts']) {
          {
                'max_tags': final int tags,
                'max_chars': final int chars,
                'vocabulary_max': final int vocabulary,
              }
              when tags >= 1 && chars >= 1 && vocabulary >= 1 =>
            (maxTags: tags, maxChars: chars, vocabularyMax: vocabulary),
          _ => null,
        },
        areaLimits: switch (m['project_areas']) {
          {'max_chars': final int chars, 'vocabulary_max': final int vocabulary}
              when chars >= 1 && vocabulary >= 1 =>
            (maxChars: chars, vocabularyMax: vocabulary),
          _ => null,
        },
        attachmentLimits: switch (m['attachments']) {
          {'max_bytes': final int bytes, 'name_max_bytes': final int name}
              when bytes >= 1 && name >= 1 =>
            (maxBytes: bytes, nameMaxBytes: name),
          _ => null,
        },
        referenceTitleMax: switch (m['references']) {
          {'title_max_chars': final int chars} when chars >= 1 => chars,
          _ => null,
        },
        stepLimits: switch (m['item_steps']) {
          {
                'min': final int min,
                'max': final int max,
                'max_chars': final int chars,
              }
              when min >= 1 && max >= min && chars >= 1 =>
            (min: min, max: max, maxChars: chars),
          _ => null,
        },
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
