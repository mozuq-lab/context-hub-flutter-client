import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../core/models.dart';
import '../core/repository.dart' show displayTime;
import 'notice.dart';
import 'parts.dart';

/// 資料棚の画面。本体が書いた資料の一覧（90_system/references.json）を並べ、
/// 名前を変える・資料棚から外す・外した資料を戻す依頼を出す。
/// 本文やURLは原文なので、ここでは直さず、メモの「訂正」で直す。
class ReferenceShelfPage extends StatelessWidget {
  const ReferenceShelfPage({
    super.key,
    required this.controller,
    required this.projectId,
    required this.title,
    required this.onRecord,
    this.onGenerated,
  });
  final HubController controller;

  /// 資料棚を開くプロジェクト。nullならどのプロジェクトにも結び付いていない資料。
  final String? projectId;
  final String title;

  /// メモを開く。
  final void Function(BuildContext context, HubRecord record) onRecord;

  /// 本体が作った資料のページ（REFERENCES.md）を開く。ページがなければnull。
  final VoidCallback? onGenerated;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('$titleの資料')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final repo = controller.repository, index = repo?.referenceIndex;
        if (repo == null || index == null) {
          return const Center(child: Text('資料の一覧を読み込めませんでした。'));
        }
        final id = projectId;
        final entries = id == null
            ? repo.unassignedReferences
            : repo.referencesFor(id);
        final removed = id == null
            ? repo.unassignedRemovedReferences
            : repo.removedReferencesFor(id);
        final editable = repo.intakeFeatures.references;
        final theme = Theme.of(context);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: pageMaxWidth),
            child: ListView(
              key: const Key('reference-shelf'),
              padding: pagePadding(context).copyWith(bottom: 48),
              children: [
                Text(
                  '本人が資料にしたメモと、AIが参考資料と読み取ったメモです。'
                  '名前を変えたり、資料棚から外したりできます。本文やURLを直すときは、メモを開いて「訂正」してください。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
                ),
                const SizedBox(height: 6),
                Text(
                  '一覧の生成: ${displayTime(index.generatedAt)}',
                  style: theme.textTheme.bodySmall,
                ),
                if (!editable)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Mac miniの本体を更新すると、ここから名前を変えたり外したりできます。',
                      style: noteStyle(context),
                    ),
                  ),
                sectionTitle(
                  context,
                  '資料（${entries.length}件）',
                  note: 'メモを資料にするには、保存するときに「資料として保存」を選ぶか、メモを開いて「資料に加える」を押します。',
                ),
                if (entries.isEmpty)
                  emptyText(context, 'まだ資料はありません。')
                else
                  for (final e in entries)
                    _EntryCard(
                      key: ValueKey('reference-${e.inputId}'),
                      controller: controller,
                      entry: e,
                      projectId: id,
                      editable: editable,
                      onRecord: onRecord,
                    ),
                if (removed.isNotEmpty) ...[
                  sectionTitle(
                    context,
                    '外した資料（${removed.length}件）',
                    note: 'メモそのものは残っています。戻すと、外す前の名前で資料棚に戻ります。',
                  ),
                  for (final e in removed)
                    _RemovedCard(
                      key: ValueKey('removed-reference-${e.inputId}'),
                      controller: controller,
                      entry: e,
                      editable: editable,
                      onRecord: onRecord,
                    ),
                ],
                if (onGenerated != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('reference-generated'),
                        onPressed: onGenerated,
                        icon: const Icon(Icons.description_outlined, size: 18),
                        label: const Text('本体が作った資料のページを見る'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.controller,
    required this.entry,
    required this.projectId,
    required this.editable,
    required this.onRecord,
  });
  final HubController controller;
  final ReferenceEntry entry;
  final String? projectId;
  final bool editable;
  final void Function(BuildContext context, HubRecord record) onRecord;

  @override
  Widget build(BuildContext context) {
    final repo = controller.repository!;
    final theme = Theme.of(context);
    final record = repo.inputRecord(entry.inputId);
    final pending = repo.referenceRequestIdFor(entry.inputId) != null;
    final ids = projectId == null
        ? const <String>{}
        : {projectId!, for (final p in repo.mergedSources(projectId!)) p.id};
    final flags = [
      entry.addedByPerson ? '本人が追加' : 'AIが参考資料と読み取り',
      if (entry.unorganized) 'AIの読み取り待ち',
      if (entry.failed) 'AIの読み取りに失敗',
      if (entry.pendingCorrection)
        '訂正の読み取り待ち'
      else if (entry.corrected)
        '訂正あり',
      if (projectId != null &&
          (entry.project == null || !ids.contains(entry.project)))
        '関連候補（AI推定）',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (entry.title != null && entry.aiSummary != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'AIの要約: ${entry.aiSummary}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${displayTime(entry.occurredAt)} · ${flags.join(' · ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (entry.file case final file?)
              sourceLink(
                context,
                key: Key('reference-file-${entry.inputId}'),
                icon: Icons.attach_file,
                label: file.label,
                onPressed: controller.access.attachmentsSupported
                    ? () => openHubFile(context, controller, file)
                    : null,
              ),
            for (final url in entry.urls)
              sourceLink(
                context,
                icon: Icons.link,
                label: url,
                onPressed: () => _openUrl(context, controller, url),
              ),
            if (entry.skippedUrls > 0)
              entryNote(
                context,
                '載せていないURLが${entry.skippedUrls}件あります（多すぎる・長すぎる・秘密情報らしい文字列を含む）。メモを開いて確かめてください。',
              ),
            rowActions(
              context,
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (record != null)
                    TextButton(
                      key: Key('reference-open-${entry.inputId}'),
                      onPressed: () => onRecord(context, record),
                      child: const Text('メモを開く'),
                    ),
                  if (pending)
                    statusText(
                      context,
                      '依頼済み（反映待ち）',
                      key: Key('reference-pending-${entry.inputId}'),
                    )
                  else if (editable) ...[
                    TextButton(
                      key: Key('reference-rename-${entry.inputId}'),
                      onPressed: controller.saving
                          ? null
                          : () => renameReference(
                              context,
                              controller,
                              entry.inputId,
                              current: entry.title,
                              aiSummary: entry.aiSummary,
                            ),
                      child: const Text('名前を変える'),
                    ),
                    TextButton(
                      key: Key('reference-remove-${entry.inputId}'),
                      onPressed: controller.saving
                          ? null
                          : () => removeReference(
                              context,
                              controller,
                              entry.inputId,
                              entry.label,
                            ),
                      child: const Text('資料棚から外す'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemovedCard extends StatelessWidget {
  const _RemovedCard({
    super.key,
    required this.controller,
    required this.entry,
    required this.editable,
    required this.onRecord,
  });
  final HubController controller;
  final RemovedReference entry;
  final bool editable;
  final void Function(BuildContext context, HubRecord record) onRecord;

  @override
  Widget build(BuildContext context) {
    final repo = controller.repository!;
    final theme = Theme.of(context);
    final record = repo.inputRecord(entry.inputId);
    final pending = repo.referenceRequestIdFor(entry.inputId) != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.label, style: theme.textTheme.titleSmall),
            if (entry.file case final file?)
              sourceLink(
                context,
                key: Key('reference-file-${entry.inputId}'),
                icon: Icons.attach_file,
                label: file.label,
                onPressed: controller.access.attachmentsSupported
                    ? () => openHubFile(context, controller, file)
                    : null,
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '外した日時: ${displayTime(entry.removedAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            rowActions(
              context,
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (record != null)
                    TextButton(
                      onPressed: () => onRecord(context, record),
                      child: const Text('メモを開く'),
                    ),
                  if (pending)
                    statusText(context, '依頼済み（反映待ち）')
                  else if (editable)
                    TextButton(
                      key: Key('reference-restore-${entry.inputId}'),
                      onPressed: controller.saving
                          ? null
                          : () => sendReferenceMark(
                              context,
                              controller,
                              entry.inputId,
                              'add',
                              title: entry.title,
                              done: '資料棚に戻す依頼をしました。',
                            ),
                      child: const Text('資料棚に戻す'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openUrl(
  BuildContext context,
  HubController controller,
  String url,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty) {
    notice(context, 'このURLは開けません。');
    return;
  }
  try {
    await controller.access.openExternal(url);
  } catch (_) {
    if (context.mounted) notice(context, 'リンクを開けませんでした。');
  }
}

/// メモに添えたファイル（Vaultの05_files）を、端末の既定のアプリで開く。開けなければ理由を示す。
Future<void> openHubFile(
  BuildContext context,
  HubController controller,
  HubFile file,
) async {
  try {
    await controller.openVaultFile(file);
  } catch (e) {
    if (context.mounted) notice(context, HubController.message(e));
  }
}

/// 資料の依頼を保存し、結果を案内する。
Future<void> sendReferenceMark(
  BuildContext context,
  HubController controller,
  String inputId,
  String action, {
  String? title,
  required String done,
}) async {
  try {
    final result = await controller.requestReferenceMark(
      inputId,
      action,
      title: title,
    );
    if (context.mounted) {
      notice(
        context,
        result.saved
            ? '$done Mac miniが受け取った後の資料棚の作り直しで反映されます。'
            : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
      );
    }
  } catch (e) {
    if (context.mounted) notice(context, HubController.message(e));
  }
}

/// 資料棚から外す。外すかを確かめてから依頼する。
Future<void> removeReference(
  BuildContext context,
  HubController controller,
  String inputId,
  String label,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('資料棚から外しますか？'),
      content: SizedBox(
        width: 520,
        child: Text(
          '「$label」を資料棚から外します。メモそのものと、AIが読み取った内容は残ります。'
          '外した資料は、資料棚の「外した資料」から戻せます。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('confirm-reference-remove'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('外す'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await sendReferenceMark(
    context,
    controller,
    inputId,
    'remove',
    done: '資料棚から外す依頼をしました。',
  );
}

/// 資料の名前を変える（資料棚にないメモなら、名前を付けて資料に加える）。
Future<void> renameReference(
  BuildContext context,
  HubController controller,
  String inputId, {
  String? current,
  String? aiSummary,
  bool adding = false,
}) async {
  final max =
      controller.repository?.intakeFeatures.referenceTitleMax ??
      referenceTitleChars;
  final value = await showDialog<({String? title})>(
    context: context,
    builder: (_) => ReferenceTitleDialog(
      initial: current,
      aiSummary: aiSummary,
      max: max,
      adding: adding,
      secret: controller.repository?.secretInReferenceTitle,
    ),
  );
  if (value == null || !context.mounted) return;
  await sendReferenceMark(
    context,
    controller,
    inputId,
    'add',
    title: value.title,
    done: adding ? '資料に加える依頼をしました。' : '資料の名前を変える依頼をしました。',
  );
}

/// 資料の名前を入力する。空なら名前を付けず、AIの要約を資料の名前にする。
class ReferenceTitleDialog extends StatefulWidget {
  const ReferenceTitleDialog({
    super.key,
    this.initial,
    this.aiSummary,
    this.max = referenceTitleChars,
    this.adding = false,
    this.secret,
  });
  final String? initial, aiSummary;
  final int max;

  /// 名前に秘密情報らしい文字列があるか（なければ調べない）。
  final bool Function(String title)? secret;

  /// 資料棚にないメモを、名前を付けて加えるとき。
  final bool adding;
  @override
  State<ReferenceTitleDialog> createState() => _ReferenceTitleDialogState();
}

class _ReferenceTitleDialogState extends State<ReferenceTitleDialog> {
  late final text = TextEditingController(text: widget.initial ?? '');
  String? error;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void submit() {
    final v = text.text.trim();
    if (v.isNotEmpty && !validReferenceTitle(v, max: widget.max)) {
      setState(() => error = '資料の名前は1行・${widget.max}文字以内で書いてください。');
      return;
    }
    if (v.isNotEmpty && (widget.secret?.call(v) ?? false)) {
      setState(() => error = referenceTitleSecretMessage);
      return;
    }
    Navigator.pop(context, (title: v.isEmpty ? null : v));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.adding ? '資料に加える' : '資料の名前を変える'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('reference-title-field'),
            controller: text,
            autofocus: true,
            // 上限は本体と同じくUTF-16の長さで数える（絵文字は2と数える）。
            buildCounter:
                (context, {required currentLength, required isFocused, maxLength}) =>
                    Text(
                      '${text.text.trim().length}/${widget.max}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
            decoration: InputDecoration(
              labelText: '資料の名前（任意）',
              helperText: widget.aiSummary == null
                  ? '空のままなら、AIが読み取った要約を資料の名前にします。'
                  : '空のままなら、AIの要約（${widget.aiSummary}）を資料の名前にします。',
              helperMaxLines: 3,
              errorText: error,
            ),
            onSubmitted: (_) => submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('やめる'),
      ),
      FilledButton(
        key: const Key('reference-title-save'),
        onPressed: submit,
        child: Text(widget.adding ? '加える' : '変える'),
      ),
    ],
  );
}
