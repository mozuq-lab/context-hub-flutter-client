import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'parts.dart';
import '../app/controller.dart';
import '../app/guided_controller.dart';
import '../core/guided.dart';
import '../core/models.dart';
import '../core/parser.dart' show clip;
import '../storage/guided_store.dart';
import 'notice.dart';
import 'views.dart' show NoticeBox, checkSecretsBeforeSave, timeLabel;

/// 選んで深掘りを開く。入力フォームと同じく、開いている間はVaultを切り替えない。
Future<void> showGuided(
  BuildContext context,
  HubController c, {
  String? project,
}) async {
  if (c.composing || c.repository == null) return;
  c.composing = true;
  try {
    // 本文の領域ではなく、画面全体に開く（詳細の上から開いても同じ）。
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => GuidedPage(hub: c, project: project),
      ),
    );
  } finally {
    c.composing = false;
  }
}

Future<void> showGuidedSettings(BuildContext context, GuidedController g) =>
    showDialog<void>(
      context: context,
      builder: (_) => GuidedSettingsDialog(controller: g),
    );

const _small = TextStyle(fontSize: 12, height: 1.6);

class GuidedPage extends StatefulWidget {
  const GuidedPage({super.key, required this.hub, this.project});
  final HubController hub;

  /// 始めるときに選んでおくプロジェクト。
  final String? project;
  @override
  State<GuidedPage> createState() => _GuidedPageState();
}

class _GuidedPageState extends State<GuidedPage> {
  late final GuidedController g = GuidedController(widget.hub);
  late final AppLifecycleListener _lifecycle;
  final seed = TextEditingController(),
      other = TextEditingController(),
      summary = TextEditingController();
  GuidedPurpose purpose = GuidedPurpose.record;
  String? project;

  /// Vaultの資料を送るか。本人がオンにしたときだけ送り（既定はオフ）、送る全文を始める前に開いて見せる。
  bool includeContext = false, otherOpen = false;
  final picked = <String>{};
  GuidedQuestion? _shown;
  GuidedContext? _material;
  String? _materialFor;

  /// 資料を作ったときの読込結果。Vaultを読み込み直したら（追加規則が変わった場合を含む）作り直す。
  Object? _materialRepo;

  Map<String, HubProject> get _projects =>
      widget.hub.repository?.projects ?? const {};

  @override
  void initState() {
    super.initState();
    // 統合済みのプロジェクトから始めたときは、統合先のプロジェクトとして深掘りする。
    final given = _projects[widget.project];
    project = given == null ? null : given.mergeTarget ?? given.id;
    g.addListener(_sync);
    widget.hub.addListener(_hubChanged);
    _lifecycle = AppLifecycleListener(
      onInactive: g.flush,
      onHide: g.flush,
      onPause: g.flush,
    );
    g.load();
  }

  /// 問いが変わったら選びかけを消し、新しいまとめを入力欄へ入れる。
  void _sync() {
    if (!mounted) return;
    final q = g.active?.current;
    if (!identical(q, _shown)) {
      _shown = q;
      picked.clear();
      other.clear();
      otherOpen = false;
    }
    final text = g.active?.summary;
    if (text != null && text != summary.text) summary.text = text;
    setState(() {});
  }

  /// Vaultを読み込み直したら、表示する資料を作り直す（送るのは表示したもの）。
  void _hubChanged() {
    if (mounted && !identical(widget.hub.repository, _materialRepo)) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.hub.removeListener(_hubChanged);
    g.removeListener(_sync);
    g.dispose();
    seed.dispose();
    other.dispose();
    summary.dispose();
    super.dispose();
  }

  /// 送る資料。始める前に見せたものをそのまま送る。
  GuidedContext _materialOf(String? id) {
    final key = id ?? '';
    final repo = widget.hub.repository;
    if (_material == null ||
        _materialFor != key ||
        !identical(_materialRepo, repo)) {
      _material = g.buildContext(id);
      _materialFor = key;
      _materialRepo = repo;
    }
    return _material!;
  }

  /// 表示した資料が今の読込結果のものか。違えば、見せていない資料を送らない。
  bool _materialShown(String? id) =>
      _material != null &&
      _materialFor == (id ?? '') &&
      identical(_materialRepo, widget.hub.repository);

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => HubAlertDialog(
          title: Text(title),
          onClose: () => Navigator.pop(context, false),
          content: SizedBox(width: 480, child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('やめる'),
            ),
            FilledButton(
              key: const Key('guided-confirm-action'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _start() async {
    if (g.resumable != null &&
        !await _confirm(
          '新しく始めますか？',
          '前回の問答は破棄されます。Vaultには何も書いていません。',
          '新しく始める',
        )) {
      return;
    }
    if (includeContext && !_materialShown(project)) {
      setState(() {});
      if (mounted) {
        notice(context, 'Vaultの資料が更新されました。表示した資料を確かめてから、もう一度「始める」を押してください。');
      }
      return;
    }
    await g.start(
      purpose,
      project: project,
      seed: seed.text,
      context: includeContext
          ? _materialOf(project)
          : const GuidedContext.none(),
    );
  }

  Future<void> _discard() async {
    if (await _confirm(
      '問答を破棄しますか？',
      g.locked
          ? '保存結果がまだ分かりません。保存済みの可能性があるため、同じ内容を保存し直さないでください。保存されたかは保存と反映で確かめられます。回答とまとめはこの端末から消えます。'
          : '回答とまとめはこの端末から消えます。Vaultには何も書いていません。',
      '破棄する',
    )) {
      await g.discard();
    }
  }

  void _sendOther() {
    final text = other.text.trim();
    if (text.isNotEmpty) g.answer(GuidedAnswer.free(text));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !g.saving,
    child: Scaffold(
      appBar: AppBar(
        // 閉じるボタンは、ほかのダイアログと同じく右上に置く（保存の途中は PopScope が閉じさせない）。
        automaticallyImplyLeading: false,
        title: const Text('質問に答えてまとめる'),
        actions: [
          IconButton(
            key: const Key('guided-settings'),
            tooltip: 'AIの設定',
            icon: const Icon(Icons.tune),
            onPressed: g.ready ? () => showGuidedSettings(context, g) : null,
          ),
          // 保存の途中は閉じられない（PopScope）ので、押せない見た目にする。
          IconButton(
            key: const Key('guided-page-close'),
            tooltip: '閉じる',
            icon: const Icon(Icons.close),
            onPressed: g.saving ? null : () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: !g.ready
            ? const Center(child: CircularProgressIndicator())
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                    children: [
                      if (g.persistFailed)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: NoticeBox(
                            '途中の状態をこの端末に残せませんでした。閉じると続きから再開できない場合があります。',
                          ),
                        ),
                      ...switch (g.phase) {
                        GuidedPhase.setup => _setup(context),
                        GuidedPhase.question => _question(context),
                        GuidedPhase.summary => _summary(context),
                      },
                    ],
                  ),
                ),
              ),
      ),
    ),
  );

  Widget _projectField({
    required Key key,
    required String? value,
    required ValueChanged<String?>? onChanged,
  }) => DropdownButtonFormField<String>(
    key: key,
    style: fieldTextStyle(context),
    initialValue: value ?? '',
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'プロジェクト（任意）'),
    items: [
      const DropdownMenuItem(value: '', child: Text('指定しない')),
      // 統合済みのプロジェクトは選ばせない（統合先を選ぶ）。
      for (final p in _projects.values.where((p) => !p.merged || p.id == value))
        DropdownMenuItem(
          value: p.id,
          child: Text(p.title, overflow: TextOverflow.ellipsis),
        ),
      if (value != null && !_projects.containsKey(value))
        DropdownMenuItem(value: value, child: Text('見つからないプロジェクト（$value）')),
    ],
    onChanged: onChanged == null
        ? null
        : (v) => onChanged(v == null || v.isEmpty ? null : v),
  );

  List<Widget> _setup(BuildContext context) {
    final theme = Theme.of(context);
    final st = g.state!, usage = g.usage!, previous = g.resumable;
    final material = includeContext ? _materialOf(project) : null;
    final sendsMaterial = material != null && material.text.isNotEmpty;
    final locked = previous?.operationId != null || g.otherVaultLocked;
    final secretProblem = g.secretPolicy.problem;
    return [
      if (secretProblem != null) ...[
        NoticeBox(
          secretProblem,
          error: true,
          key: const Key('guided-secret-problem'),
        ),
        const SizedBox(height: 12),
      ],
      if (!g.hasKey) ...[
        if (g.keyProblem != null)
          NoticeBox(
            g.keyProblem!,
            error: true,
            key: const Key('guided-key-problem'),
          )
        else
          const NoticeBox(
            'Claudeに問いとまとめを作ってもらうには、AnthropicのAPIキーが必要です。「AIの設定」から登録してください。',
            key: Key('guided-no-key'),
          ),
        Wrap(
          spacing: 8,
          children: [
            if (g.keyProblem != null)
              TextButton.icon(
                key: const Key('guided-key-retry'),
                onPressed: g.reloadKey,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('もう一度読み出す'),
              ),
            TextButton.icon(
              key: const Key('guided-open-settings'),
              onPressed: () => showGuidedSettings(context, g),
              icon: const Icon(Icons.key, size: 18),
              label: const Text('AIの設定を開く'),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
      if (previous != null) ...[
        Card(
          key: const Key('guided-resume'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('前回の問答があります', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  '${previous.purpose.label}・${previous.steps.length}問回答・${timeLabel(previous.updatedAt)}',
                  style: _small,
                ),
                if (previous.seed.isNotEmpty)
                  Text(
                    'きっかけ: ${previous.seed}',
                    style: _small,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonal(
                      key: const Key('guided-resume-continue'),
                      onPressed: g.busy ? null : g.resume,
                      child: const Text('続ける'),
                    ),
                    if (!locked)
                      TextButton(
                        key: const Key('guided-resume-drop'),
                        onPressed: () async {
                          if (await _confirm(
                            '前回の問答を破棄しますか？',
                            '回答とまとめはこの端末から消えます。Vaultには何も書いていません。',
                            '破棄する',
                          )) {
                            await g.dropStored();
                          }
                        },
                        child: const Text('破棄する'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
      if (g.otherVaultLocked) ...[
        const NoticeBox(
          '別のVaultで始めた問答に、保存結果を確かめていないものがあります。そのVaultに保存済みの可能性があります。そのVaultを開いてからこの画面を開くと、同じ操作を確かめられます。',
          key: Key('guided-other-locked'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('guided-other-drop'),
            onPressed: () async {
              if (await _confirm(
                '確かめずに破棄しますか？',
                '別のVaultの問答を、この端末から消します。保存されたかは、そのVaultを開くと保存と反映で確かめられます。同じ内容を保存し直さないでください。',
                '破棄する',
              )) {
                await g.dropStored();
              }
            },
            child: const Text('確かめずに破棄する'),
          ),
        ),
        const SizedBox(height: 16),
      ] else if (g.otherVault) ...[
        const NoticeBox('別のVaultで始めた問答が残っています。新しく始めると、その問答は破棄されます。'),
        const SizedBox(height: 16),
      ],
      Text('何をしますか', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      SegmentedButton<GuidedPurpose>(
        key: const Key('guided-purpose'),
        segments: [
          for (final p in GuidedPurpose.values)
            ButtonSegment(value: p, label: Text(p.label)),
        ],
        selected: {purpose},
        showSelectedIcon: false,
        onSelectionChanged: (v) => setState(() => purpose = v.first),
      ),
      const SizedBox(height: 6),
      Text(
        '${purpose.description}。AIが1問ずつ選択肢を出すので、選んで答えます。最後にまとめを確かめてから保存します。',
        style: _small,
      ),
      const SizedBox(height: 16),
      _projectField(
        key: const Key('guided-project'),
        value: project,
        onChanged: (v) => setState(() => project = v),
      ),
      const SizedBox(height: 16),
      TextField(
        key: const Key('guided-seed'),
        controller: seed,
        maxLength: guidedSeedChars,
        minLines: 2,
        maxLines: 4,
        decoration: InputDecoration(
          labelText: 'きっかけ（任意）',
          hintText: switch (purpose) {
            GuidedPurpose.record => '例: 今日の作業でつまずいたこと',
            GuidedPurpose.sparring => '例: 次にどちらを進めるか迷っている',
            GuidedPurpose.idea => '例: 移動中に思いついたこと',
          },
          alignLabelWithHint: true,
        ),
      ),
      SwitchListTile(
        key: const Key('guided-include-context'),
        contentPadding: EdgeInsets.zero,
        value: includeContext,
        onChanged: (v) => setState(() => includeContext = v),
        title: const Text('Vaultの資料もAIへ送る'),
        subtitle: Text(
          project == null
              ? '共通方針・進行中のプロジェクトの名前・最近のメモ5件（最大$guidedContextChars字）。選択肢が具体的になります。'
              : 'このプロジェクトの名前・方針・現在地・次の一手・未解決・提案・関連するメモ（読み取り前・読み取り失敗を含む）（最大$guidedContextChars字）。選択肢が具体的になります。',
          style: _small,
        ),
      ),
      if (material?.reason != null)
        NoticeBox(
          '資料を作れないため、資料なしで始めます（${material!.reason}）',
          key: const Key('guided-context-problem'),
        ),
      if (material != null && material.text.isNotEmpty)
        ExpansionTile(
          key: const Key('guided-context-preview'),
          // 送る全文は、オンにした時点で開いて見せる（閉じることはできる）。
          initiallyExpanded: true,
          tilePadding: EdgeInsets.zero,
          title: Text(
            '送る資料を見る（${material.text.length}字）',
            style: const TextStyle(fontSize: 13),
          ),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: SelectableText(
                  material.text,
                  style: const TextStyle(fontSize: 12.5, height: 1.55),
                ),
              ),
            ),
          ],
        ),
      const SizedBox(height: 12),
      Text(
        sendsMaterial
            ? '送り先はAnthropicのClaude APIです。目的・きっかけ・回答と上の資料を、問いとまとめを作るためだけに送ります（プロジェクトを選んだときは、その名前とIDも送ります）。Vaultへは、最後に「メモとして保存」を押したときだけ書きます。'
            : '送り先はAnthropicのClaude APIです。目的・きっかけ・回答だけを、問いとまとめを作るためだけに送ります。プロジェクトの名前などVaultの内容は送りません。Vaultへは、最後に「メモとして保存」を押したときだけ書きます。',
        key: const Key('guided-send-note'),
        style: _small,
      ),
      Text(
        '今月の呼び出し: ${usage.calls} / ${st.monthlyLimit}回（1回の問答で、問いの数＋1回ほど）・モデル: ${guidedModelChoice(st.model).label}・Effort: 問い${st.questionEffort}／まとめ${st.summaryEffort}（AIの設定で変えられます）',
        key: const Key('guided-usage'),
        style: _small,
      ),
      if (g.error != null) ...[
        const SizedBox(height: 12),
        NoticeBox(g.error!, error: true),
      ],
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          key: const Key('guided-start'),
          onPressed: !g.hasKey || g.busy || locked || secretProblem != null
              ? null
              : _start,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('始める'),
        ),
      ),
    ];
  }

  Widget _working(String text) => Row(
    children: [
      const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(text, key: const Key('guided-working'))),
      TextButton(
        key: const Key('guided-cancel'),
        onPressed: g.cancel,
        child: const Text('中止'),
      ),
    ],
  );

  List<Widget> _question(BuildContext context) {
    final theme = Theme.of(context);
    final s = g.active!, q = s.current;
    return [
      Text(
        '${s.purpose.label}・${s.steps.length + 1}問目（最大$guidedMaxQuestions問）',
        style: _small,
      ),
      const SizedBox(height: 6),
      LinearProgressIndicator(value: s.steps.length / guidedMaxQuestions),
      if (s.steps.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (i, step) in s.steps.indexed)
              Tooltip(
                message: '${step.question.text}\n→ ${step.answer.display}',
                child: ActionChip(
                  key: Key('guided-step-$i'),
                  label: Text(
                    '${i + 1}. ${clip(step.answer.display, 24)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: g.busy
                      ? null
                      : () async {
                          if (await _confirm(
                            '${i + 1}問目から答え直しますか？',
                            '「${step.question.text}」に答え直します。${i + 1}問目以降の回答は消えます。',
                            '答え直す',
                          )) {
                            g.backTo(i);
                          }
                        },
                ),
              ),
          ],
        ),
      ],
      if (s.understanding.isNotEmpty) ...[
        const SizedBox(height: 12),
        Card(
          key: const Key('guided-understanding'),
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AIの理解（推測を含む）', style: theme.textTheme.labelSmall),
                const SizedBox(height: 4),
                Text(s.understanding, style: _small),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 20),
      if (g.busy)
        _working('Claudeが次の問いを考えています…')
      else if (q == null) ...[
        if (g.error != null) NoticeBox(g.error!, error: true),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const Key('guided-retry'),
              onPressed: g.ask,
              child: const Text('もう一度'),
            ),
            if (s.steps.isNotEmpty)
              OutlinedButton(
                key: const Key('guided-wrap'),
                onPressed: g.summarize,
                child: const Text('ここでまとめる'),
              ),
            TextButton(
              key: const Key('guided-discard'),
              onPressed: _discard,
              child: const Text('やめる'),
            ),
          ],
        ),
      ] else ...[
        if (g.error != null) ...[
          NoticeBox(g.error!, error: true),
          const SizedBox(height: 12),
        ],
        Text(
          q.text,
          key: const Key('guided-question'),
          style: theme.textTheme.titleLarge,
        ),
        if (q.multiSelect)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('当てはまるものをすべて選んで「次へ」を押してください。', style: _small),
          ),
        if (q.suggestWrapUp && s.steps.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: NoticeBox(
              '必要な答えが揃ってきました。「ここでまとめる」でまとめに進めます。',
              key: Key('guided-suggest'),
            ),
          ),
        const SizedBox(height: 12),
        for (final (i, o) in q.options.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              shape: RoundedRectangleBorder(
                side: BorderSide(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: q.multiSelect
                  ? CheckboxListTile(
                      key: Key('guided-option-$i'),
                      visualDensity: formTileDensity,
                      horizontalTitleGap: formTileGap,
                      value: picked.contains(o.label),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) => setState(
                        () => v == true
                            ? picked.add(o.label)
                            : picked.remove(o.label),
                      ),
                      title: Text(o.label),
                      subtitle: o.hint.isEmpty
                          ? null
                          : Text(o.hint, style: _small),
                    )
                  : ListTile(
                      key: Key('guided-option-$i'),
                      title: Text(o.label),
                      subtitle: o.hint.isEmpty
                          ? null
                          : Text(o.hint, style: _small),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => g.answer(GuidedAnswer.selected([o.label])),
                    ),
            ),
          ),
        if (q.multiSelect)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('guided-next'),
              onPressed: picked.isEmpty
                  ? null
                  : () => g.answer(
                      GuidedAnswer.selected([
                        for (final o in q.options)
                          if (picked.contains(o.label)) o.label,
                      ]),
                    ),
              child: const Text('次へ'),
            ),
          ),
        const SizedBox(height: 12),
        if (otherOpen) ...[
          TextField(
            key: const Key('guided-other-text'),
            controller: other,
            autofocus: true,
            maxLength: guidedFreeTextChars,
            decoration: const InputDecoration(labelText: '自分の言葉で（一言）'),
            onSubmitted: (_) => _sendOther(),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('guided-other-send'),
                onPressed: _sendOther,
                child: const Text('この答えで進む'),
              ),
              TextButton(
                onPressed: () => setState(() => otherOpen = false),
                child: const Text('選択肢に戻る'),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!otherOpen)
              OutlinedButton.icon(
                key: const Key('guided-other'),
                onPressed: () => setState(() => otherOpen = true),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('その他（一言）'),
              ),
            OutlinedButton(
              key: const Key('guided-unknown'),
              onPressed: () => g.answer(const GuidedAnswer.unknown()),
              child: const Text('わからない'),
            ),
            OutlinedButton(
              key: const Key('guided-back'),
              onPressed: s.steps.isEmpty
                  ? null
                  : () => g.backTo(s.steps.length - 1),
              child: const Text('戻る'),
            ),
            OutlinedButton(
              key: const Key('guided-wrap'),
              onPressed: s.steps.isEmpty ? null : g.summarize,
              child: const Text('ここでまとめる'),
            ),
          ],
        ),
      ],
    ];
  }

  /// 保存の前に、まとめと問答の記録に秘密情報らしい文字列がないかを知らせる。
  Future<void> _save() async {
    final s = g.active, summary = s?.summary;
    if (s == null || summary == null) return;
    final body = guidedBody(summary, s);
    final checked = await checkSecretsBeforeSave(
      context,
      body,
      secrets: g.secretPolicy,
    );
    if (checked == null || !mounted) return;
    await g.save(redact: checked != body);
  }

  List<Widget> _summary(BuildContext context) {
    final s = g.active!, r = g.result;
    if (r?.saved == true) {
      return [
        const NoticeBox(
          'この端末に保存しました。同期後にMac miniが受け取り、AIが読み取ります。保存と反映で確かめられます。',
          key: Key('guided-saved'),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: const Key('guided-close'),
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
            OutlinedButton(
              key: const Key('guided-new'),
              onPressed: g.discard,
              child: const Text('新しく始める'),
            ),
          ],
        ),
      ];
    }
    if (g.busy) return [_working('Claudeがまとめを書いています…')];
    final text = s.summary;
    if (text == null) {
      return [
        if (g.error != null) NoticeBox(g.error!, error: true),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: const Key('guided-retry-summary'),
              onPressed: g.summarize,
              child: const Text('もう一度'),
            ),
            OutlinedButton(
              key: const Key('guided-back-questions'),
              onPressed: g.backToQuestions,
              child: const Text('問いに戻る'),
            ),
          ],
        ),
      ];
    }
    final problem = g.bodyProblem, readOnly = g.locked || g.saving;
    return [
      const Text('まとめを確かめて、必要なら直してください。保存するまでVaultには書きません。', style: _small),
      const SizedBox(height: 12),
      TextField(
        key: const Key('guided-summary'),
        controller: summary,
        readOnly: readOnly,
        minLines: 6,
        maxLines: 18,
        inputFormatters: [LengthLimitingTextInputFormatter(guidedBodyChars)],
        onChanged: g.editSummary,
        decoration: InputDecoration(
          labelText: 'まとめ（${s.purpose.label}）',
          alignLabelWithHint: true,
        ),
      ),
      ExpansionTile(
        key: const Key('guided-log'),
        tilePadding: EdgeInsets.zero,
        title: const Text(
          '問答の記録（このままメモの最後に付きます）',
          style: TextStyle(fontSize: 13),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              guidedLog(s),
              style: noteStyle(context),
            ),
          ),
        ],
      ),
      _projectField(
        key: ValueKey('guided-summary-project-$readOnly'),
        value: s.project,
        onChanged: readOnly ? null : g.setProject,
      ),
      const SizedBox(height: 8),
      Text(
        '種類: メモ・本文 ${guidedBody(text, s).length} / $guidedBodyChars字',
        style: _small,
      ),
      if (problem != null) NoticeBox(problem, error: true),
      if (g.error != null) ...[
        const SizedBox(height: 8),
        NoticeBox(g.error!, error: true),
      ],
      if (r != null && !r.saved) ...[
        const SizedBox(height: 8),
        const NoticeBox(
          '保存確認待ちです。同じ内容を送り直さず、「同じ操作を確認」を押してください。',
          key: Key('guided-uncertain'),
        ),
      ],
      if (g.locked)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(
            '操作ID: ${s.operationId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!g.locked)
            FilledButton.icon(
              key: const Key('guided-save'),
              onPressed: g.saving || problem != null ? null : _save,
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('メモとして保存'),
            ),
          if (g.locked)
            FilledButton(
              key: const Key('guided-confirm'),
              onPressed: g.saving ? null : g.confirmSame,
              child: const Text('同じ操作を確認'),
            ),
          if (!g.locked)
            OutlinedButton(
              key: const Key('guided-back-questions'),
              onPressed: g.saving
                  ? null
                  : () async {
                      if (await _confirm(
                        '問いに戻りますか？',
                        'このまとめは消えます。問いに答え直してから、もう一度まとめます。',
                        '問いに戻る',
                      )) {
                        g.backToQuestions();
                      }
                    },
              child: const Text('問いに戻る'),
            ),
          // 保存結果が不明なものは、同じ操作を確かめるまで捨てられない（新しい操作で送り直さないため）。
          if (!g.locked || g.confirmedOnce)
            TextButton(
              key: const Key('guided-discard'),
              onPressed: g.saving ? null : _discard,
              child: const Text('破棄する'),
            ),
          if (g.saving)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    ];
  }
}

/// APIキーと月の上限の設定。
class GuidedSettingsDialog extends StatefulWidget {
  const GuidedSettingsDialog({super.key, required this.controller});
  final GuidedController controller;
  @override
  State<GuidedSettingsDialog> createState() => _GuidedSettingsDialogState();
}

class _GuidedSettingsDialogState extends State<GuidedSettingsDialog> {
  final key = TextEditingController();
  late final limit = TextEditingController(
    text:
        '${widget.controller.state?.monthlyLimit ?? GuidedState.defaultLimit}',
  );
  String? message;
  bool failed = false, busy = false;

  @override
  void dispose() {
    key.dispose();
    limit.dispose();
    super.dispose();
  }

  /// [clearKey]は、キーの保存・削除のとき。ほかの設定を保存しても、入力中のキーは消さない。
  Future<void> _run(
    Future<String?> Function() action,
    String done, {
    bool clearKey = false,
  }) async {
    setState(() => busy = true);
    final problem = await action();
    if (!mounted) return;
    setState(() {
      busy = false;
      failed = problem != null;
      message = problem ?? done;
      if (problem == null && clearKey) key.clear();
    });
  }

  Future<void> _saveLimit() async {
    final n = int.tryParse(limit.text);
    if (n == null || n < 0 || n > GuidedState.maxLimit) {
      setState(() {
        failed = true;
        message = '上限は0〜${GuidedState.maxLimit}回で指定してください。';
      });
      return;
    }
    await _run(() async {
      await widget.controller.setLimit(n);
      return null;
    }, '月の上限を$n回にしました。');
  }

  Future<void> _setModel(String id) async {
    final label = guidedModelChoice(id).label;
    await _run(
      () async => await widget.controller.setModel(id)
          ? null
          : '端末に設定を残せませんでした。この画面を閉じるまでは$labelを使います。',
      'モデルを$labelにしました。',
    );
  }

  Widget _effortField({
    required String name,
    required String label,
    required String value,
    required bool summary,
  }) => DropdownButtonFormField<String>(
    key: Key(name),
    style: fieldTextStyle(context),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final e in guidedEfforts)
        DropdownMenuItem(
          value: e.id,
          child: Text(e.label, key: Key('$name-${e.id}')),
        ),
    ],
    onChanged: busy || widget.controller.state == null
        ? null
        : (v) {
            if (v == null) return;
            _run(
              () async =>
                  await widget.controller.setEffort(v, summary: summary)
                  ? null
                  : '端末に設定を残せませんでした。この画面を閉じるまでは$vを使います。',
              '${summary ? 'まとめ' : '問い'}のEffortを$vにしました。',
            );
          },
  );

  @override
  Widget build(BuildContext context) {
    final g = widget.controller, usage = g.usage;
    final model = guidedModelChoice(g.state?.model);
    return HubAlertDialog(
      title: const Text('AIの設定'),
      onClose: busy ? null : () => Navigator.pop(context),
      content: SizedBox(
        width: 520,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '「質問に答えてまとめる」は、あなたのAPIキーでAnthropicのClaude APIを端末から直接呼び出します。料金はAnthropicの契約に応じてかかります。',
                style: _small,
              ),
              const SizedBox(height: 12),
              Text(
                g.hasKey
                    ? 'APIキー: 登録済み'
                    : g.keyProblem != null
                    ? 'APIキー: 読み出せません'
                    : 'APIキー: 未登録',
                key: const Key('guided-key-state'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('guided-key'),
                controller: key,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: g.hasKey ? '新しいAPIキー' : 'APIキー',
                  hintText: 'sk-ant-…',
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'キーはこの端末の安全な保管場所（Macはキーチェーン、AndroidはKeystoreの鍵で暗号化）に置き、Vault・同期フォルダー・ログには書きません。',
                style: _small,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const Key('guided-key-save'),
                    onPressed: busy
                        ? null
                        : () => _run(
                            () => g.setKey(key.text),
                            'APIキーを保存しました。',
                            clearKey: true,
                          ),
                    child: const Text('キーを保存'),
                  ),
                  if (g.hasKey)
                    TextButton(
                      key: const Key('guided-key-delete'),
                      onPressed: busy
                          ? null
                          : () => _run(
                              g.deleteKey,
                              'APIキーを削除しました。',
                              clearKey: true,
                            ),
                      child: const Text('キーを削除'),
                    ),
                ],
              ),
              const Divider(height: 32),
              Text('モデル', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const Key('guided-model'),
                showSelectedIcon: false,
                segments: [
                  for (final m in guidedModels)
                    ButtonSegment(
                      value: m.id,
                      label: Text(m.label, key: Key('guided-model-${m.id}')),
                    ),
                ],
                selected: {model.id},
                onSelectionChanged: busy || g.state == null
                    ? null
                    : (picked) => _setModel(picked.first),
              ),
              const SizedBox(height: 6),
              Text(
                model.fallback
                    ? '${model.note}安全上の理由でこのモデルが応答を控えたときは、Anthropic側で別のモデルが代わりに答えることがあります。実際に応答したモデルはメモに記録します。'
                    : '${model.note}実際に応答したモデルはメモに記録します。',
                key: const Key('guided-model-note'),
                style: _small,
              ),
              const SizedBox(height: 16),
              Text('Effort（考える深さ）', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              _effortField(
                name: 'guided-question-effort',
                label: '問いを作るとき',
                value: g.state?.questionEffort ?? guidedQuestionEffort,
                summary: false,
              ),
              const SizedBox(height: 12),
              _effortField(
                name: 'guided-summary-effort',
                label: 'まとめを書くとき',
                value: g.state?.summaryEffort ?? guidedSummaryEffort,
                summary: true,
              ),
              const SizedBox(height: 6),
              const Text(
                '深くするほど、答えが返るまでの時間と費用（考える分を含む出力トークン）が増えます。既定は問いがlow、まとめがmediumです。',
                key: Key('guided-effort-note'),
                style: _small,
              ),
              const Divider(height: 32),
              TextField(
                key: const Key('guided-limit'),
                controller: limit,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '月の呼び出し上限（回）',
                  helperText: '上限に達した月は、新しい問いやまとめを作りません。0にすると呼び出しません。',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('guided-limit-save'),
                  onPressed: busy ? null : _saveLimit,
                  child: const Text('上限を保存'),
                ),
              ),
              if (usage != null) ...[
                Text(
                  '今月（${usage.month}）: ${usage.calls}回・入力${usage.input}トークン・出力${usage.output}トークン',
                  style: _small,
                ),
                for (final line in usageLines(usage)) Text(line, style: _small),
              ],
              if (message != null) ...[
                const SizedBox(height: 12),
                NoticeBox(message!, error: failed),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('guided-settings-close'),
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}

/// 今月の利用の内訳（モデル別・種類別）と、料金表による概算額の行。
List<String> usageLines(GuidedUsage usage) {
  final lines = <String>[
    for (final e in usage.models.entries)
      '${e.key}: 入力${e.value.input}・キャッシュ書込${e.value.cacheWrite}・キャッシュ読取${e.value.cacheRead}・出力${e.value.output}トークン',
  ];
  final cost = estimateCost(usage.models);
  if (usage.models.isNotEmpty) {
    lines.add(
      '概算: 約\$${cost.usd.toStringAsFixed(2)}（$claudePricesAsOf時点の料金表による目安。請求額とは異なることがあります）',
    );
  }
  if (cost.unknown.isNotEmpty) {
    lines.add('料金表にないモデル（${cost.unknown.join('、')}）の分は概算に含みません。');
  }
  if (usage.partial) {
    lines.add('内訳のない以前の記録の分は、概算に含みません。');
  }
  if (usage.uncertain > 0) {
    lines.add(
      '応答が途中で途切れ、使ったトークンを数え切れなかった呼び出しが${usage.uncertain}回あります（その分の費用が発生している可能性があります）。',
    );
  }
  return lines;
}
