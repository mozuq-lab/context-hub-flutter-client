import 'dart:isolate';
import 'dart:math' as math;
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'models.dart';
import 'repository.dart';

/// メモを書いている途中に示す、関係ありそうな過去の記録。
/// 端末内の記録だけを、AIを使わずに比べる（ネットワークにも送らない）。
class RelatedRecord {
  RelatedRecord({
    required this.root,
    required this.latest,
    required this.owner,
    required this.related,
    required this.score,
    required this.shared,
  });

  /// 元のメモ（開くとき・文脈かごに入れるときに使う）。
  final HubRecord root;

  /// 最新の本文（訂正があれば最新の訂正）。
  final HubRecord latest;

  /// 本人が指定したプロジェクト（統合先に読み替え済み）。
  final String? owner;

  /// AIが推定した関連先。
  final Set<String> related;

  /// 書いている本文の特徴のうち、この記録にも含まれる割合（0〜1）。
  final double score;

  /// 共通の特徴（抜粋の強調に使う。長い順）。
  final List<String> shared;
}

/// 書き始めの短い本文では出さない（本文の文字数。空白を除く）。
const relatedMinChars = 20;

/// 本文が、関係ありそうな記録を探す長さに届いているか（空白を除いた文字数）。
bool relatedDraftLongEnough(String draft) =>
    draft.replaceAll(RegExp(r'\s'), '').runes.length >= relatedMinChars;

/// 本文が長さに届き、比べられる特徴も[minShared]個以上あるか（ひらがなだけ・数字だけの本文は比べない）。
bool relatedSearchable(String draft, {int minShared = 3}) =>
    relatedDraftLongEnough(draft) &&
    relatedFeatures(draft).length >= minShared;

/// 1回に比べる記録の上限（新しい順）。超えた古い記録は比べない。
const relatedMaxScan = 3000;

/// 1件の記録から特徴を取り出す文字数（題名と本文の先頭）。長い作業要約で時間がかからないようにする。
const relatedMaxCharsPerRecord = 2000;

/// これより多い記録の特徴は、入力を止めないよう別のisolateで作る。
const relatedSyncLimit = 200;

/// 特徴の数がこれを超える長い記録は、長さに応じて点を下げる（どの本文とも重なりやすいため）。
const relatedLengthBase = 400;

/// 区切り（空白・記号）。ここで本文を切り、またいだ2文字は特徴にしない。
final _separators = RegExp(r'[\s\p{P}\p{S}]+', unicode: true);
final _asciiWord = RegExp(r'[a-z0-9][a-z0-9_\-.]*[a-z0-9]|[a-z0-9]');
final _digits = RegExp(r'^\d+$');

bool _isAsciiWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a);

/// ひらがなだけの2文字（「した」「ている」など）は、どの記録にも出てくるので特徴にしない。
bool _isHiragana(int c) => c >= 0x3041 && c <= 0x309F;

/// 英数字のよくある語。特徴にしない。
const _asciiStop = {
  'the', 'and', 'for', 'with', 'this', 'that', 'from', 'are', 'was', 'not', //
  'you', 'can', 'will', 'have', 'has', 'but', 'all', 'any', 'out', 'use', //
  'http', 'https', 'www', 'com', 'org', 'net', 'todo', 'memo', //
};

/// 本文の特徴。和文などは、記号・空白で区切った連なりの2文字ずつ（ひらがなだけの組は除く）、
/// 英数字は3文字以上の語（よくある語は除く）。NFKCで全角・半角をそろえ、小文字にしてから取り出す。
Set<String> relatedFeatures(String text) {
  final folded = unicode.nfkc(text).toLowerCase();
  final features = <String>{};
  for (final m in _asciiWord.allMatches(folded)) {
    final w = m.group(0)!;
    if (w.length >= 3 && !_asciiStop.contains(w) && !_digits.hasMatch(w)) {
      features.add(w);
    }
  }
  for (final segment in folded.split(_separators)) {
    final runes = segment.runes.toList();
    for (var i = 0; i + 1 < runes.length; i++) {
      final a = runes[i], b = runes[i + 1];
      if (_isAsciiWordChar(a) || _isAsciiWordChar(b)) continue;
      if (_isHiragana(a) && _isHiragana(b)) continue;
      features.add(String.fromCharCodes([a, b]));
    }
  }
  return features;
}

/// 比べる記録の特徴と、特徴ごとに含む記録の数（よくある特徴を軽く扱うため）。
class RelatedIndex {
  RelatedIndex(this.features, this.frequency);
  final List<Set<String>> features;
  final Map<String, int> frequency;
}

String _clip(String text) => text.length <= relatedMaxCharsPerRecord
    ? text
    : text.substring(0, relatedMaxCharsPerRecord);

RelatedIndex _buildIndex(List<String> texts) {
  final features = [for (final t in texts) relatedFeatures(t)];
  final frequency = <String, int>{};
  for (final set in features) {
    for (final f in set) {
      frequency[f] = (frequency[f] ?? 0) + 1;
    }
  }
  return RelatedIndex(features, frequency);
}

Future<RelatedIndex> _buildInIsolate(List<String> texts) =>
    Isolate.run(() => _buildIndex(texts));

List<String> _texts(HubRepository repo, int maxScan) => [
  for (final c in repo.relatedCandidates.take(maxScan))
    _clip('${c.latest.title}\n${c.latest.body}'),
];

final _cache = Expando<Future<RelatedIndex>>();

/// 読み込んだ記録の特徴。読み込みごとに1回だけ作る。記録が多いときは別のisolateで作り、入力を止めない。
Future<RelatedIndex> relatedIndex(
  HubRepository repo, {
  int maxScan = relatedMaxScan,
}) => _cache[repo] ??= () {
  final texts = _texts(repo, maxScan);
  return texts.length <= relatedSyncLimit
      ? Future.value(_buildIndex(texts))
      : _buildInIsolate(texts);
}();

/// 書いている本文と関係ありそうな記録を、近い順に[limit]件まで返す。
/// 本文の特徴を、多くの記録に出てくるものほど軽く数え、その[minScore]以上を含み、
/// 共通の特徴が[minShared]個以上ある記録だけを出す。長い記録は長さに応じて点を下げる。
/// [project]は書いているメモに指定したプロジェクト。同じプロジェクトの記録を少し優先する。
/// [index]がなければ、その場で作る（試験用。画面では[relatedIndex]を待ってから渡す）。
List<RelatedRecord> relatedRecords(
  HubRepository repo,
  String draft, {
  RelatedIndex? index,
  String? project,
  int limit = 3,
  double minScore = 0.3,
  int minShared = 3,
  int maxScan = relatedMaxScan,
}) {
  if (!relatedSearchable(draft, minShared: minShared)) return const [];
  final mine = relatedFeatures(draft);
  index ??= _buildIndex(_texts(repo, maxScan));
  final candidates = repo.relatedCandidates;
  final total = index.features.length;
  // どの記録にもない特徴は、1件にだけある特徴と同じ重さにする（本文にしかない語で点が下がりすぎないように）。
  double weight(String f) =>
      math.log((total + 1) / (math.max(index!.frequency[f] ?? 0, 1) + 1)) + 1;
  final mineWeight = mine.fold<double>(0, (sum, f) => sum + weight(f));
  final resolved = project == null ? null : repo.resolveProject(project);
  final hits = <(RelatedRecord, int)>[];
  for (var i = 0; i < total && i < candidates.length; i++) {
    final c = candidates[i], features = index.features[i];
    final shared = mine.where(features.contains).toList();
    if (shared.length < minShared) continue;
    var score =
        shared.fold<double>(0, (sum, f) => sum + weight(f)) / mineWeight;
    if (features.length > relatedLengthBase) {
      score *= math.sqrt(relatedLengthBase / features.length);
    }
    if (score < minScore) continue;
    // 同じプロジェクトの記録は、わずかに優先する（順位の入れ替わりだけで、出す・出さないは変えない）。
    if (resolved != null &&
        (c.owner == resolved || c.related.contains(resolved))) {
      score += 0.05;
    }
    shared.sort((a, b) => b.length.compareTo(a.length));
    hits.add((
      RelatedRecord(
        root: c.root,
        latest: c.latest,
        owner: c.owner,
        related: c.related,
        score: score,
        shared: shared,
      ),
      i,
    ));
  }
  // 近い順。同じなら新しい順（候補は新しい順に並んでいる）。
  hits.sort(
    (a, b) => b.$1.score != a.$1.score
        ? b.$1.score.compareTo(a.$1.score)
        : a.$2.compareTo(b.$2),
  );
  return [for (final h in hits.take(limit)) h.$1];
}
