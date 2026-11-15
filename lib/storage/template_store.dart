import 'dart:async';
import 'dart:convert';
import '../core/templates.dart';
import 'vault_access.dart';

/// ひな形を保存できなかった。画面に理由を示し、入力そのものは続けられる。
class TemplateStoreError extends StateError {
  TemplateStoreError(super.message);
}

/// メモのひな形を端末に残す。Vaultには書かず、アプリ専用領域の`templates.json`に保存する。
///
/// 本人が一度も変えていなければファイルを作らず、[defaultTemplates]を返す。
/// ひな形は補助なので、読めないときも最初のひな形でメモを書ける。書き込みは直列にする。
class TemplateStore {
  TemplateStore(this.access);
  final VaultAccess access;
  static const fileName = 'templates.json';

  /// 状態ファイルは64KiBまで。超える変更は保存しない。
  static const budget = 60 * 1024;

  List<MemoTemplate>? _templates;

  /// 状態ファイルを読めなかった（壊れた内容ではなく、読み出しそのものの失敗）。
  /// [list]が最初のひな形を返しているので、それをもとにした並びで本人のひな形を上書きしないよう、
  /// 読み直せるまで保存しない。
  bool get unreadable => _unreadable;
  bool _unreadable = false;
  Future<void> _tail = Future.value();

  /// 状態ファイルを読む。読み出しそのものに失敗したときは例外を出す（上書きで消さないため）。
  Future<List<MemoTemplate>> _read() async {
    final raw = await access.readState(fileName);
    if (raw == null) return defaultTemplates;
    try {
      final value = jsonDecode(raw);
      if (value is Map && value['version'] == 1 && value['templates'] is List) {
        final seen = <String>{}, templates = <MemoTemplate>[];
        for (final item in value['templates'] as List) {
          final t = MemoTemplate.fromJson(item);
          if (t != null && seen.add(t.id)) templates.add(t);
        }
        return templates.take(maxTemplates).toList();
      }
    } catch (_) {
      // 壊れた内容は最初のひな形として扱う。
    }
    return defaultTemplates;
  }

  /// いまのひな形の並び。読めないときは最初のひな形を返し、次の呼び出しで読み直す。
  Future<List<MemoTemplate>> list() async {
    final cached = _templates;
    if (cached != null) return cached;
    try {
      await _tail;
      // 読んでいる間に保存が済んでいれば、保存した並びを優先する。
      final read = await _read();
      _unreadable = false;
      return _templates ??= read;
    } catch (_) {
      _unreadable = true;
      return defaultTemplates;
    }
  }

  /// 並び全体を置き換える。
  Future<void> save(List<MemoTemplate> templates) => _serial(() async {
    if (templates.length > maxTemplates) {
      throw TemplateStoreError('ひな形は$maxTemplates件までです。');
    }
    if (templates.map((t) => t.id).toSet().length != templates.length) {
      throw TemplateStoreError('同じひな形が重なっています。');
    }
    for (final t in templates) {
      final problem = templateNameError(t.name) ?? templateBodyError(t.body);
      if (problem != null) throw TemplateStoreError(problem);
    }
    final raw = jsonEncode({
      'version': 1,
      'templates': [for (final t in templates) t.toJson()],
    });
    if (utf8.encode(raw).length > budget) {
      throw TemplateStoreError('ひな形の合計が大きすぎます。本文を短くするか、数を減らしてください。');
    }
    // ほかの端末内の記録と同じく、読めない状態のまま上書きしない。
    if (_unreadable) {
      throw TemplateStoreError('ひな形を読み込めなかったため、保存していません。画面を開き直してください。');
    }
    if (_templates == null) {
      final read = await _read();
      _templates ??= read;
    }
    await access.writeState(fileName, raw);
    _templates = List.unmodifiable(templates);
  });

  /// 最初のひな形に戻す。
  Future<void> reset() => save(defaultTemplates);

  Future<void> _serial(Future<void> Function() change) {
    final next = _tail.then((_) => change());
    _tail = next.catchError((Object _) {});
    return next;
  }
}
