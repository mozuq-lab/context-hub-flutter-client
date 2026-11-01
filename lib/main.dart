import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
