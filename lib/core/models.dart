import 'dart:convert';
import 'package:crypto/crypto.dart';

String digest(String value) => sha256.convert(utf8.encode(value)).toString();
String recordId(String path) => 'record-${digest(path).substring(0, 24)}';

class VaultSnapshot {
  final Map<String, String> files;
  final List<String> warnings;
  final bool recognized;
  final DateTime loadedAt;
  VaultSnapshot(
    this.files, {
    this.warnings = const [],
    this.recognized = true,
    DateTime? loadedAt,
  }) : loadedAt = loadedAt ?? DateTime.now();
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
  NowEntry(this.text);
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
  String get display => '$label$text'.replaceAll(RegExp(r'[\r\n]+'), ' ');
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
