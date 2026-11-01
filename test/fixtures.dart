import 'dart:convert';
import 'dart:io';
import 'package:context_hub_client/core/models.dart';

const inputId = 'IN-01M2DSFVRRA5MFS95MKFPP2CCM';
const inputPath = '00_inbox/2026-09-14_$inputId.md';
const nowPath = '10_projects/context-hub/NOW.md';
const correctionId = 'IN-01M2DSFVRRA5MFS95MKFPP2CCN';
const correctionPath = '00_inbox/2026-09-15_$correctionId.md';

Map<String, String> fixtureFiles() {
  return Map<String, String>.from(
    jsonDecode(File('assets/sample.json').readAsStringSync()) as Map,
  );
}

VaultSnapshot fixture([Map<String, String>? files]) => VaultSnapshot(
  files ?? fixtureFiles(),
  loadedAt: DateTime.utc(2026, 10, 30),
);
