import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../storage/capture_service.dart';
import '../parts.dart';
import '../save_checks.dart';

/// プロジェクトの名前・別名・キーワード（と望む結果）を編集する。別名とキーワードは1行に1つ。
/// 望む結果の欄は、本体が対応しているとき（[outcomeLimits]があるとき）だけ出す。
class ProjectDefinitionDialog extends StatefulWidget {
  const ProjectDefinitionDialog({
    super.key,
    required this.project,
    this.outcomeLimits,
  });
  final HubProject project;
  final ({int maxChars, int maxLines})? outcomeLimits;
  @override
  State<ProjectDefinitionDialog> createState() =>
      _ProjectDefinitionDialogState();
}

class _ProjectDefinitionDialogState extends State<ProjectDefinitionDialog> {
  late final title = TextEditingController(text: widget.project.title),
      aliases = TextEditingController(text: widget.project.aliases.join('\n')),
      keywords = TextEditingController(
        text: widget.project.keywords.join('\n'),
      ),
      outcome = TextEditingController(text: widget.project.outcome ?? '');

  /// 望む結果は、欄を書き換えたときだけ送る（手で書いた文を、ほかの変更のついでに整えて書き換えない）。
  ProjectDefinitionDraft get draft => ProjectDefinitionDraft(
    title: title.text,
    aliases: aliases.text.split('\n'),
    keywords: keywords.text.split('\n'),
    outcome:
        widget.outcomeLimits == null ||
            outcome.text == (widget.project.outcome ?? '')
        ? null
        : outcome.text,
    outcomeLimits: widget.outcomeLimits,
  );

  @override
  void initState() {
    super.initState();
    for (final t in [title, aliases, keywords, outcome]) {
      t.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    title.dispose();
    aliases.dispose();
    keywords.dispose();
    outcome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = draft,
        problem = next.problem,
        unchanged = next.sameAs(widget.project);
    final limits = widget.outcomeLimits;
    return HubAlertDialog(
      title: Text(
        limits == null
            ? '${widget.project.title}の呼び名とキーワード'
            : '${widget.project.title}の定義',
      ),
      onClose: () => Navigator.pop(context),
      content: SizedBox(
        width: 560,
        child: DialogScroll(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'AIはメモをどのプロジェクトに結び付けるかを、名前・別名・キーワードから判断します。メモでよく使う呼び方や、このプロジェクトに特有の言葉を加えてください。',
                style: noteStyle(context),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('definition-title'),
                controller: title,
                maxLength: ProjectDefinitionDraft.maxTitleChars,
                decoration: const InputDecoration(labelText: '名前'),
              ),
              TextField(
                key: const Key('definition-aliases'),
                controller: aliases,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: '別名（1行に1つ）',
                  helperText:
                      '${next.aliases.length}/${ProjectDefinitionDraft.maxTerms}件',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('definition-keywords'),
                controller: keywords,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'キーワード（1行に1つ）',
                  helperText:
                      '${next.keywords.length}/${ProjectDefinitionDraft.maxTerms}件',
                ),
              ),
              if (limits != null) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const Key('definition-outcome'),
                  controller: outcome,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: '望む結果（任意）',
                    hintText: 'どうなればこのプロジェクトを完了にできるか',
                    helperText:
                        '${normalizeProjectOutcome(outcome.text).length}/${limits.maxChars}文字・${limits.maxLines}行まで。空にすると外します',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (problem != null)
                NoticeBox(problem, error: true)
              else
                Text(
                  '依頼は保存され、Mac miniで処理されると反映されます。プロジェクトを指定せずに保存したメモのうち、まだどのプロジェクトにも結び付いていないものは、次のAI読み取りで新しい定義に合わせて見直されます（AIを使います）。${limits == null ? '' : '望む結果もAIへ渡し、メモの結び付けと次の一手を読む手がかりにします。'}',
                  style: noteStyle(context),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('definition-submit'),
          onPressed: problem != null || unchanged
              ? null
              : () => Navigator.pop(context, next),
          child: const Text('変更を依頼'),
        ),
      ],
    );
  }
}
