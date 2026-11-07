import 'package:flutter/services.dart';
import 'vault_access.dart';

/// ClaudeのAPIキーを端末の安全な保管場所に置く。Vaultや状態ファイルには書かない。
abstract class SecretStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();

  /// 貼り付けたAPIキーの形を確かめる。問題がなければnull。
  static String? problem(String value) {
    if (value.isEmpty) return 'APIキーを入力してください。';
    if (value.length < 20 || value.length > 512) {
      return 'APIキーの長さを確かめてください。';
    }
    if (RegExp(r'[^\x21-\x7e]').hasMatch(value)) {
      return 'APIキーに空白や使えない文字が含まれています。';
    }
    return null;
  }
}

/// Macはキーチェーン、AndroidはAndroid Keystoreの鍵で暗号化したアプリ専用領域のファイル。
class NativeSecretStore implements SecretStore {
  static const name = 'anthropic-api-key';
  final MethodChannel channel = NativeVaultAccess.channel;

  @override
  Future<String?> read() =>
      channel.invokeMethod<String>('readSecret', {'name': name});
  @override
  Future<void> write(String value) =>
      channel.invokeMethod('writeSecret', {'name': name, 'value': value});
  @override
  Future<void> delete() => channel.invokeMethod('deleteSecret', {'name': name});
}
