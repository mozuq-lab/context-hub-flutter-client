import 'package:flutter/material.dart';

import '../../core/intake_features.dart' show unassignedScope;
import '../../core/models.dart';
import '../parts.dart';
import 'contexts_dialog.dart';

/// 本人が決めた行動を「次の一手」に追加する画面。AIの読み取り（提案など）を行動にするときは、元の行を初期値にする。
class ActionDialog extends StatefulWidget {
  const ActionDialog({
    super.key,
    required this.projects,
    this.from,
    this.allowUnassigned = false,
    this.unassigned = false,
    this.effortChoice = false,
    this.contextChoices,
  });

  /// 追加と一緒に手間の目安を選べる（対応した本体で、新しく足す行動のとき）。
  final bool effortChoice;

  /// 追加と一緒に選べる場所・道具の札（語彙）。nullなら札の欄を出さない。
  final List<String>? contextChoices;

  /// 追加先に選べるプロジェクト。1件で[allowUnassigned]でなければ、そのプロジェクトに決まっている。
  final List<HubProject> projects;

  /// 追加先に「プロジェクト未定」も選べる（本体が対応しているとき）。
  final bool allowUnassigned;

  /// 最初から「プロジェクト未定」を選んでおく（[allowUnassigned]のときだけ効く）。
  final bool unassigned;

  /// AIが読み取った行を行動にするときの元の行。
  final ActionSource? from;
  @override
  State<ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<ActionDialog> {
  late final text = TextEditingController(
    text: widget.from?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '',
  );
  late String project =
      widget.allowUnassigned && (widget.unassigned || widget.projects.isEmpty)
      ? unassignedScope
      : widget.projects.first.id;
  String? effort;
  List<String> contexts = const [];

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = text.text.trim(),
        valid = validActionText(value) && contexts.length <= contextTagsMax;
    return HubAlertDialog(
      key: const Key('action-dialog'),
      title: Text(widget.from == null ? '次の一手を追加' : '自分の行動にする'),
      onClose: () => Navigator.pop(context),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.projects.length + (widget.allowUnassigned ? 1 : 0) ==
                  1)
                Text(
                  widget.projects.firstOrNull?.title ?? 'プロジェクト未定',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                )
              else
                DropdownButtonFormField<String>(
                  key: const Key('action-project'),
                  style: fieldTextStyle(context),
                  initialValue: project,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'プロジェクト'),
                  items: [
                    for (final p in widget.projects)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(p.title, overflow: TextOverflow.ellipsis),
                      ),
                    if (widget.allowUnassigned)
                      const DropdownMenuItem(
                        key: Key('action-project-unassigned'),
                        value: unassignedScope,
                        child: Text('プロジェクト未定'),
                      ),
                  ],
                  onChanged: (v) => setState(() => project = v ?? project),
                ),
              if (widget.from case final from?) ...[
                const SizedBox(height: 16),
                Text(
                  '元の行（AIの読み取り）: ${from.text}',
                  key: const Key('action-from'),
                  style: noteStyle(context),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const Key('action-text'),
                controller: text,
                autofocus: true,
                maxLines: 1,
                decoration: InputDecoration(
                  labelText: '次にやること（1行）',
                  helperText: '自分の言葉で書いてください。AIは書き換えません。',
                  // 本体の検査と同じ数え方（UTF-16の単位。絵文字などは2文字と数える）で示す。
                  counterText: '${value.length} / $actionTextChars',
                  errorText: value.isEmpty || valid
                      ? null
                      : '1行・$actionTextChars文字以内で入力してください。',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (widget.effortChoice) ...[
                const SizedBox(height: 16),
                fieldLabel(context, '手間の目安（任意）'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in itemEfforts)
                      ChoiceChip(
                        key: Key('action-effort-$e'),
                        label: Text(itemEffortLabels[e]!),
                        selected: effort == e,
                        onSelected: (on) =>
                            setState(() => effort = on ? e : null),
                      ),
                  ],
                ),
              ],
              if (widget.contextChoices case final choices?
                  when choices.isNotEmpty) ...[
                const SizedBox(height: 16),
                fieldLabel(context, '場所・道具の札（任意・いくつでも）'),
                ContextChips(
                  keyPrefix: 'action-context',
                  options: choices,
                  vocabulary: choices,
                  selected: contexts,
                  onChanged: (next) => setState(() => contexts = next),
                ),
                if (contexts.length > contextTagsMax)
                  Text(
                    '札は1つの項目に$contextTagsMax個までです。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              Text(
                project == unassignedScope
                    ? widget.from == null
                          ? '本人が追加した行動として、プロジェクト未定の次の一手に載ります。AIは書き換えず、完了か却下するまで残ります（期日は付けられません。後からプロジェクトへは移せません）。'
                          : '本人が追加した行動としてプロジェクト未定の次の一手に載り、元の行はAIの読み取りの欄から外れます。完了か却下するまで残ります（期日は付けられません）。'
                    : widget.from == null
                    ? '本人が追加した行動として、そのまま次の一手に載ります。AIは書き換えず、完了か誤りとして外すと報告するまで、新しい作業要約が届いても残ります。Mac miniで処理されると現状に反映されます。'
                    : '本人が追加した行動として次の一手に載り、元の行はAIの読み取りの欄から外れます。完了か誤りとして外すと報告するまで、新しい作業要約が届いても残ります。Mac miniで処理されると現状に反映されます。',
                style: noteStyle(context),
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
          key: const Key('action-submit'),
          onPressed: valid
              ? () => Navigator.pop(context, (
                  projectId: project,
                  text: value,
                  effort: widget.effortChoice ? effort : null,
                  contexts: widget.contextChoices != null && contexts.isNotEmpty
                      ? contexts
                      : null,
                ))
              : null,
          child: const Text('追加する'),
        ),
      ],
    );
  }
}
