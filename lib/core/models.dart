import 'dart:convert';
import 'package:crypto/crypto.dart';

String digest(String value) => sha256.convert(utf8.encode(value)).toString();
String recordId(String path) => 'record-${digest(path).substring(0, 24)}';

/// アプリが使わない本体の記録。読取の件数と時間を抑えるため、ネイティブ側で数えず読まない。
/// 本体の受付・整理の回復用や、再送判定・表示完了の記録で、アプリのどの画面も参照しない。
const snapshotSkippedPaths = [
  '90_system/receipts/pending',
  '90_system/receipts/events',
  '90_system/intake/pending',
  '90_system/association-views',
  '90_system/project-confirmations',
  '90_system/project-approvals/materialized',
];

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

/// 本体がNOWと同時に書く項目一覧の1件。解決済みならresolutionIdを持つ。
class NowItemRef {
  NowItemRef({
    required this.key,
    required this.section,
    required this.label,
    required this.text,
    required this.inputId,
    this.resolutionId,
    this.resolvedAt,
  });
  final String key, section, label, text, inputId;
  final String? resolutionId;
  final DateTime? resolvedAt;
  bool get resolved => resolutionId != null;

  /// 本体のNOWの行と同じ表示文（views.tsのplainと同じ置換）。
  String get display =>
      '$label${text.replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll('<!--', '&lt;!--')}';
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

  /// 本体のNOW項目一覧。古い本体では空。
  final List<NowItemRef> nowItems = [];
  DateTime? nowItemsGeneratedAt;
  Iterable<NowItemRef> get resolvedItems => nowItems.where((i) => i.resolved);

  /// 出典の付いた行だけ。本体が空の欄に書く定型文（「不明（…）」「残っている次の一手はありません（…）」）を除く。
  List<NowEntry> entriesWithSource(String section) =>
      sections[section]!.where((e) => e.references.isNotEmpty).toList();

  /// 確認待ちの作業記録の下書き。
  final List<GitDraft> drafts = [];
  HubProject({
    required this.id,
    required this.title,
    this.status = 'active',
    this.aliases = const [],
    this.keywords = const [],
    this.definitionHash,
  });
  String get lifecycle =>
      status == 'paused' || status == 'done' ? status : 'active';
  String get lifecycleLabel => projectLifecycleLabels[lifecycle]!;

  /// 最終根拠からの経過日数。NOWが未生成なら不明。
  int? daysSinceEvidence(DateTime now) {
    final at = lastEvidenceAt;
    if (at == null) return null;
    final days = now.difference(at).inDays;
    return days < 0 ? 0 : days;
  }

  bool stale(DateTime now) =>
      lifecycle == 'active' &&
      lastEvidenceAt != null &&
      now.difference(lastEvidenceAt!) > const Duration(days: projectStaleDays);
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

/// 検索の種類。本体の `ctx find --kind` と同じ名前。
const searchKinds = [
  'memo',
  'work-summary',
  'correction',
  'idea',
  'knowledge',
  'now',
];
const searchKindLabels = {
  'memo': 'メモ',
  'work-summary': '作業要約',
  'correction': '訂正',
  'idea': 'アイデア',
  'knowledge': '知識',
  'now': 'NOW',
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
