import 'package:flutter/material.dart';
import 'parts.dart';
import '../app/controller.dart';
import '../core/models.dart';
import 'views.dart'
    show checkSecretsBeforeSave, notice, intakeStateLabel, timeLabel;

/// 「記録に聞く」。問いを受付ファイルで送り、本体が次の整理のときに、Vaultの記録だけを根拠に答える。
/// 答えの文ごとに、根拠の記録と記録からそのまま写した引用を示し、元の記録を開ける。答えはAI生成・未検証。
class AskPanel extends StatefulWidget {
  const AskPanel({super.key, required this.controller, required this.onRecord});
  final HubController controller;

  /// 記録（アプリの記録ID）を開く。
  final void Function(String recordId) onRecord;
  @override
  State<AskPanel> createState() => _AskPanelState();
}

class _AskPanelState extends State<AskPanel> {
  final question = TextEditingController();
  String? project;
  bool sending = false;

  HubController get c => widget.controller;

  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final repo = c.repository;
    if (repo == null) return;
    final max = repo.intakeFeatures.askMaxChars;
    final text = question.text.trim();
    if (text.isEmpty || text.length > max) {
      notice(context, '問いは1〜$max文字で入力してください。');
      return;
    }
    // 問いは受付ファイルとして同期され、整理用のAIへも渡る。秘密情報らしい文字列は先に知らせる。
    final checked = await checkSecretsBeforeSave(
      context,
      text,
      secrets: repo.secretPolicy,
    );
    if (checked == null || !mounted) return;
    if (checked.length > max) {
      notice(context, '伏せ字にすると$max文字を超えます。問いを短くしてください。');
      return;
    }
    setState(() => sending = true);
    try {
      final result = await c.requestAsk(checked, project);
      if (!mounted) return;
      if (result.saved) question.clear();
      notice(
        context,
        result.saved
            ? '問いを送りました。Mac miniの次のAI読み取りのときに答えを作り、同期で届きます。'
            : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
      );
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  void openInput(String inputId) {
    final record = c.repository?.inputRecord(inputId);
    if (record == null) {
      notice(context, 'この記録はまだこの端末に届いていません。同期後に再読込してください。');
      return;
    }
    widget.onRecord(record.id);
  }

  Widget recordButton(String inputId, {Key? key}) {
    final record = c.repository?.inputRecord(inputId);
    return TextButton.icon(
      key: key,
      onPressed: () => openInput(inputId),
      icon: const Icon(Icons.article_outlined, size: 15),
      label: Text(
        record?.title ?? inputId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String statusOf(AskThread thread) {
    final request = thread.request, answer = thread.answer;
    if (answer != null) {
      return askAnswerStatus(
        answer,
        askOff: c.repository?.intakeFeatures.askOff ?? false,
      );
    }
    if (request == null) return '';
    if (request.state == 'accepted') {
      return request.detail.startsWith('答えは保存期間') ||
              request.detail == askDisabledWaiting
          ? request.detail
          : '答え待ち（次のAI読み取りのときに作ります）';
    }
    return intakeStateLabel(request.state);
  }

  Widget thread(AskThread t, int index) {
    final scheme = Theme.of(context).colorScheme;
    final answer = t.answer, request = t.request;
    final projectTitle = t.project == null
        ? null
        : c.repository?.projects[t.project]?.title ?? t.project;
    final failed =
        request != null &&
        const ['rejected', 'conflict'].contains(request.state);
    return Card(
      key: Key('ask-thread-$index'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.question,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              [
                timeLabel(t.at),
                ?projectTitle,
                statusOf(t),
              ].where((s) => s.isNotEmpty).join(' · '),
              style: TextStyle(
                fontSize: 12,
                color: failed || answer?.status == 'failed'
                    ? scheme.error
                    : null,
              ),
            ),
            if (failed && request.detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  request.detail,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
            if (answer != null && answer.sentences.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'AI生成・未検証の答えです。根拠の引用と元の記録で確かめてください。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              for (final (i, sentence) in answer.sentences.indexed)
                Padding(
                  key: Key('ask-sentence-$index-$i'),
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sentence.text, style: const TextStyle(height: 1.6)),
                      for (final e in sentence.evidence)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '「${e.quote}」',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              recordButton(
                                e.inputId,
                                key: Key('ask-evidence-${e.inputId}'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              if (answer.dropped > 0)
                Text(
                  '根拠を確かめられなかった文を${answer.dropped}件除きました。',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
            // 答えがないときは、問いに近かった記録を示す（自分で読み比べられるように）。
            if (answer != null &&
                answer.sentences.isEmpty &&
                answer.candidates.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('問いに近かった記録', style: TextStyle(fontSize: 12)),
              Wrap(
                spacing: 4,
                children: [
                  for (final id in answer.candidates.take(5)) recordButton(id),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = c.repository;
    if (repo == null) return const SizedBox.shrink();
    final enabled = repo.intakeFeatures.ask;
    final max = repo.intakeFeatures.askMaxChars;
    final projects = repo.orderedProjects.where((p) => !p.merged).toList();
    if (project != null && !projects.any((p) => p.id == project)) {
      project = null;
    }
    final busy = sending || c.saving || c.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!enabled)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              '今は「記録に聞く」を使えません。Mac miniの本体が古いか、この機能がオフになっています。Mac miniで本体を更新するか、オンにしてください。これまでの問いと答えは下にあります。',
              key: Key('ask-unavailable'),
            ),
          )
        else ...[
          TextField(
            key: const Key('ask-question'),
            controller: question,
            minLines: 2,
            maxLines: 5,
            maxLength: max,
            decoration: const InputDecoration(
              labelText: '聞きたいこと',
              hintText: '例: バックアップは結局どういう方式にしたんだっけ',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String?>(
                key: const Key('ask-project'),
                value: project,
                items: [
                  const DropdownMenuItem(value: null, child: Text('すべての記録から')),
                  for (final p in projects)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy ? null : (v) => setState(() => project = v),
              ),
              FilledButton.icon(
                key: const Key('ask-send'),
                onPressed: busy || question.text.trim().isEmpty ? null : send,
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('聞く'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '問いを保存し、Mac miniが次のAI読み取りのときに、メモと作業要約（訂正があれば最新の訂正）だけを根拠に答えます。答えはメモにはなりません。',
            style: noteStyle(context),
          ),
          const SizedBox(height: 20),
        ],
        if (repo.asks.isEmpty)
          emptyText(context, 'まだ問いはありません。', key: const Key('ask-empty'))
        else
          for (final (i, t) in repo.asks.indexed) thread(t, i),
      ],
    );
  }
}
