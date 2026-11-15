import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app/attention_check.dart';
import 'app/controller.dart';
import 'storage/vault_access.dart';
import 'ui/app.dart';

Future<Map<String, String>> loadSample() async => {
  ...Map<String, String>.from(
    jsonDecode(await rootBundle.loadString('assets/sample.json')),
  ),
  ...Map<String, String>.from(
    (jsonDecode(await rootBundle.loadString('assets/review.json'))
            as Map)['files']
        as Map,
  ),
};

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ContextHubApp(
      controller: HubController(NativeVaultAccess(), sampleLoader: loadSample),
    ),
  );
}

/// Androidが数時間おきに呼ぶ、アプリを閉じている間の確認待ちの確認。画面は作らない。
@pragma('vm:entry-point')
Future<void> attentionCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  final access = NativeVaultAccess();
  try {
    await runAttentionCheck(access);
  } catch (_) {
    // 読めないときは何も通知しない。次の確認でやり直す。
  } finally {
    try {
      await access.finishBackgroundCheck();
    } catch (_) {
      // 終了を伝えられなくても、端末側の時間切れで片付く。
    }
  }
}
