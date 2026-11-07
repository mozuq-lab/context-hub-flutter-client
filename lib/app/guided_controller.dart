import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../ai/claude_client.dart';
import '../ai/guided_services.dart';
import '../core/guided.dart';
import '../storage/capture_service.dart';
import '../storage/guided_store.dart';
import '../storage/secret_store.dart';
import 'controller.dart';

/// AIへ送るVaultの資料。[label]はproject・vault・none、[reason]は資料を作れなかった理由。
class GuidedContext {
  const GuidedContext(this.text, this.label) : reason = null;
  const GuidedContext.none([this.reason]) : text = '', label = 'none';
  final String text, label;
  final String? reason;
}

enum GuidedPhase { setup, question, summary }

/// 選んで深掘りの進行。問いとまとめはClaude APIで作り、保存は本人の確認後にInputへ行う。
///
/// 途中の状態は端末の`guided.json`に残し、閉じても続きから再開できる。
/// 画面ごとに作り、閉じたら[dispose]で実行中の依頼を打ち切る。
class GuidedController extends ChangeNotifier {
  GuidedController(this.hub)
    : services = hub.guidedServices,
      store = GuidedStore(hub.access);
  final HubController hub;
  final GuidedServices services;
  final GuidedStore store;

  /// 端末の状態。読み込むまでnull。
  GuidedState? state;

  /// 進行中の深掘り。始める前はnull。
  GuidedSession? active;

  /// 再開できる前回の深掘り（同じVaultのもの）。
  GuidedSession? resumable;

  /// 別のVaultで始めた深掘りが残っているか。新しく始めると破棄する。
  bool otherVault = false;
  GuidedPhase phase = GuidedPhase.setup;
  bool busy = false, saving = false;

  /// 画面を開いている間だけ持つAPIキー。Macのキーチェーンの確認を問いのたびに出さないよう、
  /// 読むのは開いたとき・読み出し直すとき・登録したときだけにする。
  String? _key;

  /// APIキーを読み出せなかった理由（アクセスの拒否・保管場所の故障）。キーがないだけならnull。
  String? keyProblem;
  bool get hasKey => _key != null;

  /// 途中の状態を端末に残せなかったか（大きすぎる・書込失敗）。
  bool persistFailed = false;

  /// 保存結果が不明な操作を、一度でも確認したか。確認するまでは破棄できない。
  bool confirmedOnce = false;
  String? error;
  CaptureResult? result;
  int _epoch = 0;
  bool _disposed = false;
  Timer? _debounce;

  bool get ready => state != null;

  /// 保存を試みた後か。結果が分かるまで、本文を変えず同じ操作IDで確認だけを行う。
  bool get locked => active?.operationId != null;

  /// 別のVaultの深掘りに、保存結果を確かめていない操作が残っているか。
  /// 本人が破棄を選ぶまで、新しく始めない（同じ内容を別の操作で保存し直さないため）。
  bool get otherVaultLocked =>
      otherVault && state?.session?.operationId != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _key = null;
    if (busy) {
      _epoch++;
      services.model.abort();
    }
    final pending = _debounce?.isActive == true;
    _debounce?.cancel();
    if (pending && state != null) store.write(state!);
    super.dispose();
  }

  Future<void> load() async {
    final loaded = await store.read(services.clock());
    await _loadKey();
    final stored = loaded.session;
    var dirty = false;
    if (stored != null && stored.vault == hub.location?.identity) {
      final op = stored.operationId;
      final saved = op == null ? null : await hub.operationState(op);
      if (saved == 'saved') {
        loaded.session = null;
        dirty = true;
      } else {
        // 書き込む前に止まった保存（journalなし）は、内容を直して保存し直せる。
        if (op != null && saved == null) {
          stored.operationId = null;
          dirty = true;
        }
        resumable = stored;
      }
    } else if (stored != null) {
      otherVault = true;
    }
    if (_disposed) return;
    state = loaded;
    if (dirty) await _persist();
    // 保存結果が不明な深掘りは、確認画面へ直接戻す（新しく始めて同じ内容を送り直さないため）。
    if (resumable?.operationId != null) {
      resume();
    } else {
      _changed();
    }
  }

  Future<void> _loadKey() async {
    try {
      final value = await services.secrets.read();
      _key = value == null || value.isEmpty ? null : value;
      keyProblem = null;
    } catch (_) {
      _key = null;
      keyProblem =
          'この端末の保管場所からAPIキーを読み出せませんでした。Macでキーチェーンの確認が出たときは「常に許可」を選んでください。「もう一度読み出す」で試し直すか、AIの設定で登録し直せます。';
    }
  }

  /// APIキーを読み出し直す（キーチェーンのアクセスを拒否した後など）。
  Future<void> reloadKey() async {
    if (busy) return;
    await _loadKey();
    _changed();
  }

  String? _title(GuidedSession s) =>
      s.project == null ? null : hub.repository?.projects[s.project]?.title;

  /// プロジェクト（nullならVault全体）の資料。始める前に本人へ見せ、そのまま送る。
  GuidedContext buildContext(String? project) {
    final repo = hub.repository;
    if (repo == null) return const GuidedContext.none('Vaultを読み込めていません。');
    try {
      return project == null
          ? GuidedContext(
              repo.vaultContext(maxChars: guidedContextChars),
              'vault',
            )
          : GuidedContext(
              repo.context(project, maxChars: guidedContextChars),
              'project',
            );
    } on FormatException catch (e) {
      return GuidedContext.none(e.message);
    } catch (_) {
      return const GuidedContext.none('資料を作れませんでした。');
    }
  }

  /// 前回の深掘りを続ける。問いがなければ次の問いを作る。
  void resume() {
    final s = resumable, st = state;
    if (s == null || st == null || busy) return;
    active = s;
    st.session = s;
    resumable = null;
    error = null;
    confirmedOnce = false;
    result = s.operationId == null
        ? null
        : CaptureResult(s.operationId!, '', 'uncertain');
    if (s.operationId != null || s.summary != null) {
      phase = GuidedPhase.summary;
      _changed();
    } else if (s.current == null && s.steps.length >= guidedMaxQuestions) {
      summarize();
    } else {
      phase = GuidedPhase.question;
      if (s.current == null) {
        ask();
      } else {
        _changed();
      }
    }
  }

  /// 残っている前回の深掘り（別のVaultのものを含む）を捨てる。
  /// 同じVaultで保存結果が不明なものは、確かめるまで捨てない。別のVaultのものは、
  /// そのVaultを開けない場合に備えて捨てられる（操作の記録は残り、そのVaultの受付状況で確かめられる）。
  Future<void> dropStored() async {
    final st = state;
    if (st == null || busy || active != null) return;
    if (resumable?.operationId != null) return;
    st.session = null;
    resumable = null;
    otherVault = false;
    await _persist();
    _changed();
  }

  Future<void> start(
    GuidedPurpose purpose, {
    String? project,
    String seed = '',
    GuidedContext context = const GuidedContext.none(),
  }) async {
    final st = state, identity = hub.location?.identity;
    if (st == null || identity == null || busy || active != null) return;
    if (resumable?.operationId != null || otherVaultLocked) return;
    final text = seed.trim();
    if (text.length > guidedSeedChars) {
      error = 'きっかけは$guidedSeedChars字以内にしてください。';
      _changed();
      return;
    }
    final included =
        context.text.isNotEmpty && context.text.length <= guidedContextChars;
    final s = GuidedSession(
      id: const Uuid().v4(),
      vault: identity,
      purpose: purpose,
      project: project,
      seed: text,
      context: included ? context.text : '',
      contextLabel: included ? context.label : 'none',
      startedAt: services.clock(),
    );
    active = s;
    st.session = s;
    resumable = null;
    otherVault = false;
    result = null;
    error = null;
    confirmedOnce = false;
    phase = GuidedPhase.question;
    await ask();
  }

  /// Claude APIを1回呼ぶ。月の上限を超えるなら呼ばない。回数は送る前に数える。
  Future<ModelReply> _call(GuidedPrompt prompt, int epoch) async {
    final st = state!;
    final usage = st.usage.current(services.clock());
    if (usage.calls >= st.monthlyLimit) {
      throw ModelException(
        st.monthlyLimit == 0
            ? '月の呼び出し上限が0回になっています。AIの設定で上限を変えてください。'
            : '今月の呼び出しが上限（${st.monthlyLimit}回）に達しました。AIの設定で上限を変えられます。',
      );
    }
    final key = _key;
    if (key == null) {
      throw const ModelException('APIキーが設定されていません。AIの設定で登録してください。');
    }
    st.usage = usage.add(services.clock(), calls: 1);
    // 強制終了されても回答と回数を失わないよう、送る前に残す。残す間に中止・終了されたら送らない（課金しない）。
    await _persist();
    if (epoch != _epoch) throw const ModelException('中止しました。');
    try {
      final reply = await services.model.send(prompt, apiKey: key);
      st.usage = st.usage.add(
        services.clock(),
        input: reply.inputTokens,
        output: reply.outputTokens,
      );
      return reply;
    } on ModelException catch (e) {
      // 断られた・途中で止まった応答も、使ったトークンは数える。
      st.usage = st.usage.add(
        services.clock(),
        input: e.inputTokens,
        output: e.outputTokens,
      );
      rethrow;
    }
  }

  /// 次の問いを作る。使えない出力は理由を添えて1回だけ作り直す。
  Future<void> ask() async {
    final s = active;
    if (s == null || busy || locked) return;
    // 上限まで答えたら、新しい問いは作らずまとめへ進む。
    if (s.steps.length >= guidedMaxQuestions) return summarize();
    final epoch = ++_epoch;
    busy = true;
    error = null;
    phase = GuidedPhase.question;
    _changed();
    try {
      String? note;
      for (var attempt = 0; attempt < 2; attempt++) {
        final reply = await _call(
          guidedQuestionPrompt(s, projectTitle: _title(s), retryNote: note),
          epoch,
        );
        if (epoch != _epoch) return;
        s.models.add(reply.model);
        try {
          s.current = GuidedQuestion.parse(reply.text);
          s.updatedAt = services.clock();
          return;
        } on FormatException catch (e) {
          note = e.message;
        }
      }
      error = 'Claudeの問いが決まりに合いませんでした。「もう一度」で作り直すか、ここでまとめてください。';
    } on ModelException catch (e) {
      if (epoch == _epoch) error = e.message;
    } catch (_) {
      if (epoch == _epoch) error = 'Claudeを呼び出せませんでした。もう一度試してください。';
    } finally {
      if (epoch == _epoch) {
        busy = false;
        await _persist();
        _changed();
      }
    }
  }

  /// 表示中の問いに答える。10問に達したらまとめへ進む。
  Future<void> answer(GuidedAnswer answer) async {
    final s = active, q = s?.current;
    if (s == null || q == null || busy || locked) return;
    final free = answer.freeText;
    if (free != null) {
      final text = free.trim();
      if (text.isEmpty || text.length > guidedFreeTextChars) {
        error = '一言は1〜$guidedFreeTextChars字で書いてください。';
        _changed();
        return;
      }
      answer = GuidedAnswer.free(text);
    } else if (!answer.unknown) {
      final labels = {for (final o in q.options) o.label};
      final picked = answer.selected;
      if (!picked.every(labels.contains) ||
          picked.toSet().length != picked.length ||
          (!q.multiSelect && picked.length != 1)) {
        error = '選択肢を確かめてください。';
        _changed();
        return;
      }
    }
    s.steps.add(GuidedStep(q, answer));
    s.current = null;
    s.updatedAt = services.clock();
    if (s.steps.length >= guidedMaxQuestions) {
      await summarize();
    } else {
      await ask();
    }
  }

  /// [index]番目（0から）の問いへ戻り、それ以降の回答を消す。
  void backTo(int index) {
    final s = active;
    if (s == null || busy || locked || index < 0 || index >= s.steps.length) {
      return;
    }
    s.current = s.steps[index].question;
    s.steps.removeRange(index, s.steps.length);
    s.summary = null;
    s.updatedAt = services.clock();
    error = null;
    phase = GuidedPhase.question;
    _persist();
    _changed();
  }

  /// これまでの問答からまとめを書く。
  Future<void> summarize() async {
    final s = active;
    if (s == null || busy || locked || s.steps.isEmpty) return;
    final epoch = ++_epoch;
    busy = true;
    error = null;
    phase = GuidedPhase.summary;
    _changed();
    try {
      String? note;
      for (var attempt = 0; attempt < 2; attempt++) {
        final reply = await _call(
          guidedSummaryPrompt(s, projectTitle: _title(s), retryNote: note),
          epoch,
        );
        if (epoch != _epoch) return;
        s.models.add(reply.model);
        try {
          s.summary = guidedSummary(s.purpose, reply.text);
          s.updatedAt = services.clock();
          return;
        } on FormatException catch (e) {
          note = e.message;
        }
      }
      error = 'Claudeのまとめが決まりに合いませんでした。「もう一度」で書き直すか、問いに戻ってください。';
    } on ModelException catch (e) {
      if (epoch == _epoch) error = e.message;
    } catch (_) {
      if (epoch == _epoch) error = 'Claudeを呼び出せませんでした。もう一度試してください。';
    } finally {
      if (epoch == _epoch) {
        busy = false;
        await _persist();
        _changed();
      }
    }
  }

  /// まとめを捨てて問いへ戻る。10問に達していれば最後の問いから答え直す。
  void backToQuestions() {
    final s = active;
    if (s == null || busy || locked) return;
    if (s.current == null && s.steps.length >= guidedMaxQuestions) {
      backTo(s.steps.length - 1);
      return;
    }
    s.summary = null;
    s.updatedAt = services.clock();
    error = null;
    phase = GuidedPhase.question;
    _persist();
    _changed();
  }

  /// 実行中の依頼を打ち切る。まとめの作成中なら問いへ戻る。
  void cancel() {
    if (!busy) return;
    _epoch++;
    services.model.abort();
    busy = false;
    final s = active;
    if (phase == GuidedPhase.summary &&
        s?.summary == null &&
        (s?.steps.length ?? 0) < guidedMaxQuestions) {
      phase = GuidedPhase.question;
    }
    error = '中止しました。';
    _persist();
    _changed();
  }

  /// 本人が直したまとめ。長さは入力欄で抑え、上限を超える本文は保存の前に止める（[bodyProblem]）。
  /// ここで切ると入力欄の文字とカーソルが書き換わるため、切らない。
  void editSummary(String text) {
    final s = active;
    if (s == null || locked || s.summary == null || s.summary == text) return;
    s.summary = text;
    s.updatedAt = services.clock();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), flush);
    _changed();
  }

  void setProject(String? project) {
    final s = active;
    if (s == null || locked || saving) return;
    s.project = project;
    s.updatedAt = services.clock();
    _persist();
    _changed();
  }

  /// 書きかけのまとめなどを、すぐ端末に残す（アプリが隠れるとき）。
  void flush() {
    _debounce?.cancel();
    _debounce = null;
    if (!_disposed) _persist();
  }

  Future<bool> _persist() async {
    final st = state;
    if (st == null) return false;
    final ok = await store.write(st);
    if (persistFailed != !ok) {
      persistFailed = !ok;
      _changed();
    }
    return ok;
  }

  /// 保存する本文の問題。問題がなければnull。
  String? get bodyProblem {
    final s = active, summary = s?.summary;
    if (s == null || summary == null) return null;
    if (summary.trim().isEmpty) return 'まとめが空です。';
    final n = guidedBody(summary, s).length;
    return n > guidedBodyChars
        ? '本文が$guidedBodyChars字を超えています（$n字）。まとめを短くしてください。'
        : null;
  }

  /// 確認したまとめと問答の記録を、メモとしてInputへ保存する。
  Future<void> save() async {
    final s = active, summary = s?.summary;
    if (s == null ||
        summary == null ||
        busy ||
        saving ||
        locked ||
        result?.saved == true) {
      return;
    }
    final problem = bodyProblem;
    if (problem != null) {
      error = problem;
      _changed();
      return;
    }
    if (s.project != null &&
        hub.repository?.projects.containsKey(s.project) != true) {
      error = 'プロジェクトが見つかりません。プロジェクトを選び直してください。';
      _changed();
      return;
    }
    saving = true;
    error = null;
    _debounce?.cancel();
    // 保存中に終了されても同じ操作の確認へ戻れるよう、先に操作IDを残す。
    final op = s.operationId = const Uuid().v4();
    _changed();
    if (!await _persist()) {
      // 操作IDを残せないまま送ると、結果が不明なときに別の操作IDで送り直せてしまう。
      s.operationId = null;
      saving = false;
      error = '途中の状態をこの端末に残せないため、保存を止めました。まとめを短くするか、少し待ってからもう一度保存してください。';
      _changed();
      return;
    }
    try {
      final r = await hub.save(
        CaptureDraft(
          operationId: op,
          text: guidedBody(summary, s),
          kind: 'memo',
          project: s.project,
          meta: guidedMeta(s),
        ),
      );
      result = r;
      if (r.saved) await _finish();
    } catch (e) {
      error = HubController.message(e);
      // 何も書かれていなければ（journalなし）、直して保存し直せるようにする。
      if (await hub.operationState(op) == null) {
        s.operationId = null;
        await _persist();
      }
    } finally {
      saving = false;
      _changed();
    }
  }

  /// 保存結果が不明な操作を、同じ操作IDで確かめる（再送しない）。
  Future<void> confirmSame() async {
    final op = active?.operationId;
    if (op == null || saving || busy) return;
    saving = true;
    error = null;
    _changed();
    try {
      final r = await hub.confirm(op);
      result = r;
      confirmedOnce = true;
      if (r.saved) await _finish();
    } catch (e) {
      error = HubController.message(e);
    } finally {
      saving = false;
      _changed();
    }
  }

  Future<void> _finish() async {
    final st = state;
    if (st == null) return;
    st.session = null;
    await _persist();
  }

  /// 進行中の深掘りを捨てて最初に戻る。保存結果が不明なものは、確認するまで捨てられない。
  Future<void> discard() async {
    final st = state;
    if (st == null || busy || saving) return;
    if (locked && !confirmedOnce && result?.saved != true) return;
    _debounce?.cancel();
    active = null;
    if (result?.saved != true) st.session = null;
    result = null;
    error = null;
    confirmedOnce = false;
    phase = GuidedPhase.setup;
    await _persist();
    _changed();
  }

  /// APIキーを保管する。問題があれば理由を返す。
  Future<String?> setKey(String value) async {
    final key = value.trim();
    final problem = SecretStore.problem(key);
    if (problem != null) return problem;
    try {
      await services.secrets.write(key);
    } catch (_) {
      return 'APIキーを保管できませんでした。';
    }
    _key = key;
    keyProblem = null;
    _changed();
    return null;
  }

  Future<String?> deleteKey() async {
    try {
      await services.secrets.delete();
    } catch (_) {
      return 'APIキーを削除できませんでした。';
    }
    _key = null;
    keyProblem = null;
    _changed();
    return null;
  }

  Future<void> setLimit(int limit) async {
    final st = state;
    if (st == null) return;
    st.monthlyLimit = limit.clamp(0, GuidedState.maxLimit);
    await _persist();
    _changed();
  }

  /// 今月の利用（表示用）。
  GuidedUsage? get usage => state?.usage.current(services.clock());
}
