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
import '../core/review_candidates.dart';
import '../storage/review_service.dart';
import '../core/models.dart';
import '../core/parser.dart' show clip;
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
  bool loading = false, saving = false, composing = false;
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

  // ---- 今日の3つ（端末ごと・Vaultごと。Vaultには書かない） ----
  // settings.jsonの`today`に、Vaultのidentityごとの今日選んだ項目と、持ち越しの確認を保存する。
  static const _maxTodayVaults = 12;
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
    final project = repo?.projects[projectId];
    final item = project?.nowItems.where((i) => i.key == itemKey).firstOrNull;
    if (project == null || item == null || item.resolved) {
      throw StateError('この項目は片付いたか、NOWから見つかりません。再読込して確かめてください。');
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
      visible: _visiblePage,
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
    if (enabled &&
        !await access.setAttentionNotifications(enabled: true, request: true)) {
      return false;
    }
    if (!enabled) await access.setAttentionNotifications(enabled: false);
    attentionNotify = enabled;
    attentionNotifyBlocked = false;
    await _writeSettings();
    _changed();
    return true;
  }

  /// 起動のたびに一度、設定が有効なら数時間おきの確認を登録し直す（端末の再起動で消えるため）。
  void _ensureAttentionSchedule() {
    if (_attentionScheduleChecked) return;
    _attentionScheduleChecked = true;
    if (!attentionNotify || !access.attentionNotificationsSupported) return;
    access
        .setAttentionNotifications(enabled: true)
        .then((granted) {
          if (granted || _disposed || !attentionNotify) return;
          // 端末の設定で通知を止められている。設定の画面で知らせる。
          attentionNotifyBlocked = true;
          notifyListeners();
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    _disposed = true;
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
    _changed();
    try {
      final data = await access.readSnapshot(target);
      if (epoch != _epoch) {
        return;
      }
      repository = HubRepository(data);
      _visits.clear();
      await _ensureBasket(target);
      if (epoch != _epoch) return;
      await _loadSeen();
      _initializeSeen();
      _syncAttention();
      _syncToday();
      await _writeSettings();
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
    return _setBasket(
      (current) => Basket(ids: current.ids, maxChars: maxChars),
    );
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
    final draftId = draft.gitDraftId;
    if (draftId != null) {
      // 保存確認待ちの操作がある間は、同じ下書きから二重に入力を作らない。
      if (pending.isNotEmpty) {
        throw StateError('保存確認待ちの操作があります。受付状況で確認してから保存してください。');
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
      return await CaptureService(access, location!).save(draft);
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
  String? draftKey({String? gitDraftId, String? answerTo}) {
    final target = location;
    return target == null
        ? null
        : DraftStore.keyFor(
            target.identity,
            gitDraftId: gitDraftId,
            answerTo: answerTo,
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
        throw StateError('保存確認待ちの操作があります。受付状況で確認してから訂正してください。');
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
        throw StateError('このメモの訂正は反映待ちです。受付状況を確認してください。');
      }
      if (text.trim() == chain.last.body.trim()) {
        throw StateError('訂正前と同じ本文です。直したい箇所を書き換えてください。');
      }
      // 本体は訂正を32件まで、元のメモと訂正の合計を32000文字までに制限する。
      if (chain.length > 32 ||
          chain.fold<int>(text.length, (n, r) => n + r.body.length) > 32000) {
        throw StateError('このメモは訂正の上限に達しています。新しいメモとして追加してください。');
      }
      return await CaptureService(
        access,
        target,
      ).saveCorrection(operationId, expectedLatestId, text);
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
        !(retiring ? candidate.retirable : candidate.actionable)) {
      throw StateError('候補または根拠が変更されています。表示を確認してから操作してください。');
    }
    if ((retiring
            ? review!.retirementRequestIdFor(id)
            : review!.requestIdFor(id)) !=
        null) {
      throw StateError('この候補の依頼は保存済みです。受付状況を確認してください。');
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
          !(ticket.retiring ? candidate.retirable : candidate.actionable) ||
          candidate.candidateHash != ticket.candidate.candidateHash ||
          (ticket.retiring
                  ? review!.retirementRequestIdFor(candidate.id)
                  : review!.requestIdFor(candidate.id)) !=
              null) {
        throw StateError('確認中に候補・根拠・受付が変わりました。再読込して確認してください。');
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
            throw StateError('確認中に候補・根拠・受付が変わりました。再読込して確認してください。');
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
        throw StateError('このプロジェクトの状態変更は依頼済みです。受付状況を確認してください。');
      }
      if (parsed.projectDefinitionRequestIdFor(projectId) != null) {
        throw StateError('呼び名とキーワードの変更が反映されるまで待ってから依頼してください。');
      }
      _refuseMerged(parsed, project);
      if (pending.isNotEmpty) {
        throw StateError('保存確認待ちの操作があります。受付状況で確認してから依頼してください。');
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
              parsed.projectStatusRequestIdFor(p.id) != null) {
            throw StateError('「${p.title}」への依頼が反映待ちです。受付状況を確認してください。');
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
            parsed.projectStatusRequestIdFor(projectId) != null) {
          throw StateError('このプロジェクトへの依頼が反映待ちです。受付状況を確認してください。');
        }
        _refuseMerged(parsed, found);
        final problem = next.problem;
        if (problem != null) throw StateError(problem);
        if (next.sameAs(found)) {
          throw StateError('名前・別名・キーワードに変更がありません。');
        }
        project = found;
        // 変更後の内容と最新の変更記録を含め、同じ定義へ戻す依頼が過去の操作と混ざらないようにする。
        return 'project-definition/$projectId/$expectedHash/${digest(jsonEncode([next.title, next.aliases, next.keywords]))}/${parsed.latestDefinitionChangeId(projectId) ?? '-'}';
      },
      (service, parsed, operation) =>
          service.saveProjectDefinition(operation, project, next),
    );
  }

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
        throw StateError('保存確認待ちの操作があります。受付状況で確認してから依頼してください。');
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
        // 定義だけ先に同期された統合済みのプロジェクトには、古いNOWの項目が残っていても依頼しない（本体が断る）。
        if (parsed.projects[projectId] case final owner?) {
          _refuseMerged(parsed, owner);
        }
        final found = parsed.projects[projectId]?.nowItems
            .where((i) => i.key == itemKey)
            .firstOrNull;
        // 戻せるのは欄から外れている項目だけ、完了・解決にする・外すのは欄にある項目だけ。
        if (found == null || (action != 'reopen') == found.resolved) {
          throw StateError('NOWが更新されています。表示を確認してから操作してください。');
        }
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目は報告済みです。受付状況を確認してください。');
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

  /// NOWの項目に期日・次に見直す日を付ける（両方nullで外す）依頼を保存する。
  Future<CaptureResult> requestItemSchedule(
    String projectId,
    String itemKey,
    String? due,
    String? reviewAfter,
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
        if (found == null || found.resolved) {
          throw StateError('NOWが更新されています。表示を確認してから操作してください。');
        }
        if (found.due == due && found.reviewAfter == reviewAfter) {
          throw StateError('日付は変わっていません。');
        }
        if (parsed.scheduleRequestIdFor(itemKey) != null) {
          throw StateError('この項目の日付は依頼済みです。受付状況を確認してください。');
        }
        // 完了・解決の報告が先に反映されると、本体は日付の依頼を断る。
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目の完了・解決の報告が反映されるまで待ってから依頼してください。');
        }
        item = found;
        // 依頼する日付と最新の日付記録を含め、同じ内容の再試行だけを同じ操作として扱う。
        // 項目の現在の日付のIDは外すと元に戻るため、付ける→外す→同じ日付を付ける、で過去の操作と混ざらないよう
        // 外した記録も含む最新の記録IDを使う（引き継いだ日付は項目のキーに記録がないため、現在の日付のIDも含める）。
        return 'schedule/$projectId/$itemKey/${parsed.latestScheduleIdFor(itemKey) ?? '-'}/${found.scheduleId ?? '-'}/${due ?? '-'}/${reviewAfter ?? '-'}';
      },
      (service, parsed, operation) => service.saveItemSchedule(
        operation,
        projectId,
        item,
        due,
        reviewAfter,
      ),
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
          throw StateError('NOWが更新されています。表示を確認してから操作してください。');
        }
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目は完了・解決を報告済みです。受付状況を確認してください。');
        }
        if (parsed.hintDismissRequestIdFor(itemKey, inputId) != null) {
          throw StateError('この候補は見送り済みです。受付状況を確認してください。');
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
        throw StateError('保存確認待ちの操作があります。受付状況で確認してから依頼してください。');
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
          throw StateError('NOWが更新されています。表示を確認してから操作してください。');
        }
        if (parsed.conflictRequestIdFor(projectId) != null) {
          throw StateError('生成版に戻す依頼は送信済みです。受付状況を確認してください。');
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
          throw StateError('この組は依頼済みです。受付状況を確認してください。');
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
          throw StateError('この下書きは操作済みです。受付状況を確認してください。');
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
      if (value is Map && value['today'] is Map) {
        _today = Map<String, dynamic>.from(value['today'] as Map);
      }
      if (value is Map) {
        final settings = AttentionSettings.fromJson(value['attention']);
        _attention = settings.state;
        attentionNotify = settings.notify;
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
    if (_today.isNotEmpty) 'today': _today,
    if (_attention.identity != null || attentionNotify)
      'attention': AttentionSettings(_attention, attentionNotify).toJson(),
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
