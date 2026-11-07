import 'dart:async';
import 'dart:convert';
import 'vault_access.dart';

/// 書きかけの入力。Vaultには書かず、アプリ専用領域の`drafts.json`だけに残す。
class WritingDraft {
  const WritingDraft({
    required this.text,
    this.kind = 'memo',
    this.project,
    this.gitDraftHash,
    this.operationId,
    required this.updatedAt,
  });
  final String text, kind;
  final String? project;

  /// 作業記録の下書きから書いている場合、書き始めたときの下書きhash。
  final String? gitDraftHash;

  /// 保存を試みた操作ID。保存結果が不明なまま閉じた場合に、同じ操作の確認へ戻すために使う。
  final String? operationId;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    't': text,
    'k': kind,
    if (project != null) 'p': project,
    if (gitDraftHash != null) 'g': gitDraftHash,
    if (operationId != null) 'o': operationId,
    'at': updatedAt.toUtc().toIso8601String(),
  };

  static WritingDraft? fromJson(Object? value) {
    if (value is! Map) return null;
    final text = value['t'], kind = value['k'], at = value['at'];
    final project = value['p'], hash = value['g'], op = value['o'];
    if (text is! String ||
        text.length > DraftStore.maxChars ||
        !['memo', 'work-summary'].contains(kind) ||
        at is! String ||
        DateTime.tryParse(at) == null ||
        (project != null && project is! String) ||
        (hash != null && hash is! String) ||
        (op != null && op is! String)) {
      return null;
    }
    return WritingDraft(
      text: text,
      kind: kind as String,
      project: project as String?,
      gitDraftHash: hash as String?,
      operationId: op as String?,
      updatedAt: DateTime.parse(at),
    );
  }
}

/// 書きかけのメモを端末に残す。キーはVaultのidentityと入力の種類（新規メモ・作業記録の下書きID）。
///
/// 状態ファイルは64KiBまでなので、[budget]を超えるときは古い書きかけから捨てる。
/// 書き込みは直列にし、失敗しても入力は続けられるように例外を外へ出さない。
class DraftStore {
  DraftStore(this.access);
  final VaultAccess access;
  static const fileName = 'drafts.json';
  static const maxChars = 8000;
  static const budget = 60 * 1024;

  Map<String, WritingDraft>? _drafts;
  bool _enabled = true;
  Future<void> _tail = Future.value();

  static String keyFor(String identity, {String? gitDraftId}) =>
      '$identity\u001f${gitDraftId == null ? 'memo' : 'git:$gitDraftId'}';

  Future<void> _load() async {
    if (_drafts != null) return;
    final drafts = <String, WritingDraft>{};
    try {
      final raw = await access.readState(fileName);
      final value = raw == null ? null : jsonDecode(raw);
      if (value is Map && value['version'] == 1) {
        _enabled = value['enabled'] != false;
        final items = value['drafts'];
        if (items is Map) {
          for (final e in items.entries) {
            final d = WritingDraft.fromJson(e.value);
            if (e.key is String && d != null) drafts[e.key as String] = d;
          }
        }
      }
    } catch (_) {
      // 読めない記録は空として扱う。書きかけは補助であり、保存や閲覧を止めない。
    }
    _drafts = drafts;
  }

  Future<bool> enabled() async {
    await _load();
    return _enabled;
  }

  Future<WritingDraft?> read(String key) async {
    await _load();
    return _enabled ? _drafts![key] : null;
  }

  Future<void> write(String key, WritingDraft draft) => _serial(() async {
    await _load();
    if (!_enabled) return;
    if (draft.text.trim().isEmpty && draft.operationId == null) {
      _drafts!.remove(key);
    } else {
      _drafts![key] = draft;
    }
  });

  Future<void> remove(String key) => _serial(() async {
    await _load();
    _drafts!.remove(key);
  });

  /// 書きかけを残すかどうか。残さない場合は、この端末の書きかけをすべて消す。
  Future<void> setEnabled(bool value) => _serial(() async {
    await _load();
    _enabled = value;
    if (!value) _drafts!.clear();
  });

  Future<void> _serial(Future<void> Function() change) {
    final next = _tail.then((_) async {
      await change();
      await _flush();
    });
    _tail = next.catchError((Object _) {});
    return _tail;
  }

  String _encode() => jsonEncode({
    'version': 1,
    'enabled': _enabled,
    'drafts': {for (final e in _drafts!.entries) e.key: e.value.toJson()},
  });

  Future<void> _flush() async {
    var raw = _encode();
    final order = _drafts!.keys.toList()
      ..sort(
        (a, b) => _drafts![a]!.updatedAt.compareTo(_drafts![b]!.updatedAt),
      );
    // 新しい書きかけを残すため、容量を超える間は古いものから捨てる。
    while (utf8.encode(raw).length > budget && order.length > 1) {
      _drafts!.remove(order.removeAt(0));
      raw = _encode();
    }
    if (utf8.encode(raw).length > budget) return;
    try {
      await access.writeState(fileName, raw);
    } catch (_) {
      // 書きかけの保存に失敗しても入力は続ける。
    }
  }
}
