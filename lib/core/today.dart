import 'models.dart';
import 'parser.dart' show clip;
import 'repository.dart';

/// 「今日の3つ」で選べる件数。
const todayMax = 3;

/// 続けて持ち越した日数がこれ以上になったら、大きすぎるかもしれないと添える。
const todayCarryNudge = 3;

/// 本人が今日やると選んだ、次の一手・未解決の1件。端末ごと・Vaultごとに保存し、Vaultには書かない。
///
/// 項目はプロジェクトIDとNOWの項目キーで指す。本文は、NOWから項目が見つからなくなったときに
/// 何を選んでいたかを示すためだけに短く残す。
class TodayPick {
  const TodayPick(this.projectId, this.itemKey, this.text, {this.carried = 0});
  final String projectId, itemKey, text;

  /// 前の日から続けて持ち越した日数。今日選んだばかりなら0。
  final int carried;

  static final _key = RegExp(r'^[a-f0-9]{64}$');
  static const _maxText = 80;

  TodayPick carry() =>
      TodayPick(projectId, itemKey, text, carried: carried + 1);

  Map<String, Object?> toJson() => {
    'p': projectId,
    'k': itemKey,
    't': text,
    if (carried > 0) 'n': carried,
  };

  /// 読めない値はnull（その1件だけを捨てる）。
  static TodayPick? fromJson(Object? value) {
    if (value is! Map) return null;
    final p = value['p'], k = value['k'], t = value['t'], n = value['n'];
    if (p is! String || p.isEmpty || p.length > 200) return null;
    if (k is! String || !_key.hasMatch(k)) return null;
    if (t is! String) return null;
    if (n != null && (n is! int || n < 0)) return null;
    return TodayPick(
      p,
      k,
      clip(t, _maxText),
      carried: n is int ? (n > 365 ? 365 : n) : 0,
    );
  }

  /// [item]を今日選ぶときの記録。
  factory TodayPick.of(HubProject project, NowItemRef item) =>
      TodayPick(project.id, item.key, clip(item.text.trim(), _maxText));
}

/// 「今日の3つ」の状態。[date]は選んだ日（日本時間の暦日。期日と同じ日付の決め方）。
///
/// 日付が変わると、選んでいた項目のうち片付いていないものを[carry]（持ち越しの確認）へ回し、
/// 本人が「今日も続ける・外す・期日を付ける」を選ぶまで残す。
class TodayFocus {
  const TodayFocus({this.date, this.picks = const [], this.carry = const []});
  final String? date;
  final List<TodayPick> picks, carry;

  bool get isEmpty => picks.isEmpty && carry.isEmpty;
  bool get full => picks.length >= todayMax;
  bool picked(String itemKey) => picks.any((p) => p.itemKey == itemKey);
  bool carried(String itemKey) => carry.any((p) => p.itemKey == itemKey);

  Map<String, Object?> toJson() => {
    if (date != null) 'date': date,
    'picks': [for (final p in picks) p.toJson()],
    if (carry.isNotEmpty) 'carry': [for (final p in carry) p.toJson()],
  };

  /// 読めない値は空として扱う。同じ項目は1回だけ、件数は上限までにする。
  static TodayFocus fromJson(Object? value) {
    if (value is! Map) return const TodayFocus();
    final date = value['date'];
    final seen = <String>{};
    List<TodayPick> list(Object? raw, int max) {
      final out = <TodayPick>[];
      if (raw is! List) return out;
      for (final v in raw) {
        if (out.length >= max) break;
        final p = TodayPick.fromJson(v);
        if (p != null && seen.add(p.itemKey)) out.add(p);
      }
      return out;
    }

    final picks = list(value['picks'], todayMax);
    // 持ち越しは前の日の3件と、まだ決めていない持ち越しだけなので、多くても数件。壊れた記録で増え続けないよう抑える。
    final carry = list(value['carry'], todayMax * 3);
    return TodayFocus(
      date: date is String && scheduleDatePattern.hasMatch(date) ? date : null,
      picks: picks,
      carry: carry,
    );
  }

  /// [today]になっていたら、前の日に選んだもののうち[open]（まだ片付いていない）を持ち越しの確認へ回す。
  /// 片付いたもの・見つからないものは消す。同じ日なら何もしない。
  TodayFocus rollOver(String today, bool Function(TodayPick) open) {
    if (date == today) return this;
    // 日付を戻した端末などで、前の日付へ戻ったときも同じように扱う（選んだ日と違えば持ち越し）。
    final seen = <String>{};
    return TodayFocus(
      date: today,
      carry: [
        for (final p in [...carry, ...picks.map((p) => p.carry())])
          if (open(p) && seen.add(p.itemKey)) p,
      ].take(todayMax * 3).toList(),
    );
  }

  TodayFocus _with({List<TodayPick>? picks, List<TodayPick>? carry}) =>
      TodayFocus(
        date: date,
        picks: picks ?? this.picks,
        carry: carry ?? this.carry,
      );

  /// 今日の3つに加える。持ち越しの確認にあれば、そこから移す（続けた日数を残す）。
  TodayFocus add(TodayPick pick) {
    if (picked(pick.itemKey)) return this;
    if (full) throw StateError('今日の3つは$todayMax件までです。先にどれかを外してください。');
    final kept = carry.where((p) => p.itemKey == pick.itemKey).firstOrNull;
    return _with(
      picks: [...picks, kept ?? pick],
      carry: [
        for (final p in carry)
          if (p.itemKey != pick.itemKey) p,
      ],
    );
  }

  /// 今日の3つ、または持ち越しの確認から外す。
  TodayFocus remove(String itemKey) => _with(
    picks: [
      for (final p in picks)
        if (p.itemKey != itemKey) p,
    ],
    carry: [
      for (final p in carry)
        if (p.itemKey != itemKey) p,
    ],
  );

  /// 持ち越しの確認をすべて外す。
  TodayFocus clearCarry() => _with(carry: const []);
}

/// 選んだ項目が、読込済みのNOWのどこにあるか。
class TodayEntry {
  const TodayEntry(this.pick, this.project, this.item);
  final TodayPick pick;

  /// 項目があるプロジェクトと、NOWの項目。見つからなければnull。
  final HubProject? project;
  final NowItemRef? item;

  bool get missing => item == null;

  /// 完了・解決した（誤りとして外したものも含む）。
  bool get done => item?.resolved ?? false;

  /// 表示する本文。見つからないときは選んだときの本文。
  String get text => item?.text.trim() ?? pick.text;
}

/// [pick]をNOWの項目へ結び付ける。
TodayEntry todayEntry(HubRepository repo, TodayPick pick) {
  final project = repo.projects[pick.projectId];
  final item = project?.nowItems
      .where((i) => i.key == pick.itemKey)
      .firstOrNull;
  return TodayEntry(pick, project, item);
}

/// 持ち越すか（日付が変わったときに、まだ片付いていないか）。
///
/// 読取の上限に達して一部を読めていないときは、見つからなくても持ち越す（片付いたと決めつけない）。
bool todayOpen(HubRepository repo, TodayPick pick) {
  final entry = todayEntry(repo, pick);
  if (entry.missing) return repo.snapshot.limitReached;
  // 完了・解決や誤りとして外す報告を送って反映を待っている項目も、片付いたものとして扱う。
  return !entry.done && repo.itemRequestIdFor(pick.itemKey) == null;
}
