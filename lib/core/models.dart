import 'dart:convert';
import 'package:crypto/crypto.dart';

String digest(String value) => sha256.convert(utf8.encode(value)).toString();
String recordId(String path) => 'record-${digest(path).substring(0, 24)}';

class VaultSnapshot {
  final Map<String, String> files;
  final List<String> warnings;
  final bool recognized;
  final DateTime loadedAt;
  VaultSnapshot(
    this.files, {
    this.warnings = const [],
    this.recognized = true,
    DateTime? loadedAt,
  }) : loadedAt = loadedAt ?? DateTime.now();
  String get fingerprint {
    final paths = files.keys.toList()..sort();
    return digest(paths.map((p) => '$p:${digest(files[p]!)}').join('\n'));
  }
}

class HubRecord {
  final String id, sourceId, path, title, body, kind, origin, source;
  final DateTime? at, receivedAt, generatedAt;
  String status;
  final List<String> warnings, references;
  final Map<String, Object?> metadata;
  HubRecord({
    required this.sourceId,
    required this.path,
    required this.title,
    required this.body,
    required this.kind,
    required this.origin,
    required this.source,
    this.at,
    this.receivedAt,
    this.generatedAt,
    this.status = 'waiting',
    List<String>? warnings,
    List<String>? references,
    this.metadata = const {},
  }) : id = recordId(path),
       warnings = warnings ?? [],
       references = references ?? [];
}

class NowEntry {
  String text;
  final List<String> references = [], warnings = [];
  NowEntry(this.text);
}

class HubProject {
  final String id, title, status;
  final List<String> aliases, keywords;
  String? nowRecordId;
  DateTime? generatedAt, lastEvidenceAt;
  String notes = '';
  final Map<String, List<NowEntry>> sections = {
    'current': [],
    'next': [],
    'open': [],
    'proposals': [],
  };
  final List<String> warnings = ['AIによる整理・自己報告を含む、未検証の要約です。'], references = [];
  HubProject({
    required this.id,
    required this.title,
    this.status = 'active',
    this.aliases = const [],
    this.keywords = const [],
  });
}

class IntakeStatus {
  final String id, path, title;
  final DateTime? at;
  String state, detail;
  IntakeStatus({
    required this.id,
    required this.path,
    required this.title,
    this.at,
    this.state = 'waiting',
    this.detail = '',
  });
}
