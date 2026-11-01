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
}

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
  Future<VaultSnapshot> readSnapshot(VaultLocation location) async {
    final value = (await channel.invokeMapMethod<String, dynamic>(
      'readSnapshot',
      {'handle': location.handle},
    ))!;
    return VaultSnapshot(
      Map<String, String>.from(value['files']),
      warnings: List<String>.from(value['warnings'] ?? []),
      recognized: value['recognized'] == true,
    );
  }

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
}
