import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../dialogs/capture_dialog.dart';
import '../notice.dart';
import '../parts.dart';
import '../save_checks.dart';
import 'hub_common.dart';
import 'hub_view.dart';

/// ホームの「今週の気づき」と、気づきへの反応。
extension HubInsights on HubViewState {
  /// ホームの「今週の気づき」。本体の週次の統合が、たまったメモをまとめて読み直した結果（AI生成・未検証）。
  /// 項目ごとに根拠のメモを開いて確かめられる。本体で無効のとき・結果がないときは何も出さない。
  List<Widget> insightsHome() {
    final insights = repo.insights;
    if (insights == null) return const [];
    final now = DateTime.now(),
        items = insights.items,
        age = insights.ageDays(now),
        widgets = <Widget>[];
    if (insights.failure != null) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: NoticeBox(
            '週次の統合（今週の気づき）の前回の実行が失敗しました（${insights.failure}）。${items.isEmpty ? '' : '前回までの気づきを表示しています。'}やり直し方は、VaultのHOME.mdの「失敗と競合」にあります。',
            key: const Key('home-insights-failure'),
          ),
        ),
      );
    }
    if (insights.recordProblems > 0) {
      widgets.add(
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: NoticeBox(
            '週次の統合の記録に読めないものがあり、自動の実行が止まっています。VaultのHOME.mdの「失敗と競合」で場所を確認してください。',
            key: Key('home-insights-records'),
          ),
        ),
      );
    }
    if (items.isEmpty) {
      // 項目はあるが、根拠のメモがまだこの端末に届いていない。
      if (insights.waiting > 0) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '今週の気づき: 根拠のメモがこの端末に届いていない${insights.waiting}件は、同期で届いてから表示します。',
              key: const Key('home-insights-waiting'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      }
      return widgets;
    }
    // たたんでいる間は、欄ごとに先頭の1件だけを出す。
    final shownKeys = <String>{};
    for (final section in insightSectionLabels.keys) {
      final inSection = items.where((i) => i.section == section);
      shownKeys.addAll(
        (insightsExpanded ? inSection : inSection.take(1)).map((i) => i.key),
      );
    }
    final hidden = items.length - shownKeys.length;
    widgets.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                key: const Key('home-insights'),
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text('今週の気づき ${items.length}件'),
                subtitle: Text(
                  [
                    '${hubToday(insights.createdAt)}に、たまったメモをAIがまとめて読み直した結果（AIの推定・未検証）',
                    if (insights.mode == 'quiet') '新しいメモが少なかったので、以前のメモの見直しが中心',
                    if (insights.stale(now)) '$age日前の結果',
                    if (insights.waiting > 0)
                      '根拠のメモが届いていない${insights.waiting}件は、届いてから表示',
                  ].join(' · '),
                ),
              ),
              // 1件ずつ線で区切り、欄の名前・本文・根拠・反応をその中にまとめる。
              // 線がないと、反応のボタンが次の気づきの上に付いているように見えていた。
              for (final section in insightSectionLabels.keys)
                for (final (i, item)
                    in items
                        .where(
                          (i) =>
                              i.section == section && shownKeys.contains(i.key),
                        )
                        .indexed) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  insightEntry(item, firstInSection: i == 0),
                ],
              if (hidden > 0 || insightsExpanded) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
                  child: TextButton(
                    key: const Key('home-insights-more'),
                    onPressed: () =>
                        refresh(() => insightsExpanded = !insightsExpanded),
                    child: Text(insightsExpanded ? 'たたむ' : 'ほか$hidden件を表示'),
                  ),
                ),
              ] else
                const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    return widgets;
  }

  /// 今週の気づきの項目へ反応を付ける（同じ反応をもう一度押すと外す）。
  Future<void> reactToInsight(
    String runId,
    InsightItem item,
    String reaction,
  ) async {
    try {
      final result = await c.requestInsightReaction(runId, item.key, reaction);
      if (mounted && !result.saved) {
        notice(context, '保存結果を確認できません。保存と反映から同じ操作を確認してください。');
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 今週の気づきの1件。本文はAIが書いたもので、そのまま文字として出す（Markdownとして解釈しない）。
  /// 反応（役に立った・的外れ）を付けられ、問いと止まっている意図には答えられる。
  Widget insightEntry(InsightItem item, {bool firstInSection = false}) {
    // 反応と答えに対応していない本体には、依頼を出さない。
    final runId = repo.insights?.feedback == true ? repo.insights?.runId : null;
    final (:reaction, :pending) = repo.insightReactionOf(item);
    final theme = Theme.of(context);
    // 根拠・答えのメモへのリンクは、本文の下に小さく並べる。
    Widget memoLink(Key key, IconData icon, String label, String inputId) =>
        sourceLink(
          context,
          key: key,
          icon: icon,
          label: label,
          onPressed: () {
            final record = repo.inputRecord(inputId);
            if (record != null) open(record.id);
          },
        );
    Widget links(String label, List<Widget> children) => Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 2),
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        ...children,
      ],
    );
    return Padding(
      key: Key('home-insight-${item.key}'),
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 欄の名前は各件の頭に付ける（たたんだ欄を開いても、どの欄の気づきかが分かる）。
          Text(
            insightSectionLabels[item.section] ?? item.section,
            key: firstInSection ? Key('home-insights-${item.section}') : null,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(item.text, style: const TextStyle(height: 1.6)),
          if (item.firstStep != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '最初の一歩: ${item.firstStep}',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ),
          const SizedBox(height: 4),
          links('根拠', [
            for (final source in item.sources)
              memoLink(
                Key('home-insight-source-${item.key}-${source.inputId}'),
                Icons.article_outlined,
                '${hubToday(source.at)}のメモ${source.corrected ? '（訂正あり）' : ''}',
                source.inputId,
              ),
          ]),
          if (item.answers.isNotEmpty)
            links('答え', [
              for (final answer in item.answers)
                memoLink(
                  Key('home-insight-answered-${item.key}-${answer.inputId}'),
                  Icons.chat_bubble_outline,
                  '${hubToday(answer.at)}のメモ',
                  answer.inputId,
                ),
            ]),
          // 反応と答えるは、根拠の下にこの気づきへの操作としてまとめる。
          if (runId != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: rowActions(
                context,
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final value in const ['useful', 'off-target'])
                      ChoiceChip(
                        key: Key('home-insight-$value-${item.key}'),
                        label: Text(insightReactionLabels[value]!),
                        avatar: Icon(
                          value == 'useful'
                              ? Icons.thumb_up_alt_outlined
                              : Icons.thumb_down_alt_outlined,
                          size: 14,
                        ),
                        labelStyle: const TextStyle(fontSize: 12.5),
                        // 印と文字の間を詰める（既定では印の後ろが広く空く）。
                        labelPadding: const EdgeInsets.only(left: 2, right: 6),
                        visualDensity: VisualDensity.compact,
                        selected: reaction == value,
                        tooltip: reaction == value ? 'もう一度押すと反応を外します' : null,
                        onSelected: busy
                            ? null
                            : (_) => reactToInsight(
                                runId,
                                item,
                                reaction == value ? 'none' : value,
                              ),
                      ),
                    if (insightAnswerSections.contains(item.section))
                      TextButton.icon(
                        key: Key('home-insight-answer-${item.key}'),
                        onPressed: busy
                            ? null
                            : () => showCapture(
                                context,
                                c,
                                answer: InsightAnswerTarget(
                                  runId: runId,
                                  itemKey: item.key,
                                  question: item.text,
                                ),
                              ),
                        icon: const Icon(Icons.edit_note, size: 18),
                        label: const Text('答える'),
                      ),
                    if (pending)
                      Text(
                        '反映待ち',
                        key: Key('home-insight-pending-${item.key}'),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
