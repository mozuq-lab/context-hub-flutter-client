import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../storage/vault_access.dart';
import '../storage/capture_service.dart';
import '../storage/draft_store.dart';
import '../storage/template_store.dart';
import '../storage/basket_store.dart';
import '../core/repository.dart';
import '../core/attention.dart';
import '../core/home_widget.dart';
import '../core/today.dart';
import '../core/capture_progress.dart';
import '../core/review_candidates.dart';
import '../core/intake_features.dart' show unassignedScope;
import '../storage/review_service.dart';
import '../core/people.dart';
import '../core/models.dart';
import '../core/preferences.dart';
import '../core/templates.dart';
import 'dart:math' show Random;
import '../core/parser.dart' show clip, projectIdPattern;
import '../core/secrets.dart' show SecretPolicy;
import '../ai/guided_services.dart';

class ReviewConfirmation {
  ReviewConfirmation(
    this.candidate,
    this.fingerprint,
    this.identity,
    this.epoch, {
    this.target,
    this.retiring = false,
    this.covers = const [],
  });
  final ReviewCandidate candidate;
  final String fingerprint, identity;
  final int epoch;
  final AdoptionTarget? target;
  final bool retiring;

  /// 同じ対象を指す案として、同じ判断にまとめるプロジェクト案。確認の画面で内容を示す。
  final List<ReviewCandidate> covers;
}

/// 既読判定に使うNOWの1行。hashは欄と本文（出典・訂正の注記を除く）から作る。
/// textは外れた項目の表示用で、記録の容量を抑えるため短く切り、容量を超えると空にする。
class SeenItem {
  const SeenItem(this.section, this.hash, this.text);
  final String section, hash, text;
  String get id => '$section/$hash';

  static final _link = RegExp(r' ?\[IN-[0-9A-HJKMNP-TV-Z]{26}\]\(');

  /// 出典のない行（「不明」「残っている次の一手はありません」などの定型文）はnull。
  static SeenItem? of(String section, NowEntry entry) {
    final match = _link.firstMatch(entry.raw);
    if (match == null || entry.references.isEmpty) return null;
    final body = entry.raw.substring(0, match.start).trim();
    return SeenItem(
      section,
      digest('$section\u001f$body').substring(0, 16),
      clip(body, 60),
    );
  }
}

class ProjectChanges {
  const ProjectChanges({required this.added, required this.removed});
  final List<SeenItem> added, removed;
  bool get isEmpty => added.isEmpty && removed.isEmpty;
}

class HubController extends ChangeNotifier {
  HubController(
    this.access, {
    required this.sampleLoader,
    GuidedServices? guided,
    this.autoReloadInterval,
  }) : guidedServices = guided ?? GuidedServices.native();
  final VaultAccess access;
  final Future<Map<String, String>> Function() sampleLoader;

  /// 選んで深掘りが使うClaude APIとAPIキーの保管場所。使うときだけ呼ぶ。
  final GuidedServices guidedServices;
  VaultLocation? location;
  HubRepository? _repository;
  HubRepository? get repository => _repository;

  /// 読み直した記録にも、この端末のピン留めの並びを渡す。
  set repository(HubRepository? value) {
    _repository = value;
    _applyPins();
  }

  ReviewRepository? get review => repository?.review;
  final Map<String, String> _reviewOperations = {};
  bool loading = false, saving = false;
  bool _composing = false;

  /// 入力フォーム・確認を開いているか。閉じたときに、待たせていた知らせ（保存したメモの受付・整理）を出せるよう通知する。
  bool get composing => _composing;
  set composing(bool value) {
    if (_composing == value) return;
    _composing = value;
    // フォームを閉じる処理の途中（画面の組み立て中のこともある）で通知しないよう、少し後にする。
    if (!value && _notices.isNotEmpty) {
      scheduleMicrotask(() {
        if (!_disposed) notifyListeners();
      });
    }
  }

  String? error, captureWarning;
  List<CaptureResult> pending = [];
  int _epoch = 0;

  /// 再読込の世代（[reload]ごとに進める）。
  int _reloads = 0;
  bool _disposed = false;
  void _changed() {
    if (!_disposed) {
      // 確認のための読み直しなどで記録が入れ替わったら、判断待ちの件数も作り直す。
      if (_seenLoaded &&
          repository != null &&
          !identical(repository, _attentionFor) &&
          _syncAttention()) {
        _writeSettings().catchError((Object _) {});
      }
      // どの読み直しで記録が入れ替わっても、保存したメモの段階が進んだかを確かめる。
      if (repository != null && !identical(repository, _progressFor)) {
        _progressFor = repository;
        _syncProgress();
      }
      _syncHomeWidget();
      _syncDockBadge();
      notifyListeners();
    }
  }

  // ---- プロジェクトのピン留めと並び順（端末ごと・Vaultごと。Vaultには書かない） ----
  // settings.jsonの`pins`に、Vaultのidentityごとのピン留めしたプロジェクトIDを、本人が決めた順に保存する。
  static const maxPins = 30;
  static const _maxPinVaults = 12;
  Map<String, dynamic> _pins = {};

  /// ピン留めしたプロジェクトのID。読込済みのVaultにないものは返さない。
  List<String> get pinnedProjectIds =>
      repository?.pinnedProjects.map((p) => p.id).toList() ?? const [];

  List<String> _storedPins() {
    final value = _pins[location?.identity ?? ''];
    final seen = <String>{};
    return [
      if (value is List)
        for (final id in value)
          if (id is String && id.isNotEmpty && seen.add(id)) id,
    ];
  }

  void _applyPins() => _repository?.pinned = _storedPins();

  Future<void> _savePins(List<String> ids) async {
    final target = location, repo = repository;
    if (target == null || repo == null) throw StateError('先にVaultを選んでください。');
    // 呼び出し側が端末の設定を読んでから並びを作る。ここでは待たずに並びを置き、続けて押された操作と入れ違わないようにする。
    final before = _pins[target.identity];
    // いま使っているVaultを最後に置き、古いVaultの分から手放す。
    _pins.remove(target.identity);
    if (ids.isNotEmpty) _pins[target.identity] = ids;
    while (_pins.length > _maxPinVaults) {
      _pins.remove(_pins.keys.first);
    }
    _applyPins();
    final syncing = _markPreference('pins');
    try {
      await _writeSettings();
    } catch (_) {
      // 保存できなかった並びを、保存できたように見せない。
      if (before == null) {
        _pins.remove(target.identity);
      } else {
        _pins[target.identity] = before;
      }
      _applyPins();
      _changed();
      throw StateError('ピン留めを保存できませんでした。もう一度お試しください。');
    }
    _changed();
    if (syncing) _schedulePreferenceSend();
  }

  /// プロジェクトをピン留めする、または外す。新しいピン留めは末尾に加える。
  Future<void> setPinned(String projectId, bool pinned) async {
    final repo = repository;
    if (repo == null) throw StateError('先にVaultを選んでください。');
    if (pinned && !repo.projects.containsKey(projectId)) {
      throw StateError('このVaultにプロジェクトがありません。');
    }
    await _loadSeen();
    // 読めていない記録があるときは、見えないプロジェクトのピン留めを捨てない。
    final ids = _storedPins()
        .where(
          (id) =>
              id != projectId &&
              (repo.snapshot.limitReached || repo.projects.containsKey(id)),
        )
        .toList();
    if (pinned) {
      if (ids.where(repo.projects.containsKey).length >= maxPins) {
        throw StateError('ピン留めは$maxPins件までです。使っていないものを外してください。');
      }
      ids.add(projectId);
    }
    await _savePins(ids);
  }

  /// ピン留めしたプロジェクトを、並びの中で前（-1）または後ろ（+1）へ動かす。
  Future<void> movePin(String projectId, int delta) async {
    final repo = repository;
    if (repo == null) throw StateError('先にVaultを選んでください。');
    await _loadSeen();
    final ids = _storedPins();
    // 画面に見えている並び（Vaultにあるもの）の中で入れ替える。
    final shown = ids.where(repo.projects.containsKey).toList();
    final from = shown.indexOf(projectId), to = from + delta;
    if (from < 0 || to < 0 || to >= shown.length) return;
    final a = ids.indexOf(shown[from]), b = ids.indexOf(shown[to]);
    ids[a] = shown[to];
    ids[b] = shown[from];
    await _savePins(ids);
  }

  // ---- 好みを端末間でそろえる（ピン留めと並び順・ひな形・かごの上限） ----
  // settings.jsonの`preferenceSync`に、この端末の名前（device）と、Vaultのidentityごとに
  // まとまりごとの「この端末が持っている版の日時」（times）、まだ送れていないまとまり（dirty）、
  // 最後に送った受付ID（sent）を残す。Vaultごとに本人が有効にする。
  //
  // どちらが新しいかは、本体が記録した日時（受け付けた時刻より先の日時は丸められる）で決める。
  // - 本人の変更には、端末の時計と、知っている版の日時の1ミリ秒後の遅い方を付ける（時計の遅れた端末の変更が負けないように）。
  // - 自分が送った版がVaultに記録されたら、その日時（丸めた後）を持っている版の日時にする（時計の進んだ端末が、ほかの端末の後の変更を取りこぼさないように）。
  // - まとまりごとに別の受付ファイルで送る（1つが断られても、ほかのまとまりは届く）。
  Map<String, dynamic> _preferenceSync = {};
  Timer? _preferenceTimer;
  bool _sendingPreferences = false;

  /// 送らなかった・送れなかったときの知らせ（ひな形の秘密情報らしい文字列など）。なければnull。
  String? preferenceNotice;

  Map<String, dynamic>? _syncFor(String? identity) {
    final vaults = _preferenceSync['vaults'];
    final value = vaults is Map ? vaults[identity] : null;
    return value is Map<String, dynamic> ? value : null;
  }

  Map<String, dynamic>? get _syncVault => _syncFor(location?.identity);

  /// このVaultで好みをほかの端末とそろえているか。
  bool get preferenceSyncEnabled => _syncVault != null;

  /// 本体が好みの共有に対応しているか。
  bool get preferenceSyncSupported =>
      repository?.intakeFeatures.preferences ?? false;

  String get _deviceName {
    final current = _preferenceSync['device'];
    if (current is String &&
        RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(current)) {
      return current;
    }
    final random = Random.secure();
    final name =
        'app-${List.generate(12, (_) => random.nextInt(16).toRadixString(16)).join()}';
    _preferenceSync['device'] = name;
    return name;
  }

  static Map<String, dynamic> _mapOf(Map<String, dynamic> vault, String key) =>
      vault[key] is Map
      ? Map<String, dynamic>.from(vault[key] as Map)
      : <String, dynamic>{};

  DateTime? _preferenceTime(String group, [String? identity]) {
    final vault = _syncFor(identity ?? location?.identity);
    return vault == null
        ? null
        : DateTime.tryParse('${_mapOf(vault, 'times')[group]}');
  }

  Set<String> _dirtyOf(String? identity) {
    final dirty = _syncFor(identity)?['dirty'];
    return {
      if (dirty is List)
        for (final g in dirty)
          if (preferenceGroups.contains(g)) g as String,
    };
  }

  /// まとまりの状態を変える。[sent]を渡すと、最後に送った受付IDも記録する。
  void _setPreferenceState(
    String identity,
    String group,
    DateTime at, {
    required bool dirty,
    String? sent,
  }) {
    final vault = _syncFor(identity);
    if (vault == null) return;
    final times = _mapOf(vault, 'times'), pending = _dirtyOf(identity);
    times[group] = at.toUtc().toIso8601String();
    dirty ? pending.add(group) : pending.remove(group);
    vault['times'] = times;
    vault['dirty'] = [
      for (final g in preferenceGroups)
        if (pending.contains(g)) g,
    ];
    if (sent != null) vault['sent'] = _mapOf(vault, 'sent')..[group] = sent;
  }

  /// 本人の変更に付ける日時。知っている版（この端末の版とVaultの版）より必ず後にする。
  DateTime _stamp(String identity, String group) {
    var known = _preferenceTime(group, identity);
    if (identity == location?.identity) {
      final shared = repository?.sharedPreferences[group]?.updatedAt;
      if (shared != null && (known == null || shared.isAfter(known))) {
        known = shared;
      }
    }
    final now = DateTime.now().toUtc(),
        after = known?.add(const Duration(milliseconds: 1));
    return after != null && after.isAfter(now) ? after : now;
  }

  /// 本人が変えたまとまりを、待たずに「送っていない変更」として記録する（記録の前に読込が割り込んで、Vaultの版で上書きしないように）。
  /// ひな形は端末で1つなので、そろえているほかのVaultにも、次に開いたときに送る。そろえていなければfalse。
  bool _markPreference(String group) {
    final identity = location?.identity;
    final targets = group == 'templates'
        ? [
            if (_preferenceSync['vaults'] case final Map vaults)
              for (final k in vaults.keys)
                if (k is String) k,
          ]
        : [?identity];
    var marked = false;
    for (final id in targets) {
      if (_syncFor(id) == null) continue;
      _setPreferenceState(id, group, _stamp(id, group), dirty: true);
      marked = true;
    }
    return marked;
  }

  void _schedulePreferenceSend() {
    _preferenceTimer?.cancel();
    _preferenceTimer = Timer(const Duration(seconds: 2), () {
      sendPreferences().catchError((Object _) {});
    });
  }

  /// まだ送っていないまとまりを、まとまりごとの受付ファイルで送る。本体が受け付けていないときは何もしない。
  Future<void> sendPreferences() async {
    final target = location, repo = repository;
    if (target == null ||
        repo == null ||
        _disposed ||
        _sendingPreferences ||
        !preferenceSyncEnabled ||
        !repo.intakeFeatures.preferences) {
      return;
    }
    final identity = target.identity;
    bool still() => !_disposed && location?.identity == identity;
    _sendingPreferences = true;
    final notices = <String>[];
    try {
      for (final group in _dirtyOf(identity)) {
        final at = _preferenceTime(group, identity) ?? _stamp(identity, group);
        Map<String, Object?>? value;
        switch (group) {
          case 'pins':
            value = {
              'ids': _storedPins()
                  .where(projectIdPattern.hasMatch)
                  .take(maxPins)
                  .toList(),
            };
          case 'basket':
            // 読み込んだかごがこのVaultのものでなければ、次の機会に送る（別のVaultの上限を送らない）。
            if (_basketFor == identity) {
              value = {'max_chars': basket.maxChars};
            }
          case 'templates':
            final list = await templates.list();
            if (!still()) return;
            if (templates.unreadable) continue;
            final policy = repo.secretPolicy.usable
                ? repo.secretPolicy
                : SecretPolicy.builtin;
            if (list.any(
              (t) => policy.find('${t.name}\n${t.body}').isNotEmpty,
            )) {
              // 秘密情報らしい文字列を、同期するファイルへ広げない（本体も断る）。
              notices.add(
                'ひな形に秘密情報らしい文字列があるため、ひな形はほかの端末とそろえていません。ひな形から取り除くと、そろえます。',
              );
              continue;
            }
            value = {
              'items': [
                for (final t in list)
                  {
                    'id': t.id,
                    'name': t.name.trim(),
                    'body': t.body,
                    'project': ?_templateProject(t, identity),
                  },
              ],
            };
        }
        if (value == null) continue;
        final payload = encodePreferencesPayload(_deviceName, {
          group: (at: at, value: value),
        });
        if (preferenceGroupsOf(payload) == null) {
          // 本体の受付ファイルの上限（32KiB）を超えるなど、送れない形。
          notices.add(
            '${preferenceGroupLabels[group]}が大きすぎるため、ほかの端末とそろえていません。短くすると、そろえます。',
          );
          continue;
        }
        final result = await CaptureService(
          access,
          target,
        ).savePreferences(const Uuid().v4(), payload);
        if (!still()) return;
        // 送っている間に本人がもう一度変えたまとまりは、次にまた送る。
        if (result.saved && _preferenceTime(group, identity) == at) {
          _setPreferenceState(
            identity,
            group,
            at,
            dirty: false,
            sent: result.requestId,
          );
        }
      }
      preferenceNotice = notices.isEmpty ? null : notices.join('\n');
      try {
        await _writeSettings();
      } catch (_) {}
    } finally {
      _sendingPreferences = false;
      _changed();
    }
  }

  /// このVaultで好みをそろえ始める。[useVault]がtrueなら、Vaultにある好みをこの端末へ取り込み、
  /// Vaultにないまとまりだけを送る。falseなら、この端末の好みを送ってほかの端末にそろえてもらう。
  Future<void> enablePreferenceSync({required bool useVault}) async {
    final target = location, repo = repository;
    if (target == null || repo == null) throw StateError('先にVaultを選んでください。');
    if (!repo.intakeFeatures.preferences) {
      throw StateError('Mac miniの本体が好みの共有に対応していません。本体を更新してください。');
    }
    await _loadSeen();
    if (location?.identity != target.identity) return;
    _deviceName;
    final vaults = _preferenceSync['vaults'] is Map
        ? Map<String, dynamic>.from(_preferenceSync['vaults'] as Map)
        : <String, dynamic>{};
    vaults[target.identity] = <String, dynamic>{
      'times': <String, dynamic>{},
      'dirty': <String>[],
    };
    _preferenceSync['vaults'] = vaults;
    for (final group in preferenceGroups) {
      final shared = repo.sharedPreferences[group];
      if (useVault && shared != null) {
        await _applySharedPreference(target.identity, group, shared);
      } else {
        _setPreferenceState(
          target.identity,
          group,
          _stamp(target.identity, group),
          dirty: true,
        );
      }
    }
    await _writeSettings();
    _changed();
    await sendPreferences();
  }

  /// このVaultで好みをそろえるのをやめる。この端末の好みはそのまま残る。
  Future<void> disablePreferenceSync() async {
    final vaults = _preferenceSync['vaults'];
    if (vaults is Map) vaults.remove(location?.identity);
    _preferenceTimer?.cancel();
    preferenceNotice = null;
    await _writeSettings();
    _changed();
  }

  /// 読み込んだVaultの好みと、この端末の版を比べる。
  /// - 自分が送った版が記録されていれば、記録の日時を持っている版の日時にする（取り込み直さない）。
  /// - この端末の版より新しい版は取り込む（まだ送っていない変更より新しくても、後の変更が勝つ）。
  /// - 送った依頼が断られていれば、理由を知らせる。
  Future<void> _syncPreferences() async {
    final repo = repository, identity = location?.identity;
    if (repo == null || identity == null || !preferenceSyncEnabled) return;
    var changed = false;
    final notices = <String>[];
    for (final group in preferenceGroups) {
      final vault = _syncFor(identity);
      if (vault == null) return;
      final sent = _mapOf(vault, 'sent')[group];
      final dirty = _dirtyOf(identity).contains(group);
      if (sent is String) {
        final request = repo.intake.where((i) => i.id == sent).firstOrNull;
        if (request != null &&
            const ['rejected', 'conflict'].contains(request.state)) {
          notices.add(
            '${preferenceGroupLabels[group]}をそろえられませんでした: ${request.detail}',
          );
        }
      }
      final shared = repo.sharedPreferences[group],
          local = _preferenceTime(group, identity);
      if (shared == null) continue;
      if (sent is String && shared.requestId == sent) {
        if (!dirty && local != shared.updatedAt) {
          _setPreferenceState(identity, group, shared.updatedAt, dirty: false);
          changed = true;
        }
        continue;
      }
      if (local != null && !shared.updatedAt.isAfter(local)) continue;
      try {
        await _applySharedPreference(identity, group, shared);
        changed = true;
      } catch (_) {
        // 取り込めなかったまとまりは、次の読込で試し直す。
      }
      if (location?.identity != identity) return;
    }
    if (notices.isNotEmpty) preferenceNotice = notices.join('\n');
    if (changed) {
      try {
        await _writeSettings();
      } catch (_) {}
    }
    if (_dirtyOf(identity).isNotEmpty) _schedulePreferenceSend();
  }

  Future<void> _applySharedPreference(
    String identity,
    String group,
    SharedPreference shared,
  ) async {
    if (location?.identity != identity) return;
    switch (group) {
      case 'pins':
        final ids = pinsValue(shared.value);
        if (ids == null) return;
        _pins.remove(identity);
        if (ids.isNotEmpty) _pins[identity] = ids;
        while (_pins.length > _maxPinVaults) {
          _pins.remove(_pins.keys.first);
        }
        _applyPins();
      case 'templates':
        final items = templatesValue(shared.value);
        if (items == null) return;
        final current = {for (final t in await templates.list()) t.id: t};
        if (templates.unreadable || location?.identity != identity) return;
        await templates.save([
          for (final i in items)
            MemoTemplate(
              id: i.template.id,
              name: i.template.name,
              body: i.template.body,
              projects: current[i.template.id]?.projects ?? const {},
            ).withProject(identity, i.project),
        ]);
      case 'basket':
        final max = basketValue(shared.value);
        if (max == null) return;
        final target = location!;
        await _ensureBasket(target);
        if (_basketFor != identity || location?.identity != identity) return;
        basket = Basket(ids: basket.ids, maxChars: max);
        await baskets.write(identity, basket);
    }
    if (location?.identity != identity) return;
    _setPreferenceState(identity, group, shared.updatedAt, dirty: false);
  }

  static String? _templateProject(MemoTemplate t, String identity) {
    final p = t.projects[identity];
    return p != null && projectIdPattern.hasMatch(p) ? p : null;
  }

  /// ひな形の並びを保存する。好みをそろえていれば、ほかの端末へも送る。
  Future<void> saveTemplates(List<MemoTemplate> next) async {
    final syncing = _markPreference('templates');
    await templates.save(next);
    if (syncing) await _preferenceChangedSaved();
  }

  /// 記録した変更を端末の設定に残し、少し待ってから送る。
  Future<void> _preferenceChangedSaved() async {
    try {
      await _writeSettings();
    } catch (_) {}
    _schedulePreferenceSend();
  }

  // ---- 同期で届いた変更の自動の読込（端末ごと。Vaultには書かない） ----
  /// アプリを前面に出している間に、Vaultが変わっていないかを確かめる間隔。nullなら確かめない（テストの既定）。
  /// 前面に戻ったときの確認は、この値に関わらず[autoReload]が有効なら行う。
  final Duration? autoReloadInterval;

  /// 同期で届いた変更を自動で読み込むか。settings.jsonの`autoReload`（既定は有効）。
  bool autoReload = true;

  /// 自動の読込の設定を変える。設定は端末に保存する。
  Future<void> setAutoReload(bool enabled) async {
    if (location == null) throw StateError('先にVaultを選んでください。');
    await _loadSeen();
    final before = autoReload;
    autoReload = enabled;
    try {
      await _writeSettings();
    } catch (_) {
      autoReload = before;
      _changed();
      throw StateError('設定を保存できませんでした。もう一度お試しください。');
    }
    _changed();
  }

  /// 前回の読込から変わっていないか。ファイルの更新時刻と大きさが分かる端末ではそれで、分からなければ本文で比べる。
  static bool _sameSnapshot(VaultSnapshot a, VaultSnapshot b) {
    if (!listEquals(a.warnings, b.warnings) || a.recognized != b.recognized) {
      return false;
    }
    if (a.stamps.isNotEmpty && b.stamps.isNotEmpty) {
      if (!mapEquals(a.stamps, b.stamps) ||
          !setEquals(a.files.keys.toSet(), b.files.keys.toSet())) {
        return false;
      }
      // 書き込まれた直後のファイルには更新時刻と大きさが付かない。そうしたファイルは本文で比べる。
      return b.files.keys
          .where((path) => !b.stamps.containsKey(path))
          .every((path) => a.files[path] == b.files[path]);
    }
    return a.fingerprint == b.fingerprint;
  }

  /// 表示を止めずに、同期で届いた変更があれば読み込む。変わっていなければ表示を差し替えない。
  /// 読込・保存・入力の途中では何もしない。読めなかったときは前の表示を残し、知らせない（本人の再読込で示す）。
  /// 読み込んだらtrue。
  Future<bool> refreshQuietly() async {
    final target = location, previous = repository?.snapshot;
    if (target == null ||
        previous == null ||
        loading ||
        saving ||
        composing ||
        error != null ||
        _quietRunning) {
      return false;
    }
    _quietRunning = true;
    try {
      return await _refreshQuietly(target, previous);
    } finally {
      _quietRunning = false;
    }
  }

  /// 自動の読込を実行中か。前の読込が終わるまで次を始めない（大きなVaultで読み続けないように）。
  bool _quietRunning = false;

  /// 最後にVaultが変わっていないかを確かめた（または読み込んだ）時刻。前面に戻ったときの間引きに使う。
  DateTime? lastCheckedAt;

  Future<bool> _refreshQuietly(
    VaultLocation target,
    VaultSnapshot previous,
  ) async {
    final epoch = _epoch, generation = ++_reloads;
    // 読んでいる間に、確認のための読み直しで記録が新しくなった、または入力・保存が始まったら、結果を使わない。
    bool current() =>
        epoch == _epoch &&
        generation == _reloads &&
        !loading &&
        !saving &&
        !composing &&
        !_disposed &&
        identical(repository?.snapshot, previous);
    try {
      final data = await access.refreshSnapshot(target, previous);
      if (!current()) return false;
      lastCheckedAt = DateTime.now();
      if (_sameSnapshot(previous, data)) {
        // ファイルは変わっていなくても、日付が変われば今日の3つの持ち越しを反映する。
        if (_syncToday()) {
          await _writeSettings().catchError((Object _) {});
          _changed();
        }
        return false;
      }
      repository = HubRepository(data);
      await _ensureBasket(target);
      await _loadSeen();
      bool still() => epoch == _epoch && generation == _reloads && !_disposed;
      if (!still()) return false;
      final seen = _initializeSeen(),
          attended = _syncAttention(),
          rolled = _syncToday();
      if (seen || attended || rolled) {
        await _writeSettings().catchError((Object _) {});
      }
      await _pending(target, epoch, still);
      _changed();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- この端末から保存したメモの進み具合（アプリを開いている間だけ。どこにも保存しない） ----
  static const _maxTracked = 50;
  final Map<String, CaptureStage> _tracked = {};

  /// 段階を確かめた記録。記録が入れ替わったら確かめ直す。
  HubRepository? _progressFor;
  final List<CaptureNotice> _notices = [];

  /// 段階が進んだことの知らせがあるか。
  bool get hasCaptureNotices => _notices.isNotEmpty;

  /// 段階が進んだことの知らせを受け取り、空にする。
  List<CaptureNotice> takeCaptureNotices() {
    final out = List<CaptureNotice>.of(_notices);
    _notices.clear();
    return out;
  }

  void _track(CaptureResult result) {
    if (!result.saved) return;
    _tracked[result.requestId] = CaptureStage.saved;
    while (_tracked.length > _maxTracked) {
      _tracked.remove(_tracked.keys.first);
    }
  }

  /// 読み込んだ記録で、保存したメモの段階が進んだかを確かめる。整理済み・受け付けられなかったものは見届けて外す。
  void _syncProgress() {
    final repo = repository;
    if (repo == null) return;
    for (final e in _tracked.entries.toList()) {
      final stage = captureStage(repo, e.key);
      if (stage.index <= e.value.index) continue;
      _notices.add(CaptureNotice(e.key, stage));
      if (stage == CaptureStage.organized || stage == CaptureStage.failed) {
        _tracked.remove(e.key);
      } else {
        _tracked[e.key] = stage;
      }
    }
  }

  // ---- 今日の3つ（端末ごと・Vaultごと。Vaultには書かない） ----
  // settings.jsonの`today`に、Vaultのidentityごとの今日選んだ項目と、持ち越しの確認を保存する。
  static const _maxTodayVaults = 6;
  Map<String, dynamic> _today = {};

  /// 今日の3つ。日付が変わっていれば、片付いていない項目を持ち越しの確認へ回した状態を返す
  /// （保存は次に設定を書くとき。読むたびに持ち越しの日数は増えない）。
  TodayFocus get today {
    final stored = TodayFocus.fromJson(_today[location?.identity ?? '']);
    final repo = repository;
    if (repo == null) return stored;
    return stored.rollOver(hubToday(), (p) => todayOpen(repo, p));
  }

  /// 日付が変わった後の状態を記録へ反映する。記録が変わったらtrue（設定の保存が要る）。
  bool _syncToday() {
    final target = location;
    if (target == null || repository == null) return false;
    final stored = _today[target.identity];
    if (stored == null) return false;
    final next = today;
    if (jsonEncode(next.toJson()) == jsonEncode(stored)) return false;
    _putToday(target.identity, next);
    return true;
  }

  void _putToday(String identity, TodayFocus value) {
    // いま使っているVaultを最後に置き、古いVaultの分から手放す。
    _today.remove(identity);
    if (!value.isEmpty) _today[identity] = value.toJson();
    while (_today.length > _maxTodayVaults) {
      _today.remove(_today.keys.first);
    }
  }

  Future<void> _saveToday(
    TodayFocus Function(TodayFocus current) change,
  ) async {
    final target = location;
    if (target == null || repository == null) {
      throw StateError('先にVaultを選んでください。');
    }
    await _loadSeen();
    final before = Map<String, dynamic>.from(_today);
    _putToday(target.identity, change(today));
    try {
      await _writeSettings();
    } catch (_) {
      // 保存できなかった選択を、保存できたように見せない。
      _today = before;
      _changed();
      throw StateError('今日の3つを保存できませんでした。もう一度お試しください。');
    }
    _changed();
  }

  /// 次の一手・未解決の項目を、今日の3つに加える（[on]がfalseなら外す）。
  /// 持ち越しの確認にある項目を加えると、「今日も続ける」として持ち越しから移す。
  Future<void> setToday(String projectId, String itemKey, bool on) async {
    if (!on) return _saveToday((t) => t.remove(itemKey));
    final repo = repository;
    // プロジェクト未定の行は、本体の項目一覧（_unassigned）から選ぶ。
    if (projectId == unassignedScope) {
      final item = repo?.unassignedItems
          .where((i) => i.key == itemKey)
          .firstOrNull;
      if (item == null || item.resolved) {
        throw StateError('この行は片付いたか、一覧から見つかりません。再読込して確かめてください。');
      }
      return _saveToday((t) => t.add(TodayPick.unassigned(item)));
    }
    final project = repo?.projects[projectId];
    final item = project?.nowItems.where((i) => i.key == itemKey).firstOrNull;
    if (project == null || item == null || item.resolved) {
      throw StateError('この項目は片付いたか、現状から見つかりません。再読込して確かめてください。');
    }
    await _saveToday((t) => t.add(TodayPick.of(project, item)));
  }

  /// 持ち越しの確認から外す（今日はやらない）。
  Future<void> dropCarried(String itemKey) =>
      _saveToday((t) => t.remove(itemKey));

  /// 持ち越しの確認をすべて外す。
  Future<void> clearCarried() => _saveToday((t) => t.clearCarry());

  // ---- Androidのホーム画面ウィジェット（端末の表示だけ。Vaultには書かない） ----
  /// 表示設定はVaultごとに持つ。サンプルや別のVaultで選んだ設定を、ほかのVaultへ持ち込まない。
  Map<String, dynamic> _homeWidgets = {};
  HomeWidgetSettings get homeWidget =>
      HomeWidgetSettings.fromJson(_homeWidgets[location?.identity]);
  bool get homeScreenSupported => access.homeScreenSupported;
  String? _homeWidgetSent;
  bool _homeWidgetEverSent = false;

  /// 読込済みの記録が変わったら、ウィジェットに出す内容を渡し直す。
  /// 読込中と再読込の失敗では前の内容を残し、表示できる記録がなくなったら内容を消す。
  void _syncHomeWidget() {
    if (!access.homeScreenSupported) return;
    final repo = repository;
    if (repo == null && loading) return;
    String? content;
    if (repo != null) {
      try {
        content = encodeHomeWidget(
          homeWidgetContent(repo, settings: homeWidget, focus: today.picks),
        );
      } catch (_) {
        content = null;
      }
    }
    if (_homeWidgetEverSent && content == _homeWidgetSent) return;
    _homeWidgetEverSent = true;
    _homeWidgetSent = content;
    // 表示の更新に失敗しても、アプリの操作は続ける。
    access.updateHomeWidget(content).catchError((Object _) {});
  }

  /// ウィジェットの表示設定を変える。設定は端末に保存する。
  Future<void> setHomeWidget(HomeWidgetSettings settings) async {
    final target = location;
    if (target == null) throw StateError('先にVaultを選んでください。');
    await _loadSeen();
    if (settings == const HomeWidgetSettings()) {
      _homeWidgets.remove(target.identity);
    } else {
      _homeWidgets[target.identity] = settings.toJson();
    }
    await _writeSettings();
    _changed();
  }

  // ---- 判断待ちの件数と既読（端末ごと。Vaultには書かない） ----
  /// 読込済みの記録にある判断待ち（確認待ちの候補・作業記録の下書き・止まったNOW）。
  List<AttentionItem> attention = const [];
  AttentionState _attention = const AttentionState();

  /// アプリを閉じている間の確認待ちの通知を使う設定（Androidだけ）。
  bool attentionNotify = false;
  bool get attentionNotificationsSupported =>
      access.attentionNotificationsSupported;

  /// 設定は有効だが、端末で通知が許可されていない（起動時に確かめた結果）。
  bool attentionNotifyBlocked = false;

  /// アプリを閉じている間の期日の通知を使う設定（Androidだけ）。確認待ちの通知とは別に切り替える。
  bool dueNotify = false;

  /// 期日の通知の設定は有効だが、端末で通知が許可されていない（起動時に確かめた結果）。
  bool dueNotifyBlocked = false;

  /// 期日の通知から「次の一手」を開いた回数。画面は、増えたら「次の一手」の欄に戻し、絞り込みを外す
  /// （通知で数えた項目が、前に開いていた欄や絞り込みで隠れないように）。
  int dueOpened = 0;
  String _visiblePage = 'home';
  int? _dockBadgeSent;
  bool _attentionScheduleChecked = false;

  /// 判断待ちを数えた記録。記録が入れ替わったら数え直す。
  HubRepository? _attentionFor;

  /// 直近に届いた（それまでアプリで出していなかった）判断待ちの鍵。通知から開く画面を決める。
  Set<String> _attentionArrived = const {};

  /// [page]で判断できる判断待ちの件数。
  int attentionCount(String page) =>
      attention.where((i) => i.page == page).length;

  /// [page]の判断待ちのうち、まだその画面で見ていない件数。
  int attentionFresh(String page) =>
      attention.where((i) => i.page == page && !_attention.seen(i)).length;

  /// 通知から開く画面。直近に届いた判断待ち（なければ、まだ見ていない判断待ち）を判断できる画面で、
  /// どちらもなければ確認待ちの一覧。
  String get attentionLanding {
    final fresh = attention.where((i) => !_attention.seen(i)).toList();
    return fresh
            .where((i) => _attentionArrived.contains(i.key))
            .firstOrNull
            ?.page ??
        fresh.firstOrNull?.page ??
        'review';
  }

  /// 読み込んだ判断待ちを既読の記録へ反映する。記録が変わったらtrue（設定の保存が要る）。
  bool _syncAttention() {
    final repo = repository, target = location;
    if (repo == null || target == null) return false;
    _attentionFor = repo;
    var complete = false;
    try {
      attention = attentionItems(repo);
      complete = attentionComplete(repo);
    } catch (_) {
      // 件数を作れなくても、閲覧と操作は続ける。
      attention = const [];
      return false;
    }
    if (_attention.identity == target.identity) {
      final arrived = _attention.unknown(attention);
      if (arrived.isNotEmpty) {
        _attentionArrived = {for (final i in arrived) i.key};
      }
    } else {
      _attentionArrived = const {};
    }
    // アプリで件数を出したので、端末に出ている通知は消す。失敗しても操作は続ける。
    if (access.attentionNotificationsSupported) {
      access.clearAttentionNotification().catchError((Object _) {});
    }
    final next = _attention.sync(
      target.identity,
      attention,
      visible: _shown ? _visiblePage : null,
      // 同期の途中や読取の失敗で判断待ちが欠けて見えるときは、見つからない記録を消さない。
      prune: complete,
    );
    if (next == _attention) return false;
    _attention = next;
    return true;
  }

  /// Macのドックのアイコンに判断待ちの件数を出す。読込中と再読込の失敗では前の件数を残す。
  void _syncDockBadge() {
    if (!access.dockBadgeSupported) return;
    if (repository == null && loading) return;
    final count = repository == null ? 0 : attention.length;
    if (count == _dockBadgeSent) return;
    _dockBadgeSent = count;
    // 表示の更新に失敗しても、アプリの操作は続ける。
    access.setDockBadge(count).catchError((Object _) {});
  }

  /// ウインドウが見えているか。閉じている（隠れている）間に読み直しても、開いていた画面のものを既読にしない。
  bool _shown = true;

  /// ウインドウが見えるようになった・隠れたことを伝える。見えるようになったら、開いている画面のものを既読にする。
  Future<void> setShown(bool shown) async {
    if (_shown == shown) return;
    _shown = shown;
    if (shown) await showPage(_visiblePage);
  }

  /// 開いている画面を伝える。その画面で判断できるものは見たものとして既読にする。
  Future<void> showPage(String page) async {
    _visiblePage = page;
    final next = _attention.markSeen(page, attention);
    if (next == _attention) return;
    _attention = next;
    try {
      await _writeSettings();
    } catch (_) {
      // 既読の記録に失敗しても閲覧は続ける。
    }
    _changed();
  }

  /// 確認待ちの通知の設定を変える。有効にできなかった（端末で通知が許可されていない）ときはfalse。
  Future<bool> setAttentionNotify(bool enabled) async {
    if (location == null) throw StateError('先にVaultを選んでください。');
    await _loadSeen();
    if (!await _switchNotifications('attention', enabled)) return false;
    attentionNotify = enabled;
    attentionNotifyBlocked = false;
    await _writeSettings();
    _changed();
    return true;
  }

  /// 期日の通知の設定を変える。有効にできなかった（端末で通知が許可されていない）ときはfalse。
  Future<bool> setDueNotify(bool enabled) async {
    if (location == null) throw StateError('先にVaultを選んでください。');
    await _loadSeen();
    if (!await _switchNotifications('due', enabled)) return false;
    dueNotify = enabled;
    dueNotifyBlocked = false;
    await _writeSettings();
    _changed();
    return true;
  }

  /// 有効にしている通知の種類。[change]の種類だけを入れ替えて数える。
  Set<String> _notifyKinds([String? change, bool enabled = false]) => {
    if (change == 'attention' ? enabled : attentionNotify) 'attention',
    if (change == 'due' ? enabled : dueNotify) 'due',
  };

  /// [kind]の通知を切り替える。数時間おきの確認は2種類で共有するため、もう一方の通知を
  /// 使っている間は、無効にしても確認の登録を残し、[kind]の出ている通知だけを消す。
  /// 有効にするときは、許可がまだなら端末の許可画面を出す。許可されなければfalse。
  Future<bool> _switchNotifications(String kind, bool enabled) async {
    final active = _notifyKinds(kind, enabled);
    if (enabled) {
      final ok = await access.setAttentionNotifications(
        enabled: true,
        request: true,
        kind: kind,
        active: active,
      );
      // 許可画面で許可されたら、もう一方の「許可されていない」表示も確かめ直す。
      if (ok) await _recheckBlocked(kind == 'attention' ? 'due' : 'attention');
      return ok;
    }
    final rest = active.firstOrNull;
    if (rest == null) {
      await access.setAttentionNotifications(
        enabled: false,
        kind: kind,
        active: const {},
      );
    } else {
      // 残る種類だけを確認の対象として伝え直す（残る種類も止められていれば、確認の登録を消す）。
      final ok = await access.setAttentionNotifications(
        enabled: true,
        kind: rest,
        active: active,
      );
      _setBlocked(rest, !ok);
      await access.clearAttentionNotification(kind: kind);
    }
    return true;
  }

  /// [kind]の通知が有効で「許可されていない」と示しているとき、許可を確かめ直す。
  Future<void> _recheckBlocked(String kind) async {
    final blocked = kind == 'attention'
        ? attentionNotifyBlocked
        : dueNotifyBlocked;
    if (!blocked || !_notifyKinds().contains(kind)) return;
    try {
      final ok = await access.setAttentionNotifications(
        enabled: true,
        kind: kind,
        active: _notifyKinds(),
      );
      _setBlocked(kind, !ok);
    } catch (_) {
      // 確かめられなくても、切り替えは続ける。
    }
  }

  void _setBlocked(String kind, bool blocked) {
    if (kind == 'attention') {
      attentionNotifyBlocked = blocked;
    } else {
      dueNotifyBlocked = blocked;
    }
  }

  /// 起動のたびに一度、設定が有効なら数時間おきの確認を登録し直す（端末の再起動で消えるため）。
  void _ensureAttentionSchedule() {
    if (_attentionScheduleChecked) return;
    _attentionScheduleChecked = true;
    if (!access.attentionNotificationsSupported) return;
    final active = _notifyKinds();
    for (final kind in active) {
      access
          .setAttentionNotifications(enabled: true, kind: kind, active: active)
          .then((granted) {
            if (granted || _disposed || !_notifyKinds().contains(kind)) return;
            // 端末の設定で通知を止められている。設定の画面で知らせる。
            _setBlocked(kind, true);
            notifyListeners();
          })
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _preferenceTimer?.cancel();
    _epoch++;
    super.dispose();
  }

  static String message(Object e) => e is StateError
      ? e.message.toString()
      : e is FormatException
      ? e.message
      : 'アクセスに失敗しました。保存先と権限を確認してください。';
  void _maySwitch() {
    if (composing || saving) {
      throw StateError('入力フォームを閉じてからVaultを切り替えてください。');
    }
  }

  Future<void> restore() async {
    try {
      final raw = await access.readState('settings.json');
      if (raw == null) {
        return;
      }
      final value = jsonDecode(raw) as Map<String, dynamic>;
      await activate(VaultLocation.fromJson(value));
    } catch (e) {
      error = message(e);
      _changed();
    }
  }

  Future<void> useSample() async {
    _maySwitch();
    await activate(await access.sampleVault(await sampleLoader()));
  }

  Future<void> chooseVault() async {
    _maySwitch();
    final target = await access.pickVault();
    if (target != null) {
      await activate(target);
    }
  }

  Future<void> _pending(
    VaultLocation target,
    int epoch, [
    bool Function()? current,
  ]) async {
    bool still() => epoch == _epoch && (current?.call() ?? true);
    try {
      final list = await CaptureService(access, target).pending();
      if (still()) {
        pending = list;
        captureWarning = null;
      }
    } catch (e) {
      if (still()) {
        captureWarning = message(e);
        pending = [];
      }
    }
  }

  Future<void> activate(VaultLocation target) async {
    _maySwitch();
    final epoch = ++_epoch;
    loading = true;
    error = null;
    repository = null;
    attention = const [];
    location = target;
    pending = [];
    captureWarning = null;
    basket = const Basket();
    _basketFor = null;
    // 前のVaultで保存したメモの知らせは、別のVaultで出さない。
    _tracked.clear();
    _notices.clear();
    _changed();
    try {
      final data = await access.readSnapshot(target);
      if (epoch != _epoch) {
        return;
      }
      repository = HubRepository(data);
      lastCheckedAt = DateTime.now();
      _visits.clear();
      await _ensureBasket(target);
      if (epoch != _epoch) return;
      await _loadSeen();
      _initializeSeen();
      _syncAttention();
      _syncToday();
      await _writeSettings();
      await _syncPreferences();
      await _pending(target, epoch);
    } catch (e) {
      if (epoch == _epoch) {
        error = message(e);
      }
    } finally {
      if (epoch == _epoch) {
        loading = false;
        _changed();
      }
    }
  }

  Future<void> reload() async {
    final target = location;
    if (target == null) {
      return;
    }
    // Vaultの切替（_epoch）とは別に、再読込の世代を数える。後から始めた再読込があれば、
    // 先に始めた再読込の結果は使わない（遅れて終わった古い読取で新しい表示を上書きしない）。
    final epoch = _epoch, generation = ++_reloads;
    bool current() => epoch == _epoch && generation == _reloads;
    final previous = repository?.snapshot;
    loading = true;
    error = null;
    _changed();
    try {
      // 表示の更新では、変わっていないファイルを読み直さない。
      final data = previous == null
          ? await access.readSnapshot(target)
          : await access.refreshSnapshot(target, previous);
      if (!current()) return;
      repository = HubRepository(data);
      lastCheckedAt = DateTime.now();
      // Vaultを開くのに失敗した後の再読込でも、残したかごを読んでから使う（空のかごで上書きしない）。
      await _ensureBasket(target);
      // Vaultを開くのに失敗した後の再読込でも、残した設定（既読・ピン留め・ウィジェット・判断待ち）を読んでから書く（空の設定で上書きしない）。
      await _loadSeen();
      if (!current()) return;
      final seen = _initializeSeen(),
          attended = _syncAttention(),
          rolled = _syncToday();
      if (seen || attended || rolled) {
        try {
          await _writeSettings();
        } catch (_) {
          // 既読の記録に失敗しても閲覧は続ける。
        }
      }
      if (current()) await _syncPreferences();
      await _pending(target, epoch, current);
    } catch (e) {
      if (current()) {
        error = message(e);
      }
    } finally {
      if (current()) {
        loading = false;
        _changed();
      }
    }
  }

  Future<String> context(String project) async =>
      (await _verifiedRepository()).context(project);

  /// コピーの直前に読み直し、表示中の内容と同じで、確認の間にも変わっていないVaultを返す。
  /// 変わっていれば表示を更新して止める（内容を確かめてからもう一度コピーしてもらう）。
  Future<HubRepository> _verifiedRepository() async {
    final target = location, old = repository;
    final epoch = _epoch;
    if (target == null || old == null || loading || error != null) {
      throw StateError('先にVaultを再読込してください。');
    }
    final fresh = await access.readSnapshot(target);
    if (epoch != _epoch || _disposed) {
      throw StateError('Vaultが切り替わりました。');
    }
    final parsed = HubRepository(fresh);
    repository = parsed;
    _changed();
    if (old.snapshot.fingerprint != fresh.fingerprint) {
      throw StateError('Vaultに変更がありました。表示を更新したので、内容を確認してからコピーしてください。');
    }
    // 列挙後に届いた採用・停止を、別の走査でもう一度照合する。
    final confirmed = await access.readSnapshot(target);
    if (epoch != _epoch || _disposed) throw StateError('Vaultが切り替わりました。');
    // 読取の注意の有無は、読み直した内容（parsed）でコピーする資料ごとに判断する。
    // 確認の走査で注意が変わったときは、判断の前提が変わったので止める。
    if (!confirmed.recognized ||
        confirmed.warnings.join('\n') != fresh.warnings.join('\n') ||
        fresh.fingerprint != confirmed.fingerprint) {
      repository = HubRepository(confirmed);
      _changed();
      throw StateError('コピーの確認中に同期された記録が変わりました。再読込して確認してください。');
    }
    return parsed;
  }

  /// 文脈かご（端末内のみ）。
  late final BasketStore baskets = BasketStore(access);
  Basket basket = const Basket();

  /// [basket]を読み込んだVaultのidentity。読む前にかごを書き換えて、残したかごを消さないようにする。
  String? _basketFor;

  Future<void> _ensureBasket(VaultLocation target) async {
    if (_basketFor == target.identity) return;
    final loaded = await baskets.read(target.identity);
    if (location?.identity != target.identity) return;
    basket = loaded;
    _basketFor = target.identity;
  }

  /// この記録（訂正の前後は同じ1件）がかごに入っているか。
  bool inBasket(String recordId) {
    final repo = repository;
    if (repo == null) return basket.ids.contains(recordId);
    final key = repo.bundleKeyOf(recordId);
    return basket.ids.any((id) => repo.bundleKeyOf(id) == key);
  }

  /// かごに入っている記録のうち、今のVaultで見つからない記録。
  List<String> get missingInBasket {
    final repo = repository;
    if (repo == null) return const [];
    return basket.ids
        .where(
          (id) =>
              !HubRepository.bundleKinds.contains(repo.records[id]?.kind ?? ''),
        )
        .toList();
  }

  Future<void> _setBasket(Basket Function(Basket current) change) async {
    final target = location;
    if (target == null) return;
    await _ensureBasket(target);
    if (_basketFor != target.identity) {
      throw StateError('Vaultが切り替わりました。');
    }
    final next = change(basket);
    basket = next;
    _changed();
    await baskets.write(target.identity, next);
  }

  /// かごに入れる。入っていれば外す（訂正の前後も同じ1件として外す）。入れたらtrue。
  Future<bool> toggleBasket(String recordId) async {
    final repo = repository;
    if (repo == null) throw StateError('先にVaultを再読込してください。');
    final key = repo.bundleKeyOf(recordId);
    var added = false;
    await _setBasket((current) {
      if (current.ids.any((id) => repo.bundleKeyOf(id) == key)) {
        return Basket(
          ids: current.ids.where((id) => repo.bundleKeyOf(id) != key).toList(),
          maxChars: current.maxChars,
        );
      }
      if (!HubRepository.bundleKinds.contains(repo.records[recordId]?.kind)) {
        throw StateError('この記録はかごに入れられません。');
      }
      if (current.ids.length >= BasketStore.maxItems) {
        throw StateError('かごには${BasketStore.maxItems}件まで入れられます。');
      }
      added = true;
      return Basket(
        ids: [...current.ids, recordId],
        maxChars: current.maxChars,
      );
    });
    return added;
  }

  Future<void> removeFromBasket(String recordId) => _setBasket(
    (current) => Basket(
      ids: current.ids.where((id) => id != recordId).toList(),
      maxChars: current.maxChars,
    ),
  );

  /// かごの並びを変える。[newIndex]は移動後の位置。
  Future<void> moveInBasket(int oldIndex, int newIndex) =>
      _setBasket((current) {
        final ids = [...current.ids];
        if (oldIndex < 0 || oldIndex >= ids.length) return current;
        final id = ids.removeAt(oldIndex);
        ids.insert(newIndex.clamp(0, ids.length), id);
        return Basket(ids: ids, maxChars: current.maxChars);
      });

  Future<void> clearBasket() =>
      _setBasket((current) => Basket(maxChars: current.maxChars));

  Future<void> setBasketLimit(int maxChars) {
    if (!Basket.limits.contains(maxChars)) {
      throw StateError('文字数上限を選び直してください。');
    }
    final syncing = _markPreference('basket');
    return _setBasket(
      (current) => Basket(ids: current.ids, maxChars: maxChars),
    ).then((_) {
      if (syncing) _preferenceChangedSaved();
    });
  }

  /// かごの記録を、コピーの直前に読み直したVaultから1つの文章にまとめる。
  Future<({String text, List<String> included, List<String> omitted})>
  bundleContext() async {
    if (basket.ids.isEmpty) throw StateError('かごに記録がありません。');
    final parsed = await _verifiedRepository();
    // 読み直しの間にかごを変えた場合も、押した後のかごを使う。
    final ids = [...basket.ids], maxChars = basket.maxChars;
    if (ids.isEmpty) throw StateError('かごに記録がありません。');
    if (ids.any(
      (id) => !HubRepository.bundleKinds.contains(parsed.records[id]?.kind),
    )) {
      throw StateError('かごに見つからない記録があります。かごから外してください。');
    }
    return parsed.bundleContext(ids, maxChars: maxChars);
  }

  Future<CaptureResult> save(CaptureDraft draft) async {
    if (location == null ||
        repository == null ||
        loading ||
        error != null ||
        captureWarning != null ||
        saving) {
      throw StateError('保存先と確認情報を先に確認してください。');
    }
    if (draft.continues != null && !repository!.intakeFeatures.continues) {
      throw StateError('Mac miniの本体が「続き」に対応していません。本体を更新してください。');
    }
    final draftId = draft.gitDraftId;
    if (draftId != null) {
      // 保存確認待ちの操作がある間は、同じ下書きから二重に入力を作らない。
      if (pending.isNotEmpty) {
        throw StateError('保存確認待ちの操作があります。保存と反映で確認してから保存してください。');
      }
      final found = repository!.gitDrafts[draftId];
      if (found == null ||
          found.hash != draft.gitDraftHash ||
          found.projectId != draft.project ||
          repository!.draftRequestIdFor(draftId) != null) {
        throw StateError('下書きが更新されたか、操作済みです。表示を確認してください。');
      }
    }
    saving = true;
    _changed();
    try {
      final result = await CaptureService(access, location!).save(draft);
      _track(result);
      return result;
    } finally {
      saving = false;
      await reload();
      _changed();
    }
  }

  /// 書きかけのメモ（端末内のみ）。
  late final DraftStore drafts = DraftStore(access);

  /// メモのひな形（端末内のみ）。
  late final TemplateStore templates = TemplateStore(access);

  /// 現在のVaultでの書きかけのキー。Vaultが未選択ならnull。
  String? draftKey({String? gitDraftId, String? answerTo, String? continues}) {
    final target = location;
    return target == null
        ? null
        : DraftStore.keyFor(
            target.identity,
            gitDraftId: gitDraftId,
            answerTo: answerTo,
            continues: continues,
          );
  }

  /// 書きかけに残した操作IDの保存状態。journalがなければnull、読めなければ再送を防ぐため'uncertain'。
  Future<String?> operationState(String operationId) async {
    final target = location;
    if (target == null) return 'uncertain';
    try {
      return await CaptureService(access, target).journalState(operationId);
    } catch (_) {
      return 'uncertain';
    }
  }

  /// 表示中の記録の訂正チェーンを最新のVaultで確かめ、最新の入力（expectedLatestId）への訂正を保存する。
  /// 操作IDは入力フォームが持ち、保存結果が不明なときは同じ操作IDで確認する。
  Future<CaptureResult> requestCorrection(
    String operationId,
    String recordId,
    String expectedLatestId,
    String text,
  ) async {
    final target = location, epoch = _epoch;
    if (target == null ||
        repository == null ||
        loading ||
        saving ||
        error != null ||
        captureWarning != null) {
      throw StateError('保存先と確認情報を先に確認してください。');
    }
    saving = true;
    _changed();
    try {
      // 結果不明の依頼が残っていると、同じチェーンへの訂正が届いているかを判断できない。
      if (pending.isNotEmpty) {
        throw StateError('保存確認待ちの操作があります。保存と反映で確認してから訂正してください。');
      }
      final fresh = await access.readSnapshot(target);
      if (epoch != _epoch || _disposed) throw StateError('Vaultが切り替わりました。');
      final parsed = HubRepository(fresh);
      repository = parsed;
      _changed();
      final chain = parsed.correctionChainOf(recordId);
      if (chain == null || chain.last.sourceId != expectedLatestId) {
        throw CorrectionTargetChanged();
      }
      if (parsed.correctionRequestIdFor(recordId) != null) {
        throw StateError('このメモの訂正は反映待ちです。保存と反映を確認してください。');
      }
      if (text.trim() == chain.last.body.trim()) {
        throw StateError('訂正前と同じ本文です。直したい箇所を書き換えてください。');
      }
      // 行動の文面は、行動と同じく1行・200文字以内にする（本体が断るため）。
      if (chain.first.kind == 'action' && !validActionText(text)) {
        throw StateError('行動の文面は1行・$actionTextChars文字以内で、前後に空白を付けずに入力してください。');
      }
      // 本体は訂正を32件まで、元のメモと訂正の合計を32000文字までに制限する。
      if (chain.length > 32 ||
          chain.fold<int>(text.length, (n, r) => n + r.body.length) > 32000) {
        throw StateError('このメモは訂正の上限に達しています。新しいメモとして追加してください。');
      }
      final result = await CaptureService(
        access,
        target,
      ).saveCorrection(operationId, expectedLatestId, text);
      _track(result);
      return result;
    } finally {
      saving = false;
      if (!_disposed) await reload();
      _changed();
    }
  }

  Future<CaptureResult> confirm(String operation) async {
    if (location == null || saving) {
      throw StateError('保存先を確認してください。');
    }
    saving = true;
    _changed();
    try {
      final result = await CaptureService(access, location!).confirm(operation);
      // 受付状況から保存を確認できた操作は、同じ内容の次の依頼で使い回さない。
      if (result.saved) {
        _reviewOperations.removeWhere((_, value) => value == operation);
      }
      return result;
    } finally {
      saving = false;
      await reload();
      _changed();
    }
  }

  Future<ReviewConfirmation> prepareReview(
    String id, {
    AdoptionTarget? target,
    bool retiring = false,
    Set<String> exclude = const {},
  }) async {
    final vaultTarget = location, old = repository, epoch = _epoch;
    if (vaultTarget == null ||
        old == null ||
        loading ||
        saving ||
        error != null ||
        captureWarning != null) {
      throw StateError('保存先と候補を先に再読込してください。');
    }
    final fresh = await access.readSnapshot(vaultTarget);
    if (epoch != _epoch || _disposed) throw StateError('Vaultが切り替わりました。');
    repository = HubRepository(fresh);
    _changed();
    final candidate = review?.byId(id);
    if (old.snapshot.fingerprint != fresh.fingerprint ||
        candidate == null ||
        !(retiring ? candidate.retirable : candidate.rejectable)) {
      throw StateError('候補または根拠が変更されています。表示を確認してから操作してください。');
    }
    if ((retiring
            ? review!.retirementRequestIdFor(id)
            : review!.requestIdFor(id)) !=
        null) {
      throw StateError('この候補の依頼は保存済みです。保存と反映を確認してください。');
    }
    if (target != null && !retiring) review!.validateTarget(target);
    // まとめて判断する案。本人が外した案（[exclude]）は含めず、確認待ちに残す。
    final covers = retiring
        ? const <ReviewCandidate>[]
        : [
            for (final member in review!.groupMembers(candidate))
              if (!exclude.contains(member.id)) member,
          ];
    _refuseBlockedGroup(candidate, covers);
    return ReviewConfirmation(
      candidate,
      fresh.fingerprint,
      vaultTarget.identity,
      epoch,
      target: target,
      retiring: retiring,
      covers: covers,
    );
  }

  /// 名前か別名が同じ案の採用が反映を待っている間は、まとめた判断を依頼しない。
  /// 採用でプロジェクトができると、名前か別名が同じ案が古い案になり、その案を含むまとめた依頼の全体を本体が受け付けられなくなる。
  void _refuseBlockedGroup(
    ReviewCandidate candidate,
    List<ReviewCandidate> covers,
  ) {
    final blocker = review!.groupBlocker(candidate, covers);
    if (blocker != null) {
      throw StateError(
        '「${blocker.title}」の採用が反映されるまで、名前か別名が同じ案を含むまとめた判断は依頼できません。同期後に確認するか、その案を外して判断してください。',
      );
    }
  }

  Future<CaptureResult> submitReview(
    ReviewConfirmation ticket,
    String action,
  ) async {
    final target = location;
    if (target == null ||
        ticket.epoch != _epoch ||
        ticket.identity != target.identity ||
        _disposed ||
        loading ||
        saving ||
        captureWarning != null ||
        error != null) {
      throw StateError('保存先と確認情報を再確認してください。');
    }
    saving = true;
    _changed();
    try {
      final fresh = await access.readSnapshot(target);
      if (ticket.epoch != _epoch || _disposed) {
        throw StateError('Vaultが切り替わりました。');
      }
      repository = HubRepository(fresh);
      _changed();
      final candidate = review?.byId(ticket.candidate.id);
      if (fresh.fingerprint != ticket.fingerprint ||
          candidate == null ||
          !(ticket.retiring
              ? candidate.retirable
              : action == 'reject'
              ? candidate.rejectable
              : candidate.actionable) ||
          candidate.candidateHash != ticket.candidate.candidateHash ||
          (ticket.retiring
                  ? review!.retirementRequestIdFor(candidate.id)
                  : review!.requestIdFor(candidate.id)) !=
              null) {
        throw StateError('確認中に候補・根拠・受け取り状況が変わりました。再読込して確認してください。');
      }
      if (ticket.retiring != (action == 'retire')) {
        throw const FormatException('確認と操作が一致しません。');
      }
      if (ticket.target != null && !ticket.retiring) {
        review!.validateTarget(ticket.target!);
      }
      // まとめて判断する案は、確認の画面で示したものと同じ内容で、いまもこの案にまとめられる案でなければ依頼しない。
      final covers = <ReviewCandidate>[];
      if (!ticket.retiring) {
        final members = {
          for (final member in review!.groupMembers(candidate))
            member.id: member,
        };
        for (final shown in ticket.covers) {
          final member = members[shown.id];
          if (member == null || member.candidateHash != shown.candidateHash) {
            throw StateError('確認中に候補・根拠・受け取り状況が変わりました。再読込して確認してください。');
          }
          covers.add(member);
        }
        _refuseBlockedGroup(candidate, covers);
      }
      // まとめた判断が反映を待っている間は、名前か別名が同じ案を採用しない。本体は同じ実行に届いた依頼を
      // IDの順に受け付けるので、後から依頼した採用が先に反映されると、まとめた依頼の全体が受け付けられなくなる。
      if (action == 'approve') {
        final waiting = review!.approveBlocker(candidate);
        if (waiting != null) {
          throw StateError(
            '「${waiting.title}」をまとめた判断が反映されるまで、名前か別名が同じこの案の採用は依頼できません。同期後に確認してください。',
          );
        }
      }
      // 同じ候補への同じ内容の依頼は、同じ操作として1回だけ保存する。本体が受け付けられなかった依頼の
      // 後の判断は、新しい操作として保存する（同じ操作のままでは、保存済みの依頼を確かめ直すだけになる）。
      final failed = ticket.retiring
          ? const <String>[]
          : review!.failedRequestIdsFor(candidate.id);
      final key =
          '${target.identity}/${candidate.id}/${ticket.retiring ? 'retire/${candidate.dependencies[candidate.targetPath]}' : candidate.candidateHash}${failed.isEmpty ? '' : '/after/${failed.join('+')}'}';
      final operation = _reviewOperations.putIfAbsent(
        key,
        () => const Uuid().v4(),
      );
      final service = ReviewService(access, target);
      return ticket.retiring
          ? await service.retire(operation, candidate)
          : await service.submit(
              operation,
              candidate,
              action,
              target: ticket.target,
              covers: covers,
            );
    } finally {
      saving = false;
      if (!_disposed) await reload();
      _changed();
    }
  }

  /// 採用した方針を「まだ有効」と確かめたことを、表示中の内容のhashに結び付けてInputへ依頼する。
  /// 古い本体はこの依頼を知らず受け付けられないため、本体が対応を書き出しているときだけ依頼する。
  Future<CaptureResult> requestPolicyKeep(
    String candidateId,
    String expectedHash,
  ) async {
    final target = location, epoch = _epoch;
    if (target == null ||
        repository == null ||
        loading ||
        saving ||
        error != null ||
        captureWarning != null) {
      throw StateError('保存先と確認情報を先に確認してください。');
    }
    saving = true;
    _changed();
    try {
      final fresh = await access.readSnapshot(target);
      if (epoch != _epoch || _disposed) throw StateError('Vaultが切り替わりました。');
      final parsed = HubRepository(fresh);
      repository = parsed;
      _changed();
      if (!parsed.intakeFeatures.policyKeep) {
        throw StateError('Mac miniの本体がまだ「まだ有効」の記録に対応していません。本体を更新してください。');
      }
      final candidate = review?.byId(candidateId);
      if (candidate == null ||
          !candidate.keepable ||
          candidate.dependencies[candidate.targetPath] != expectedHash) {
        throw StateError('方針の内容が変更されています。表示を確認してから操作してください。');
      }
      if (review!.policyKeepRequestIdFor(candidateId) != null ||
          review!.retirementRequestIdFor(candidateId) != null) {
        throw StateError('この方針の依頼は保存済みです。保存と反映を確認してください。');
      }
      // 確かめた内容と、前回確かめた日時を含める。保存結果が不明なまま押し直しても同じ操作として1回だけ保存する。
      final key =
          '${target.identity}/policy-keep/${candidate.id}/$expectedHash/${candidate.policyReview?.confirmedAt?.toIso8601String() ?? '-'}';
      final operation = _reviewOperations.putIfAbsent(
        key,
        () => const Uuid().v4(),
      );
      return await ReviewService(access, target).keep(operation, candidate);
    } finally {
      saving = false;
      if (!_disposed) await reload();
      _changed();
    }
  }

  /// 表示中の定義hashに結び付けて、プロジェクトの状態変更をInputへ依頼する。
  Future<CaptureResult> requestProjectStatus(
    String projectId,
    String expectedHash,
    String status,
  ) async {
    final target = location, epoch = _epoch;
    if (target == null ||
        repository == null ||
        loading ||
        saving ||
        error != null ||
        captureWarning != null) {
      throw StateError('保存先と確認情報を先に確認してください。');
    }
    saving = true;
    _changed();
    try {
      final fresh = await access.readSnapshot(target);
      if (epoch != _epoch || _disposed) throw StateError('Vaultが切り替わりました。');
      final parsed = HubRepository(fresh);
      repository = parsed;
      _changed();
      final project = parsed.projects[projectId];
      if (project == null || project.definitionHash != expectedHash) {
        throw StateError('プロジェクト定義が変更されています。表示を確認してから操作してください。');
      }
      if (parsed.projectStatusRequestIdFor(projectId) != null) {
        throw StateError('このプロジェクトの状態変更は依頼済みです。保存と反映を確認してください。');
      }
      if (parsed.projectDefinitionRequestIdFor(projectId) != null ||
          parsed.projectAreaRequestIdFor(projectId) != null) {
        throw StateError('呼び名とキーワード・領域の変更が反映されるまで待ってから依頼してください。');
      }
      _refuseMerged(parsed, project);
      if (pending.isNotEmpty) {
        throw StateError('保存確認待ちの操作があります。保存と反映で確認してから依頼してください。');
      }
      // 状態を含めないことで、保存結果が不明なまま別の状態を依頼する二重送信を防ぐ。
      // 最新の変更記録を含め、同じ定義へ戻った後の依頼が過去の操作と混ざらないようにする。
      final key =
          '${target.identity}/project-status/$projectId/$expectedHash/${parsed.latestStatusChangeId(projectId) ?? '-'}';
      final operation = _reviewOperations.putIfAbsent(
        key,
        () => const Uuid().v4(),
      );
      final result = await CaptureService(
        access,
        target,
      ).saveProjectStatus(operation, project, status);
      if (result.saved) _reviewOperations.remove(key);
      return result;
    } finally {
      saving = false;
      if (!_disposed) await reload();
      _changed();
    }
  }

  /// 統合済みのプロジェクトと、統合・取り消しの反映を待っているプロジェクトへの定義の変更を止める。
  static void _refuseMerged(HubRepository parsed, HubProject project) {
    if (parsed.projectMergeRequestIdFor(project.id) != null) {
      throw StateError('統合の依頼が反映されるまで待ってから依頼してください。');
    }
    final target = project.mergeTarget;
    if (target != null) {
      throw StateError(
        'このプロジェクトは「${parsed.projects[target]?.title ?? target}」に統合済みです。統合先で操作してください。',
      );
    }
  }

  /// 表示中の2つの定義hashに結び付けて、プロジェクトの統合（[unmerge]なら取り消し）をInputへ依頼する。
  ///
  /// 統合すると、統合元の入力・完了報告・日付を統合先のものとして読む（原文と記録は動かさない）。
  Future<CaptureResult> requestProjectMerge(
    String fromId,
    String fromHash,
    String intoId,
    String intoHash, {
    bool unmerge = false,
  }) {
    late HubProject from, into;
    return _confirmedRequest(
      (parsed) {
        final a = parsed.projects[fromId], b = parsed.projects[intoId];
        if (a == null ||
            b == null ||
            a.definitionHash != fromHash ||
            b.definitionHash != intoHash) {
          throw StateError('プロジェクト定義が変更されています。表示を確認してから操作してください。');
        }
        for (final p in [a, b]) {
          if (parsed.projectMergeRequestIdFor(p.id) != null ||
              parsed.projectDefinitionRequestIdFor(p.id) != null ||
              parsed.projectStatusRequestIdFor(p.id) != null ||
              parsed.projectAreaRequestIdFor(p.id) != null) {
            throw StateError('「${p.title}」への依頼が反映待ちです。保存と反映を確認してください。');
          }
        }
        if (unmerge) {
          if (a.mergedInto != intoId) {
            throw StateError('統合先が変わっています。表示を確認してから操作してください。');
          }
        } else {
          if (fromId == intoId) throw StateError('別のプロジェクトを統合先に選んでください。');
          if (a.mergedInto != null) {
            throw StateError('「${a.title}」は既に統合済みです。');
          }
          if (b.mergedInto != null) {
            throw StateError('「${b.title}」は統合済みです。統合先を選び直してください。');
          }
          if (parsed.projects.values.any((p) => p.mergedInto == fromId)) {
            throw StateError(
              '「${a.title}」にはほかのプロジェクトが統合されています。先にそちらの統合を取り消してください。',
            );
          }
        }
        from = a;
        into = b;
        // 最新の統合の記録を含め、取り消した後の同じ定義への依頼が過去の操作と混ざらないようにする。
        return 'project-${unmerge ? 'unmerge' : 'merge'}/$fromId/$fromHash/$intoId/$intoHash/${parsed.latestMergeChangeId(fromId) ?? '-'}';
      },
      (service, parsed, operation) =>
          service.saveProjectMerge(operation, from, into, unmerge: unmerge),
    );
  }

  /// 表示中の定義hashに結び付けて、名前・別名・キーワードの変更をInputへ依頼する。
  Future<CaptureResult> requestProjectDefinition(
    String projectId,
    String expectedHash,
    ProjectDefinitionDraft next,
  ) {
    late HubProject project;
    return _confirmedRequest(
      (parsed) {
        final found = parsed.projects[projectId];
        if (found == null || found.definitionHash != expectedHash) {
          throw StateError('プロジェクト定義が変更されています。表示を確認してから操作してください。');
        }
        if (parsed.projectDefinitionRequestIdFor(projectId) != null ||
            parsed.projectStatusRequestIdFor(projectId) != null ||
            parsed.projectAreaRequestIdFor(projectId) != null) {
          throw StateError('このプロジェクトへの依頼が反映待ちです。保存と反映を確認してください。');
        }
        _refuseMerged(parsed, found);
        // 望む結果に対応していない本体へ送ると、依頼ごと断られる。
        if (next.outcome != null &&
            parsed.intakeFeatures.projectOutcome == null) {
          throw StateError('Mac miniの本体が望む結果に対応していません。本体を更新してください。');
        }
        final problem = next.problem;
        if (problem != null) throw StateError(problem);
        if (next.sameAs(found)) {
          throw StateError('名前・別名・キーワード・望む結果に変更がありません。');
        }
        project = found;
        // 変更後の内容と最新の変更記録を含め、同じ定義へ戻す依頼が過去の操作と混ざらないようにする。
        return 'project-definition/$projectId/$expectedHash/${digest(jsonEncode([next.title, next.aliases, next.keywords, if (next.outcome != null) next.outcome]))}/${parsed.latestDefinitionChangeId(projectId) ?? '-'}';
      },
      (service, parsed, operation) =>
          service.saveProjectDefinition(operation, project, next),
    );
  }

  /// プロジェクトに領域を付ける・変える・外す（[area]がnull）依頼。表示中の定義hash（[expectedHash]）に結び付ける。
  /// 領域は本人が選び、AIは付けない。本体はメモの関連付けをやり直さない（登録簿のhashに含めない）。
  Future<CaptureResult> requestProjectArea(
    String projectId,
    String expectedHash,
    String? area,
  ) {
    if (area != null && !validArea(area)) {
      throw StateError('領域は1〜$areaChars文字の1行で、前後に空白を付けずに入力してください（「$noAreaLabel」は使えません）。');
    }
    late HubProject project;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.areas) {
          throw StateError('Mac miniの本体が領域に対応していません。本体を更新してください。');
        }
        final found = parsed.projects[projectId];
        if (found == null || found.definitionHash != expectedHash) {
          throw StateError('プロジェクト定義が変更されています。表示を確認してから操作してください。');
        }
        if (parsed.projectDefinitionRequestIdFor(projectId) != null ||
            parsed.projectStatusRequestIdFor(projectId) != null ||
            parsed.projectAreaRequestIdFor(projectId) != null) {
          throw StateError('このプロジェクトへの依頼が反映待ちです。保存と反映を確認してください。');
        }
        _refuseMerged(parsed, found);
        if (found.area == area) {
          throw StateError(area == null ? '外す領域はありません。' : '既に領域「$area」です。');
        }
        project = found;
        // 変更後の領域と最新の変更記録を含め、同じ領域へ戻す依頼が過去の操作と混ざらないようにする。
        return 'project-area/$projectId/$expectedHash/${digest(jsonEncode([area]))}/${parsed.latestAreaChangeId(projectId) ?? '-'}';
      },
      (service, parsed, operation) =>
          service.saveProjectArea(operation, project, area),
    );
  }

  /// 領域の語彙（領域を選ぶときの一覧、並びも含む）を変える依頼。Vaultの好みに置き、すべての端末で同じ一覧と並びを使う。
  /// 好みをそろえる設定とは関係なく送る。語彙から外した領域は、付いているプロジェクトに残る。
  Future<CaptureResult> requestAreaVocabulary(List<String> items) {
    if (!validAreaVocabulary(items)) {
      throw StateError('領域は$areaVocabularyMax個まで、同じ領域を重ねずに入力してください。');
    }
    late String payload;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.areas) {
          throw StateError('Mac miniの本体が領域に対応していません。本体を更新してください。');
        }
        if (listEquals(parsed.areaVocabulary, items)) {
          throw StateError('領域の一覧は変わっていません。');
        }
        // 変えた日時は、知っている版（Vaultの版・反映待ちの版）より必ず後にする（遅れて届いた古い変更で巻き戻さないため）。
        final known = parsed.vocabularyAt('areas');
        final now = DateTime.now().toUtc(),
            after = known?.add(const Duration(milliseconds: 1));
        payload = encodePreferencesPayload(_deviceName, {
          'areas': (
            at: after != null && after.isAfter(now) ? after : now,
            value: {'items': items},
          ),
        });
        return 'areas-vocabulary/${digest(jsonEncode([parsed.sharedPreferences['areas']?.requestId, known?.toIso8601String(), items]))}';
      },
      (service, parsed, operation) =>
          service.savePreferences(operation, payload),
    );
  }

  /// 整理（AIの読み取り）に失敗したメモ1件を、次の整理でもう一度試すよう頼む。
  /// 本人が見た失敗の試行回数に結び付け、同じ失敗へは重ねて頼まない（本体も1回だけ試す）。
  Future<CaptureResult> requestOrganizeRetry(String inputId) {
    late int attempts;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.organizeRetry) {
          throw StateError('Mac miniの本体が整理のやり直しに対応していません。本体を更新してください。');
        }
        final found = parsed.failedAttemptsFor(inputId);
        if (found == null) {
          throw StateError('このメモは整理に失敗していません。表示を確認してください。');
        }
        if (!parsed.organizeRetryable(inputId)) {
          throw StateError('このメモには訂正が届いているか、訂正を依頼中です。訂正した後のメモが整理されるので、やり直しは要りません。');
        }
        if (parsed.organizeRetryRequestIdFor(inputId) != null ||
            parsed.organizeRetryQueued(inputId)) {
          throw StateError('このメモのやり直しは依頼済みです。次の整理を待ってください。');
        }
        attempts = found;
        return 'organize-retry/$inputId/$attempts';
      },
      (service, parsed, operation) =>
          service.saveOrganizeRetry(operation, inputId, attempts),
    );
  }

  /// 人の登録（[personId]がまだない人）・名前と呼び名の変更・外す依頼。
  /// 変更と外すは、表示中の定義hash（[expectedHash]）に結び付ける。[draft]は外すときだけnull。
  Future<CaptureResult> requestPerson(
    String personId,
    String action, {
    String? expectedHash,
    PersonDraft? draft,
  }) => _confirmedRequest(
    (parsed) {
      if (!parsed.intakeFeatures.people) {
        throw StateError('Mac miniの本体がまだ人の登録に対応していません。本体を更新してください。');
      }
      final found = parsed.people[personId];
      if (action == 'add') {
        if (found != null ||
            parsed.pendingPersonAdds.any((p) => p.personId == personId)) {
          // 同じ登録の保存結果が不明だった場合の確認は、同じ操作IDで受け付ける。
          if (!parsed.pendingPersonAdds.any(
            (p) => p.personId == personId && p.name == draft?.name,
          )) {
            throw StateError('同じIDの人が既にいます。画面を開き直してください。');
          }
        }
      } else {
        if (found == null || found.definitionHash != expectedHash) {
          throw StateError('人の定義が変更されています。表示を確認してから操作してください。');
        }
        if (parsed.personRequestIdFor(personId) != null) {
          throw StateError('この人への依頼が反映待ちです。保存と反映を確認してください。');
        }
      }
      if (draft != null) {
        final problem = draft.problem;
        if (problem != null) throw StateError(problem);
        final other = draft.overlap(parsed.peopleForOverlap, except: personId);
        if (other != null) {
          throw StateError('名前か呼び名が「${other.name}」と重なります。別の呼び名にしてください。');
        }
        if (found != null && action == 'edit' && draft.sameAs(found)) {
          throw StateError('名前・呼び名に変更がありません。');
        }
      }
      return 'person-definition/$personId/$action/${expectedHash ?? '-'}/${digest(jsonEncode([draft?.name, draft?.aliases]))}/${parsed.latestPersonChangeId(personId) ?? '-'}';
    },
    (service, parsed, operation) => service.savePersonDefinition(
      operation,
      personId: personId,
      action: action,
      expectedHash: expectedHash,
      draft: draft,
    ),
  );

  /// 最新のVaultを読み直して確認し、同じ確認内容には同じ操作IDを使って依頼を保存する。
  Future<CaptureResult> _confirmedRequest(
    String Function(HubRepository parsed) keyFor,
    Future<CaptureResult> Function(
      CaptureService service,
      HubRepository parsed,
      String operation,
    )
    save,
  ) async {
    final target = location, epoch = _epoch;
    if (target == null ||
        repository == null ||
        loading ||
        saving ||
        error != null ||
        captureWarning != null) {
      throw StateError('保存先と確認情報を先に確認してください。');
    }
    saving = true;
    _changed();
    try {
      final fresh = await access.readSnapshot(target);
      if (epoch != _epoch || _disposed) throw StateError('Vaultが切り替わりました。');
      final parsed = HubRepository(fresh);
      repository = parsed;
      _changed();
      final key = '${target.identity}/${keyFor(parsed)}';
      if (pending.isNotEmpty) {
        throw StateError('保存確認待ちの操作があります。保存と反映で確認してから依頼してください。');
      }
      final operation = _reviewOperations.putIfAbsent(
        key,
        () => const Uuid().v4(),
      );
      final result = await save(
        CaptureService(access, target),
        parsed,
        operation,
      );
      if (result.saved) _reviewOperations.remove(key);
      return result;
    } finally {
      saving = false;
      if (!_disposed) await reload();
      _changed();
    }
  }

  /// NOWの項目を完了・解決（resolve）、誤りとして外す（exclude）、または未解決へ戻す（reopen）報告を保存する。
  /// 誤りとして外すときは理由（[exclusionReasons]）を付け、一言（[note]）は任意。
  Future<CaptureResult> requestItemResolution(
    String projectId,
    String itemKey,
    String action, {
    String? reason,
    String? note,
  }) {
    final exclude = action == 'exclude';
    if (!['resolve', 'reopen', 'exclude'].contains(action) ||
        (exclude
            ? !exclusionReasons.contains(reason)
            : reason != null || note != null)) {
      throw StateError('項目と操作を確認してください。');
    }
    if (note != null && !validExclusionNote(note)) {
      throw StateError('一言は1行・$exclusionNoteChars文字以内で入力してください。');
    }
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        final unassigned = projectId == unassignedScope;
        if (unassigned && !parsed.intakeFeatures.unassignedItems) {
          throw StateError(
            'Mac miniの本体がプロジェクト未定の行の完了・却下に対応していません。本体を更新してください。',
          );
        }
        // 定義だけ先に同期された統合済みのプロジェクトには、古いNOWの項目が残っていても依頼しない（本体が断る）。
        if (parsed.projects[projectId] case final owner?) {
          _refuseMerged(parsed, owner);
        }
        final found =
            (unassigned
                    ? parsed.unassignedItems
                    : parsed.projects[projectId]?.nowItems ??
                          const <NowItemRef>[])
                .where((i) => i.key == itemKey)
                .firstOrNull;
        // 戻せるのは欄から外れている項目だけ、完了・解決にする・外すのは欄にある項目だけ。
        if (found == null || (action != 'reopen') == found.resolved) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目は報告済みです。保存と反映を確認してください。');
        }
        item = found;
        // 最新の解決・再開記録を含め、解決→再開→解決のように同じ操作を繰り返しても過去の操作と混ざらないようにする。
        // 外す操作は理由と一言も含め、内容を変えた依頼を同じ操作として扱わない。
        return 'item/$projectId/$itemKey/$action/${parsed.latestResolutionIdFor(itemKey) ?? '-'}${exclude ? '/${digest('$reason\n${note ?? ''}')}' : ''}';
      },
      (service, parsed, operation) => service.saveItemResolution(
        operation,
        projectId,
        item,
        action,
        reason: reason,
        note: note,
      ),
    );
  }

  /// 本人が決めた行動を、プロジェクトの「次の一手」へ直接載せる依頼を保存する（モデルを通さない）。
  /// [projectId]が[unassignedScope]なら、プロジェクトを決めずにプロジェクト未定の次の一手へ載せる。
  /// [from]はAIが読み取った行（提案・作業要約の次の一手）を行動にするときの元の行。文面は本人が直したもの。
  /// [effort]と[contexts]は、追加と一緒に付ける手間の目安と場所・道具の札（本人が選んだときだけ）。
  Future<CaptureResult> requestAction(
    String projectId,
    String text, {
    ActionSource? from,
    String? effort,
    List<String>? contexts,
  }) {
    if (!validActionText(text)) {
      throw StateError('行動は1行・$actionTextChars文字以内で、前後に空白を付けずに入力してください。');
    }
    if ((effort != null && !itemEfforts.contains(effort)) ||
        (contexts != null && !validContextTags(contexts))) {
      throw StateError('手間の目安と札を選び直してください。');
    }
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.actions) {
          throw StateError('Mac miniの本体が次の一手の直接追加に対応していません。本体を更新してください。');
        }
        if ((effort != null && !parsed.intakeFeatures.actionEffort) ||
            (contexts != null && !parsed.intakeFeatures.actionContexts)) {
          throw StateError('Mac miniの本体が、追加と一緒に手間の目安や札を付けることに対応していません。本体を更新してください。');
        }
        // プロジェクト未定の置き場を指定したときは、プロジェクトを付けずに追加する（対応した本体だけが受け付ける）。
        final unassigned = projectId == unassignedScope;
        if (unassigned && !parsed.intakeFeatures.unassignedActions) {
          throw StateError('Mac miniの本体がプロジェクト未定の行動に対応していません。本体を更新してください。');
        }
        final owner = unassigned ? null : parsed.projects[projectId];
        if (!unassigned && owner == null) {
          throw StateError('プロジェクトが見つかりません。再読込してください。');
        }
        // 統合済みのプロジェクトには追加しない（本体が断る）。統合先へ追加してもらう。
        if (owner != null) _refuseMerged(parsed, owner);
        // 元の行は、どのプロジェクトのNOW・プロジェクト未定の一覧にあってもよい（追加先と違う置き場から引き取れる）。
        final items = [
          for (final p in parsed.projects.values) ...p.nowItems,
          ...parsed.unassignedItems,
        ];
        if (from?.key case final key?) {
          final found = items.where((i) => i.key == key).firstOrNull;
          if (found == null ||
              found.resolved ||
              found.action ||
              found.section != 'next' ||
              found.inputId != from!.inputId ||
              found.text != from.text) {
            throw StateError('現状が更新されています。表示を確認してから操作してください。');
          }
          // 完了・誤りとして外す報告が反映待ちの項目は、行動にしない（本体の扱いが決まっていないため）。
          if (parsed.itemRequestIdFor(key) != null) {
            throw StateError('この項目への報告が反映待ちです。保存と反映を確認してください。');
          }
          // 日付・定例の回の依頼が反映待ちの項目も、先に行動になると依頼が断られるため、反映を待つ。
          if (parsed.scheduleRequestIdFor(key) != null) {
            throw StateError('この項目の日付の依頼が反映待ちです。保存と反映を確認してください。');
          }
        } else if (from != null &&
            !parsed.projects.values.any(
              (p) => p.sections['proposals']!.any((e) {
                final shown = parsed.proposalSource(e);
                return shown?.inputId == from.inputId &&
                    shown?.text == from.text;
              }),
            )) {
          // 「提案」の行は、今のNOWにまだ載っているときだけ行動にする。
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (from != null && parsed.takenOver(from.inputId, from.text)) {
          throw StateError('この行は既に行動にしています。次の一手を確認してください。');
        }
        // 同じ内容の再試行だけを同じ操作として扱う。保存できたら操作IDを外すので、同じ文面を改めて足すこともできる。
        return 'action/$projectId/${digest(jsonEncode([text, from?.inputId, from?.text, from?.key, effort, contexts]))}';
      },
      (service, parsed, operation) => service.saveAction(
        operation,
        projectId,
        text,
        from: from,
        effort: effort,
        contexts: contexts,
      ),
    );
  }

  /// 本人が追加した行動を、別の置き場（プロジェクト・プロジェクト未定）へ移す依頼を保存する。
  /// [fromScope]は今の置き場（プロジェクトのIDか[unassignedScope]）、[toScope]は移す先。
  /// 移す先に同じ文面の行動を足し、元の行動を元の行として指す（本体が記録を写し、元の行動を一覧から外す）。
  Future<CaptureResult> requestMoveAction(
    String fromScope,
    String itemKey,
    String toScope,
  ) {
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        final features = parsed.intakeFeatures;
        if (!features.actionMoves) {
          throw StateError('Mac miniの本体が行動を移す操作に対応していません。本体を更新してください。');
        }
        if ((fromScope == unassignedScope || toScope == unassignedScope) &&
            !features.unassignedActions) {
          throw StateError('Mac miniの本体がプロジェクト未定の行動に対応していません。本体を更新してください。');
        }
        if (fromScope == toScope) throw StateError('移す先が今の置き場と同じです。');
        final source = fromScope == unassignedScope
            ? null
            : parsed.projects[fromScope];
        if (fromScope != unassignedScope && source == null) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (source != null) _refuseMerged(parsed, source);
        if (toScope != unassignedScope) {
          final target = parsed.projects[toScope];
          if (target == null || !target.active) {
            throw StateError('移す先は進行中のプロジェクトを選んでください。');
          }
          _refuseMerged(parsed, target);
        }
        final found = (source?.nowItems ?? parsed.unassignedItems)
            .where((i) => i.key == itemKey)
            .firstOrNull;
        if (found == null || !found.action || found.section != 'next') {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (found.resolved) {
          throw StateError('完了・却下した行動は移せません。未解決へ戻してから移してください。');
        }
        // ほかの依頼が反映待ちの行動は、反映を待ってから移す（移した後の元の行動には、本体が依頼を断るため）。
        if (parsed.itemRequestIdFor(itemKey) != null ||
            parsed.scheduleRequestIdFor(itemKey) != null ||
            parsed.effortRequestIdFor(itemKey) != null ||
            parsed.contextsRequestIdFor(itemKey) != null ||
            parsed.stepsRequestIdFor(itemKey) != null ||
            parsed.waitRequestIdFor(itemKey) != null ||
            parsed.somedayRequestIdFor(itemKey) != null ||
            parsed.correctionRequestIdForInput(found.inputId) != null) {
          throw StateError('この行動への依頼が反映待ちです。保存と反映を確認してください。');
        }
        if (parsed.takenOver(found.inputId, found.text)) {
          throw StateError('この行動は既に移す依頼をしています。保存と反映を確認してください。');
        }
        item = found;
        return 'move-action/$fromScope/$itemKey/$toScope';
      },
      (service, parsed, operation) => service.saveAction(
        operation,
        toScope,
        item.text,
        from: ActionSource(inputId: item.inputId, text: item.text, key: item.key),
      ),
    );
  }

  /// 期日・手間の目安・定例の回を依頼する項目。見つからなければnull。
  /// [projectId]が[unassignedScope]なら、プロジェクトを決めずに本人が追加した行動だけを対象にする（AIの行には付けない）。
  static NowItemRef? _recordTarget(
    HubRepository parsed,
    String projectId,
    String itemKey,
  ) {
    if (projectId == unassignedScope) {
      if (!parsed.intakeFeatures.unassignedRecords) {
        throw StateError(
          'Mac miniの本体がプロジェクト未定の行動の期日・手間の目安に対応していません。本体を更新してください。',
        );
      }
      return parsed.unassignedItems
          .where((i) => i.key == itemKey && i.action)
          .firstOrNull;
    }
    // 定義だけ先に同期された統合済みのプロジェクトには、古いNOWの項目が残っていても依頼しない（本体が断る）。
    if (parsed.projects[projectId] case final owner?) {
      _refuseMerged(parsed, owner);
    }
    return parsed.projects[projectId]?.nowItems
        .where((i) => i.key == itemKey)
        .firstOrNull;
  }

  /// NOWの項目に期日・次に見直す日を付ける（両方nullで外す）依頼を保存する。
  /// [projectId]が[unassignedScope]なら、プロジェクト未定の本人が追加した行動に付ける。
  Future<CaptureResult> requestItemSchedule(
    String projectId,
    String itemKey,
    String? due,
    String? reviewAfter, {
    bool withRepeat = false,
    RepeatRule? repeat,
  }) {
    if (repeat != null && (!withRepeat || due == null)) {
      throw StateError('繰り返しには期日が必要です。');
    }
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        final found = _recordTarget(parsed, projectId, itemKey);
        if (found == null || found.resolved) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        // 繰り返しを送らない依頼では、本体は今の繰り返しを保つ（期日を外すと繰り返しも外れる）。
        final nextRepeat = withRepeat
            ? repeat
            : (due == null ? null : found.repeat);
        if (found.due == due &&
            found.reviewAfter == reviewAfter &&
            found.repeat == nextRepeat) {
          throw StateError('日付は変わっていません。');
        }
        if (withRepeat && !parsed.intakeFeatures.repeat) {
          throw StateError('Mac miniの本体が繰り返しに対応していません。本体を更新してください。');
        }
        if (parsed.scheduleRequestIdFor(itemKey) != null) {
          throw StateError('この項目の日付は依頼済みです。保存と反映を確認してください。');
        }
        // 完了・解決の報告が先に反映されると、本体は日付の依頼を断る。
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目の完了・解決の報告が反映されるまで待ってから依頼してください。');
        }
        item = found;
        // 依頼する日付と最新の日付記録を含め、同じ内容の再試行だけを同じ操作として扱う。
        // 項目の現在の日付のIDは外すと元に戻るため、付ける→外す→同じ日付を付ける、で過去の操作と混ざらないよう
        // 外した記録も含む最新の記録IDを使う（引き継いだ日付は項目のキーに記録がないため、現在の日付のIDも含める）。
        return 'schedule/$projectId/$itemKey/${parsed.latestScheduleIdFor(itemKey) ?? '-'}/${found.scheduleId ?? '-'}/${due ?? '-'}/${reviewAfter ?? '-'}${withRepeat ? '/${repeat == null ? 'none' : '${repeat.unit}${repeat.every}'}' : ''}';
      },
      (service, parsed, operation) => service.saveItemSchedule(
        operation,
        projectId,
        item,
        due,
        reviewAfter,
        withRepeat: withRepeat,
        repeat: repeat,
      ),
    );
  }

  /// 手間の目安を依頼する。[effort]がnullなら外す。
  Future<CaptureResult> requestItemEffort(
    String projectId,
    String itemKey,
    String? effort,
  ) {
    if (effort != null && !itemEfforts.contains(effort)) {
      throw StateError('手間の目安を選び直してください。');
    }
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.effort) {
          throw StateError('Mac miniの本体が手間の目安に対応していません。本体を更新してください。');
        }
        final found = _recordTarget(parsed, projectId, itemKey);
        if (found == null || found.resolved) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (found.effort == effort) {
          throw StateError('手間の目安は変わっていません。');
        }
        if (parsed.effortRequestIdFor(itemKey) != null) {
          throw StateError('この項目の手間の目安は依頼済みです。保存と反映を確認してください。');
        }
        // 完了・解決の報告が先に反映されると、本体は目安の依頼を断る。
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目の完了・解決の報告が反映されるまで待ってから依頼してください。');
        }
        item = found;
        // 日付と同じく、外した記録も含む最新の記録IDを含め、同じ内容の再試行だけを同じ操作にする。
        return 'effort/$projectId/$itemKey/${parsed.latestEffortIdFor(itemKey) ?? '-'}/${found.effort ?? '-'}/${effort ?? 'none'}';
      },
      (service, parsed, operation) =>
          service.saveItemEffort(operation, projectId, item, effort),
    );
  }

  /// 次の一手の手順を、[steps]の全体（手順と終えた数）に置き換える依頼。nullなら外す。手順は本人が書き、AIは作らない。
  /// 進める・戻すも全体を送る（[ItemSteps.done]を1つ増やす・減らす）。
  /// [seen]は本人が見ていた手順（なければnull）。読み直した今の手順と違えば依頼しない（古い表示から進み具合を巻き戻さない）。
  Future<CaptureResult> requestItemSteps(
    String projectId,
    String itemKey,
    ItemSteps? steps, {
    required ItemSteps? seen,
  }) {
    if (steps != null && ItemSteps.tryParse(steps.toJson()) == null) {
      throw StateError('手順は$itemStepsMin〜$itemStepsMax個、それぞれ1行・$actionTextChars文字以内で入力してください。');
    }
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.steps) {
          throw StateError('Mac miniの本体が手順に対応していません。本体を更新してください。');
        }
        final found = _recordTarget(parsed, projectId, itemKey);
        if (found == null || found.resolved) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (found.section != 'next') {
          throw StateError('手順は「次の一手」の項目だけに付けられます。');
        }
        if (found.steps != seen) {
          throw StateError('この項目の手順は、別の端末などで変わっています。今の手順を確かめてから操作してください。');
        }
        if (found.steps == steps) {
          throw StateError(steps == null ? '外す手順はありません。' : '手順は変わっていません。');
        }
        if (parsed.stepsRequestIdFor(itemKey) != null) {
          throw StateError('この項目の手順は依頼済みです。保存と反映を確認してください。');
        }
        // 完了・解決の報告が先に反映されると、本体は手順の依頼を断る。
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目の完了・解決の報告が反映されるまで待ってから依頼してください。');
        }
        item = found;
        // 外した記録も含む最新の記録IDと変更前後を含め、同じ内容の再試行だけを同じ操作にする。
        return 'steps/$projectId/$itemKey/${parsed.latestStepsIdFor(itemKey) ?? '-'}/${digest(jsonEncode([found.steps?.toJson(), steps?.toJson()]))}';
      },
      (service, parsed, operation) =>
          service.saveItemSteps(operation, projectId, item, steps),
    );
  }

  /// 場所・道具の札を、[contexts]の全体に置き換える依頼。nullなら外す。札は本人が選び、AIは付けない。
  Future<CaptureResult> requestItemContexts(
    String projectId,
    String itemKey,
    List<String>? contexts,
  ) {
    if (contexts != null && !validContextTags(contexts)) {
      throw StateError('札を選び直してください（$contextTagsMax個まで）。');
    }
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.contexts) {
          throw StateError('Mac miniの本体が場所・道具の札に対応していません。本体を更新してください。');
        }
        final found = _recordTarget(parsed, projectId, itemKey);
        if (found == null || found.resolved) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (listEquals(found.contexts, contexts ?? const <String>[])) {
          throw StateError('札は変わっていません。');
        }
        if (parsed.contextsRequestIdFor(itemKey) != null) {
          throw StateError('この項目の札は依頼済みです。保存と反映を確認してください。');
        }
        // 完了・解決の報告が先に反映されると、本体は札の依頼を断る。
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目の完了・解決の報告が反映されるまで待ってから依頼してください。');
        }
        item = found;
        // 外した記録も含む最新の記録IDを含め、同じ内容の再試行だけを同じ操作にする。
        return 'contexts/$projectId/$itemKey/${parsed.latestContextIdFor(itemKey) ?? '-'}/${digest(jsonEncode([found.contexts, contexts]))}';
      },
      (service, parsed, operation) =>
          service.saveItemContexts(operation, projectId, item, contexts),
    );
  }

  /// 場所・道具の札の語彙（札を選ぶときの一覧、並びも含む）を変える依頼。Vaultの好みに置き、すべての端末で同じ一覧を使う。
  /// 好みをそろえる設定とは関係なく送る。語彙から外した札は、付いている項目に残る。
  Future<CaptureResult> requestContextVocabulary(List<String> items) {
    if (items.length > contextVocabularyMax ||
        !items.every(validContextTag) ||
        items.toSet().length != items.length) {
      throw StateError('札は$contextVocabularyMax個まで、同じ札を重ねずに入力してください。');
    }
    late String payload;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.contexts) {
          throw StateError('Mac miniの本体が場所・道具の札に対応していません。本体を更新してください。');
        }
        if (listEquals(parsed.contextVocabulary, items)) {
          throw StateError('札の一覧は変わっていません。');
        }
        // 変えた日時は、知っている版（Vaultの版・反映待ちの版）より必ず後にする（遅れて届いた古い変更で巻き戻さないため）。
        final known = parsed.contextVocabularyAt;
        final now = DateTime.now().toUtc(),
            after = known?.add(const Duration(milliseconds: 1));
        payload = encodePreferencesPayload(_deviceName, {
          'contexts': (
            at: after != null && after.isAfter(now) ? after : now,
            value: {'items': items},
          ),
        });
        return 'contexts-vocabulary/${digest(jsonEncode([parsed.sharedPreferences['contexts']?.requestId, parsed.contextVocabularyAt?.toIso8601String(), items]))}';
      },
      (service, parsed, operation) =>
          service.savePreferences(operation, payload),
    );
  }

  /// 項目を「いつかやる」へ移す（[action]がmove）・見直したが今は始めない（keep）・元の欄へ戻す（back）依頼。
  /// 移した日と見直した日は端末の今日（本体と同じ暦日）にする。AIは移さず、本人の操作だけを送る。
  Future<CaptureResult> requestItemSomeday(
    String projectId,
    String itemKey,
    String action, {
    DateTime? now,
  }) {
    if (!const ['move', 'keep', 'back'].contains(action)) {
      throw StateError('項目と操作を確認してください。');
    }
    final today = hubToday(now);
    late NowItemRef item;
    late ({String since, String reviewed})? someday;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.someday) {
          throw StateError('Mac miniの本体が「いつかやる」に対応していません。本体を更新してください。');
        }
        final found = _recordTarget(parsed, projectId, itemKey);
        if (found == null || found.resolved) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (action == 'move' ? found.someday : !found.someday) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (action == 'move' && found.waiting) {
          throw StateError('連絡待ちの項目は「いつかやる」へ移せません。先に連絡待ちの印を外してください。');
        }
        if (action == 'keep' && found.somedayReviewed == today) {
          throw StateError('今日すでに見直しています。');
        }
        if (parsed.somedayRequestIdFor(itemKey) != null) {
          throw StateError('この項目の「いつかやる」は依頼済みです。保存と反映を確認してください。');
        }
        // 完了・解決の報告が先に反映されると、本体は依頼を断る。連絡待ちの依頼とも重ねない。
        if (parsed.itemRequestIdFor(itemKey) != null ||
            parsed.waitRequestIdFor(itemKey) != null) {
          throw StateError('この項目への別の依頼が反映されるまで待ってから依頼してください。');
        }
        item = found;
        someday = switch (action) {
          'move' => (since: today, reviewed: today),
          'keep' => (since: found.somedaySince!, reviewed: today),
          _ => null,
        };
        // 外した記録も含む最新の記録IDを含め、同じ内容の再試行だけを同じ操作にする。
        return 'someday/$projectId/$itemKey/${parsed.latestSomedayIdFor(itemKey) ?? '-'}/${found.somedayId ?? '-'}/$action/$today';
      },
      (service, parsed, operation) =>
          service.saveItemSomeday(operation, projectId, item, someday),
    );
  }

  /// アイデアを「いつかやる」に置く（add）・見直した（keep）・始めた（start）・やめた（drop）、
  /// 休止中のプロジェクトを見直した（[target]がprojectでkeep）ことを依頼する。判断した日は端末の今日。
  Future<CaptureResult> requestSomedayReview(
    String target,
    String targetId,
    String action, {
    DateTime? now,
  }) {
    if (!const ['idea', 'project'].contains(target) ||
        !somedayReviewActions.contains(action) ||
        (target == 'project' && action != 'keep')) {
      throw StateError('対象と操作を確認してください。');
    }
    final today = hubToday(now);
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.someday) {
          throw StateError('Mac miniの本体が「いつかやる」に対応していません。本体を更新してください。');
        }
        final entry = parsed.somedayEntries
            .where((e) => e.kind == target && e.id == targetId)
            .firstOrNull;
        if (target == 'idea' && parsed.ideaRecord(targetId) == null) {
          throw StateError('アイデアが見つかりません。表示を確認してから操作してください。');
        }
        if (target == 'project') {
          final project = parsed.projects[targetId];
          if (project == null || project.lifecycle != 'paused') {
            throw StateError('現状が更新されています。表示を確認してから操作してください。');
          }
          _refuseMerged(parsed, project);
        }
        // 置くのは一覧にないアイデアだけ、見直す・始める・やめるのは一覧にあるものだけ。
        if ((action == 'add') != (entry == null)) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (action == 'keep' && entry?.reviewed == today) {
          throw StateError('今日すでに見直しています。');
        }
        if (parsed.somedayReviewRequestIdFor(target, targetId) != null) {
          throw StateError('この「いつかやる」は依頼済みです。保存と反映を確認してください。');
        }
        return 'someday-review/$target/$targetId/$action/$today/${entry?.reviewed ?? '-'}';
      },
      (service, parsed, operation) => service.saveSomedayReview(
        operation,
        target,
        targetId,
        action,
        today,
      ),
    );
  }

  /// 週次レビューを終えた（見直した）と報告する依頼。見直した日は端末の今日（本体と同じ暦日）。
  /// AIは報告せず、本人が最後の段で押したときだけ送る。反映されると、端末の途中の進み具合は使わなくなる。
  Future<CaptureResult> requestWeeklyReview({DateTime? now}) {
    final today = hubToday(now);
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.weeklyReview) {
          throw StateError('Mac miniの本体が週次レビューに対応していません。本体を更新してください。');
        }
        if (parsed.weeklyReviewRequestId != null) {
          throw StateError('見直したことは報告済みです。保存と反映を確認してください。');
        }
        if (parsed.weeklyReview?.lastReviewOn == today) {
          throw StateError('今日の見直しは記録済みです。');
        }
        return 'weekly-review/$today/${parsed.weeklyReview?.lastReviewId ?? '-'}';
      },
      (service, parsed, operation) =>
          service.saveWeeklyReview(operation, today),
    );
  }

  // ---- 週次レビューの途中の進み具合（端末ごと・Vaultごと。Vaultには書かない） ----
  // settings.jsonの`weeklyReview`に、Vaultのidentityごとの今いる段と始めた日、始めた時点の最後の見直しの記録IDを保存する。
  static const _maxWeeklyVaults = 6;
  Map<String, dynamic> _weekly = {};

  /// 続きから再開できる進み具合。始めた後に別の端末やCLIで見直しを報告していれば（最後の見直しが変わっていれば）null。
  /// 始めてから見直しの間隔（7日）以上たった進み具合も使わない（中身が変わった段を飛ばさないよう、最初からやり直す）。
  WeeklyProgress? get weeklyProgress {
    final stored = WeeklyProgress.fromJson(_weekly[location?.identity ?? '']);
    final review = repository?.weeklyReview;
    if (stored == null || review == null) return stored;
    if (waitingDays(stored.started, hubToday()) >= review.intervalDays) {
      return null;
    }
    return stored.base == (review.lastReviewId ?? '') ? stored : null;
  }

  /// 週次レビューの今いる段を端末に残す（[step]がnullなら進み具合を消す）。保存できなくても画面の操作は続けられる。
  Future<void> setWeeklyStep(String? step) async {
    final target = location;
    if (target == null || repository == null) return;
    await _loadSeen();
    final current = weeklyProgress;
    _weekly.remove(target.identity);
    if (step != null) {
      _weekly[target.identity] = WeeklyProgress(
        step: step,
        started: current?.started ?? hubToday(),
        base: repository!.weeklyReview?.lastReviewId ?? '',
      ).toJson();
    }
    while (_weekly.length > _maxWeeklyVaults) {
      _weekly.remove(_weekly.keys.first);
    }
    _changed();
    try {
      await _writeSettings();
    } catch (_) {
      // 進み具合は補助なので、保存できなくても週次レビューは続けられる。
    }
  }

  /// 連絡待ちの印を依頼する。[since]（頼んだ日）がnullなら印を外す。[who]（相手）は任意。
  /// 相手の名前はVaultに残る（同期先とバックアップにも入る）。ホーム画面のウィジェットと通知には出さない。
  Future<CaptureResult> requestItemWait(
    String projectId,
    String itemKey, {
    String? who,
    String? since,
  }) {
    if ((since != null && !validScheduleDate(since)) ||
        (who != null && (since == null || !validWaitWho(who)))) {
      throw StateError('相手と頼んだ日を確認してください。');
    }
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.wait) {
          throw StateError('Mac miniの本体が連絡待ちに対応していません。本体を更新してください。');
        }
        final found = _recordTarget(parsed, projectId, itemKey);
        if (found == null || found.resolved) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (since == null
            ? !found.waiting
            : found.waitingSince == since && found.waitingWho == who) {
          throw StateError('連絡待ちは変わっていません。');
        }
        if (parsed.waitRequestIdFor(itemKey) != null) {
          throw StateError('この項目の連絡待ちは依頼済みです。保存と反映を確認してください。');
        }
        if (since != null && found.someday) {
          throw StateError('「いつかやる」の項目には連絡待ちの印を付けられません。先に元の欄へ戻してください。');
        }
        if (parsed.somedayRequestIdFor(itemKey) != null) {
          throw StateError('この項目の「いつかやる」の依頼が反映されるまで待ってから依頼してください。');
        }
        // 完了・解決の報告が先に反映されると、本体は連絡待ちの依頼を断る。
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目の完了・解決の報告が反映されるまで待ってから依頼してください。');
        }
        item = found;
        // 日付と同じく、外した記録も含む最新の記録IDを含め、同じ内容の再試行だけを同じ操作にする。
        return 'wait/$projectId/$itemKey/${parsed.latestWaitIdFor(itemKey) ?? '-'}/${found.waitingId ?? '-'}/${since ?? 'none'}/${who ?? '-'}';
      },
      (service, parsed, operation) => service.saveItemWait(
        operation,
        projectId,
        item,
        since == null ? null : (who: who, since: since),
      ),
    );
  }

  /// 定例の項目の今の回を完了する（done）・見送る（skip）依頼を保存する。確認した回の期日を添え、本体が次の回へ進める。
  Future<CaptureResult> requestItemOccurrence(
    String projectId,
    String itemKey,
    String action,
  ) {
    if (!occurrenceActions.contains(action)) {
      throw StateError('項目と操作を確認してください。');
    }
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.occurrence) {
          throw StateError('Mac miniの本体が定例の回の完了に対応していません。本体を更新してください。');
        }
        final found = _recordTarget(parsed, projectId, itemKey);
        if (found == null || !found.repeating) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (parsed.scheduleRequestIdFor(itemKey) != null) {
          throw StateError('この項目の日付は依頼済みです。保存と反映を確認してください。');
        }
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目の完了・解決の報告が反映されるまで待ってから依頼してください。');
        }
        item = found;
        // 確認した回（期日）と日付の記録を含め、同じ回への同じ操作の再試行だけを同じ操作として扱う。
        return 'occurrence/$projectId/$itemKey/${found.due}/$action/${found.scheduleId ?? '-'}';
      },
      (service, parsed, operation) =>
          service.saveItemOccurrence(operation, projectId, item, action),
    );
  }

  /// 「記録に聞く」の問いを保存する。答えは本体の次の整理のときに作られ、同期で届く。
  Future<CaptureResult> requestAsk(String question, String? project) {
    final text = question.trim();
    if (text.isEmpty || text.length > askQuestionChars) {
      throw StateError('問いは1〜$askQuestionChars文字で入力してください。');
    }
    return _confirmedRequest(
      (parsed) {
        if (!parsed.intakeFeatures.ask) {
          throw StateError('今は「記録に聞く」を使えません。Mac miniの本体を更新するか、この機能をオンにしてください。');
        }
        if (project != null && !parsed.projects.containsKey(project)) {
          throw StateError('プロジェクトが見つかりません。選び直してください。');
        }
        // 同じ問いを聞き直す場合も、新しい問いとして送る（前の答えの後に記録が増えていることがあるため）。
        return 'ask/${digest('$text\n${project ?? ''}')}/${parsed.asks.length}';
      },
      (service, parsed, operation) => service.saveAsk(operation, text, project),
    );
  }

  /// 「片付いたかも」が違うとき、そのメモからの候補を見送る依頼を保存する。項目の完了・解決は変えない。
  Future<CaptureResult> requestHintDismiss(
    String projectId,
    String itemKey,
    String inputId,
  ) {
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        // 定義だけ先に同期された統合済みのプロジェクトには、古いNOWの項目が残っていても依頼しない（本体が断る）。
        if (parsed.projects[projectId] case final owner?) {
          _refuseMerged(parsed, owner);
        }
        final found = parsed.projects[projectId]?.nowItems
            .where((i) => i.key == itemKey)
            .firstOrNull;
        if (found == null ||
            found.resolved ||
            !found.hints.any((h) => h.inputId == inputId)) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目は完了・解決を報告済みです。保存と反映を確認してください。');
        }
        if (parsed.hintDismissRequestIdFor(itemKey, inputId) != null) {
          throw StateError('この候補は見送り済みです。保存と反映を確認してください。');
        }
        item = found;
        return 'hint/$projectId/$itemKey/$inputId';
      },
      (service, parsed, operation) =>
          service.saveHintDismiss(operation, projectId, item, inputId),
    );
  }

  /// 新しいプロジェクトの作成を依頼する。操作IDとプロジェクトIDは入力フォームが持ち、
  /// 保存結果が不明なときは同じ操作IDで確認する。
  Future<CaptureResult> requestProjectCreate(NewProjectRequest request) async {
    final target = location, epoch = _epoch;
    if (target == null ||
        repository == null ||
        loading ||
        saving ||
        error != null ||
        captureWarning != null) {
      throw StateError('保存先と確認情報を先に確認してください。');
    }
    final problem = request.formatError;
    if (problem != null) throw StateError(problem);
    saving = true;
    _changed();
    try {
      final fresh = await access.readSnapshot(target);
      if (epoch != _epoch || _disposed) throw StateError('Vaultが切り替わりました。');
      final parsed = HubRepository(fresh);
      repository = parsed;
      _changed();
      if (pending.any((p) => p.operationId != request.operationId)) {
        throw StateError('保存確認待ちの操作があります。保存と反映で確認してから依頼してください。');
      }
      // 望む結果に対応していない本体へ送ると、作成の依頼ごと断られる。
      if (request.outcome.isNotEmpty &&
          parsed.intakeFeatures.projectOutcome == null) {
        throw StateError('Mac miniの本体が望む結果に対応していません。望む結果を空にするか、本体を更新してください。');
      }
      if (request.area != null && !parsed.intakeFeatures.areas) {
        throw StateError('Mac miniの本体が領域に対応していません。領域を空にするか、本体を更新してください。');
      }
      // 保存結果が不明だった同じ依頼の確認では、自分自身を作成依頼中として重なりに数えない。
      if (!pending.any((p) => p.operationId == request.operationId)) {
        final overlap = request.overlapError(
          parsed.projects.values,
          parsed.pendingProjectCreations,
        );
        if (overlap != null) throw StateError(overlap);
      }
      return await CaptureService(access, target).saveProjectCreate(request);
    } finally {
      saving = false;
      if (!_disposed) await reload();
      _changed();
    }
  }

  /// 手で書き換えて止まったNOWを、表示中のNOW.mdのhashに結び付けて生成版へ戻す依頼を保存する。
  Future<CaptureResult> requestConflictResolve(
    String projectId,
    String expectedHash,
  ) {
    late HubProject project;
    return _confirmedRequest(
      (parsed) {
        final found = parsed.projects[projectId];
        if (found?.nowConflict?.nowHash != expectedHash) {
          throw StateError('現状が更新されています。表示を確認してから操作してください。');
        }
        if (parsed.conflictRequestIdFor(projectId) != null) {
          throw StateError('生成版に戻す依頼は送信済みです。保存と反映を確認してください。');
        }
        project = found!;
        return 'conflict-resolve/$projectId/$expectedHash';
      },
      (service, parsed, operation) =>
          service.saveConflictResolve(operation, project),
    );
  }

  /// 表示中のアイデアのhash。確認の画面を出すときに取り、依頼に渡す。読めなければnull。
  String? ideaSeenHash(String id) {
    final repo = repository, record = repo?.ideaRecord(id);
    final raw = record == null ? null : repo!.snapshot.files[record.path];
    return raw == null ? null : digest(raw);
  }

  /// 似ているアイデアの組を束ねる（link）か、別の話とする（separate）依頼を保存する。
  /// 束ねるのは索引にある未確認の組、束から外すのは同じ束にある組、別の話とするのはそのどちらか。
  ///
  /// [seenA]・[seenB]は、本人が確認の画面で見ていた時点の両方のアイデアのhash（[ideaSeenHash]）。
  /// 読み直した内容と食い違えば、依頼を保存せずに止める。
  Future<CaptureResult> requestIdeaLink(
    String a,
    String b,
    String action, {
    required String seenA,
    required String seenB,
  }) {
    late String hashA, hashB;
    return _confirmedRequest(
      (parsed) {
        final key = ideaPairKey(a, b);
        final candidate = parsed.ideaCandidates
            .where((c) => ideaPairKey(c.a, c.b) == key)
            .firstOrNull;
        // 束から外せるのは、本人が直接束ねた組だけ（束を間接につないでいる組は外しても束に残る）。
        final linked = parsed.ideaGroupOf(a)?.linksDirectly(a, b) ?? false;
        if (!ideaLinkActions.contains(action) ||
            (action == 'link' && candidate == null) ||
            (action == 'separate' && candidate == null && !linked)) {
          throw StateError('似ているアイデアの一覧が更新されています。表示を確認してから操作してください。');
        }
        if (parsed.ideaLinkRequestIdFor(a, b) != null) {
          throw StateError('この組は依頼済みです。保存と反映を確認してください。');
        }
        final ra = parsed.ideaRecord(a), rb = parsed.ideaRecord(b);
        if (ra == null || rb == null) {
          throw StateError('アイデアが見つかりません。再読込してください。');
        }
        // 依頼には、本人が見ていた内容のhashを付ける。読み直した内容が変わっていれば止める。
        hashA = digest(parsed.snapshot.files[ra.path]!);
        hashB = digest(parsed.snapshot.files[rb.path]!);
        if (hashA != seenA || hashB != seenB) {
          throw StateError('アイデアの内容が更新されました。表示を確認してから、もう一度操作してください。');
        }
        // 索引がアイデアより先に（または後に）同期されている間は、束ねる依頼を出さない。
        if (candidate != null &&
            action == 'link' &&
            ((candidate.a == a ? candidate.hashA : candidate.hashB) != hashA ||
                (candidate.a == b ? candidate.hashA : candidate.hashB) !=
                    hashB)) {
          throw StateError('似ているアイデアの一覧とアイデアの同期が揃っていません。再読込してから操作してください。');
        }
        return 'idea-link/$key/$action/$hashA/$hashB';
      },
      (service, parsed, operation) =>
          service.saveIdeaLink(operation, a, hashA, b, hashB, action),
    );
  }

  /// 今週の気づきの項目へ反応（[insightReactions]）を付ける依頼を保存する。noneは反応を外す。
  /// 一覧が別の週の気づきに入れ替わっていれば、保存せずに止める。
  Future<CaptureResult> requestInsightReaction(
    String runId,
    String itemKey,
    String reaction,
  ) => _confirmedRequest(
    (parsed) {
      final current = parsed.insights;
      if (!insightReactions.contains(reaction) ||
          current?.runId != runId ||
          !current!.items.any((i) => i.key == itemKey)) {
        throw StateError('今週の気づきが更新されています。表示を確認してから操作してください。');
      }
      return 'insight-reaction/$runId/$itemKey/$reaction';
    },
    (service, parsed, operation) =>
        service.saveInsightReaction(operation, runId, itemKey, reaction),
  );

  /// 作業記録の下書きを見送る依頼を保存する。
  Future<CaptureResult> requestGitDraftDismiss(
    String draftId,
    String expectedHash,
  ) {
    late GitDraft draft;
    return _confirmedRequest(
      (parsed) {
        final found = parsed.gitDrafts[draftId];
        if (found == null || found.hash != expectedHash) {
          throw StateError('下書きが更新されています。表示を確認してから操作してください。');
        }
        if (parsed.draftRequestIdFor(draftId) != null) {
          throw StateError('この下書きは操作済みです。保存と反映を確認してください。');
        }
        draft = found;
        return 'git-draft-dismiss/$draftId/$expectedHash';
      },
      (service, parsed, operation) =>
          service.saveGitDraftDismiss(operation, draft),
    );
  }

  // ---- 前回見てからの変化（端末ごと・Vaultごと。Vaultには書かない） ----
  // settings.jsonの`seen`に、Vaultのidentityごと・プロジェクトごとの最後に見たNOWの項目を保存する。
  // 状態ファイルは64KiBまでなので、保存先の設定と合わせて[_settingsBudget]以内に収める。
  static const _settingsBudget = 48 * 1024;
  Map<String, dynamic> _seen = {};
  bool _seenLoaded = false;
  final Map<String, List<SeenItem>?> _visits = {};

  Future<void> _loadSeen() async {
    if (_seenLoaded) return;
    try {
      final raw = await access.readState('settings.json');
      final value = raw == null ? null : jsonDecode(raw);
      if (value is Map && value['seen'] is Map) {
        _seen = Map<String, dynamic>.from(value['seen'] as Map);
      }
      if (value is Map && value['homeWidget'] is Map) {
        _homeWidgets = Map<String, dynamic>.from(value['homeWidget'] as Map);
      }
      if (value is Map && value['pins'] is Map) {
        _pins = Map<String, dynamic>.from(value['pins'] as Map);
      }
      if (value is Map && value['preferenceSync'] is Map) {
        _preferenceSync =
            jsonDecode(jsonEncode(value['preferenceSync']))
                as Map<String, dynamic>;
      }
      if (value is Map) autoReload = value['autoReload'] != false;
      if (value is Map && value['today'] is Map) {
        _today = Map<String, dynamic>.from(value['today'] as Map);
      }
      if (value is Map && value['weeklyReview'] is Map) {
        _weekly = Map<String, dynamic>.from(value['weeklyReview'] as Map);
      }
      if (value is Map) {
        final settings = AttentionSettings.fromJson(value['attention']);
        _attention = settings.state;
        attentionNotify = settings.notify;
        dueNotify = settings.due;
      }
    } catch (_) {
      // 読めない記録は空として扱う。保存先の設定はrestoreで別に扱う。
    }
    _seenLoaded = true;
    _applyPins();
    _ensureAttentionSchedule();
  }

  /// 保存先の設定を書く。既読の記録は容量内に収め、書けなくても保存先の設定は残す。
  /// 端末に残した設定を読む前には書かない（読む前に書くと、既読・ピン留め・ウィジェットの設定を消してしまう）。
  Future<void> _writeSettings() async {
    final target = location;
    if (target == null) return;
    await _loadSeen();
    String encoded;
    try {
      encoded = _encodeSettings(target);
    } catch (_) {
      _seen = {};
      encoded = jsonEncode({..._settingsBase(target)});
    }
    await access.writeState('settings.json', encoded);
  }

  Map<String, Object?> _settingsBase(VaultLocation target) => {
    ...target.toJson(),
    if (_homeWidgets.isNotEmpty) 'homeWidget': _homeWidgets,
    if (_pins.isNotEmpty) 'pins': _pins,
    if (_preferenceSync.isNotEmpty) 'preferenceSync': _preferenceSync,
    if (_today.isNotEmpty) 'today': _today,
    if (_weekly.isNotEmpty) 'weeklyReview': _weekly,
    if (!autoReload) 'autoReload': false,
    if (_attention.identity != null || attentionNotify || dueNotify)
      'attention': AttentionSettings(
        _attention,
        attentionNotify,
        due: dueNotify,
      ).toJson(),
  };

  /// 既読の記録を容量内に収めて設定を作る。古いVault→本文→古いプロジェクトの順に削る。
  String _encodeSettings(VaultLocation target) {
    String encode() => jsonEncode({..._settingsBase(target), 'seen': _seen});
    bool fits(String v) => utf8.encode(v).length <= _settingsBudget;
    final current = _seen[target.identity];
    final projects = repository?.projects;
    if (current is Map && projects != null) {
      current.removeWhere((id, _) => !projects.containsKey(id));
    }
    String at(Object? v) => v is Map && v['at'] is String ? v['at'] : '';
    String vaultAt(Object? v) => v is Map
        ? v.values.map(at).fold('', (a, b) => a.compareTo(b) >= 0 ? a : b)
        : '';
    var value = encode();
    while (!fits(value)) {
      final others = _seen.keys.where((k) => k != target.identity).toList()
        ..sort((a, b) => vaultAt(_seen[a]).compareTo(vaultAt(_seen[b])));
      if (others.isEmpty) break;
      _seen.remove(others.first);
      value = encode();
    }
    if (current is! Map) return value;
    final order = current.keys.toList()
      ..sort((a, b) => at(current[a]).compareTo(at(current[b])));
    for (final id in order) {
      if (fits(value)) break;
      final items = (current[id] as Map?)?['items'];
      if (items is List) {
        for (final i in items) {
          if (i is Map) i.remove('t');
        }
      }
      value = encode();
    }
    for (final id in order) {
      if (fits(value)) break;
      current.remove(id);
      value = encode();
    }
    return value;
  }

  static List<SeenItem> seenItemsOf(HubProject project) => [
    for (final section in ['current', 'next', 'open'])
      for (final entry in project.sections[section]!)
        ?SeenItem.of(section, entry),
  ];

  Map<String, dynamic> get _seenForVault {
    final identity = location?.identity ?? '';
    final value = _seen[identity];
    if (value is Map<String, dynamic>) return value;
    final created = <String, dynamic>{};
    _seen[identity] = created;
    return created;
  }

  List<SeenItem>? _stored(String projectId) {
    final value = (_seen[location?.identity ?? ''] as Map?)?[projectId];
    if (value is! Map || value['items'] is! List) return null;
    // 旧形式（hashのない記録）は記録なしとして扱い、今の内容で記録し直す。
    if ((value['items'] as List).any((i) => i is! Map || i['h'] is! String)) {
      return null;
    }
    return [
      for (final i in value['items'] as List)
        if (i is Map && i['s'] is String && i['h'] is String)
          SeenItem(
            i['s'] as String,
            i['h'] as String,
            i['t'] is String ? i['t'] as String : '',
          ),
    ];
  }

  void _store(HubProject project) {
    _seenForVault[project.id] = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'items': [
        for (final i in seenItemsOf(project).take(300))
          {'s': i.section, 'h': i.hash, 't': i.text},
      ],
    };
  }

  /// まだ記録のないプロジェクトは、今の内容を既読として記録する（初回にすべてを新着にしない）。
  bool _initializeSeen() {
    final repo = repository;
    if (repo == null) return false;
    var changed = false;
    for (final project in repo.projects.values) {
      if (project.nowRecordId == null || _stored(project.id) != null) continue;
      _store(project);
      changed = true;
    }
    return changed;
  }

  /// 前回見たときから増えた項目と外れた項目。記録がなければnull。
  ProjectChanges? changesSince(HubProject project, {bool visit = false}) {
    final base = visit && _visits.containsKey(project.id)
        ? _visits[project.id]
        : _stored(project.id);
    if (base == null) return null;
    final now = seenItemsOf(project),
        before = base.map((i) => i.id).toSet(),
        after = now.map((i) => i.id).toSet();
    return ProjectChanges(
      added: now.where((i) => !before.contains(i.id)).toList(),
      removed: base.where((i) => !after.contains(i.id)).toList(),
    );
  }

  /// プロジェクトを開いたとき、表示中の比較の基準を固定してから今の内容を既読にする。
  Future<void> beginVisit(String projectId) async {
    final project = repository?.projects[projectId];
    if (project == null || project.nowRecordId == null) return;
    await _loadSeen();
    _visits[projectId] = _stored(projectId);
    _store(project);
    try {
      await _writeSettings();
    } catch (_) {
      // 既読の記録に失敗しても閲覧は続ける。
    }
    _changed();
  }

  /// すべてのプロジェクトを既読にする。
  Future<void> markAllSeen() async {
    final repo = repository;
    if (repo == null) return;
    await _loadSeen();
    for (final project in repo.projects.values) {
      if (project.nowRecordId != null) _store(project);
    }
    _visits.clear();
    await _writeSettings();
    _changed();
  }

  String? resolveLink(String sourcePath, String href) {
    try {
      final uri = Uri.parse(href);
      if (uri.hasScheme ||
          uri.hasAuthority ||
          uri.path.startsWith('/') ||
          uri.path.contains('\\')) {
        return null;
      }
      final path = p.posix.normalize(
        p.posix.join(p.posix.dirname(sourcePath), uri.path),
      );
      return repository?.records.values
          .where((r) => r.path == path)
          .firstOrNull
          ?.id;
    } catch (_) {
      return null;
    }
  }
}

/// 訂正を書いている間に、同じメモへ新しい訂正が届いた。フォームを開き直して最新の本文から書き直す。
class CorrectionTargetChanged extends StateError {
  CorrectionTargetChanged()
    : super('このメモに新しい訂正が届いています。フォームを閉じ、最新の本文を確認してから訂正し直してください。');
}
