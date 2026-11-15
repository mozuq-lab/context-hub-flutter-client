import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/models.dart';

class VaultLocation {
  const VaultLocation(this.handle, this.name, {String? identity})
    : identity = identity ?? handle;
  final String handle;
  final String name;
  final String identity;
  Map<String, String> toJson() => {
    'handle': handle,
    'name': name,
    'identity': identity,
  };
  static VaultLocation fromJson(Map<Object?, Object?> value) => VaultLocation(
    value['handle'] as String,
    value['name'] as String,
    identity: value['identity'] as String?,
  );
}

abstract class VaultAccess {
  Future<VaultLocation?> pickVault();
  Future<VaultLocation> sampleVault(Map<String, String> files);
  Future<VaultSnapshot> readSnapshot(VaultLocation location);

  /// [previous]から変わっていないファイルは読み直さずに引き継ぐ。表示の更新だけに使い、
  /// 確認を伴う操作（コピー・採用・依頼）は[readSnapshot]で全体を読み直す。
  Future<VaultSnapshot> refreshSnapshot(
    VaultLocation location,
    VaultSnapshot previous,
  ) => readSnapshot(location);
  Future<String?> readRequest(VaultLocation location, String requestId);
  Future<void> writeRequest(
    VaultLocation location,
    String requestId,
    String raw,
  );
  Future<String?> readState(String name);
  Future<void> writeState(String name, String raw, {bool exclusive = false});
  Future<List<String>> listJournals();
  Future<void> openExternal(String url);

  /// ホーム画面ウィジェットとアイコン長押しのショートカットを使える端末か（Androidだけ）。
  bool get homeScreenSupported => false;

  /// ホーム画面ウィジェットに出す内容を渡す。nullなら「アプリを開いて読み込む」表示に戻す。
  Future<void> updateHomeWidget(String? content) async {}

  /// ショートカットやウィジェットから指定された起動時の操作を1回だけ受け取る。なければnull。
  Future<String?> takeLaunchAction() async => null;

  /// アプリを開いたまま新しい起動時の操作が届いたときの通知先を登録する。
  void listenLaunchActions(void Function() onAction) {}
}

/// 起動時の操作として受け付ける名前。ほかの値は無視する。
const launchActions = {'capture', 'guided', 'next'};

class NativeVaultAccess implements VaultAccess {
  static const channel = MethodChannel('com.mozuqlab.contexthub/vault');
  @override
  Future<VaultLocation?> pickVault() async {
    final result = await channel.invokeMapMethod<Object?, Object?>('pickVault');
    return result == null ? null : VaultLocation.fromJson(result);
  }

  @override
  Future<VaultLocation> sampleVault(Map<String, String> files) async =>
      VaultLocation.fromJson(
        (await channel.invokeMapMethod<Object?, Object?>('sampleVault', {
          'files': files,
        }))!,
      );
  @override
  Future<VaultSnapshot> readSnapshot(VaultLocation location) async =>
      _merge(await _read(location, const {}), const {});

  @override
  Future<VaultSnapshot> refreshSnapshot(
    VaultLocation location,
    VaultSnapshot previous,
  ) async {
    final known = {
      for (final e in previous.stamps.entries)
        if (previous.files.containsKey(e.key)) e.key: e.value,
    };
    final value = await _read(location, known);
    try {
      return _merge(value, previous.files);
    } on FormatException {
      // 引き継ぐ本文が見つからない場合は、全体を読み直す。
      return readSnapshot(location);
    }
  }

  Future<Map<String, dynamic>> _read(
    VaultLocation location,
    Map<String, String> known,
  ) async => (await channel.invokeMapMethod<String, dynamic>('readSnapshot', {
    'handle': location.handle,
    'skip': snapshotSkippedPaths,
    if (known.isNotEmpty) 'known': known,
  }))!;

  static VaultSnapshot _merge(
    Map<String, dynamic> value,
    Map<String, String> previous,
  ) => mergeSnapshot(
    files: Map<String, String>.from(value['files']),
    unchanged: List<String>.from(value['unchanged'] ?? const []),
    stamps: Map<String, String>.from(value['stamps'] ?? const {}),
    warnings: List<String>.from(value['warnings'] ?? []),
    recognized: value['recognized'] == true,
    previous: previous,
  );

  @override
  Future<String?> readRequest(VaultLocation location, String requestId) =>
      channel.invokeMethod<String>('readRequest', {
        'handle': location.handle,
        'requestId': requestId,
      });
  @override
  Future<void> writeRequest(
    VaultLocation location,
    String requestId,
    String raw,
  ) => channel.invokeMethod('writeRequest', {
    'handle': location.handle,
    'requestId': requestId,
    'raw': raw,
  });
  @override
  Future<String?> readState(String name) =>
      channel.invokeMethod<String>('readState', {'name': name});
  @override
  Future<void> writeState(String name, String raw, {bool exclusive = false}) =>
      channel.invokeMethod('writeState', {
        'name': name,
        'raw': raw,
        'exclusive': exclusive,
      });
  @override
  Future<List<String>> listJournals() async =>
      (await channel.invokeListMethod<String>('listJournals'))!;
  @override
  Future<void> openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('http(s)リンクだけを開けます。');
    }
    await channel.invokeMethod('openExternal', {'url': url});
  }

  @override
  bool get homeScreenSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> updateHomeWidget(String? content) async {
    if (!homeScreenSupported) return;
    await channel.invokeMethod('updateHomeWidget', {'content': content});
  }

  @override
  Future<String?> takeLaunchAction() async {
    if (!homeScreenSupported) return null;
    final action = await channel.invokeMethod<String>('takeLaunchAction');
    return launchActions.contains(action) ? action : null;
  }

  @override
  void listenLaunchActions(void Function() onAction) {
    if (!homeScreenSupported) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'launchAction') onAction();
    });
  }
}

/// ネイティブの読取結果と、前回から引き継ぐ本文をまとめる。引き継ぐ本文がなければFormatException。
VaultSnapshot mergeSnapshot({
  required Map<String, String> files,
  required List<String> unchanged,
  required Map<String, String> stamps,
  required List<String> warnings,
  required bool recognized,
  required Map<String, String> previous,
}) {
  final merged = Map<String, String>.of(files);
  for (final path in unchanged) {
    final raw = previous[path];
    if (raw == null || merged.containsKey(path)) {
      throw const FormatException('引き継ぐ記録がありません。');
    }
    merged[path] = raw;
  }
  return VaultSnapshot(
    merged,
    warnings: warnings,
    recognized: recognized,
    stamps: stamps,
    reused: unchanged.length,
  );
}
