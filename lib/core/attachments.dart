import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unicode;

/// メモに添えるファイル（PDF・画像など、Markdown以外の資料）。本体の`attachments.ts`と同じ規則にする。
///
/// 本体はファイルをVaultの`05_files/<年-月>/<キー>/<ファイル名>`に複製し、メモのfrontmatterの
/// `attachment`に場所・名前・大きさ・SHA-256を書く。アプリはファイルを`Input/files/<受付ID>`に
/// 置いてから、`attachment`（名前・大きさ・SHA-256）を付けたcaptureの依頼を書く。

/// ファイル名の上限（UTF-8のバイト数）。本体が`intake-features.json`で示す値がなければこれを使う。
const fileNameMaxBytes = 200;

/// 使えない文字: 制御文字・改行類・単独のサロゲート・幅のない文字と書字方向の制御、パスの区切り、
/// Windows・exFATで使えない記号（本体の`FORBIDDEN`と同じ）。
const _forbiddenClass =
    r'[\p{Cc}\p{Cs}\p{Zl}\p{Zp}\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF/\\:*?"<>|]';
final _forbidden = RegExp(_forbiddenClass, unicode: true);
final _trailing = RegExp(r'[.\s]+$', unicode: true);

/// 手元のファイル名を、本体が受け付ける名前に整える（本体の`sanitizeFileName`と同じ）。
/// 使えない文字は「_」に置き換え、長すぎる名前は拡張子を残して切る。
/// 合成済みの文字（NFC）にそろえる（Macのファイル名は分解した形のことがある）。
String sanitizeFileName(String raw, {int maxBytes = fileNameMaxBytes}) {
  var name = unicode
      .nfc(raw.split(RegExp(r'[\\/]')).last)
      .replaceAll(_forbidden, '_')
      .replaceAll('.sync-conflict-', '.sync_conflict-');
  name = name
      .trim()
      .replaceFirst(RegExp(r'^\.+'), '_')
      .replaceFirst(_trailing, '');
  final dot = name.lastIndexOf('.');
  final ext =
      dot > 0 && RegExp(r'^\.[A-Za-z0-9]{1,16}$').hasMatch(name.substring(dot))
      ? name.substring(dot)
      : '';
  final stem = (ext.isEmpty ? name : name.substring(0, dot)).runes.toList();
  while (stem.isNotEmpty &&
      utf8.encode(String.fromCharCodes(stem) + ext).length > maxBytes) {
    stem.removeLast();
  }
  final cut = String.fromCharCodes(stem).replaceFirst(_trailing, '').trimLeft();
  return unicode.nfc((cut.isEmpty ? 'file' : cut) + ext);
}

/// 本体が受け付けるファイル名か。
bool validFileName(Object? name, {int maxBytes = fileNameMaxBytes}) =>
    name is String &&
    name.isNotEmpty &&
    unicode.nfc(name) == name &&
    utf8.encode(name).length <= maxBytes &&
    !_forbidden.hasMatch(name) &&
    name.trim() == name &&
    !name.startsWith('.') &&
    !name.endsWith('.') &&
    !name.contains('.sync-conflict-');

/// ファイル名に秘密情報らしい文字列があるときの説明（本体も断る）。
const fileNameSecretMessage = 'ファイル名に秘密情報らしい文字列があります。ファイル名を変えてから選び直してください。';

/// ファイルの大きさの表示（本体の`fileSizeLabel`と同じ）。
String fileSizeLabel(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).round().clamp(1, 1024)}KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';

/// 上限の表示（本体の`limitText`と同じ。MB・KB・バイト）。
String fileLimitLabel(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = (bytes / 1024 / 1024).toStringAsFixed(1);
    return '${mb.endsWith('.0') ? mb.substring(0, mb.length - 2) : mb}MB';
  }
  return bytes >= 1024 ? '${bytes ~/ 1024}KB' : '$bytesバイト';
}

/// 開くとプログラムとして動く・ほかの場所へ移る種類のファイル（アプリからは開かない）。
/// Vaultに書ける誰かが置いたファイルを、本人が「開く」で実行してしまわないため。
final _launchableExtensions =
    ('app command tool sh bash zsh csh ksh fish py pyc rb pl php js mjs '
            'jar terminal webloc inetloc fileloc url scpt scptd applescript '
            'workflow action pkg mpkg dmg apk apks xapk aab dex exe msi bat cmd '
            'com ps1 vbs lnk desktop prefpane kext plugin bundle osax service '
            'saver mobileconfig configprofile definition shortcut ')
        .trim()
        .split(' ')
        .toSet();
bool launchableFileName(String name) {
  final dot = name.lastIndexOf('.');
  return dot >= 0 &&
      _launchableExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// Vault内のファイルの場所（本体が書く`05_files/<年-月>/<キー>/<名前>`だけ）。
final attachmentPathPattern = RegExp(
  r'^05_files/\d{4}-(?:0[1-9]|1[0-2])/[0-9a-f]{24}/[^/]+$',
);

/// メモに添えたファイル（Vault内の場所・名前・大きさ）。
class HubFile {
  const HubFile(this.path, this.name, this.bytes);
  final String path, name;
  final int bytes;

  /// 本体が書いた形（`path`・`name`・`bytes`）を読む。形が違えばnull。
  static HubFile? fromJson(Object? value) {
    if (value
        case {
          'path': final String path,
          'name': final String name,
          'bytes': final int bytes,
        }
        when attachmentPathPattern.hasMatch(path) &&
            path.endsWith('/$name') &&
            validFileName(name, maxBytes: 1024) &&
            bytes >= 0) {
      return HubFile(path, name, bytes);
    }
    return null;
  }

  String get label => '$name（${fileSizeLabel(bytes)}）';
}
