import 'dart:async';
import 'dart:convert';
import '../core/guided.dart';
import 'vault_access.dart';

/// 今月のClaude APIの利用。[month]は端末の時刻での年月（例: 2026-11）。
///
/// [input]・[output]は合計（旧形式から読めるもの）。[models]はモデルごとの種類別の内訳で、
/// 概算額の計算に使う（旧形式で記録した分には内訳がない）。[uncertain]は、依頼は届いたが応答が
/// 途中で途切れ、使ったトークンを最後まで数えられなかった呼び出しの数。
class GuidedUsage {
  const GuidedUsage(
    this.month, {
    this.calls = 0,
    this.input = 0,
    this.output = 0,
    this.models = const {},
    this.uncertain = 0,
  });
  final String month;
  final int calls, input, output, uncertain;
  final Map<String, TokenUsage> models;

  /// 内訳に残すモデルの数。超えた分は合計にだけ足す（状態ファイルを大きくしないため）。
  static const maxModels = 20;
  static final _modelName = RegExp(r'^[a-z0-9.\-]{1,100}$');

  static String monthOf(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}';

  /// [now]の月の利用。月が進めば0から数える。記録した月が[now]より先のとき（時計を過去の月へ
  /// 戻した・一度先の月に進んだ時計を直した）は、回数とトークンをそのまま[now]の月に引き継ぐ。
  /// 時計を戻して上限を外せず、先の月のまま止まって数え直されないこともない。
  GuidedUsage current(DateTime now) {
    final m = monthOf(now);
    if (m == month) return this;
    if (m.compareTo(month) > 0) return GuidedUsage(m);
    return GuidedUsage(
      m,
      calls: calls,
      input: input,
      output: output,
      models: models,
      uncertain: uncertain,
    );
  }

  /// 呼び出しは送る前に数え（失敗しても回数に入れる）、トークンは応答を受け取ってから足す。
  GuidedUsage add(
    DateTime now, {
    int calls = 0,
    Map<String, TokenUsage> used = const {},
    bool uncertain = false,
  }) {
    final base = current(now);
    final merged = {...base.models};
    for (final e in used.entries) {
      if (!_modelName.hasMatch(e.key)) continue;
      final known = merged[e.key];
      if (known == null && merged.length >= maxModels) continue;
      merged[e.key] = (known ?? const TokenUsage()) + e.value;
    }
    final total = used.values.fold(const TokenUsage(), (a, b) => a + b);
    return GuidedUsage(
      base.month,
      calls: (base.calls + calls).clamp(0, 1 << 30),
      input: base.input + total.allInput,
      output: base.output + total.output,
      models: merged,
      uncertain: base.uncertain + (uncertain ? 1 : 0),
    );
  }

  /// 内訳のない（旧形式で記録した・内訳に入りきらなかった）トークンがあるか。
  bool get partial {
    final sum = models.values.fold(const TokenUsage(), (a, b) => a + b);
    return sum.allInput < input || sum.output < output;
  }

  Map<String, Object?> toJson() => {
    'month': month,
    'calls': calls,
    'input': input,
    'output': output,
    if (models.isNotEmpty)
      'models': {for (final e in models.entries) e.key: e.value.toJson()},
    if (uncertain > 0) 'uncertain': uncertain,
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
    // 内訳と不確かな回数は後から加えた項目。無い・壊れているときは内訳なしとして読む。
    final models = <String, TokenUsage>{};
    final raw = value['models'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final u = TokenUsage.fromJson(e.value);
        if (e.key is String &&
            _modelName.hasMatch(e.key as String) &&
            u != null &&
            models.length < maxModels) {
          models[e.key as String] = u;
        }
      }
    }
    final uncertain = value['uncertain'];
    return GuidedUsage(
      month,
      calls: numbers[0] as int,
      input: numbers[1] as int,
      output: numbers[2] as int,
      models: models,
      uncertain: uncertain is int && uncertain > 0 ? uncertain : 0,
    );
  }
}

/// 選んで深掘りの端末内の状態。途中の深掘り（1件）と、今月の利用・月の上限。
class GuidedState {
  GuidedState({
    this.session,
    required this.usage,
    this.monthlyLimit = defaultLimit,
    this.unreadable = false,
  });
  static const defaultLimit = 200, maxLimit = 10000;
  GuidedSession? session;
  GuidedUsage usage;

  /// 状態ファイルを読み出せなかった（壊れた内容ではなく、読み出しそのものの失敗）。
  /// 月の上限・利用回数・途中の深掘りが分からないので、書き込まず（上書きして消さない）、
  /// Claude APIも呼ばない。画面を開き直すと読み直す。
  final bool unreadable;

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
    String? raw;
    try {
      raw = await access.readState(fileName);
    } catch (_) {
      return GuidedState(
        usage: GuidedUsage(GuidedUsage.monthOf(now)),
        unreadable: true,
      );
    }
    try {
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
      // 壊れた内容は空として扱う。途中の深掘りは補助であり、閲覧や保存を止めない。
    }
    return GuidedState(usage: GuidedUsage(GuidedUsage.monthOf(now)));
  }

  static String encode(GuidedState state) => jsonEncode({
    'version': 1,
    'usage': state.usage.toJson(),
    'limit': state.monthlyLimit,
    if (state.session != null) 'session': state.session!.toJson(),
  });

  /// 書けたかどうか。大きすぎるとき・読み出せなかった状態のときは書かずにfalse。
  Future<bool> write(GuidedState state) {
    if (state.unreadable) return Future.value(false);
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
