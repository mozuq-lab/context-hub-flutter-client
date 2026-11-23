import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'parts.dart';
import '../app/controller.dart';
import '../core/models.dart';
import '../core/templates.dart';
import 'views.dart' show NoticeBox;

/// ひな形の見出しを1行にまとめた表示（例: 決まったこと / 次にやること / 持ち越し）。
String templateOutline(MemoTemplate t) {
  final headings = [
    for (final line in t.body.split('\n'))
      if (RegExp(r'^#{1,6}[ \t]+\S').hasMatch(line))
        line.replaceFirst(RegExp(r'^#{1,6}[ \t]+'), '').trim(),
  ];
  if (headings.isNotEmpty) return headings.join(' / ');
  final first = t.body
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  return first.trim();
}

/// 端末のひな形を並べ替え・追加・編集・削除する画面。変更はその場で端末に保存する。
class TemplateManagerDialog extends StatefulWidget {
  const TemplateManagerDialog({super.key, required this.controller});
  final HubController controller;
  @override
  State<TemplateManagerDialog> createState() => _TemplateManagerDialogState();
}

class _TemplateManagerDialogState extends State<TemplateManagerDialog> {
  List<MemoTemplate>? templates;
  String? error;
  bool busy = false;

  String? get _identity => widget.controller.location?.identity;
  Map<String, HubProject> get _projects =>
      widget.controller.repository?.projects ?? const {};

  @override
  void initState() {
    super.initState();
    widget.controller.templates.list().then((value) {
      if (!mounted) return;
      setState(() {
        templates = value;
        if (widget.controller.templates.unreadable) {
          error = '端末のひな形を読み込めませんでした。最初のひな形を表示しています。開き直すまで変更は保存しません。';
        }
      });
    });
  }

  /// 並び全体を保存する。失敗したら画面の並びは変えず、理由を示す。
  Future<void> _save(List<MemoTemplate> next) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.saveTemplates(next);
      if (mounted) setState(() => templates = next);
    } catch (e) {
      if (mounted) setState(() => error = HubController.message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit(MemoTemplate? current) async {
    final list = templates!;
    final edited = await showDialog<MemoTemplate>(
      context: context,
      // 外側を押しても、書いた本文を捨てて閉じない。
      barrierDismissible: false,
      builder: (_) => TemplateEditDialog(
        template: current,
        identity: _identity,
        projects: _projects,
      ),
    );
    if (edited == null || !mounted) return;
    await _save([
      for (final t in list)
        if (t.id == edited.id) edited else t,
      if (current == null) edited,
    ]);
  }

  Future<void> _move(int index, int delta) async {
    final next = [...templates!];
    final item = next.removeAt(index);
    next.insert(index + delta, item);
    await _save(next);
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => HubAlertDialog(
          title: Text(title),
          onClose: () => Navigator.pop(context, false),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('やめる'),
            ),
            FilledButton(
              key: const Key('template-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _delete(MemoTemplate t) async {
    if (!await _confirm('ひな形を削除', '「${t.name}」をこの端末から削除します。', '削除する')) {
      return;
    }
    await _save([
      for (final x in templates!)
        if (x.id != t.id) x,
    ]);
  }

  Future<void> _reset() async {
    if (!await _confirm(
      '最初のひな形に戻す',
      'この端末で追加・編集したひな形と並び順を捨て、最初の${defaultTemplates.length}件に戻します。',
      '戻す',
    )) {
      return;
    }
    await _save(defaultTemplates);
  }

  @override
  Widget build(BuildContext context) {
    final list = templates;
    final identity = _identity;
    return HubAlertDialog(
      title: const Text('ひな形'),
      onClose: busy ? null : () => Navigator.pop(context),
      content: SizedBox(
        width: 560,
        child: list == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : DialogScroll(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'メモの本文欄へ差し込む見出しです。この端末だけに保存し、Vaultには書きません。中身を書かなかった見出しは、メモの保存前に取り除きます。',
                      style: noteStyle(context),
                    ),
                    const SizedBox(height: 8),
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('ひな形はありません。'),
                      ),
                    for (final (index, t) in list.indexed)
                      Padding(
                        key: Key('template-row-${t.id}'),
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              [
                                templateOutline(t),
                                if (identity != null &&
                                    _projects[t.projects[identity]] != null)
                                  '既定のプロジェクト: ${_projects[t.projects[identity]]!.title}',
                              ].join('\n'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: noteStyle(context),
                            ),
                            // 幅の狭い画面でも名前と見出しを読めるよう、操作は下に並べる。
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  key: Key('template-up-${t.id}'),
                                  tooltip: '上へ',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: busy || index == 0
                                      ? null
                                      : () => _move(index, -1),
                                  icon: const Icon(
                                    Icons.arrow_upward,
                                    size: 18,
                                  ),
                                ),
                                IconButton(
                                  key: Key('template-down-${t.id}'),
                                  tooltip: '下へ',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: busy || index == list.length - 1
                                      ? null
                                      : () => _move(index, 1),
                                  icon: const Icon(
                                    Icons.arrow_downward,
                                    size: 18,
                                  ),
                                ),
                                IconButton(
                                  key: Key('template-edit-${t.id}'),
                                  tooltip: '編集',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: busy ? null : () => _edit(t),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                ),
                                IconButton(
                                  key: Key('template-delete-${t.id}'),
                                  tooltip: '削除',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: busy ? null : () => _delete(t),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 1),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('template-add'),
                          onPressed: busy || list.length >= maxTemplates
                              ? null
                              : () => _edit(null),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('ひな形を追加'),
                        ),
                        TextButton(
                          key: const Key('template-reset'),
                          onPressed: busy ? null : _reset,
                          child: const Text('最初のひな形に戻す'),
                        ),
                      ],
                    ),
                    if (list.length >= maxTemplates)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'ひな形は$maxTemplates件までです。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: NoticeBox(error!, error: true),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          key: const Key('template-close'),
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}

/// ひな形1件の名前・本文・このVaultでの既定のプロジェクトを編集する画面。
class TemplateEditDialog extends StatefulWidget {
  const TemplateEditDialog({
    super.key,
    this.template,
    required this.identity,
    required this.projects,
  });

  /// 編集するひな形。nullなら新しく作る。
  final MemoTemplate? template;
  final String? identity;
  final Map<String, HubProject> projects;
  @override
  State<TemplateEditDialog> createState() => _TemplateEditDialogState();
}

class _TemplateEditDialogState extends State<TemplateEditDialog> {
  late final name = TextEditingController(text: widget.template?.name ?? '');
  late final body = TextEditingController(text: widget.template?.body ?? '');
  String? project, error;

  @override
  void initState() {
    super.initState();
    final stored = widget.template?.projects[widget.identity];
    project = widget.projects.containsKey(stored) ? stored : null;
  }

  @override
  void dispose() {
    name.dispose();
    body.dispose();
    super.dispose();
  }

  void _submit() {
    final problem =
        templateNameError(name.text) ?? templateBodyError(body.text);
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    final base =
        widget.template ??
        MemoTemplate(id: 't-${const Uuid().v4()}', name: '', body: '');
    final identity = widget.identity;
    final edited = base.copyWith(name: name.text.trim(), body: body.text);
    Navigator.pop(
      context,
      identity == null ? edited : edited.withProject(identity, project),
    );
  }

  @override
  Widget build(BuildContext context) => HubAlertDialog(
    title: Text(widget.template == null ? 'ひな形を追加' : 'ひな形を編集'),
    onClose: () => Navigator.pop(context),
    content: SizedBox(
      width: 520,
      child: DialogScroll(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('template-name'),
              controller: name,
              maxLength: MemoTemplate.maxNameChars,
              decoration: const InputDecoration(labelText: '名前'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('template-body'),
              controller: body,
              minLines: 6,
              maxLines: 12,
              maxLength: MemoTemplate.maxBodyChars,
              decoration: const InputDecoration(
                labelText: '本文',
                hintText: '## 決まったこと\n\n## 次にやること',
                alignLabelWithHint: true,
                helperText: '「## 見出し」の行を並べます。中身を書かなかった見出しは保存前に取り除きます。',
                helperMaxLines: 3,
              ),
            ),
            if (widget.identity != null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('template-project'),
                style: fieldTextStyle(context),
                initialValue: project ?? '',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'このVaultでの既定のプロジェクト（任意）',
                  helperText: 'ひな形を選んだとき、プロジェクトが未指定ならこのプロジェクトにします。',
                  helperMaxLines: 2,
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('指定しない')),
                  // 統合済みのプロジェクトは選ばせない（統合先を選ぶ）。
                  for (final p in widget.projects.values.where(
                    (p) => !p.merged || p.id == project,
                  ))
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(p.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => project = v == '' ? null : v),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: NoticeBox(error!, error: true),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('やめる'),
      ),
      FilledButton(
        key: const Key('template-save'),
        onPressed: _submit,
        child: const Text('この端末に保存'),
      ),
    ],
  );
}
