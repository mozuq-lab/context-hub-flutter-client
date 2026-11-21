import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

String digest(String value) => sha256.convert(utf8.encode(value)).toString();
String recordId(String path) => 'record-${digest(path).substring(0, 24)}';

/// アプリが使わない本体の記録。読取の件数と時間を抑えるため、ネイティブ側で数えず読まない。
/// 本体の受付・整理の回復用や、表示完了の記録で、アプリのどの画面も参照しない。
/// 確認待ち一覧の依存hashを検証する確認情報・反映記録は読み込む。
const snapshotSkippedPaths = [
  '90_system/receipts/pending',
  '90_system/receipts/events',
  '90_system/intake/pending',
  '90_system/association-views',
  // 週次の統合の実行の記録。アプリは、本体がまとめた一覧（90_system/insights.json）だけを読む。
  '90_system/synthesis',
  // 定例の回を片付けた記録。アプリは、NOWの項目一覧の次の期日と、本体の経緯（HISTORY.md）だけを読む。
  '90_system/item-occurrences',
];

/// 本体が知らない上位の版（schema_version 2以降）で書いた記録があるときの注意。ファイルごとには出さず1件だけ出す。
const newerFormatWarning = '本体が新しい形式で書いた記録があります。読めない記録があるため、アプリを更新してください。';

/// 本体の記録が、このアプリの知らない上位の版で書かれているか。
bool newerSchema(Object? value) {
  if (value is! Map) return false;
  final version = value['schema_version'];
  return version is int && version > 1;
}

/// ネイティブの読取上限に達したときの注意の書き出し。
const snapshotLimitWarningPrefix = '読取の上限';

class VaultSnapshot {
  final Map<String, String> files;
  final List<String> warnings;
  final bool recognized;
  final DateTime loadedAt;

  /// ファイルごとの更新時刻と大きさ。次の読取で変わっていないファイルを読み直さないために使う。
  final Map<String, String> stamps;

  /// 前回の読取から本文を引き継いだファイルの数。
  final int reused;
  VaultSnapshot(
    this.files, {
    this.warnings = const [],
    this.recognized = true,
    DateTime? loadedAt,
    this.stamps = const {},
    this.reused = 0,
  }) : loadedAt = loadedAt ?? DateTime.now();

  /// 読取の上限に達し、一部の記録を読めていない。
  bool get limitReached =>
      warnings.any((w) => w.startsWith(snapshotLimitWarningPrefix));
  String get fingerprint {
    final paths = files.keys.toList()..sort();
    return digest(paths.map((p) => '$p:${digest(files[p]!)}').join('\n'));
  }
}

class HubRecord {
  final String id, sourceId, path, title, body, kind, origin, source;
  final DateTime? at, receivedAt, generatedAt;
  String status;
  final List<String> warnings, references;
  final Map<String, Object?> metadata;
  HubRecord({
    required this.sourceId,
    required this.path,
    required this.title,
    required this.body,
    required this.kind,
    required this.origin,
    required this.source,
    this.at,
    this.receivedAt,
    this.generatedAt,
    this.status = 'waiting',
    List<String>? warnings,
    List<String>? references,
    this.metadata = const {},
  }) : id = recordId(path),
       warnings = warnings ?? [],
       references = references ?? [];
}

class NowEntry {
  String text;
  final List<String> references = [], warnings = [];

  /// 本体のNOW項目一覧（90_system/now-items）と照合できた項目のキー。完了・解決の報告に使う。
  String? itemKey;

  /// 出典を外す前の行（先頭の「- 」だけを除く）。項目一覧との照合に使う。
  final String raw;
  NowEntry(this.text, {this.raw = ''});
}

/// 本体のitem-resolutionsと同じ、項目を「誤り」として外す理由。
const exclusionReasons = ['misread', 'wrong-project', 'outdated'];
const exclusionReasonLabels = {
  'misread': '読み違い',
  'wrong-project': '別のプロジェクトの話',
  'outdated': 'もう古い',
};

/// 誤りとして外すときの一言の上限（本体のEXCLUSION_NOTE_CHARSと同じ）。
const exclusionNoteChars = 200;

/// 一言が本体の検査（1〜200文字・1行・制御文字なし・前後の空白なし）を通るか。
bool validExclusionNote(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= exclusionNoteChars &&
    value.trim() == value &&
    !RegExp(r'\p{Cc}', unicode: true).hasMatch(value);

/// 本体がNOWと同時に書く項目一覧の1件。完了・解決、または誤りとして外した項目はresolutionIdを持つ。
class NowItemRef {
  NowItemRef({
    required this.key,
    required this.section,
    required this.label,
    required this.text,
    required this.inputId,
    this.resolutionId,
    this.resolvedAt,
    this.exclusionReason,
    this.exclusionNote,
    this.scheduleId,
    this.due,
    this.reviewAfter,
    this.repeat,
    this.hints = const [],
    this.action = false,
    this.fromInputId,
    this.fromText,
    this.fromKey,
  });
  final String key, section, label, text, inputId;

  /// 本人が直接追加した行動（本体の入力の種類action）。AIの読み取りではない。
  final bool action;

  /// AIが読み取った行を行動にしたときの、元の行の根拠の入力ID・直す前の本文・項目キー（キー付きの項目だったときだけ）。
  final String? fromInputId, fromText, fromKey;
  final String? resolutionId;
  final DateTime? resolvedAt;

  /// 本人が「誤り」として外した理由（[exclusionReasons]）と一言。完了・解決した項目ではnull。
  final String? exclusionReason, exclusionNote;

  /// 本人が付けた期日・次に見直す日（YYYY-MM-DD）。古い本体や日付のない項目ではnull。
  final String? scheduleId, due, reviewAfter;

  /// 期日の繰り返し（定例）。繰り返さない項目や、繰り返しを知らない本体ではnull。期日があるときだけ付く。
  final RepeatRule? repeat;

  /// 定例の今の回（期日）を片付けられる。
  bool get repeating => repeat != null && due != null && !resolved;

  /// 本人がプロジェクトを指定したメモから、本体の整理でAIが「片付いたかも」と示したもの。未確認で、完了・解決ではない。
  final List<NowItemHint> hints;

  /// 欄から外れている（完了・解決した、または誤りとして外した）。
  bool get resolved => resolutionId != null;

  /// 完了・解決ではなく、誤りとして外した。
  bool get excluded => resolutionId != null && exclusionReason != null;
  bool get scheduled => due != null || reviewAfter != null;

  /// 本体のNOWの行と同じ表示文（views.tsのplainと同じ置換）。
  String get display =>
      '$label${text.replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll('<!--', '&lt;!--')}';
}

/// 本体と同じ、本人が追加する行動の文面の上限（UTF-16の単位で数える）。
const actionTextChars = 200;

/// 行動の文面が本体の検査（1〜200文字・1行・制御文字と行区切り・段落区切り・文字の向きを変える制御なし・前後の空白なし）を通るか。
bool validActionText(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= actionTextChars &&
    value.trim() == value &&
    !RegExp(
      r'[\p{Cc}\p{Zl}\p{Zp}\u202A-\u202E\u2066-\u2069]',
      unicode: true,
    ).hasMatch(value);

/// 本体のNOWで、本人が追加した行動に付くラベル。
const actionLabel = '本人が追加: ';

/// AIが読み取った行（NOWの提案・作業要約の次の一手）を行動にするときの、元の行。
class ActionSource {
  const ActionSource({required this.inputId, required this.text, this.key});
  final String inputId, text;

  /// 元の行がNOWの項目（キー付き）だったときの項目キー。
  final String? key;
}

/// 本人が追加を依頼し、まだNOWの項目一覧に載っていない行動（端末に保存した依頼・Miniが受け付けた依頼）。
class PendingAction {
  const PendingAction({
    required this.requestId,
    required this.projectId,
    required this.text,
    required this.state,
    this.from,
  });
  final String requestId, projectId, text, state;
  final ActionSource? from;
}

/// 「片付いたかも」の根拠。メモのIDと、メモの原文からの引用。
class NowItemHint {
  const NowItemHint({required this.inputId, required this.quote, this.at});
  final String inputId, quote;
  final DateTime? at;
}

/// 本体の`ctx backup verify`が残した、バックアップから復元できるかの確認結果の1件。
class BackupCheck {
  const BackupCheck({
    required this.id,
    required this.archive,
    required this.archiveCreatedAt,
    required this.checkedAt,
    required this.ok,
    required this.issueCount,
    required this.maxAgeDays,
    this.encrypted = false,
  });
  final String id, archive;

  /// ageで暗号化したバックアップ（.tar.gz.age）を復号して確かめた。
  final bool encrypted;
  final DateTime archiveCreatedAt, checkedAt;
  final bool ok;
  final int issueCount;

  /// 確認したときの本体の目安（backup.verifyMaxAgeDays）。
  final int maxAgeDays;
}

/// 「最後に確かめた復元点」。本体のbackupStatus・backupHomeLineと同じ決め方で表示する。
class BackupStatus {
  const BackupStatus({this.latest, this.restorePoint});

  /// 最後の確認と、確かめた復元点（復元できた確認のうち、いちばん新しいバックアップ）。確認がなければnull。
  final BackupCheck? latest, restorePoint;

  /// 本体のrestorePointOfと同じく、復元できたいちばん新しいバックアップ（同じなら後の確認）を復元点にする。
  /// 古いアーカイブを後から確かめても、復元点は古くならない。[checks]は確認した順。
  factory BackupStatus.of(List<BackupCheck> checks) {
    BackupCheck? point;
    for (final c in checks) {
      if (c.ok &&
          (point == null ||
              !c.archiveCreatedAt.isBefore(point.archiveCreatedAt))) {
        point = c;
      }
    }
    return BackupStatus(latest: checks.lastOrNull, restorePoint: point);
  }
  bool get isEmpty => latest == null;
  static int _days(DateTime from, DateTime now) {
    final d = now.toUtc().difference(from.toUtc()).inDays;
    return d < 0 ? 0 : d;
  }

  /// 復元点が何日前のバックアップか。
  int? ageDays(DateTime now) =>
      restorePoint == null ? null : _days(restorePoint!.archiveCreatedAt, now);

  /// ホームに出す1行。復元できた確認がなければnull。
  String? line(DateTime now) {
    final point = restorePoint;
    if (point == null) return null;
    final checked = _days(point.checkedAt, now);
    final t = point.archiveCreatedAt.toUtc().add(const Duration(hours: 9));
    String two(int n) => n.toString().padLeft(2, '0');
    return '最後に確かめた復元点: ${hubToday(point.archiveCreatedAt)} ${two(t.hour)}:${two(t.minute)}の${point.encrypted ? '暗号化した' : ''}バックアップ（${ageDays(now)}日前 / ${checked == 0 ? '今日' : '$checked日前に'}復元できることを確認）';
  }

  /// 本人に知らせる注意。最後の確認が失敗した、または復元点が目安より古い。
  List<String> warnings(DateTime now) {
    final last = latest, point = restorePoint;
    if (last == null) return const [];
    return [
      if (!last.ok)
        '最後の確認でバックアップ（${last.archive}）から復元できませんでした（${last.issueCount}件の問題）。Miniで`ctx backup status`の内容を確かめ、バックアップを取り直してください。',
      if (point != null && ageDays(now)! > last.maxAgeDays)
        '確かめた復元点が${ageDays(now)}日前のバックアップです（目安は${last.maxAgeDays}日以内）。バックアップが続いているかを確認し、Miniで`ctx backup verify`を実行してください。',
    ];
  }
}

/// 本人が設定したリポジトリのコミット履歴から本体が作った、作業記録の下書き。
class GitDraft {
  GitDraft({
    required this.id,
    required this.projectId,
    required this.repo,
    required this.text,
    required this.hash,
    required this.commitCount,
    this.createdAt,
  });
  final String id, projectId, repo, text, hash;
  final int commitCount;
  final DateTime? createdAt;
}

/// 本体のproject-mergesと同じ操作。
const projectMergeActions = ['merge', 'unmerge'];

/// 本体のproject-statusと同じ状態。旧版の自由記述は進行中として扱う。
const projectLifecycles = ['active', 'paused', 'done'];
const projectLifecycleLabels = {'active': '進行中', 'paused': '休止', 'done': '完了'};

/// 本体のretrieve.staleDaysの既定値。HOMEの停滞表示と同じ日数で判断する。
const projectStaleDays = 14;

class HubProject {
  final String id, title, status;
  final List<String> aliases, keywords;

  /// 本人が確認したproject.mdのhash。状態変更の依頼に結び付ける。
  final String? definitionHash;
  String? nowRecordId;
  DateTime? generatedAt, lastEvidenceAt;
  String notes = '';
  final Map<String, List<NowEntry>> sections = {
    'current': [],
    'next': [],
    'open': [],
    'proposals': [],
  };
  final List<String> warnings = ['AIによる整理・自己報告を含む、未検証の要約です。'], references = [];

  /// 本体が生成するプロジェクトの経緯（HISTORY.md）。古い本体や未生成ならnull。
  HubDigest? history;

  /// 本体が生成するプロジェクトの資料（REFERENCES.md）。参考資料に分類されたメモとURLの一覧。
  /// 古い本体や、資料のないプロジェクトではnull。
  HubDigest? shelf;

  /// project.mdに書かれた統合先（`merged_into`）。統合されていなければnull。
  final String? mergedInto;

  /// 統合先をたどった最後のプロジェクトID。統合されていない、または統合先が見つからない・循環している場合はnull。
  /// 統合済みのプロジェクトの入力・完了報告・日付は、このプロジェクトのものとして読む（本体と同じ）。
  String? mergeTarget;
  bool get merged => mergeTarget != null;

  /// 本体のNOW項目一覧。古い本体では空。
  final List<NowItemRef> nowItems = [];
  DateTime? nowItemsGeneratedAt;
  Iterable<NowItemRef> get resolvedItems =>
      nowItems.where((i) => i.resolved && !i.excluded);

  /// 本人が「誤り」として外した項目。完了・解決には数えない。
  Iterable<NowItemRef> get excludedItems => nowItems.where((i) => i.excluded);

  /// 出典の付いた行だけ。本体が空の欄に書く定型文（「不明（…）」「残っている次の一手はありません（…）」）を除く。
  List<NowEntry> entriesWithSource(String section) =>
      sections[section]!.where((e) => e.references.isNotEmpty).toList();

  /// 本人が追加を依頼し、まだNOWの項目一覧に載っていない行動。
  final List<PendingAction> pendingActions = [];

  /// 次の一手の件数（出典の付いた行と、反映待ちの行動）。
  int get nextCount => entriesWithSource('next').length + pendingActions.length;

  /// 確認待ちの作業記録の下書き。
  final List<GitDraft> drafts = [];

  /// NOWの自動領域が手で書き換えられ、本体が新版を退避している（更新が止まっている）状態。なければnull。
  NowConflict? nowConflict;
  HubProject({
    required this.id,
    required this.title,
    this.status = 'active',
    this.aliases = const [],
    this.keywords = const [],
    this.definitionHash,
    this.mergedInto,
  });
  String get lifecycle =>
      status == 'paused' || status == 'done' ? status : 'active';
  String get lifecycleLabel => projectLifecycleLabels[lifecycle]!;

  /// 進行中として扱うか。統合済みのプロジェクトは、状態が進行中のままでも統合先に含めて扱うので数えない（本体と同じ）。
  bool get active => lifecycle == 'active' && mergeTarget == null;

  /// 最終根拠からの経過日数。NOWが未生成なら不明。
  int? daysSinceEvidence(DateTime now) {
    final at = lastEvidenceAt;
    if (at == null) return null;
    final days = now.difference(at).inDays;
    return days < 0 ? 0 : days;
  }

  bool stale(DateTime now) =>
      active &&
      lastEvidenceAt != null &&
      now.difference(lastEvidenceAt!) > const Duration(days: projectStaleDays);
}

/// 期日・見直す日に使う暦日（YYYY-MM-DD）。本体と同じく2000〜2099年の実在する日だけ。
final scheduleDatePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
bool validScheduleDate(Object? value) {
  if (value is! String) return false;
  final m = scheduleDatePattern.firstMatch(value);
  if (m == null) return false;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (y < 2000 || y > 2099) return false;
  final date = DateTime.utc(y, mo, d);
  return date.year == y && date.month == mo && date.day == d;
}

/// 定例の繰り返し（本体の`repeat`）。期日をunitのevery個分ずつ進める。
class RepeatRule {
  const RepeatRule(this.unit, this.every);
  final String unit;
  final int every;
  static const units = ['day', 'week', 'month'];

  /// 繰り返しの間隔の上限（本体のREPEAT_EVERY_MAXと同じ）。
  static const maxEvery = 12;

  /// 日付の画面で選べる繰り返し。
  static const choices = [
    RepeatRule('day', 1),
    RepeatRule('week', 1),
    RepeatRule('week', 2),
    RepeatRule('month', 1),
    RepeatRule('month', 3),
  ];

  /// 本体のrepeatLabelと同じ表示（毎日・毎週・毎月・N日ごと・N週ごと・Nか月ごと）。
  String get label => every == 1
      ? const {'day': '毎日', 'week': '毎週', 'month': '毎月'}[unit]!
      : '$every${const {'day': '日', 'week': '週', 'month': 'か月'}[unit]}ごと';

  Map<String, Object> toJson() => {'unit': unit, 'every': every};

  /// 本体の記録のrepeat（{unit, every, day?}）。形式が合わなければFormatException。
  static RepeatRule parse(Object? value) {
    if (value is! Map ||
        !units.contains(value['unit']) ||
        value['every'] is! int ||
        (value['every'] as int) < 1 ||
        (value['every'] as int) > maxEvery ||
        value.keys.any((k) => !const ['unit', 'every', 'day'].contains(k)) ||
        (value['day'] != null &&
            (value['day'] is! int ||
                (value['day'] as int) < 1 ||
                (value['day'] as int) > 31))) {
      throw const FormatException();
    }
    return RepeatRule(value['unit'] as String, value['every'] as int);
  }

  @override
  bool operator ==(Object other) =>
      other is RepeatRule && other.unit == unit && other.every == every;
  @override
  int get hashCode => Object.hash(unit, every);
}

/// 定例の今の回を片付ける操作。done: 今回を完了 / skip: 今回は見送る。
const occurrenceActions = ['done', 'skip'];
const occurrenceActionLabels = {'done': '今回を完了', 'skip': '今回は見送る'};

/// 「記録に聞く」の答えの状態（本体のaskStatuses）。
const askStatusLabels = {
  'pending': '答え待ち',
  'answered': '答えあり',
  'not-found': '記録に見当たりませんでした',
  'unsupported': '根拠を確かめられる答えがありませんでした',
  'no-sources': '問いに近い記録がありませんでした',
  'failed': '答えを作れませんでした',
};

/// 答えを作れなかった（failed）理由のうち、本人が対処できるもの（本体のASK_ERROR_KINDS）。
const askFailureLabels = {
  'project-missing': '選んだプロジェクトが見つからなくなりました。選び直して聞き直してください',
};

/// 答えの状態の表示。答えを作れなかったときは、本人が対処できる理由を添える。
String askAnswerStatus(AskAnswer answer) {
  final label = askStatusLabels[answer.status] ?? answer.status,
      reason = answer.status == 'failed'
          ? askFailureLabels[answer.error]
          : null;
  return reason == null ? label : '$label（$reason）';
}

/// 本体の設定で「記録に聞く」が無効の間、受け付け済みの問いに示す状態。本体は有効に戻すと答える。
const askDisabledWaiting = '答え待ち（本体で「記録に聞く」が無効になっています。有効に戻すと答えます）';

/// 答えの文と、その根拠（記録のIDと、記録からそのまま写した引用）。
class AskSentence {
  const AskSentence(this.text, this.evidence);
  final String text;
  final List<({String inputId, String quote})> evidence;
}

/// 本体が`90_system/answers/ASK-*.json`に書く、問いと答え。答えはAI生成・未検証。
class AskAnswer {
  const AskAnswer({
    required this.id,
    required this.status,
    required this.question,
    required this.askedAt,
    this.project,
    this.requestId,
    this.answeredAt,
    this.sentences = const [],
    this.candidates = const [],
    this.dropped = 0,
    this.error,
  });
  final String id, status, question;
  final String? project, requestId, error;
  final DateTime askedAt;
  final DateTime? answeredAt;
  final List<AskSentence> sentences;

  /// 根拠の候補としてモデルへ渡した記録のID（問いに近い順）。
  final List<String> candidates;
  final int dropped;
  bool get pending => status == 'pending';
}

/// 日時の年月日をそのまま暦日（YYYY-MM-DD）にする。
String scheduleDate(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// 本体と同じ「今日」。本体の設定はタイムゾーンをAsia/Tokyo（UTC+9、夏時間なし）に固定しているため、
/// 端末のタイムゾーンに関わらず日本時間の暦日で決める。
String hubToday([DateTime? now]) =>
    scheduleDate((now ?? DateTime.now()).toUtc().add(const Duration(hours: 9)));
String addScheduleDays(String date, int days) {
  final m = scheduleDatePattern.firstMatch(date)!;
  return scheduleDate(
    DateTime.utc(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
    ).add(Duration(days: days)),
  );
}

/// 本体のHOMEと同じ区分。期日が今日〜6日後までなら「7日以内」。見直す日が先の項目は、期日が近くなければたたむ。
enum ScheduleBucket { overdue, today, week, later, none }

const scheduleBucketLabels = {
  ScheduleBucket.overdue: '期限切れ',
  ScheduleBucket.today: '今日',
  ScheduleBucket.week: '7日以内',
};
({ScheduleBucket bucket, bool hidden}) scheduleBucket(
  String? due,
  String? reviewAfter,
  String today,
) {
  final weekEnd = addScheduleDays(today, 6);
  final bucket = due == null
      ? ScheduleBucket.none
      : due.compareTo(today) < 0
      ? ScheduleBucket.overdue
      : due == today
      ? ScheduleBucket.today
      : due.compareTo(weekEnd) <= 0
      ? ScheduleBucket.week
      : ScheduleBucket.later;
  final hidden =
      reviewAfter != null &&
      reviewAfter.compareTo(today) > 0 &&
      (bucket == ScheduleBucket.none || bucket == ScheduleBucket.later);
  return (bucket: bucket, hidden: hidden);
}

class HubDigest {
  HubDigest({required this.body, this.generatedAt, this.periodDays});
  final String body;
  final DateTime? generatedAt;
  final int? periodDays;
  final List<String> warnings = ['集計は本体の記録から作られ、要約はAI生成・未検証です。'];
}

class IntakeStatus {
  final String id, path, title;
  final DateTime? at;
  String state, detail;
  IntakeStatus({
    required this.id,
    required this.path,
    required this.title,
    this.at,
    this.state = 'waiting',
    this.detail = '',
  });
}

/// 「記録に聞く」の問いの上限（本体のASK_QUESTION_CHARSと同じ）。
const askQuestionChars = 500;

/// 本体が答えた記録を残す日数（本体のASK_RETENTION_DAYSと同じ）。
const askRetentionDays = 30;

/// 「記録に聞く」の1件。この端末から送った問いは受付の状況（[request]）を持ち、答えが届けば[answer]を持つ。
class AskThread {
  const AskThread({
    required this.question,
    required this.at,
    this.project,
    this.request,
    this.answer,
  });
  final String question;
  final String? project;
  final DateTime at;
  final IntakeStatus? request;
  final AskAnswer? answer;
}

/// 検索の種類。本体の `ctx find --kind` と同じ名前。
/// referenceは記録の種類ではなく、整理でAIが参考資料に分類したメモ・作業要約（訂正を含む）に当たる。
const searchKinds = [
  'memo',
  'work-summary',
  'action',
  'correction',
  'idea',
  'knowledge',
  'now',
  'reference',
];
const searchKindLabels = {
  'memo': 'メモ',
  'work-summary': '作業要約',
  'action': '行動',
  'correction': '訂正',
  'idea': 'アイデア',
  'knowledge': '知識',
  'now': 'NOW',
  'reference': '資料',
};

/// 検索の絞り込み条件。本体の `ctx find` の --project・--kind・--since・--until・--sort に対応する。
class SearchFilter {
  const SearchFilter({
    this.project,
    this.kinds = const {},
    this.since,
    this.until,
    this.sort = 'relevance',
  });
  final String? project;
  final Set<String> kinds;
  final DateTime? since, until;

  /// relevance（一致数の多い順）またはnewest（新しい順）。検索語がなければ新しい順。
  final String sort;
  bool get active =>
      project != null || kinds.isNotEmpty || since != null || until != null;
}

/// 手で書き換えたため更新が止まったNOW。本体の`conflict-resolve`で生成版に戻せる。
class NowConflict {
  /// 本体が退避した最新の生成版（`90_system/conflicts/NOW.<id>.<ULID>.md`）。
  final String latestPath;

  /// 退避の件数。旧版の本体は再生成のたびに1件ずつ増やす。
  final int count;

  /// 確認時点のNOW.mdのhash。依頼に結び付ける。
  final String nowHash;

  /// 手で変えた（最後に書いた生成版にない）行。
  final List<String> manualLines;

  /// 手で変える前の生成版と比べたか。falseは基準がなく最新の退避と比べた結果。
  final bool comparedWithGenerated;
  const NowConflict({
    required this.latestPath,
    required this.count,
    required this.nowHash,
    required this.manualLines,
    required this.comparedWithGenerated,
  });
}

/// 本人が依頼し、まだプロジェクト定義が届いていない新しいプロジェクト。
class PendingProjectCreation {
  final String requestId, projectId, title;
  final String state;
  const PendingProjectCreation({
    required this.requestId,
    required this.projectId,
    required this.title,
    required this.state,
  });
}

/// 本体のproject-createと同じ形式のID（`project-` + 小文字のULID）。
final newProjectIdPattern = RegExp(r'^project-[0-9a-hjkmnp-tv-z]{26}$');

/// 本体のconflict-resolveで戻せるNOWの対象パス。
String nowTargetPath(String projectId) => '10_projects/$projectId/NOW.md';

/// 現在の内容のうち、基準の生成版にない行（前後の空白を除き、重複は1つにする）。本体のmanualLinesと同じ。
List<String> manualLinesOf(String current, String generated) {
  final known = generated.split(RegExp(r'\r?\n')).map((l) => l.trim()).toSet();
  final seen = <String>{};
  return [
    for (final line in current.split(RegExp(r'\r?\n')).map((l) => l.trim()))
      if (line.isNotEmpty && !known.contains(line) && seen.add(line)) line,
  ];
}

const _crockford = '0123456789abcdefghjkmnpqrstvwxyz';

/// 新しいプロジェクトのID。本体のプロジェクト案の採用と同じ`project-` + 小文字のULID。
String newProjectId([DateTime? now, Random? random]) {
  final rng = random ?? Random.secure();
  var time = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final chars = List.filled(26, '0');
  for (var i = 9; i >= 0; i--) {
    chars[i] = _crockford[time % 32];
    time ~/= 32;
  }
  for (var i = 10; i < 26; i++) {
    chars[i] = _crockford[rng.nextInt(32)];
  }
  return 'project-${chars.join()}';
}

/// 名前の重なりの判定に使う正規化（本体と同じNFKC・前後の空白除去・小文字化）。
String normalizeProjectName(String value) =>
    unicode.nfkc(value).trim().toLowerCase();

/// 本人が入力した新しいプロジェクトの内容。本体のproject-createに送る。
class NewProjectRequest {
  final String operationId, projectId, title, firstMemo;
  final List<String> aliases, keywords;
  const NewProjectRequest({
    required this.operationId,
    required this.projectId,
    required this.title,
    this.aliases = const [],
    this.keywords = const [],
    this.firstMemo = '',
  });

  /// カンマ・読点・改行区切りの入力を、前後の空白を除いた重複のない一覧にする。
  static List<String> splitNames(String value) {
    final seen = <String>{};
    return [
      for (final name in value.split(RegExp(r'[,、，\r\n]')).map((s) => s.trim()))
        if (name.isNotEmpty && seen.add(name)) name,
    ];
  }

  /// 本体の受付形式に合わない内容の理由。問題なければnull。
  String? get formatError {
    bool bad(String s, int max) =>
        s.isEmpty ||
        s.length > max ||
        s.trim() != s ||
        s.contains(RegExp(r'[\r\n]'));
    if (!newProjectIdPattern.hasMatch(projectId)) return 'プロジェクトIDが不正です。';
    if (bad(title, 200)) return '名前は1〜200文字で入力してください。';
    if (aliases.length > 50 || aliases.any((a) => bad(a, 100))) {
      return '別名は50件まで、それぞれ100文字までで入力してください。';
    }
    if (keywords.length > 50 || keywords.any((k) => bad(k, 100))) {
      return 'キーワードは50件まで、それぞれ100文字までで入力してください。';
    }
    if (firstMemo.length > 8000 || utf8.encode(firstMemo).length > 32000) {
      return '最初のメモは8000文字までで入力してください。';
    }
    // 本体が読む受付ファイルの上限（本文の上限×4+8192バイト）。受付ID・出典・日時の分を見込んで判定する。
    final header = {
      'schema_version': 1,
      'request_id': 'REQ-${'0' * 32}',
      'source': 'flutter-client/${'0' * 36}',
      'occurred_at': '0000-00-00T00:00:00.000000Z',
      ...fields,
    };
    if (utf8.encode('---\n${jsonEncode(header)}\n---\n$firstMemo').length >
        40192) {
      return '名前・別名・キーワードと最初のメモを合わせた量が多すぎます。減らしてください。';
    }
    return null;
  }

  /// 受付ファイルの項目。本文は最初のメモ。
  Map<String, dynamic> get fields => {
    'operation': 'project-create',
    'project_id': projectId,
    'title': title,
    'aliases': aliases,
    'keywords': keywords,
    'confirmed': true,
  };

  /// 名前・別名が、既存のプロジェクトや作成依頼中のプロジェクトと重なる場合の理由。
  /// 既存プロジェクトとの判定は本体（NFKC・小文字化）に合わせ、作成依頼中のものは名前だけを見る。
  String? overlapError(
    Iterable<HubProject> projects,
    Iterable<PendingProjectCreation> pending,
  ) {
    final wanted = {
      for (final n in [title, ...aliases]) normalizeProjectName(n),
    }..remove('');
    for (final p in projects) {
      final hit = [p.id, p.title, ...p.aliases].firstWhere(
        (n) => wanted.contains(normalizeProjectName(n)),
        orElse: () => '',
      );
      if (hit.isNotEmpty) {
        return '「$hit」は既存のプロジェクト「${p.title}」の名前・別名と重なります。既存のプロジェクトを使うか、名前を変えてください。';
      }
    }
    for (final p in pending) {
      if (p.projectId == projectId) return 'このプロジェクトは作成を依頼済みです。受付状況を確認してください。';
      if (wanted.contains(normalizeProjectName(p.title))) {
        return '「${p.title}」は作成を依頼済みです。受付状況を確認してください。';
      }
    }
    return null;
  }
}

/// 本体が書く、どのプロジェクトにも結び付いていないメモのタスク候補とAIの提案
/// （90_system/unassigned-actions.json）。表示だけで、完了の報告や期日の対象にはならない。
class UnassignedMemo {
  const UnassignedMemo({
    required this.inputId,
    required this.at,
    required this.text,
    required this.ownWords,
    required this.task,
    required this.suggestions,
  });

  /// 元のメモ。
  final String inputId;
  final DateTime at;

  /// 訂正のない短いメモは本人の言葉、それ以外はAIの一行要約（未検証）。
  final String text;

  /// [text]が本人の言葉か。falseならAIの一行要約（未検証）。
  final bool ownWords;

  /// AIが「タスク」と分類したメモか（未検証）。
  final bool task;

  /// AIが挙げた次の一手の提案（未検証）。
  final List<String> suggestions;
}

/// 本体が書く「今週の気づき」（90_system/insights.json）。週次の統合で、たまったメモをAIがまとめて
/// 読み直した結果のうち、最後に成功した回のもの。AI生成・未検証で、表示だけに使う。
class Insights {
  const Insights({
    required this.runId,
    required this.generatedAt,
    this.feedback = false,
    required this.intervalDays,
    required this.createdAt,
    required this.mode,
    required this.items,
    required this.waiting,
    required this.failure,
    required this.recordProblems,
  });

  /// 最後に成功した実行のID（SYN-…）。反応と答えを結び付けるときに使う。まだ成功していなければnull。
  final String? runId;

  /// 本体がこの一覧を書いた日時。反応の依頼が一覧に反映されたかの判定に使う。
  final DateTime generatedAt;

  /// 本体が反応と答えに対応しているか（対応した本体は、すべての項目に`reaction`と`answers`を書く）。
  /// 対応前の本体には反応の依頼が届かず、答えも項目に結び付かないので、反応と「答える」を出さない。
  final bool feedback;

  /// 本体が自動で実行する間隔（日）。これより古い結果には、何日前のものかを添える。
  final int intervalDays;

  /// 最後に成功した実行の日時。まだ成功していなければnull。
  final DateTime? createdAt;

  /// 最後に成功した実行の種類（first・weekly・quiet）。quietは、新しいメモが少なく以前のメモを見直した回。
  final String? mode;

  /// 根拠のメモがすべてこの端末に届いている項目（本体の並び順）。
  final List<InsightItem> items;

  /// 根拠のメモが届いていないため、まだ載せていない項目の数。
  final int waiting;

  /// 最後の実行が失敗しているときの理由（表示用）。失敗していなければnull。
  final String? failure;

  /// 本体が読めない実行の記録の件数。1件でもあると、本体は自動で実行しない。
  final int recordProblems;

  /// 最後に成功した実行からの日数（24時間単位）。
  int? ageDays(DateTime now) {
    final at = createdAt;
    if (at == null) return null;
    final days = now.difference(at).inDays;
    return days < 0 ? 0 : days;
  }

  /// 間隔を過ぎても新しい結果が届いていないか。
  bool stale(DateTime now) => (ageDays(now) ?? 0) > intervalDays;
}

/// 今週の気づきの1件。
class InsightItem {
  const InsightItem({
    required this.key,
    required this.section,
    required this.text,
    required this.firstStep,
    required this.sources,
    this.reaction,
    this.answers = const [],
  });

  /// 項目のキー（本体が決める）。
  final String key;

  /// 欄（[insightSectionLabels]のキー）。
  final String section;

  /// AIが書いた本文（未検証）。
  final String text;

  /// 止まっている意図の、最初の一歩（未検証）。なければnull。
  final String? firstStep;

  /// 根拠のメモ。
  final List<InsightSource> sources;

  /// 本体に記録された本人の反応（[insightReactionLabels]のキー）。反応がなければnull。
  final String? reaction;

  /// この項目への答えのメモ（古い順）。
  final List<InsightAnswer> answers;
}

/// 今週の気づきの項目への答えのメモ。
class InsightAnswer {
  const InsightAnswer({required this.inputId, required this.at});
  final String inputId;
  final DateTime at;
}

/// 今週の気づきへの反応（本体の受付操作 insight-reaction）。noneは前の反応を外す依頼。
const insightReactions = ['useful', 'off-target', 'none'];
const insightReactionLabels = {'useful': '役に立った', 'off-target': '的外れ'};

/// 「答える」を出す欄。問いと、止まっている意図（「まだ調べますか」のように問いの形で書かれる）。
const insightAnswerSections = {'questions', 'stalled'};

/// 今週の気づきの項目に答えるときの対象。答えはふつうのメモとして保存し、どの気づきへの答えかをmetaで添える。
class InsightAnswerTarget {
  const InsightAnswerTarget({
    required this.runId,
    required this.itemKey,
    required this.question,
  });
  final String runId, itemKey;

  /// 答える問い（AIが書いた本文）。メモだけを読んでも何への答えか分かるよう、metaに残す。
  final String question;

  /// 本体が答えとして結び付けるmeta（本体のinsight-feedback.tsと同じキー）。
  Map<String, String> get meta => {
    'capture_mode': 'insight-answer',
    'insight_run': runId,
    'insight_key': itemKey,
    'insight_question': question.length > 2000
        ? question.substring(0, 2000)
        : question,
  };
}

/// 気づきの根拠のメモ。
class InsightSource {
  const InsightSource({
    required this.inputId,
    required this.at,
    required this.corrected,
  });
  final String inputId;
  final DateTime at;

  /// 気づきを作った後に、このメモへ訂正が届いたか。
  final bool corrected;
}

/// 今週の気づきの欄と見出し（表示順）。
const insightSectionLabels = {
  'connections': 'つながり',
  'shifts': '考えの変化',
  'stalled': '止まっている意図',
  'actions': '次の一手の提案',
  'questions': '問い',
};

/// 週次の統合が失敗した理由の表示。
const insightFailureLabels = {
  'invalid-output': '応答の形式が不正',
  'timeout': '応答待ちの時間切れ',
  'prompt-too-large': '送る内容が大きすぎる',
  'llm-error': 'モデルの呼び出しに失敗',
  'interrupted': '実行が途中で止まった',
};

/// 本体が書く、似ているアイデアの未確認の組（90_system/idea-index.json）。
class IdeaCandidate {
  const IdeaCandidate(this.a, this.b, this.score, this.hashA, this.hashB);

  /// アイデアID（IDEA-…）。昇順。
  final String a, b;
  final double score;

  /// 本体が索引を作ったときのIDEAファイルのhash。束ねる依頼はこれに結び付ける。
  final String hashA, hashB;
  String other(String id) => id == a ? b : a;
  bool has(String id) => id == a || id == b;
}

/// 本人が束ねたアイデア。[ideas]の先頭が代表（元のメモが最も新しいもの）。
class IdeaGroup {
  const IdeaGroup(this.representative, this.ideas, this.links);
  final String representative;
  final List<String> ideas;

  /// 束をつないでいる、本人が束ねた組（ideaPairKey）。束から外すにはこの組を別の話にする。
  final Set<String> links;
  bool linksDirectly(String a, String b) => links.contains(ideaPairKey(a, b));
}

/// 似ているアイデアの判断（束ねる・別の話）の依頼の対象。
String ideaPairKey(String a, String b) =>
    a.compareTo(b) < 0 ? '$a/$b' : '$b/$a';
const ideaLinkActions = ['link', 'separate'];
final ideaIdPattern = RegExp(r'^IDEA-[0-9A-HJKMNP-TV-Z]{26}$');

/// Miniでの受付・定義の同期を待っている、アプリからの人の登録依頼。
class PendingPersonAdd {
  PendingPersonAdd({
    required this.requestId,
    required this.personId,
    required this.name,
    required this.aliases,
    required this.state,
  });
  final String requestId, personId, name, state;
  final List<String> aliases;
}
