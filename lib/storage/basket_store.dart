import 'dart:async';
import 'dart:convert';
import 'vault_access.dart';

/// 文脈かごの中身。記録はアプリの記録ID（パスから作る）で持ち、並びは本人が決めた順。
class Basket {
  const Basket({this.ids = const [], this.maxChars = Basket.defaultMaxChars});
  final List<String> ids;
  final int maxChars;

  /// まとめてコピーするときの文字数上限の選択肢。既定は出典付きcontextのコピーと同じ6000字。
  static const limits = [6000, 12000, 30000];
  static const defaultMaxChars = 6000;
}

/// 文脈かごを端末に残す。Vaultには書かず、アプリ専用領域の`basket.json`にVaultのidentityごとに保存する。
///
/// かごは補助なので、読めない・書けないときも閲覧やコピーを止めない。書き込みは直列にする。
class BasketStore {
  BasketStore(this.access);
  final VaultAccess access;
  static const fileName = 'basket.json';

  /// 1つのかごに入れられる記録の数（本体の`ctx bundle`と同じ上限）。
  static const maxItems = 50;

  /// 残すVaultの数。超えたら最後にかごを変えたのが古いVaultのかごから捨てる。
  static const maxVaults = 10;
  static final _id = RegExp(r'^record-[a-f0-9]{24}$');

  Map<String, ({Basket basket, DateTime at})>? _vaults;
  Future<void>? _loading;

  /// 状態ファイルを読めなかった（壊れた内容ではなく、読み出しそのものの失敗）。
  /// ほかのVaultのかごを消さないよう、読めるまで書かずに次の操作で読み直す。
  bool _unreadable = false;
  Future<void> _tail = Future.value();

  Future<void> _load() => _loading ??= _read();

  Future<void> _read() async {
    final vaults = <String, ({Basket basket, DateTime at})>{};
    _unreadable = false;
    String? raw;
    try {
      raw = await access.readState(fileName);
    } catch (_) {
      _unreadable = true;
    }
    try {
      final value = raw == null ? null : jsonDecode(raw);
      if (value is Map && value['version'] == 1 && value['vaults'] is Map) {
        for (final e in (value['vaults'] as Map).entries) {
          final v = e.value;
          if (e.key is! String || v is! Map) continue;
          final ids = v['ids'], max = v['max'], at = v['at'];
          if (ids is! List ||
              at is! String ||
              DateTime.tryParse(at) == null ||
              !Basket.limits.contains(max)) {
            continue;
          }
          final valid = ids
              .whereType<String>()
              .where(_id.hasMatch)
              .toSet()
              .take(maxItems)
              .toList();
          vaults[e.key as String] = (
            basket: Basket(ids: valid, maxChars: max as int),
            at: DateTime.parse(at),
          );
        }
      }
    } catch (_) {
      // 読めない記録は空のかごとして扱う。
    }
    _vaults = vaults;
  }

  Future<Basket> read(String identity) async {
    if (_unreadable) _loading = null;
    await _load();
    return _vaults![identity]?.basket ?? const Basket();
  }

  Future<void> write(String identity, Basket basket) {
    final next = _tail.then((_) async {
      if (_unreadable) _loading = null;
      await _load();
      if (_unreadable) return;
      final vaults = _vaults!;
      if (basket.ids.isEmpty && basket.maxChars == Basket.defaultMaxChars) {
        vaults.remove(identity);
      } else {
        vaults[identity] = (
          basket: Basket(
            ids: basket.ids.take(maxItems).toList(),
            maxChars: basket.maxChars,
          ),
          at: DateTime.now().toUtc(),
        );
      }
      while (vaults.length > maxVaults) {
        final oldest = vaults.entries.reduce(
          (a, b) => a.value.at.isBefore(b.value.at) ? a : b,
        );
        vaults.remove(oldest.key);
      }
      try {
        await access.writeState(
          fileName,
          jsonEncode({
            'version': 1,
            'vaults': {
              for (final e in vaults.entries)
                e.key: {
                  'ids': e.value.basket.ids,
                  'max': e.value.basket.maxChars,
                  'at': e.value.at.toIso8601String(),
                },
            },
          }),
        );
      } catch (_) {
        // かごの保存に失敗しても、この起動中のかごはそのまま使える。
      }
    });
    _tail = next.catchError((Object _) {});
    return _tail;
  }
}
