import 'dart:async';
import 'dart:convert';
import '../core/guided.dart';
import 'vault_access.dart';

/// 今月のClaude APIの利用。[month]は端末の時刻での年月（例: 2026-11）。
class GuidedUsage {
  const GuidedUsage(
    this.month, {
    this.calls = 0,
    this.input = 0,
    this.output = 0,
  });
  final String month;
  final int calls, input, output;

  static String monthOf(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}';

  /// [now]の月の利用。月が変われば0から数える。
  GuidedUsage current(DateTime now) =>
      month == monthOf(now) ? this : GuidedUsage(monthOf(now));

  /// 呼び出しは送る前に数え（失敗しても回数に入れる）、トークンは応答を受け取ってから足す。
  GuidedUsage add(
    DateTime now, {
    int calls = 0,
    int input = 0,
    int output = 0,
  }) {
    final base = current(now);
    return GuidedUsage(
      base.month,
      calls: base.calls + calls,
      input: base.input + input,
      output: base.output + output,
    );
  }

  Map<String, Object?> toJson() => {
    'month': month,
    'calls': calls,
    'input': input,
    'output': output,
  };

  static GuidedUsage? fromJson(Object? value) {
    if (value is! Map) return null;
    final month = value['month'];
    final numbers = [value['calls'], value['input'], value['output']];
    if (month is! String ||
        !RegExp(r'^\d{4}-\d{2}$').hasMatch(month) ||
        numbers.any((n) => n is! int || n < 0)) {
      return null;
    }
    return GuidedUsage(
      month,
      calls: numbers[0] as int,
      input: numbers[1] as int,
      output: numbers[2] as int,
    );
  }
}

/// 選んで深掘りの端末内の状態。途中の深掘り（1件）と、今月の利用・月の上限。
class GuidedState {
  GuidedState({
    this.session,
    required this.usage,
    this.monthlyLimit = defaultLimit,
  });
  static const defaultLimit = 200, maxLimit = 10000;
  GuidedSession? session;
  GuidedUsage usage;

  /// 月の呼び出し回数の上限。0ならClaude APIを呼ばない。
  int monthlyLimit;
}

/// `guided.json`（アプリ専用領域）の読み書き。Vaultには書かない。
///
/// 状態ファイルは64KiBまでなので、[budget]を超える途中の状態は書かない（前回の状態を残す）。
/// 書き込みは直列にし、失敗しても深掘りは続けられるように例外を外へ出さない。
class GuidedStore {
  GuidedStore(this.access);
  final VaultAccess access;
  static const fileName = 'guided.json';
  static const budget = 60 * 1024;
  Future<void> _tail = Future.value();

  Future<GuidedState> read(DateTime now) async {
    try {
      final raw = await access.readState(fileName);
      final value = raw == null ? null : jsonDecode(raw);
      if (value is Map && value['version'] == 1) {
        final limit = value['limit'];
        return GuidedState(
          session: GuidedSession.fromJson(value['session']),
          usage:
              (GuidedUsage.fromJson(value['usage']) ??
                      GuidedUsage(GuidedUsage.monthOf(now)))
                  .current(now),
          monthlyLimit:
              limit is int && limit >= 0 && limit <= GuidedState.maxLimit
              ? limit
              : GuidedState.defaultLimit,
        );
      }
    } catch (_) {
      // 読めない状態は空として扱う。途中の深掘りは補助であり、閲覧や保存を止めない。
    }
    return GuidedState(usage: GuidedUsage(GuidedUsage.monthOf(now)));
  }

  static String encode(GuidedState state) => jsonEncode({
    'version': 1,
    'usage': state.usage.toJson(),
    'limit': state.monthlyLimit,
    if (state.session != null) 'session': state.session!.toJson(),
  });

  /// 書けたかどうか。大きすぎるときは書かずにfalse。
  Future<bool> write(GuidedState state) {
    final raw = encode(state);
    final next = _tail.then((_) async {
      if (utf8.encode(raw).length > budget) return false;
      try {
        await access.writeState(fileName, raw);
        return true;
      } catch (_) {
        return false;
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}
