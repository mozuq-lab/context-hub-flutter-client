import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/calendar.dart';
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

/// ファイルを添える・開く操作でネイティブが返す理由（エラーコード）と、本人向けの説明。
const attachmentFailureMessages = {
  'attachment_not_file':
      'フォルダーやパッケージ（.rtfd・.pagesなど）は添えられません。1つのファイルを選ぶか、PDFなどに書き出してから選んでください。',
  'attachment_unreadable':
      '選んだファイルを読めません（クラウドにだけあるファイルなど）。端末に保存してから選び直してください。',
  'attachment_too_large': 'ファイルが上限より大きくなっています。小さくしてから選び直してください。',
  'attachment_lost': '選んだファイルを使えなくなりました（アプリを開き直したなど）。ファイルを選び直してください。',
  'attachment_conflict':
      '前に写しかけた別のファイルと重なりました。もう一度保存してください（新しい保存として写し直します）。',
  'file_missing': 'ファイルがまだこの端末に届いていません。同期が終わってから開いてください。',
  'file_no_app': 'このファイルを開けるアプリがありません。',
  'file_launchable': '実行できる種類のファイルは、アプリからは開きません。',
};

/// 端末で本人が選んだ、メモに添えるファイル。[token]は端末側の参照で、アプリを閉じると使えなくなる。
/// [name]は端末が合成済みの文字（NFC）にそろえた元の名前、[bytes]は選んだ時点の大きさ。
class PickedAttachment {
  const PickedAttachment(this.token, this.name, this.bytes);
  final String token, name;
  final int bytes;
}

/// Vaultの`Input/files/<受付ID>`へ写したファイルの大きさとSHA-256（16進の小文字）。
class StagedAttachment {
  const StagedAttachment(this.bytes, this.sha256);
  final int bytes;
  final String sha256;
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

  /// この端末が書いた依頼を取り下げられる端末か。
  bool get withdrawSupported => false;

  /// `Input/<requestId>.md`の内容のSHA-256が[expectedSha256]と同じときだけ、そのファイルと添えたファイル
  /// （`Input/files/<requestId>`）を消す。消したら`withdrawn`、依頼のファイルがなければ`missing`、
  /// 内容が違えば何も消さずに`changed`、本体が受付を始めていれば（停止回復の記録`90_system/intake/pending/<requestId>.json`がある）
  /// 何も消さずに`started`を返す。依頼を消した後の失敗（同期・添付の削除）は`withdrawn`として返す。
  Future<String> withdrawRequest(
    VaultLocation location,
    String requestId,
    String expectedSha256,
  ) => throw UnsupportedError('この端末では依頼を取り下げられません。');
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

  /// ドックのアイコンに判断待ちの件数を出せる端末か（Macだけ）。
  bool get dockBadgeSupported => false;

  /// ドックのアイコンに件数を出す。0なら消す。
  Future<void> setDockBadge(int count) async {}

  /// 端末のカレンダーへ予定を入れられる端末か（MacとAndroid）。
  bool get calendarSupported => false;

  /// 予定を1件、端末のカレンダーへ渡す。Androidは予定の作成画面を開き、Macは予定のファイルをカレンダーで開く。
  /// どちらも本人が確かめて保存し、アプリはカレンダーの権限を取らない。Vaultには触れない。
  Future<void> addToCalendar(CalendarEvent event) async {}

  /// アプリを閉じている間の通知（確認待ち・期日）を使える端末か（Androidだけ）。
  bool get attentionNotificationsSupported => false;

  /// 数時間おきの確認を有効・無効にする。有効にできた（[kind]の通知が許可されている）ときだけtrue。
  ///
  /// [kind]は[notificationKinds]のどれか（確認待ちは`attention`、期日は`due`）。確認は両方で共有する。
  /// [request]がtrueなら、許可がまだのときに端末の許可画面を出す（本人が設定を入れたときだけ）。
  /// 有効にすると数時間おきの確認を登録し、無効にすると登録と出ているすべての通知を消す。
  /// どちらかの通知を使っている間は、無効にせずに有効のまま呼ぶ。
  /// [active]は有効にしている種類のすべて（省略すると[kind]だけ）。端末はこの種類のお知らせが
  /// すべて止められている間は確認を行わず、有効にするときにすべて止められていれば登録を消す。
  Future<bool> setAttentionNotifications({
    required bool enabled,
    bool request = false,
    String kind = 'attention',
    Set<String>? active,
  }) async => false;

  /// 端末に通知する。[key]が[kind]の前回の通知と同じなら出し直さない。
  Future<void> showAttentionNotification({
    required String key,
    required String title,
    required String text,
    String kind = 'attention',
  }) async {}

  /// 出ている[kind]の通知を消す（確認待ちは、アプリで件数を出したとき）。
  ///
  /// 期日（`due`）は通知を消すだけで、その日に通知した記録は残す（同じ日に知らせ直さない）。
  Future<void> clearAttentionNotification({String kind = 'attention'}) async {}

  /// アプリを閉じている間の確認が終わったことを端末へ伝える。
  Future<void> finishBackgroundCheck() async {}

  /// ファイルを選んでメモに添え、Vaultのファイルを開ける端末か（MacとAndroid）。
  bool get attachmentsSupported => false;

  /// 端末のファイル選択画面を開く。選ばなければnull。Vaultには触れない。
  Future<PickedAttachment?> pickAttachment() async => null;

  /// 選んだファイルを`Input/files/<requestId>`へ写し、写した大きさとSHA-256を返す。
  /// [maxBytes]を超えるファイルは写さずに失敗する。同じ名前のファイルが既にあれば、内容が同じときだけ成功する。
  Future<StagedAttachment> stageAttachment(
    VaultLocation location,
    String requestId,
    PickedAttachment file, {
    required int maxBytes,
  }) => throw UnsupportedError('この端末ではファイルを添えられません。');

  /// Vault内のファイル（`05_files`）を、端末の既定のアプリで開く。
  Future<void> openVaultFile(VaultLocation location, String path) =>
      throw UnsupportedError('この端末ではファイルを開けません。');
}

/// 起動時の操作として受け付ける名前。ほかの値は無視する。
/// `due`は期日の通知から開いたときで、同期済みの内容を読み込んでから次の一手を開く。
const launchActions = {'capture', 'guided', 'next', 'attention', 'due'};

/// アプリを閉じている間の通知の種類。確認待ち（attention）と期日（due）。
const notificationKinds = {'attention', 'due'};

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
  bool get withdrawSupported => true;

  @override
  Future<String> withdrawRequest(
    VaultLocation location,
    String requestId,
    String expectedSha256,
  ) async {
    if (!RegExp(r'^REQ-[a-f0-9]{32}$').hasMatch(requestId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
      throw const FormatException('取り下げる依頼を確かめられません。');
    }
    final result = await channel.invokeMethod<String>('withdrawRequest', {
      'handle': location.handle,
      'requestId': requestId,
      'sha256': expectedSha256,
    });
    if (!const ['withdrawn', 'missing', 'changed', 'started'].contains(result)) {
      throw const FormatException('取り下げの結果を確かめられません。');
    }
    return result!;
  }

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

  @override
  bool get dockBadgeSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<void> setDockBadge(int count) async {
    if (!dockBadgeSupported) return;
    await channel.invokeMethod('setDockBadge', {'count': count});
  }

  @override
  bool get calendarSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<void> addToCalendar(CalendarEvent event) async {
    if (!calendarSupported) return;
    await channel.invokeMethod('addToCalendar', {
      'uid': event.uid,
      'date': event.date,
      'title': event.title,
      'description': event.description,
      'ics': event.ics,
    });
  }

  @override
  bool get attentionNotificationsSupported => homeScreenSupported;

  @override
  Future<bool> setAttentionNotifications({
    required bool enabled,
    bool request = false,
    String kind = 'attention',
    Set<String>? active,
  }) async {
    if (!attentionNotificationsSupported) return false;
    final kinds = active ?? {kind};
    if (!notificationKinds.containsAll({kind, ...kinds})) {
      throw ArgumentError.value(kind);
    }
    return await channel.invokeMethod<bool>('attentionNotifications', {
          'enabled': enabled,
          'request': request,
          'kind': kind,
          'active': kinds.toList(),
        }) ==
        true;
  }

  @override
  Future<void> showAttentionNotification({
    required String key,
    required String title,
    required String text,
    String kind = 'attention',
  }) async {
    if (!attentionNotificationsSupported) return;
    if (!notificationKinds.contains(kind)) throw ArgumentError.value(kind);
    await channel.invokeMethod('showAttention', {
      'key': key,
      'title': title,
      'text': text,
      'kind': kind,
    });
  }

  @override
  Future<void> clearAttentionNotification({String kind = 'attention'}) async {
    if (!attentionNotificationsSupported) return;
    if (!notificationKinds.contains(kind)) throw ArgumentError.value(kind);
    await channel.invokeMethod('clearAttention', {'kind': kind});
  }

  @override
  Future<void> finishBackgroundCheck() async {
    if (!attentionNotificationsSupported) return;
    await channel.invokeMethod('backgroundDone');
  }

  @override
  bool get attachmentsSupported => calendarSupported;

  /// ファイルを添える・開く操作の失敗を、本人に分かる理由にする（Vaultの選び直しを促さない）。
  static Future<T> _attachmentCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      final message = attachmentFailureMessages[e.code];
      if (message != null) throw StateError(message);
      rethrow;
    }
  }

  @override
  Future<PickedAttachment?> pickAttachment() async {
    if (!attachmentsSupported) return null;
    final result = await _attachmentCall(
      () => channel.invokeMapMethod<String, Object?>('pickAttachment'),
    );
    if (result == null) return null;
    if (result case {
      'token': final String token,
      'name': final String name,
      'bytes': final int bytes,
    } when token.isNotEmpty && bytes >= 0) {
      return PickedAttachment(token, name, bytes);
    }
    throw const FormatException('選んだファイルを確かめられません。');
  }

  @override
  Future<StagedAttachment> stageAttachment(
    VaultLocation location,
    String requestId,
    PickedAttachment file, {
    required int maxBytes,
  }) async {
    if (!attachmentsSupported) {
      throw UnsupportedError('この端末ではファイルを添えられません。');
    }
    final result = await _attachmentCall(
      () => channel.invokeMapMethod<String, Object?>('stageAttachment', {
        'handle': location.handle,
        'requestId': requestId,
        'token': file.token,
        'maxBytes': maxBytes,
      }),
    );
    if (result case {
      'bytes': final int bytes,
      'sha256': final String sha256,
    } when bytes >= 0 && RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      return StagedAttachment(bytes, sha256);
    }
    throw const FormatException('写したファイルを確かめられません。');
  }

  @override
  Future<void> openVaultFile(VaultLocation location, String path) async {
    if (!attachmentsSupported) {
      throw UnsupportedError('この端末ではファイルを開けません。');
    }
    await _attachmentCall(
      () => channel.invokeMethod('openVaultFile', {
        'handle': location.handle,
        'path': path,
      }),
    );
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
