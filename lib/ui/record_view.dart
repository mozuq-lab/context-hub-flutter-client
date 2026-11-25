import 'dart:async';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/happened.dart';
import '../core/models.dart';
import '../core/parser.dart' show clip;
import '../core/repository.dart';
import 'dialogs/capture_dialog.dart';
import 'dialogs/correction_dialog.dart';
import 'labels.dart';
import 'markdown_view.dart';
import 'notice.dart';
import 'parts.dart';
import 'reference_shelf.dart';
import 'save_checks.dart';

/// 記録を文脈かごに入れる・外すボタン。かごの変化に合わせて表示を変える。
class BasketToggle extends StatelessWidget {
  const BasketToggle({
    super.key,
    required this.controller,
    required this.record,
    this.labeled = false,
  });
  final HubController controller;
  final HubRecord record;

  /// 記録の詳細では文字付きのボタンにする。
  final bool labeled;

  Future<void> _toggle(BuildContext context) async {
    try {
      final added = await controller.toggleBasket(record.id);
      if (context.mounted) {
        notice(
          context,
          added
              ? '文脈かごに入れました（${controller.basket.ids.length}件）'
              : '文脈かごから外しました',
        );
      }
    } catch (e) {
      if (context.mounted) notice(context, HubController.message(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final inside = controller.inBasket(record.id);
      if (labeled) {
        return TextButton.icon(
          key: const Key('record-basket'),
          onPressed: () => _toggle(context),
          icon: Icon(
            inside ? Icons.check_circle : Icons.add_circle_outline,
            size: 18,
          ),
          label: Text(inside ? 'かごから外す' : '文脈かごに入れる'),
        );
      }
      return IconButton(
        key: Key('basket-toggle-${record.id}'),
        tooltip: inside ? '文脈かごから外す' : '文脈かごに入れる',
        onPressed: () => _toggle(context),
        // 一覧の行では主役の題名より目立たないよう、小さめ・控えめの色にする（入っているときだけ強調色）。
        icon: Icon(
          inside ? Icons.check_circle : Icons.add_circle_outline,
          size: 20,
          color: inside
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    },
  );
}

class RecordView extends StatelessWidget {
  const RecordView({super.key, required this.controller, required this.record});
  final HubController controller;
  final HubRecord record;
  void open(BuildContext context, String id) {
    final r = controller.repository?.records[id];
    if (r != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RecordView(controller: controller, record: r),
        ),
      );
    }
  }

  /// 原文の訂正。最新の訂正に対して書き、反映待ちの間は重ねて訂正しない。
  Widget correctionPanel(BuildContext context) {
    final repo = controller.repository;
    final chain = repo?.correctionChainOf(record.id);
    if (repo == null || chain == null) return const SizedBox.shrink();
    final latest = chain.last,
        requestId = repo.correctionRequestIdFor(record.id);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (latest.id != record.id)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NoticeBox(
                'この記録には新しい訂正があります（${latest.sourceId}）。訂正は最新の本文に対して書きます。',
              ),
            ),
          if (requestId != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NoticeBox(
                chain.first.kind == 'action'
                    ? '行動の文面の訂正を送りました。Mac miniに届くまで、現状の次の一手は直す前の文面のままです（$requestId）。'
                    : '訂正を送りました。Mac miniに届いてAIが読み取るまで、要約は訂正前の内容のままです（$requestId）。',
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('write-correction'),
                style: compactOutlinedStyle(context),
                icon: const Icon(Icons.edit_note, size: 18),
                label: Text(
                  chain.first.kind == 'action' ? '行動の文面を直す' : '訂正を書く',
                ),
                onPressed:
                    requestId != null ||
                        controller.saving ||
                        controller.composing
                    ? null
                    : () => showCorrection(
                        context,
                        controller,
                        record.id,
                        latest,
                      ),
              ),
              // 続きを書く操作も、訂正と同じ行に並べる（前のメモ・続きのリンクは下の続きの欄に出す）。
              if (repo.intakeFeatures.continues &&
                  (chain.first.kind == 'memo' ||
                      chain.first.kind == 'work-summary'))
                OutlinedButton.icon(
                  key: const Key('write-continuation'),
                  style: compactOutlinedStyle(context),
                  icon: const Icon(Icons.subdirectory_arrow_right, size: 18),
                  label: const Text('続きを書く'),
                  onPressed: controller.saving || controller.composing
                      ? null
                      : () => showCapture(
                          context,
                          controller,
                          continues: chain.first,
                        ),
                ),
              if (latest.id != record.id)
                TextButton(
                  onPressed: () => open(context, latest.id),
                  child: const Text('最新の訂正を開く'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// メモに添えたファイル（PDF・画像など）。訂正を見ているときも元のメモのファイルを示す。
  Widget attachmentPanel(BuildContext context) {
    final root =
        controller.repository?.correctionChainOf(record.id)?.first ?? record;
    final file = root.attachment;
    if (file == null) return const SizedBox.shrink();
    return Padding(
      key: const Key('record-attachment'),
      padding: const EdgeInsets.only(top: 16),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          const Icon(Icons.attach_file, size: 18),
          Text('添えたファイル: ${file.label}'),
          if (controller.access.attachmentsSupported)
            OutlinedButton(
              key: const Key('record-attachment-open'),
              style: compactOutlinedStyle(context),
              onPressed: () => openHubFile(context, controller, file),
              child: const Text('開く'),
            ),
        ],
      ),
    );
  }

  /// 整理（AIの読み取り）に失敗したメモの、失敗の理由と「整理をやり直す」。
  /// 本人が頼んだ1件だけを、次の整理でもう一度試す（本体が1回だけ試し、原文は変えない）。
  /// 資料棚に載っているか、と資料に加える・名前を変える・外す・戻す操作。資料の一覧を書く本体にだけ出す。
  Widget referencePanel(BuildContext context) {
    final repo = controller.repository;
    if (repo == null || repo.referenceIndex == null) {
      return const SizedBox.shrink();
    }
    // 訂正を見ているときも、資料の記録は元の入力に付ける。
    final root = repo.correctionChainOf(record.id)?.first ?? record;
    if (root.kind != 'memo' && root.kind != 'work-summary') {
      return const SizedBox.shrink();
    }
    final inputId = root.sourceId;
    final entry = repo.referenceEntryOf(inputId),
        removed = entry == null ? repo.removedReferenceOf(inputId) : null,
        pending = repo.referenceRequestIdFor(inputId) != null,
        editable = repo.intakeFeatures.references && !controller.saving;
    final status = entry != null
        ? '資料棚にあります: ${entry.label}${entry.addedByPerson ? '' : '（AIが参考資料と読み取り）'}'
        : removed != null
        ? '資料棚から外しています。'
        : '資料棚にはありません。';
    return Padding(
      key: const Key('reference-panel'),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status,
            key: const Key('reference-status'),
            style: const TextStyle(fontSize: 12),
          ),
          if (pending)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '資料棚への依頼が反映待ちです。',
                key: Key('reference-requested'),
                style: TextStyle(fontSize: 12),
              ),
            )
          else if (repo.intakeFeatures.references)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (entry == null && removed == null)
                    OutlinedButton.icon(
                      key: const Key('reference-add'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('資料に加える'),
                      onPressed: editable
                          ? () => renameReference(
                              context,
                              controller,
                              inputId,
                              adding: true,
                            )
                          : null,
                    ),
                  if (removed != null)
                    OutlinedButton.icon(
                      key: const Key('reference-restore'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: const Text('資料棚に戻す'),
                      onPressed: editable
                          ? () => sendReferenceMark(
                              context,
                              controller,
                              inputId,
                              'add',
                              title: removed.title,
                              done: '資料棚に戻す依頼をしました。',
                            )
                          : null,
                    ),
                  if (entry != null) ...[
                    OutlinedButton.icon(
                      key: const Key('reference-rename'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('資料の名前を変える'),
                      onPressed: editable
                          ? () => renameReference(
                              context,
                              controller,
                              inputId,
                              current: entry.title,
                              aiSummary: entry.aiSummary,
                            )
                          : null,
                    ),
                    OutlinedButton.icon(
                      key: const Key('reference-remove'),
                      style: compactOutlinedStyle(context),
                      icon: const Icon(
                        Icons.bookmark_remove_outlined,
                        size: 18,
                      ),
                      label: const Text('資料棚から外す'),
                      onPressed: editable
                          ? () => removeReference(
                              context,
                              controller,
                              inputId,
                              entry.label,
                            )
                          : null,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget retryPanel(BuildContext context) {
    final repo = controller.repository;
    if (repo == null) return const SizedBox.shrink();
    final attempts = repo.failedAttemptsFor(record.sourceId);
    if (attempts == null) return const SizedBox.shrink();
    final retryable = repo.organizeRetryable(record.sourceId);
    final requested = repo.organizeRetryRequestIdFor(record.sourceId) != null,
        queued = repo.organizeRetryQueued(record.sourceId),
        supported = repo.intakeFeatures.organizeRetry,
        error = repo.organizeErrorFor(record.sourceId);
    return Padding(
      key: const Key('organize-retry-panel'),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AIの読み取り（整理）に失敗しています（$attempts回試しました）。原文は残っています。',
            style: const TextStyle(fontSize: 12),
          ),
          if (error != null && error.isNotEmpty)
            Text(
              '理由: ${clip(error.replaceAll(RegExp(r'\s+'), ' '), 160)}',
              key: const Key('organize-error'),
              style: const TextStyle(fontSize: 12),
            ),
          if (requested || queued)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                queued ? 'やり直しを頼みました。次の整理でもう一度試します。' : 'やり直しを依頼済みです（反映待ち）。',
                key: const Key('organize-retry-requested'),
                style: const TextStyle(fontSize: 12),
              ),
            )
          else if (supported && !retryable)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '訂正が届いている（または依頼中の）メモは、訂正した後のメモが整理されます。',
                key: Key('organize-retry-superseded'),
                style: TextStyle(fontSize: 12),
              ),
            )
          else if (supported)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                key: const Key('organize-retry'),
                icon: const Icon(Icons.refresh),
                label: const Text('整理をやり直す'),
                onPressed: controller.saving
                    ? null
                    : () async {
                        try {
                          final result = await controller.requestOrganizeRetry(
                            record.sourceId,
                          );
                          if (context.mounted) {
                            notice(
                              context,
                              result.saved
                                  ? 'やり直しを依頼しました。次の整理でもう一度試します。'
                                  : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            notice(context, HubController.message(e));
                          }
                        }
                      },
              ),
            ),
        ],
      ),
    );
  }

  /// 続き。前のメモとこのメモの続きをたどり、このメモの続きを書ける（訂正とは別に、前のメモを残したまま追記する）。
  Widget continuationPanel(BuildContext context) {
    final repo = controller.repository;
    final chain = repo?.correctionChainOf(record.id);
    if (repo == null || chain == null) return const SizedBox.shrink();
    final root = chain.first;
    if (root.kind != 'memo' && root.kind != 'work-summary') {
      return const SizedBox.shrink();
    }
    final previous = repo.previousOf(root),
        missing = root.metadata['continues_input_id'],
        later = repo.continuationsOf(root.sourceId);
    // 続きを書く操作は訂正の欄に並べるので、ここには前のメモと続きがあるときだけ出す。
    if (previous == null && missing == null && later.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget link(HubRecord r) => TextButton(
      key: Key('continuation-${r.sourceId}'),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
      ),
      onPressed: () => open(context, r.id),
      child: Text(
        '${timeLabel(r.at)} ${clip(r.title.replaceAll(RegExp(r'\s+'), ' '), 60)}',
        textAlign: TextAlign.left,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (previous != null) ...[
            const Text('前のメモ', style: TextStyle(fontSize: 12)),
            link(previous),
          ] else if (missing is String)
            Text(
              '前のメモ（$missing）はまだ届いていません。',
              style: const TextStyle(fontSize: 12),
            ),
          if (later.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('続き（${later.length}件）', style: const TextStyle(fontSize: 12)),
            for (final r in later) link(r),
          ],
        ],
      ),
    );
  }

  /// 似ているアイデアと束ねたアイデア。束ねる・別の話にする判断を依頼できる。
  /// アイデアを「いつかやる」に置く操作。置いてあれば、そう示す（見直しは「いつかやる」の画面で行う）。
  Widget ideaSomedayPanel(BuildContext context) {
    final repo = controller.repository;
    final id = record.sourceId;
    if (repo == null || !repo.intakeFeatures.someday) {
      return const SizedBox.shrink();
    }
    final Widget child;
    if (repo.somedayReviewRequestIdFor('idea', id) != null) {
      child = Text('「いつかやる」を依頼済み（反映待ち）', style: noteStyle(context));
    } else if (repo.somedayIdea(id)) {
      child = const Text(
        '「いつかやる」に置いています。見直しは「いつかやる」の画面で行います。',
        key: Key('idea-someday-listed'),
        style: TextStyle(fontSize: 12),
      );
    } else if (repo.somedayGeneratedAt == null) {
      // 本体の一覧がまだないときは、置いてあるか分からないので操作を出さない。
      return const SizedBox.shrink();
    } else {
      child = OutlinedButton.icon(
        key: const Key('idea-someday'),
        onPressed: controller.saving || controller.loading
            ? null
            : () => sendIdeaSomeday(context, controller, id, record.title),
        icon: const Icon(Icons.inventory_2_outlined, size: 18),
        label: const Text('「いつかやる」に置く'),
      );
    }
    return Padding(padding: const EdgeInsets.only(top: 16), child: child);
  }

  Widget ideaPanel(BuildContext context) {
    final repo = controller.repository;
    if (repo == null) return const SizedBox.shrink();
    final me = record.sourceId,
        group = repo.ideaGroupOf(me),
        similar = repo.similarIdeas(me);
    if (group == null && similar.isEmpty) return const SizedBox.shrink();
    final busy = controller.saving || controller.loading;
    Widget pairActions(String other, {required bool candidate}) {
      final requestId = repo.ideaLinkRequestIdFor(me, other);
      if (requestId != null) {
        return Text(
          '依頼済み（$requestId）。Mac miniで処理されると反映されます。',
          style: const TextStyle(fontSize: 12),
        );
      }
      return Wrap(
        spacing: 8,
        children: [
          if (candidate)
            FilledButton.tonal(
              key: Key('idea-link-$other'),
              onPressed: busy
                  ? null
                  : () => sendIdeaLink(context, controller, me, other, 'link'),
              child: const Text('同じ話として束ねる'),
            ),
          TextButton(
            key: Key('idea-separate-$other'),
            onPressed: busy
                ? null
                : () =>
                      sendIdeaLink(context, controller, me, other, 'separate'),
            child: Text(candidate ? '別の話' : '束から外す'),
          ),
        ],
      );
    }

    Widget ideaCard(String id, {String? note, Widget? actions}) {
      final r = repo.ideaRecord(id)!;
      return Card(
        key: Key('idea-related-$id'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.title),
                subtitle: note == null ? null : Text(note),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(context, r.id),
              ),
              ?actions,
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (group != null) ...[
            sectionTitle(
              context,
              '束ねたアイデア（${group.ideas.length}件）',
              top: 0,
              note: '本人が同じ話と判断したアイデアです。検索では1件にまとめて表示します（本体の検索）。',
            ),
            for (final id in group.ideas.where((id) => id != me))
              ideaCard(
                id,
                note: [
                  if (id == group.representative) '代表（元のメモが最も新しい）',
                  if (!group.linksDirectly(me, id)) '別のアイデアを通して束ねています',
                ].join(' · ').nullIfEmpty,
                actions: group.linksDirectly(me, id)
                    ? pairActions(id, candidate: false)
                    : null,
              ),
            const SizedBox(height: 16),
          ],
          if (similar.isNotEmpty) ...[
            sectionTitle(
              context,
              '似ているアイデア（${similar.length}件）',
              top: 0,
              note: '文字の重なりから見つけた候補です（AIは使っていません）。同じ話なら束ねると、どこまで考えたかを1か所で追えます。違う話なら「別の話」を選ぶと、次から候補に出しません。',
            ),
            for (final c in similar)
              ideaCard(
                c.other(me),
                note: '似ている度合い ${c.score.toStringAsFixed(2)}',
                actions: pairActions(c.other(me), candidate: true),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('記録の詳細'),
      actions: [
        if (HubRepository.bundleKinds.contains(record.kind))
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: BasketToggle(
              controller: controller,
              record: record,
              labeled: true,
            ),
          ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: pagePadding(context).copyWith(bottom: 48),
          children: [
            Text(
              record.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '${originLabel(record.origin)} · ${stateLabel(record.status)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (happenedOf(record) case final h?)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${h.date}のこと（${displayTime(h.recordedAt)}に記録）',
                  key: const Key('record-happened'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 20),
            for (final warning in record.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NoticeBox(warning),
              ),
            // 本文は1枚の面に載せ、下の操作や出典と分ける。
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: SafeMarkdown(
                  text: record.body,
                  sourcePath: record.path,
                  controller: controller,
                  onRecord: (id) => open(context, id),
                ),
              ),
            ),
            if (record.kind == 'idea')
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => ideaSomedayPanel(context),
              ),
            if (record.kind == 'idea')
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => ideaPanel(context),
              ),
            if (const [
              'memo',
              'work-summary',
              'action',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => correctionPanel(context),
              ),
            if (const [
              'memo',
              'work-summary',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => continuationPanel(context),
              ),
            if (const [
              'memo',
              'work-summary',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => retryPanel(context),
              ),
            if (const ['memo', 'correction'].contains(record.kind))
              attachmentPanel(context),
            if (const [
              'memo',
              'work-summary',
              'correction',
            ].contains(record.kind))
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => referencePanel(context),
              ),
            sectionTitle(context, '出典・日時', top: 32),
            SelectableText(
              '${record.sourceId}\n${record.path}\n入力元: ${record.source}\n${recordTimeLines(record)}\nMac miniが受け取った時刻: ${timeLabel(record.receivedAt)}\n生成: ${timeLabel(record.generatedAt)}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(height: 1.9),
            ),
            for (final id in record.references)
              TextButton(
                onPressed: () => open(context, id),
                child: Text(controller.repository?.records[id]?.title ?? '出典'),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 似ているアイデアの組を束ねる・別の話にする依頼を、確認してから保存する。
/// アイデアを「いつかやる」に置く依頼。置くかは本人が決め、AIは置かない。
Future<void> sendIdeaSomeday(
  BuildContext context,
  HubController c,
  String ideaId,
  String title,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => HubAlertDialog(
      title: const Text('「いつかやる」に置く'),
      onClose: () => Navigator.pop(dialog, false),
      content: Text(
        '「$title」を、今は取り組まないアイデアとして「いつかやる」に置くよう依頼します。「いつかやる」の画面で、ほかの項目と一緒に見直せます。アイデアと元のメモは変わりません。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('idea-someday-confirm'),
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('置く'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final result = await c.requestSomedayReview('idea', ideaId, 'add');
    if (context.mounted) {
      notice(
        context,
        result.saved
            ? '「いつかやる」に置く依頼を保存しました。Mac miniで処理されると反映されます。'
            : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
      );
    }
  } catch (e) {
    if (context.mounted) notice(context, HubController.message(e));
  }
}

Future<void> sendIdeaLink(
  BuildContext context,
  HubController c,
  String me,
  String other,
  String action,
) async {
  final repo = c.repository;
  // 確認の画面に出す時点の内容を覚えておき、確認の間に変わっていれば依頼しない。
  final seenMe = c.ideaSeenHash(me), seenOther = c.ideaSeenHash(other);
  if (seenMe == null || seenOther == null) {
    notice(context, 'アイデアが見つかりません。再読込してください。');
    return;
  }
  final title = repo?.ideaRecord(other)?.title ?? other;
  final linked = repo?.ideaGroupOf(me)?.linksDirectly(me, other) ?? false;
  final (heading, body, verb) = action == 'link'
      ? ('同じ話として束ねる', '「$title」と同じ話として束ねるよう依頼します。アイデアと元のメモは変わりません。', '束ねる')
      : linked
      ? ('束から外す', '「$title」との束ねを外すよう依頼します。次からは似ているアイデアの候補にも出しません。', '外す')
      : ('別の話にする', '「$title」とは別の話として、次から候補に出さないよう依頼します。', '別の話にする');
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => HubAlertDialog(
      title: Text(heading),
      onClose: () => Navigator.pop(dialog, false),
      content: Text('$body依頼は保存され、Mac miniで処理されると反映されます。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('idea-link-confirm'),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(verb),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final result = await c.requestIdeaLink(
      me,
      other,
      action,
      seenA: seenMe,
      seenB: seenOther,
    );
    if (context.mounted) {
      notice(
        context,
        result.saved
            ? '依頼を保存しました。Mac miniで処理されると反映されます。'
            : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
      );
    }
  } catch (e) {
    if (context.mounted) notice(context, HubController.message(e));
  }
}
