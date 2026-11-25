import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../app/controller.dart';
import '../../core/happened.dart';
import '../../core/models.dart';
import '../../core/parser.dart' show clip;
import '../../core/related.dart';
import '../../core/repository.dart';
import '../../core/templates.dart';
import '../../storage/capture_service.dart';
import '../../storage/draft_store.dart';
import '../../storage/vault_access.dart' show PickedAttachment;
import '../hub/search_page.dart';
import '../labels.dart';
import '../parts.dart';
import '../record_view.dart';
import '../save_checks.dart';
import '../shortcuts.dart';
import '../template_view.dart';
import '../theme.dart';

Future<void> showCapture(
  BuildContext context,
  HubController c, {
  GitDraft? draft,
  InsightAnswerTarget? answer,
  HubRecord? continues,
}) async {
  if (c.composing) {
    return;
  }
  c.composing = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CaptureDialog(
        controller: c,
        draft: draft,
        answer: answer,
        continues: continues,
      ),
    );
  } finally {
    c.composing = false;
  }
}

class CaptureDialog extends StatefulWidget {
  const CaptureDialog({
    super.key,
    required this.controller,
    this.draft,
    this.answer,
    this.continues,
  });
  final HubController controller;

  /// 続きとして書く前のメモ（訂正を除いた元の入力の記録）。前のメモで指定したプロジェクトを初期値にする。
  final HubRecord? continues;

  /// 作業記録の下書きから入力を作る場合の下書き。本文とプロジェクトを初期値にする。
  final GitDraft? draft;

  /// 今週の気づきの問いに答える場合の対象。答えはふつうのメモとして保存し、どの問いへの答えかをmetaで添える。
  final InsightAnswerTarget? answer;
  @override
  State<CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<CaptureDialog> {
  final text = TextEditingController();
  String operation = const Uuid().v4();
  String kind = 'memo';
  String? project, error;

  /// 本人が選んだ出来事の日付（YYYY-MM-DD）。今日のことならnull。
  String? happenedOn;

  /// 資料として保存するか（AIの分類に関係なく資料棚に載せる）と、本人が付ける資料の名前。
  bool reference = false;
  final referenceTitle = TextEditingController();

  /// メモに添えるファイル（端末で選んだもの。名前は本体の規則で整えたもの）。ファイルを添えたメモは資料として保存する。
  PickedAttachment? attachment;

  /// 戻した書きかけで選んでいたファイルの名前（ファイルは戻せないため、選び直してもらう）。
  String? _lostAttachment;

  /// ファイルを添えられるか。下書きから作る入力と問いへの答えには出さず、端末と本体の両方が対応しているときだけ。
  bool get _canAttach =>
      _canReference &&
      widget.draft == null &&
      widget.controller.attachmentsAvailable;

  ({int maxBytes, int nameMaxBytes}) get _attachmentLimits =>
      widget.controller.repository?.intakeFeatures.attachmentLimits ??
      (maxBytes: 0, nameMaxBytes: fileNameMaxBytes);

  Future<void> _pickAttachment() async {
    try {
      final picked = await widget.controller.pickAttachment();
      if (picked == null || !mounted) return;
      final max = _attachmentLimits.maxBytes;
      final problem = picked.bytes < 1
          ? '空のファイルは添えられません。'
          : picked.bytes > max
          ? 'ファイルが大きすぎます（上限${fileLimitLabel(max)}を超えています）。小さくしてから選び直してください。'
          : (widget.controller.repository?.secretInReferenceTitle(
                  picked.name,
                ) ??
                false)
          ? fileNameSecretMessage
          : null;
      setState(() {
        error = problem;
        if (problem != null) return;
        attachment = picked;
        _lostAttachment = null;
        // ファイルを添えたメモは、資料として保存するメモにする。
        reference = true;
        kind = 'memo';
      });
      _schedulePersist();
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    }
  }

  Widget _attachmentChooser(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (attachment case final file?)
          InputChip(
            key: const Key('capture-attachment'),
            avatar: const Icon(Icons.attach_file, size: 18),
            label: Text(
              '${file.name}（${fileSizeLabel(file.bytes)}）',
              overflow: TextOverflow.ellipsis,
            ),
            deleteButtonTooltipMessage: 'ファイルを外す',
            onDeleted: locked
                ? null
                : () {
                    setState(() => attachment = null);
                    _schedulePersist();
                  },
          )
        else
          OutlinedButton.icon(
            key: const Key('capture-attach'),
            style: compactOutlinedStyle(context),
            icon: const Icon(Icons.attach_file, size: 18),
            label: const Text('ファイルを添える（PDF・画像など）'),
            onPressed: locked || busy ? null : _pickAttachment,
          ),
        if (attachment != null)
          fieldNote(
            context,
            'ファイルはMac miniのVault（05_files）に置き、資料棚から開けます。中身はAIへ渡さず、AIが読むのはメモの本文だけです。何のファイルかを本文に書いておくと探しやすくなります（空ならファイル名を本文にします）。',
            key: const Key('capture-attachment-note'),
          )
        else if (_lostAttachment case final name?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: NoticeBox(
              '書きかけで選んでいたファイル（$name）は戻せません。添える場合は選び直してください。',
              key: const Key('capture-attachment-lost'),
            ),
          ),
      ],
    ),
  );

  /// 資料として保存できるか。問いへの答えは資料にせず、対応前の本体にも出さない。
  bool get _canReference =>
      widget.answer == null &&
      (widget.controller.repository?.intakeFeatures.references ?? false);

  /// 資料の名前の上限（本体が示す値）。
  int get _referenceTitleMax =>
      widget.controller.repository?.intakeFeatures.referenceTitleMax ??
      referenceTitleChars;

  /// 送る資料の名前（前後の空白を除き、空ならnull）。
  String? get _referenceTitleValue {
    final v = referenceTitle.text.trim();
    return v.isEmpty ? null : v;
  }

  Widget _referenceChooser(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CheckboxListTile(
        key: const Key('capture-reference'),
        contentPadding: EdgeInsets.zero,
        visualDensity: formTileDensity,
        horizontalTitleGap: formTileGap,
        controlAffinity: ListTileControlAffinity.leading,
        value: reference,
        // ファイルを添えたメモは、必ず資料として保存する。
        onChanged: locked || attachment != null
            ? null
            : (v) {
                setState(() => reference = v ?? false);
                _schedulePersist();
              },
        title: Text('資料として保存', style: formTileTitle(context)),
        subtitle: Text(
          attachment != null
              ? 'ファイルを添えたメモは資料として保存します。'
              : 'AIの分類に関係なく、資料棚に載せます。アイデアや提案としては扱いません。',
        ),
      ),
      if (_canAttach) _attachmentChooser(context),
      if (reference) ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('capture-reference-title'),
          controller: referenceTitle,
          enabled: !locked,
          // 上限は本体と同じくUTF-16の長さで数える（絵文字は2と数える）。超えた分は保存の前に知らせる。
          buildCounter:
              (
                context, {
                required currentLength,
                required isFocused,
                maxLength,
              }) => Text(
                '${referenceTitle.text.trim().length}/$_referenceTitleMax',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          decoration: const InputDecoration(
            labelText: '資料の名前（任意）',
            helperText: '空のままなら、AIが読み取った要約を資料の名前にします。後から変えられます。',
            helperMaxLines: 3,
          ),
        ),
      ],
    ],
  );

  /// 出来事の日付を選べるか。下書き・問いへの答えは今日の記録なので出さず、対応前の本体にも出さない。
  bool get _canBackdate =>
      widget.draft == null &&
      widget.answer == null &&
      (widget.controller.repository?.intakeFeatures.happenedOn ?? false);

  /// 本体の設定でさかのぼれる日数。
  int get _maxBackdateDays =>
      widget.controller.repository?.intakeFeatures.maxBackdateDays ??
      defaultMaxBackdateDays;

  Future<void> _pickHappenedOn() async {
    // 暦日で数える（端末の夏時間をまたいでも1日ずれないよう、時刻の引き算にしない）。
    final today = hubToday(),
        last = DateTime.parse(addScheduleDays(today, -1)),
        first = DateTime.parse(addScheduleDays(today, -_maxBackdateDays));
    final current = happenedOn != null ? DateTime.parse(happenedOn!) : last;
    final picked = await showDatePicker(
      context: context,
      initialDate: current.isBefore(first) || current.isAfter(last)
          ? last
          : current,
      firstDate: first,
      lastDate: last,
      helpText: 'いつのことか',
    );
    if (picked == null || !mounted) return;
    setState(() => happenedOn = scheduleDate(picked));
    _schedulePersist();
  }

  Widget _happenedChooser(BuildContext context) {
    final today = hubToday(),
        yesterday = addScheduleDays(today, -1),
        dayBefore = addScheduleDays(today, -2);
    final custom =
        happenedOn != null &&
        happenedOn != yesterday &&
        happenedOn != dayBefore;
    void choose(String? value) {
      setState(() => happenedOn = value);
      _schedulePersist();
    }

    return Column(
      key: const Key('memo-happened'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        fieldLabel(context, 'いつのこと'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, value) in [
              ('今日', null),
              ('昨日', yesterday),
              if (_maxBackdateDays >= 2) ('おととい', dayBefore),
            ])
              ChoiceChip(
                key: Key('memo-happened-${value ?? 'today'}'),
                label: Text(label),
                selected: happenedOn == value,
                onSelected: locked ? null : (_) => choose(value),
              ),
            ChoiceChip(
              key: const Key('memo-happened-pick'),
              label: Text(custom ? happenedOn! : '日付を選ぶ…'),
              selected: custom,
              onSelected: locked ? null : (_) => _pickHappenedOn(),
            ),
          ],
        ),
        if (happenedOn != null)
          fieldNote(
            context,
            'この日の出来事として記録します。経緯や現在地はこの日の順に並び、本文の「明日」「来週」もこの日を基準に読まれます。',
            top: 8,
          ),
      ],
    );
  }

  CaptureResult? result;
  bool busy = false, locked = false;

  // ---- 書きかけの保持（端末内のみ） ----
  String? _draftKey;
  bool _ready = false, _keepDrafts = true, _finished = false;

  /// 保存結果が不明な書きかけで、「同じ操作を確認」を一度でも行ったか。行うまでは書きかけを閉じられない。
  bool _confirmedOnce = false;

  /// 戻した書きかけの日時。戻していなければnull。
  DateTime? _restoredAt;
  int _formGeneration = 0;
  Timer? _debounce;
  AppLifecycleListener? _lifecycle;

  DraftStore get _drafts => widget.controller.drafts;

  // ---- 書いている途中の関係ありそうな記録（端末内の記録だけで探す） ----
  bool _showRelated = true;
  List<RelatedRecord> _related = const [];
  Timer? _relatedTimer;

  /// 入力が止まってから探す。比べるのは端末に読み込んだ記録だけで、ネットワークにもAIにも送らない。
  void _scheduleRelated() {
    _relatedTimer?.cancel();
    _relatedTimer = Timer(const Duration(milliseconds: 600), _findRelated);
  }

  Future<void> _findRelated() async {
    if (!mounted) return;
    final repo = widget.controller.repository;
    if (!_showRelated || locked || widget.answer != null || repo == null) {
      if (_related.isNotEmpty) setState(() => _related = const []);
      return;
    }
    // 記録の特徴は読み込みごとに1回だけ作る（記録が多ければ別のisolateで作り、入力を止めない）。
    final RelatedIndex index;
    try {
      index = await relatedIndex(repo);
    } catch (_) {
      return; // 探せなくても入力は続ける。
    }
    // 待つ間に閉じた・読み直した・設定を止めたときは、古い結果を出さない。
    if (!mounted || widget.controller.repository != repo || !_showRelated) {
      return;
    }
    final next = relatedRecords(
      repo,
      text.text,
      index: index,
      project: project,
    );
    // 読み直しで点や本文が変わることがあるので、毎回置き換える。
    if (next.isNotEmpty || _related.isNotEmpty) {
      setState(() => _related = next);
    }
  }

  Future<void> _setShowRelated(bool value) async {
    setState(() {
      _showRelated = value;
      if (!value) _related = const [];
    });
    if (value) _findRelated();
    try {
      await _drafts.setRelatedEnabled(value);
    } catch (_) {
      // 設定を残せなくても入力は続ける。
    }
  }

  /// 関係ありそうな記録の一覧。開く・文脈かごに入れる・同じプロジェクトで保存するを選べる。
  Widget _relatedBox() {
    final repo = widget.controller.repository,
        scheme = Theme.of(context).colorScheme;
    if (repo == null) return const SizedBox.shrink();
    return Container(
      key: const Key('related-records'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(hubRadiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '前に書いた、関係ありそうな記録',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          fieldNote(
            context,
            '同じことを書いていないか、続きの話ではないかを確かめられます。この端末に読み込んだ記録だけを、文字の重なりで探しています。',
            top: 2,
          ),
          // 行ごとの「…で保存する」が次の行に付いて見えないよう、線で区切る。
          for (final (i, hit) in _related.indexed) ...[
            if (i > 0) const Divider(height: 17),
            _relatedRow(repo, hit),
          ],
        ],
      ),
    );
  }

  Widget _relatedRow(HubRepository repo, RelatedRecord hit) {
    final owner = hit.owner == null ? null : repo.projects[hit.owner];
    final inferred = hit.related.where((id) => id != hit.owner);
    // 本人が指定したプロジェクトは、まだ同期されていなくてもAI推定とは書かない。
    final where = owner != null
        ? owner.title
        : hit.owner != null
        ? hit.owner!
        : inferred.isNotEmpty
        ? '${repo.projects[inferred.first]?.title ?? inferred.first}（AI推定）'
        : 'プロジェクト未定';
    final canUseProject =
        owner != null &&
        !owner.merged &&
        project == null &&
        widget.draft == null &&
        !locked;
    return Padding(
      key: Key('related-${hit.root.id}'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hit.latest.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                Text(
                  '${timeLabel(hit.root.at).split(' ').first} · $where${hit.latest.kind == 'correction' ? ' · 訂正あり' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  searchSnippet(hit.latest.body, hit.shared.take(5).toList()),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (canUseProject)
                  TextButton(
                    key: Key('related-project-${hit.root.id}'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () {
                      setState(() {
                        project = owner.id;
                        _formGeneration++;
                      });
                      _schedulePersist();
                    },
                    child: Text('「${owner.title}」で保存する'),
                  ),
              ],
            ),
          ),
          IconButton(
            key: Key('related-open-${hit.root.id}'),
            tooltip: '開く（同じ内容なら、開いた画面から訂正を書けます）',
            icon: const Icon(Icons.open_in_new, size: 18),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    RecordView(controller: widget.controller, record: hit.root),
              ),
            ),
          ),
          BasketToggle(controller: widget.controller, record: hit.root),
        ],
      ),
    );
  }

  // ---- ひな形（端末内のみ） ----
  static const _editTemplates = '\u0000edit';
  List<MemoTemplate> _templates = defaultTemplates;
  final _textFocus = FocusNode();

  /// ひな形を本文へ差し込む。本文が空なら全体、空でなければ末尾へ足す。
  void _applyTemplate(MemoTemplate template) {
    final next = insertTemplate(text.text, template.body);
    if (next.text.length > 8000) {
      setState(() => error = 'ひな形を差し込むと8000文字を超えます。本文を短くしてください。');
      return;
    }
    final preset = template.projects[widget.controller.location?.identity];
    final projects = widget.controller.repository?.projects ?? const {};
    setState(() {
      error = null;
      text.value = TextEditingValue(
        text: next.text,
        selection: TextSelection.collapsed(offset: next.cursor),
      );
      // ひな形の既定のプロジェクトは、未指定のときだけ使う（本人が選んだものを変えない）。
      if (widget.draft == null &&
          project == null &&
          preset != null &&
          projects.containsKey(preset)) {
        // 統合済みのプロジェクトが既定なら、統合先にする。
        project = projects[preset]!.mergeTarget ?? preset;
        _formGeneration++;
      }
    });
    _textFocus.requestFocus();
    _schedulePersist();
  }

  /// ひな形の見出しを本文へ差し込むメニュー。
  Widget _templateMenu(BuildContext context) => PopupMenuButton<String>(
    key: const Key('template-menu'),
    tooltip: 'ひな形の見出しを本文へ差し込む',
    onSelected: (id) {
      if (id == _editTemplates) {
        _manageTemplates();
        return;
      }
      for (final t in _templates) {
        if (t.id == id) _applyTemplate(t);
      }
    },
    itemBuilder: (context) => [
      for (final t in _templates)
        PopupMenuItem(
          key: Key('template-item-${t.id}'),
          value: t.id,
          child: Text(t.name, overflow: TextOverflow.ellipsis),
        ),
      if (_templates.isNotEmpty) const PopupMenuDivider(),
      const PopupMenuItem(
        key: Key('template-manage'),
        value: _editTemplates,
        child: Text('ひな形を編集…'),
      ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.playlist_add,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            'ひな形',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    ),
  );

  /// メモの種類の切り替え。ふつうのメモと、AIの作業の報告（作業要約）の2つを横に並べ、どちらか1つを選ぶ。
  Widget _kindChooser(BuildContext context) => SegmentedButton<String>(
    key: const Key('memo-kind'),
    showSelectedIcon: false,
    style: SegmentedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    // 2つは同じ幅になる。狭い画面では印を外し、「AIの作業要約」が途中で折り返さないようにする。
    segments: [
      ButtonSegment(
        value: 'memo',
        icon: wideKindChooser(context)
            ? const Icon(Icons.edit_note, size: 18)
            : null,
        label: const Text('メモ', key: Key('memo-kind-memo')),
        tooltip: '思いつき・疑問・作業の記録など、ふつうはこちら',
      ),
      ButtonSegment(
        value: 'work-summary',
        icon: wideKindChooser(context)
            ? const Icon(Icons.smart_toy_outlined, size: 18)
            : null,
        label: const Text('AIの作業要約', key: Key('memo-kind-work-summary')),
        tooltip: 'AIが書いた作業の報告を貼るとき（未検証として扱う）',
      ),
    ],
    selected: {kind},
    // ファイルを添えたメモは、種類を変えない（ファイルはメモにだけ添える）。
    onSelectionChanged: locked || attachment != null
        ? null
        : (v) {
            setState(() => kind = v.first);
            _schedulePersist();
          },
  );

  Future<void> _manageTemplates() async {
    await showDialog<void>(
      context: context,
      builder: (_) => TemplateManagerDialog(controller: widget.controller),
    );
    final next = await widget.controller.templates.list();
    if (mounted) setState(() => _templates = next);
  }

  @override
  void initState() {
    super.initState();
    _initial();
    final answer = widget.answer;
    _draftKey = widget.controller.draftKey(
      gitDraftId: widget.draft?.id,
      answerTo: answer == null ? null : '${answer.runId}/${answer.itemKey}',
      continues: widget.continues?.sourceId,
    );
    text.addListener(_schedulePersist);
    text.addListener(_scheduleRelated);
    referenceTitle.addListener(_schedulePersist);
    _lifecycle = AppLifecycleListener(
      onInactive: _persistNow,
      onHide: _persistNow,
      onPause: _persistNow,
    );
    _restore();
  }

  void _initial() {
    final draft = widget.draft;
    text.text = draft?.text ?? '';
    kind = 'memo';
    // 続きは、プロジェクトを指定しなければ本体が前のメモのプロジェクトを引き継ぐ（統合を戻したときも前のメモと一緒に動く）。
    project = draft?.projectId;
    happenedOn = null;
    reference = false;
    referenceTitle.text = '';
    attachment = null;
    _lostAttachment = null;
  }

  /// 続きでプロジェクトを指定しないときに引き継ぐ、前のメモのプロジェクトの名前（統合済みなら統合先）。続きでない・指定がなければnull。
  String? get _inheritedTitle {
    final repo = widget.controller.repository,
        id = widget.continues?.metadata['project'];
    if (repo == null || id is! String) return null;
    return repo.projects[repo.resolveProject(id)]?.title;
  }

  /// 前回の書きかけを戻す。保存済みの操作の書きかけは消し、保存結果が不明なものは確認へ戻す。
  Future<void> _restore() async {
    final key = _draftKey;
    try {
      _templates = await widget.controller.templates.list();
      _showRelated = await _drafts.relatedEnabled();
      if (key == null) return;
      _keepDrafts = await _drafts.enabled();
      final stored = await _drafts.read(key);
      if (stored == null) return;
      final draft = widget.draft;
      final projects = widget.controller.repository?.projects ?? const {};
      if ((draft != null && stored.gitDraftHash != draft.hash) ||
          (draft != null && stored.project != draft.projectId)) {
        // 下書きが作り直された場合、古い本文は戻さない。
        await _drafts.remove(key);
        return;
      }
      final op = stored.operationId;
      final state = op == null
          ? null
          : await widget.controller.operationState(op);
      if (state == 'saved') {
        await _drafts.remove(key);
        return;
      }
      if (!mounted || text.text != (draft?.text ?? '')) return;
      text.text = stored.text;
      kind = widget.answer != null ? 'memo' : stored.kind;
      project = draft != null
          ? draft.projectId
          : stored.project != null && projects.containsKey(stored.project)
          ? stored.project
          : null;
      // 日付が古くなって選べなくなった書きかけは、今日のことに戻す。
      happenedOn =
          _canBackdate &&
              validHappenedOn(stored.happenedOn, maxDays: _maxBackdateDays)
          ? stored.happenedOn
          : null;
      reference = _canReference && stored.reference;
      referenceTitle.text = reference ? stored.referenceTitle ?? '' : '';
      // 保存の記録を作る前に止まった書きかけ（ファイルを写している途中など）も、ファイルは戻せないため選び直してもらう。
      _lostAttachment = reference && (op == null || state == null)
          ? stored.attachmentName
          : null;
      _restoredAt = stored.updatedAt;
      if (op != null && state != null) {
        // 保存を試みた操作は、同じ操作IDで確認だけを行う（再送しない）。
        operation = op;
        locked = true;
        result = CaptureResult(op, '', 'uncertain');
      }
    } catch (_) {
      // 書きかけを戻せなくても入力は始められる。
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }

  void _schedulePersist() {
    if (!_ready) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _persistNow);
  }

  void _persistNow() {
    _debounce?.cancel();
    _debounce = null;
    _persist();
  }

  /// 書きかけを残さない設定では、保存を試みた操作IDだけを残す（本文は[DraftStore]が外す）。
  Future<void> _persist() async {
    final key = _draftKey;
    if (key == null || !_ready || _finished) return;
    if (!_keepDrafts && !locked) return;
    await _drafts.write(
      key,
      WritingDraft(
        text: text.text.length > DraftStore.maxChars
            ? text.text.substring(0, DraftStore.maxChars)
            : text.text,
        kind: kind,
        project: project,
        gitDraftHash: widget.draft?.hash,
        operationId: locked ? operation : null,
        happenedOn: happenedOn,
        reference: reference,
        referenceTitle: reference ? _referenceTitleValue : null,
        attachmentName: reference ? attachment?.name ?? _lostAttachment : null,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _finish() async {
    _finished = true;
    _debounce?.cancel();
    final key = _draftKey;
    if (key != null) await _drafts.remove(key);
  }

  /// 戻した書きかけを捨て、最初の状態から書き直す。
  Future<void> _discard() async {
    final key = _draftKey;
    _debounce?.cancel();
    if (key != null) await _drafts.remove(key);
    if (!mounted) return;
    setState(() {
      _initial();
      operation = const Uuid().v4();
      locked = false;
      result = null;
      error = null;
      _restoredAt = null;
      _confirmedOnce = false;
      _formGeneration++;
    });
  }

  Future<void> _setKeepDrafts(bool value) async {
    setState(() => _keepDrafts = value);
    await _drafts.setEnabled(value);
    if (value) await _persist();
  }

  @override
  void dispose() {
    if (_debounce?.isActive == true) _persistNow();
    _debounce?.cancel();
    _lifecycle?.dispose();
    text.removeListener(_schedulePersist);
    text.removeListener(_scheduleRelated);
    referenceTitle.removeListener(_schedulePersist);
    _relatedTimer?.cancel();
    text.dispose();
    referenceTitle.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Future<void> _settled(CaptureResult r) async {
    if (r.saved) {
      await _finish();
    } else {
      await _persist();
    }
  }

  Future<void> submit() async {
    // 中身を書かなかったひな形の見出しは保存しない。文字数は取り除いた後の本文で数える。
    var body = stripEmptyTemplateHeadings(
      text.text,
      templateHeadings(_templates),
    );
    if (body.trim().isEmpty && text.text.trim().isNotEmpty) {
      setState(() => error = 'ひな形の見出しだけで、中身がありません。見出しの下に書いてから保存してください。');
      return;
    }
    final file = attachment;
    if (file != null && (!_canAttach || kind != 'memo' || !reference)) {
      setState(
        () => error = 'ファイルを添えられなくなりました（本体か保存先が変わりました）。ファイルを外してから保存してください。',
      );
      return;
    }
    // ファイルだけを添えたときは、ファイル名を本文にする。
    if (body.trim().isEmpty && file != null) body = file.name;
    if (body.trim().isEmpty || body.length > 8000) {
      setState(() => error = '本文は1〜8000文字で入力してください。');
      return;
    }
    // 日をまたいで開いていたなどで選べない日付になったときは、保存の前に選び直してもらう。
    if (_canBackdate &&
        happenedOn != null &&
        !validHappenedOn(happenedOn, maxDays: _maxBackdateDays)) {
      setState(
        () => error = '「いつのこと」の日付は、昨日から$_maxBackdateDays日前までで選び直してください。',
      );
      return;
    }
    final title = _canReference && reference ? _referenceTitleValue : null;
    if (title != null && !validReferenceTitle(title, max: _referenceTitleMax)) {
      setState(() => error = '資料の名前は1行・$_referenceTitleMax文字以内で書いてください。');
      return;
    }
    if (title != null &&
        (widget.controller.repository?.secretInReferenceTitle(title) ??
            false)) {
      setState(() => error = referenceTitleSecretMessage);
      return;
    }
    final checked = await checkSecretsBeforeSave(
      context,
      body,
      secrets: widget.controller.repository?.secretPolicy,
    );
    if (checked == null || !mounted) return;
    if (checked != body && checked.length > 8000) {
      setState(() => error = '伏せ字にすると8000文字を超えます。本文を短くしてください。');
      return;
    }
    // 保存する本文（空の見出しを除き、選んだ場合は伏せ字にしたもの）を画面にも示す。
    if (checked != text.text) text.text = checked;
    setState(() {
      busy = true;
      locked = true;
      error = null;
    });
    // 保存中に終了されても同じ操作の確認へ戻れるよう、先に操作IDを書きかけへ残す。
    _debounce?.cancel();
    await _persist();
    try {
      final r = await widget.controller.save(
        CaptureDraft(
          operationId: operation,
          text: text.text,
          kind: kind,
          project: project,
          gitDraftId: widget.draft?.id,
          gitDraftHash: widget.draft?.hash,
          meta: widget.answer?.meta,
          happenedOn: _canBackdate ? happenedOn : null,
          maxBackdateDays: _maxBackdateDays,
          continues: widget.continues?.sourceId,
          reference: _canReference && reference,
          referenceTitle: title,
          referenceTitleMax: _referenceTitleMax,
          attachment: file,
          attachmentMaxBytes: _attachmentLimits.maxBytes,
          fileNameMaxBytes: _attachmentLimits.nameMaxBytes,
        ),
      );
      await _settled(r);
      if (mounted) {
        setState(() => result = r);
      }
    } catch (e) {
      // 保存の記録（journal）を作る前に止まった場合（ファイルを写せなかった・形式の誤りなど）は、直して送り直せるようにする。
      // 写しかけのファイルと重ならないよう、次の保存は別の操作IDにする。記録後に結果が不明になった場合は、同じ操作IDで確認する。
      final state = await widget.controller.operationState(operation);
      if (mounted) {
        setState(() {
          error = HubController.message(e);
          if (state == null) {
            locked = false;
            operation = const Uuid().v4();
          }
        });
        if (state == null) await _persist();
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> confirmSame() async {
    setState(() => busy = true);
    try {
      final r = await widget.controller.confirm(operation);
      await _settled(r);
      if (mounted) {
        setState(() {
          result = r;
          _confirmedOnce = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = HubController.message(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  // ⌘Return（Ctrl+Enter）で「Inputへ保存」と同じ操作をする。
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      saveFormActivator: () {
        if (!busy && _ready && !locked) submit();
      },
      // Escは、本文が空（変換中でもない）ときだけ「フォームを閉じる」と同じ操作をする。書きかけを誤って捨てないため。
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (!busy &&
            !text.value.composing.isValid &&
            text.text.trim().isEmpty) {
          Navigator.pop(context);
        }
      },
    },
    // Mac以外では入力欄が自動で選ばれないため、開いた直後からキーが届くよう受け口を置く（ソフトキーボードは開かない）。
    child: Focus(
      autofocus: !usesCommandKey,
      skipTraversal: true,
      child: PopScope(
        canPop: !busy,
        child: HubAlertDialog(
          title: Text(
            widget.answer != null
                ? '問いに答える'
                : widget.continues != null
                ? '続きを書く'
                : widget.draft == null
                ? '思いつきを、そのまま。'
                : '下書きから入力を作る',
          ),
          onClose: busy ? null : () => Navigator.pop(context),
          content: SizedBox(
            width: 620,
            child: !_ready
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : DialogScroll(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        fieldNote(
                          context,
                          '保存先: ${widget.controller.location?.name ?? ''}',
                          top: 0,
                        ),
                        if (_restoredAt != null && result?.saved != true) ...[
                          const SizedBox(height: 12),
                          NoticeBox(
                            locked
                                ? '前回、保存結果を確かめられないまま閉じた書きかけです（${timeLabel(_restoredAt)}）。同じ内容を送り直さず、「同じ操作を確認」を押してください。'
                                : '前回の書きかけを戻しました（${timeLabel(_restoredAt)}）。',
                            key: const Key('draft-restored'),
                          ),
                          // 保存結果が不明なまま閉じた書きかけは、同じ操作を確かめてからでないと閉じられない。
                          // 先に閉じると新しい操作IDで同じ内容を送り直しやすくなるため。
                          if (!locked || _confirmedOnce)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                key: const Key('draft-discard'),
                                onPressed: busy ? null : _discard,
                                child: Text(
                                  locked ? '書きかけを閉じて新しく書く' : '書きかけを破棄して新しく書く',
                                ),
                              ),
                            ),
                        ],
                        if (widget.continues case final previous?) ...[
                          const SizedBox(height: 12),
                          NoticeBox(
                            '前のメモの続きとして保存します。前のメモは変わりません。Mac miniのAI読み取りでは、前のメモを前提として読みます。\n前のメモ: ${clip(previous.title.replaceAll(RegExp(r'\s+'), ' '), 80)}',
                            key: const Key('continues-previous'),
                          ),
                        ],
                        if (widget.answer case final answer?) ...[
                          const SizedBox(height: 12),
                          Container(
                            key: const Key('answer-question'),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '今週の気づきの問い（AIの推定・未検証）',
                                  style: noteStyle(context),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  answer.question,
                                  style: const TextStyle(height: 1.6),
                                ),
                              ],
                            ),
                          ),
                          fieldNote(
                            context,
                            '答えはふつうのメモとして保存し、この問いへの答えだと分かるように記録します。次の週の読み直しで使われます。',
                            top: 8,
                          ),
                        ],
                        const SizedBox(height: 16),
                        // 種類は、本文の上に2つの切り替えで並べる（ほとんどはメモのまま）。ひな形は、収まれば同じ行の右に、狭い画面では次の行に置く。
                        if (widget.answer == null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                _kindChooser(context),
                                if (!locked) _templateMenu(context),
                              ],
                            ),
                          ),
                        // 下書きから作る入力では、下の案内が同じことを伝えるので出さない。
                        if (widget.answer == null &&
                            widget.draft == null &&
                            kind == 'work-summary')
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: fieldNote(
                              context,
                              'AIが書いた作業の報告を貼るときの種類です。AIの自己報告（未検証）として読み取り、プロジェクトの現在地・次の一手の材料にします。',
                              key: const Key('memo-kind-note'),
                              top: 0,
                            ),
                          ),
                        TextField(
                          key: const Key('memo-text'),
                          controller: text,
                          focusNode: _textFocus,
                          // Macではキーボードで開いたまま書けるよう、本文へ移る。
                          autofocus: usesCommandKey,
                          readOnly: locked,
                          minLines: 5,
                          maxLines: 10,
                          maxLength: 8000,
                          decoration: InputDecoration(
                            hintText: widget.answer != null
                                ? '1行からで構いません'
                                : '断片的なメモ、疑問、あとで考えたいこと…',
                            alignLabelWithHint: true,
                          ),
                        ),
                        if (_related.isNotEmpty && _showRelated && !locked)
                          _relatedBox(),
                        fieldGap,
                        DropdownButtonFormField<String>(
                          key: ValueKey('memo-project-$_formGeneration'),
                          initialValue: project ?? '',
                          isExpanded: true,
                          style: fieldTextStyle(context),
                          decoration: const InputDecoration(
                            labelText: 'プロジェクト（任意）',
                          ),
                          items: [
                            // 続きでは、指定しなければ本体が前のメモのプロジェクトを引き継ぐので、そのとおりに示す。
                            DropdownMenuItem(
                              value: '',
                              child: Text(
                                _inheritedTitle == null
                                    ? '指定しない'
                                    : '前のメモと同じ（$_inheritedTitle）',
                              ),
                            ),
                            // 統合済みのプロジェクトは選ばせない（統合先を選ぶ）。
                            for (final p
                                in (widget
                                            .controller
                                            .repository
                                            ?.projects
                                            .values ??
                                        const <HubProject>[])
                                    .where((p) => !p.merged || p.id == project))
                              DropdownMenuItem(
                                value: p.id,
                                child: Text(
                                  p.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          // 下書きは同じプロジェクトの入力でだけ使用済みになるため、プロジェクトを固定する。
                          onChanged: locked || widget.draft != null
                              ? null
                              : (v) {
                                  setState(() => project = v == '' ? null : v);
                                  _schedulePersist();
                                  _scheduleRelated();
                                },
                        ),
                        if (_canBackdate) ...[
                          fieldGap,
                          _happenedChooser(context),
                        ],
                        if (_canReference) ...[
                          const SizedBox(height: 12),
                          _referenceChooser(context),
                        ],
                        if (widget.draft != null && kind == 'work-summary')
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: NoticeBox(
                              '作業要約として保存すると、プロジェクトの現在地・次の一手はこの本文から作られます。次の一手を書き足してください。',
                            ),
                          ),
                        fieldNote(
                          context,
                          '保存すると、同期の後にMac miniが受け取り、AIが読み取ります。進み具合は「保存と反映」で見られます。',
                          top: 16,
                        ),
                        // この端末だけの設定は、メモの中身の欄と見出しで分けて、控えめにまとめる。
                        if (_draftKey != null || widget.answer == null) ...[
                          fieldGap,
                          fieldLabel(context, 'この端末の設定'),
                        ],
                        if (_draftKey != null)
                          CheckboxListTile(
                            key: const Key('keep-drafts'),
                            contentPadding: EdgeInsets.zero,
                            visualDensity: formTileDensity,
                            horizontalTitleGap: formTileGap,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _keepDrafts,
                            onChanged: (v) => _setKeepDrafts(v ?? true),
                            title: Text(
                              '書きかけをこの端末に残す',
                              style: formTileTitle(context),
                            ),
                            subtitle: const Text(
                              'フォームを閉じたりアプリが終了したりしても、次に開いたときに続きから書けます。保存が確かめられたら消します。Vaultには書きません。',
                            ),
                          ),
                        if (widget.answer == null)
                          CheckboxListTile(
                            key: const Key('show-related'),
                            contentPadding: EdgeInsets.zero,
                            visualDensity: formTileDensity,
                            horizontalTitleGap: formTileGap,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _showRelated,
                            onChanged: (v) => _setShowRelated(v ?? true),
                            title: Text(
                              '書いている途中に、関係ありそうな過去の記録を出す',
                              style: formTileTitle(context),
                            ),
                            subtitle: const Text(
                              'この端末に読み込んだ記録だけを比べます。ネットワークにもAIにも送りません。',
                            ),
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: NoticeBox(error!, error: true),
                          ),
                        if (result != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: NoticeBox(
                              result!.saved
                                  ? 'この端末に保存しました'
                                  : '保存確認待ちです。再送せず同じ操作を確認してください。',
                            ),
                          ),
                        if (locked)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: SelectableText(
                              '操作ID: $operation',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: Text(result?.saved == true ? '閉じる' : 'フォームを閉じる'),
            ),
            if (!locked)
              FilledButton(
                key: const Key('save-memo'),
                onPressed: busy || !_ready ? null : submit,
                child: const Text('メモとして保存'),
              ),
            if (locked && result?.saved != true)
              FilledButton(
                key: const Key('confirm-same'),
                onPressed: busy ? null : confirmSame,
                child: const Text('同じ操作を確認'),
              ),
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    ),
  );
}
