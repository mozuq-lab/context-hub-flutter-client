import 'dart:convert';
import 'models.dart' show digest;
import 'repository.dart';

/// 本人の判断を待っているもの。確認待ちの候補、作業記録の下書き、手で書き換えて止まったNOW。
///
/// 似ているアイデアの組と「片付いたかも」は数が増えやすく急がないため、数えない。
class AttentionItem {
  AttentionItem(
    this.kind,
    String id,
    this.page, {
    Iterable<String> members = const [],
  }) : key = _keyOf(kind, id),
       memberKeys = [for (final member in members) _keyOf(kind, member)];
  static String _keyOf(String kind, String id) =>
      digest('$kind:$id').substring(0, 12);

  /// candidate（候補）・draft（下書き）・conflict（止まったNOW）。
  final String kind;

  /// 判断できる画面。`review` または `project:<id>`。
  final String page;

  /// 端末に残す既読の鍵。IDそのものではなく短いhashにして、設定ファイルの容量を抑える。
  final String key;

  /// この1件に含めて示しているもの（代表の案にまとめたプロジェクト案）の鍵。
  /// 代表の案がこの端末で読めなくなると、まとめた案は1件ずつ並ぶ。そのときに新着として
  /// 知らせ直さないよう、代表の案を画面で見たときに、まとめた案も見たものとして記録を残す。
  final List<String> memberKeys;
}

/// 通知と件数の表示に使う種類の順と呼び名。
const attentionKindLabels = {
  'candidate': '候補',
  'draft': '作業記録の下書き',
  'conflict': '止まったNOW',
};

/// 読込済みの記録から、判断待ちの一覧を作る。
///
/// この端末から依頼済みで反映を待っているものは、もう判断が済んでいるので数えない。
List<AttentionItem> attentionItems(HubRepository repo) {
  final items = <AttentionItem>[];
  // 同じ対象を指すプロジェクト案は、代表の案の1件として数える（一覧と同じ数え方）。
  for (final c in repo.review.pendingRows) {
    if (repo.review.requestIdFor(c.id) != null) continue;
    items.add(
      AttentionItem(
        'candidate',
        c.id,
        'review',
        members: [for (final m in repo.review.groupMembers(c)) m.id],
      ),
    );
  }
  for (final p in repo.orderedProjects) {
    for (final d in p.drafts) {
      if (repo.draftRequestIdFor(d.id) != null) continue;
      items.add(AttentionItem('draft', d.id, 'project:${p.id}'));
    }
    if (p.nowConflict != null && repo.conflictRequestIdFor(p.id) == null) {
      // 止まっている間に手で書き換え直しても、同じ判断待ちとして扱う（知らせ直さない）。
      items.add(AttentionItem('conflict', p.id, 'project:${p.id}'));
    }
  }
  return items;
}

/// 判断待ちが欠けずに読めているか。
///
/// 同期の途中や読取の失敗では、候補・下書き・NOWが一時的に見えなくなる。
/// そのときに「片付いた」と扱うと、同期が済んだ後で同じものを新着として知らせ直してしまう。
bool attentionComplete(HubRepository repo) =>
    repo.snapshot.recognized &&
    repo.warnings.isEmpty &&
    repo.review.warnings.isEmpty &&
    // 一覧では判断できる候補が、この端末では根拠の未同期などで操作できなくなっていないか。
    !repo.review.items.any(
      (c) => c.status == 'unavailable' && c.data['status'] != 'unavailable',
    );

/// 端末に残す鍵の上限。超える分は覚えず、新着として扱わない。
const attentionMaxKeys = 400;

/// 判断待ちの既読の記録。端末ごと・開いているVaultの分だけを持ち、Vaultには書かない。
///
/// 鍵ごとに、アプリの画面で見た（true）か、アプリを開いている間に件数として出ただけ（false）かを持つ。
class AttentionState {
  const AttentionState({
    this.identity,
    this.keys = const {},
    this.full = false,
  });

  /// 記録の対象のVault。別のVaultを開いたら記録を作り直す。
  final String? identity;
  final Map<String, bool> keys;

  /// 上限を超えて覚えきれなかった。覚えていない鍵は既読として扱う。
  final bool full;

  /// 判断できる画面を開いて見たか。
  bool seen(AttentionItem item) => keys[item.key] ?? full;

  /// アプリを開いている間に件数として出たか（通知が要らないか）。
  bool known(AttentionItem item) => full || keys.containsKey(item.key);

  /// まだ画面で見ていないもの。
  List<AttentionItem> fresh(Iterable<AttentionItem> items) =>
      items.where((i) => !seen(i)).toList();

  /// アプリを開いている間に一度も出ていないもの。通知の対象。
  List<AttentionItem> unknown(Iterable<AttentionItem> items) =>
      items.where((i) => !known(i)).toList();

  /// 読み込んだ判断待ちを記録へ反映する。
  ///
  /// 初めてのVaultでは、いまあるものをすべて既読にする（初回にすべてを新着にしない）。
  /// [visible]の画面にあるものは見たものとして既読にする。
  /// [prune]がfalse（判断待ちが欠けて見えているかもしれない）のときは、見つからない鍵を消さない。
  AttentionState sync(
    String identity,
    List<AttentionItem> items, {
    String? visible,
    bool prune = true,
  }) {
    final first = this.identity != identity;
    final current = <String, bool>{};
    for (final item in items) {
      final before = first ? true : seen(item);
      current[item.key] = before || item.page == visible;
    }
    // 1件に含めて示しているものは、その1件と一緒に件数として出たものとして覚える。
    // 既読にするのは、含めて示している1件を画面で見たときだけ（先に1件ずつ見ていたものは既読のまま）。
    // 代表の案を見た後で組に加わった案は、まだ見ていないので、1件ずつ並んだときに新着として示す。
    for (final item in items) {
      final shown = first || item.page == visible;
      for (final key in item.memberKeys) {
        current[key] = shown || (current[key] ?? keys[key] ?? false);
      }
    }
    if (current.length > attentionMaxKeys) {
      final kept = current.keys.toList()..sort();
      return AttentionState(
        identity: identity,
        keys: {for (final k in kept.take(attentionMaxKeys)) k: current[k]!},
        full: true,
      );
    }
    // いま見つからない鍵は、古い順に、上限に収まる分だけ残す。
    final stale = first || prune
        ? const <String>[]
        : keys.keys.where((k) => !current.containsKey(k)).toList();
    final room = attentionMaxKeys - current.length;
    return AttentionState(
      identity: identity,
      keys: {
        for (final k in stale.skip(
          stale.length > room ? stale.length - room : 0,
        ))
          k: keys[k]!,
        ...current,
      },
    );
  }

  /// [page]にある判断待ちを既読にする。
  AttentionState markSeen(String page, Iterable<AttentionItem> items) =>
      AttentionState(
        identity: identity,
        keys: {
          ...keys,
          for (final i in items)
            if (i.page == page)
              for (final key in [i.key, ...i.memberKeys])
                if (keys.containsKey(key)) key: true,
        },
        full: full,
      );

  Map<String, Object?> toJson() => {
    if (identity != null) 'vault': identity,
    'keys': {for (final e in keys.entries) e.key: e.value ? 1 : 0},
    if (full) 'full': true,
  };

  /// 読めない値は記録なしとして扱う。
  static AttentionState fromJson(Object? value) {
    if (value is! Map || value['vault'] is! String || value['keys'] is! Map) {
      return const AttentionState();
    }
    final keys = <String, bool>{};
    for (final e in (value['keys'] as Map).entries) {
      final k = e.key;
      if (k is! String || !RegExp(r'^[a-f0-9]{12}$').hasMatch(k)) continue;
      if (keys.length >= attentionMaxKeys) break;
      keys[k] = e.value == 1;
    }
    return AttentionState(
      identity: value['vault'] as String,
      keys: keys,
      full: value['full'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AttentionState &&
      other.identity == identity &&
      other.full == full &&
      other.keys.length == keys.length &&
      keys.entries.every((e) => other.keys[e.key] == e.value);
  @override
  int get hashCode => Object.hash(identity, full, keys.length);
}

/// 端末の設定ファイル（settings.json）の`attention`に残す内容。既読の記録と、通知を使うかどうか。
class AttentionSettings {
  const AttentionSettings(this.state, this.notify);
  final AttentionState state;

  /// アプリを閉じている間の確認待ちの通知を使う（Androidだけ）。
  final bool notify;

  Map<String, Object?> toJson() => {
    ...state.toJson(),
    if (notify) 'notify': true,
  };

  /// 読めない値は、記録なし・通知なしとして扱う。
  static AttentionSettings fromJson(Object? value) => AttentionSettings(
    AttentionState.fromJson(value),
    value is Map && value['notify'] == true,
  );
}

/// 端末の通知に出す内容。件数と種類だけで、候補やメモの本文は入れない。
class AttentionNotice {
  const AttentionNotice(this.key, this.title, this.text);

  /// 同じ内容を繰り返し通知しないための鍵。
  final String key;
  final String title, text;
}

/// 通知の文を作る。[items]はアプリを開いている間に出ていない判断待ち。空ならnull。
AttentionNotice? attentionNotice(List<AttentionItem> items) {
  if (items.isEmpty) return null;
  final keys = items.map((i) => i.key).toList()..sort();
  final parts = [
    for (final kind in attentionKindLabels.entries)
      if (items.where((i) => i.kind == kind.key).length case final n when n > 0)
        '${kind.value} $n件',
  ];
  return AttentionNotice(
    digest(jsonEncode(keys)).substring(0, 16),
    '確認待ちが${items.length}件増えています',
    '${parts.join(' · ')}（この端末に同期済みの内容）',
  );
}
