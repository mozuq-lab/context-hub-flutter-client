import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../storage/vault_access.dart';
import '../storage/capture_service.dart';
import '../core/repository.dart';
import '../core/review_candidates.dart';
import '../storage/review_service.dart';

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
      await access.writeState('settings.json', jsonEncode(target.toJson()));
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
    loading = true;
    error = null;
    _changed();
    try {
      final data = await access.readSnapshot(target);
      if (epoch != _epoch) {
        return;
      }
      repository = HubRepository(data);
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
      final operation = _reviewOperations.putIfAbsent(
        '${target.identity}/project-status/$projectId/$expectedHash/$status',
        () => const Uuid().v4(),
      );
      return await CaptureService(
        access,
        target,
      ).saveProjectStatus(operation, project, status);
    } finally {
      saving = false;
      if (!_disposed) await reload();
      _changed();
    }
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
