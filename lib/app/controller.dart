import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../storage/vault_access.dart';
import '../storage/capture_service.dart';
import '../storage/draft_store.dart';
import '../core/repository.dart';
import '../core/review_candidates.dart';
import '../storage/review_service.dart';
import '../core/models.dart';
import '../core/parser.dart' show clip;

class ReviewConfirmation {
  ReviewConfirmation(
    this.candidate,
    this.fingerprint,
    this.identity,
    this.epoch, {
    this.target,
    this.retiring = false,
  });
  final ReviewCandidate candidate;
  final String fingerprint, identity;
  final int epoch;
  final AdoptionTarget? target;
  final bool retiring;
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
  HubController(this.access, {required this.sampleLoader});
  final VaultAccess access;
  final Future<Map<String, String>> Function() sampleLoader;
  VaultLocation? location;
  HubRepository? repository;
  ReviewRepository? get review => repository?.review;
  final Map<String, String> _reviewOperations = {};
  bool loading = false, saving = false, composing = false;
  String? error, captureWarning;
  List<CaptureResult> pending = [];
  int _epoch = 0;
  bool _disposed = false;
  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
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

  Future<void> _pending(VaultLocation target, int epoch) async {
    try {
      final list = await CaptureService(access, target).pending();
      if (epoch == _epoch) {
        pending = list;
        captureWarning = null;
      }
    } catch (e) {
      if (epoch == _epoch) {
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
    location = target;
    pending = [];
    captureWarning = null;
    _changed();
    try {
      final data = await access.readSnapshot(target);
      if (epoch != _epoch) {
        return;
      }
      repository = HubRepository(data);
      _visits.clear();
      await _loadSeen();
      _initializeSeen();
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
    final epoch = _epoch;
    final previous = repository?.snapshot;
    loading = true;
    error = null;
    _changed();
    try {
      // 表示の更新では、変わっていないファイルを読み直さない。
      final data = previous == null
          ? await access.readSnapshot(target)
          : await access.refreshSnapshot(target, previous);
      if (epoch != _epoch) {
        return;
      }
      repository = HubRepository(data);
      if (_initializeSeen()) {
        try {
          await _writeSettings();
        } catch (_) {
          // 既読の記録に失敗しても閲覧は続ける。
        }
      }
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

  Future<String> context(String project) async {
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
    if (!confirmed.recognized ||
        confirmed.warnings.isNotEmpty ||
        fresh.fingerprint != confirmed.fingerprint) {
      repository = HubRepository(confirmed);
      _changed();
      throw StateError('コピーの確認中に同期された記録が変わりました。再読込して確認してください。');
    }
    return parsed.context(project);
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

  /// 現在のVaultでの書きかけのキー。Vaultが未選択ならnull。
  String? draftKey({String? gitDraftId}) {
    final target = location;
    return target == null
        ? null
        : DraftStore.keyFor(target.identity, gitDraftId: gitDraftId);
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
      return await CaptureService(access, location!).confirm(operation);
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
    return ReviewConfirmation(
      candidate,
      fresh.fingerprint,
      vaultTarget.identity,
      epoch,
      target: target,
      retiring: retiring,
    );
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
      final key =
          '${target.identity}/${candidate.id}/${ticket.retiring ? 'retire/${candidate.dependencies[candidate.targetPath]}' : candidate.candidateHash}';
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

  /// NOWの項目を完了・解決（resolve）または未解決へ戻す（reopen）報告を保存する。
  Future<CaptureResult> requestItemResolution(
    String projectId,
    String itemKey,
    String action,
  ) {
    late NowItemRef item;
    return _confirmedRequest(
      (parsed) {
        final found = parsed.projects[projectId]?.nowItems
            .where((i) => i.key == itemKey)
            .firstOrNull;
        if (found == null || (action == 'resolve') == found.resolved) {
          throw StateError('NOWが更新されています。表示を確認してから操作してください。');
        }
        if (parsed.itemRequestIdFor(itemKey) != null) {
          throw StateError('この項目は報告済みです。受付状況を確認してください。');
        }
        item = found;
        // 最新の解決・再開記録を含め、解決→再開→解決のように同じ操作を繰り返しても過去の操作と混ざらないようにする。
        return 'item/$projectId/$itemKey/$action/${parsed.latestResolutionIdFor(itemKey) ?? '-'}';
      },
      (service, parsed, operation) =>
          service.saveItemResolution(operation, projectId, item, action),
    );
  }

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
    } catch (_) {
      // 読めない記録は空として扱う。保存先の設定はrestoreで別に扱う。
    }
    _seenLoaded = true;
  }

  /// 保存先の設定を書く。既読の記録は容量内に収め、書けなくても保存先の設定は残す。
  Future<void> _writeSettings() async {
    final target = location;
    if (target == null) return;
    String encoded;
    try {
      encoded = _encodeSettings(target);
    } catch (_) {
      _seen = {};
      encoded = jsonEncode(target.toJson());
    }
    await access.writeState('settings.json', encoded);
  }

  /// 既読の記録を容量内に収めて設定を作る。古いVault→本文→古いプロジェクトの順に削る。
  String _encodeSettings(VaultLocation target) {
    String encode() => jsonEncode({...target.toJson(), 'seen': _seen});
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
