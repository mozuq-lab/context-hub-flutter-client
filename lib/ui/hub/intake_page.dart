import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../../storage/capture_service.dart';
import '../labels.dart';
import '../notice.dart';
import '../parts.dart';
import 'hub_common.dart';
import 'hub_view.dart';

/// 保存と反映（この端末から保存した依頼の状況と取り下げ）。
extension HubIntake on HubViewState {
  /// この端末が保存した、まだ受け付けられていない依頼を取り下げる。
  Future<void> withdrawRequest(IntakeStatus status) async {
    if (!await confirmAction(
          '依頼を取り下げる',
          '${status.title}\n\nこの端末が保存した依頼のファイル（添えたファイルを含む）を消します。同期で削除がMac miniへ伝わる前に受け付けられた場合は取り下げは間に合わず、「取り下げた依頼」にそう示します。',
          '取り下げる',
        ) ||
        !mounted) {
      return;
    }
    try {
      await c.withdrawRequest(status.id);
      if (mounted) notice(context, '依頼を取り下げました。');
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// 保存と反映。この端末から保存した依頼と、本体での受付・整理の状況。
  List<Widget> intakeView() {
    final children = <Widget>[];
    children.add(
      title(
        '保存と反映',
        'この端末で保存したものが、Mac miniに受け取られ、反映されるまでを示します。同期の後に再読込すると進みます。',
      ),
    );
    for (final result in c.pending) {
      children.add(
        Card(
          child: ListTile(
            title: const Text('保存確認待ち'),
            subtitle: Text(result.requestId),
            trailing: TextButton(
              onPressed: c.saving
                  ? null
                  : () async {
                      try {
                        final r = await c.confirm(result.operationId);
                        if (mounted) {
                          notice(
                            context,
                            r.saved
                                ? 'この端末に保存されています'
                                : 'まだ保存を確認できません。同じ操作IDを保持しています。',
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          notice(context, HubController.message(e));
                        }
                      }
                    },
              child: const Text('同じ操作を確認'),
            ),
          ),
        ),
      );
    }
    if (repo.intake.isEmpty &&
        c.pending.isEmpty &&
        c.withdrawnRequests.isEmpty) {
      children.add(emptyText(context, 'この端末から保存したものはありません。'));
    }
    if (repo.intake.isNotEmpty) {
      children.add(
        groupCard([
          for (final status in repo.intake)
            ListTile(
              title: Text(intakeStateLabel(status.state)),
              subtitle: Text(
                [
                  status.title,
                  timeLabel(status.at),
                  if (status.detail.isNotEmpty) status.detail,
                  ?intakeNextStep(status.state),
                ].join('\n'),
                style: const TextStyle(height: 1.7),
              ),
              // この端末が保存し、まだ受け付けられていない依頼は取り下げられる。
              trailing: c.canWithdraw(status)
                  ? TextButton(
                      key: Key('withdraw-${status.id}'),
                      onPressed: c.saving || c.loading
                          ? null
                          : () => withdrawRequest(status),
                      child: const Text('取り下げる'),
                    )
                  : null,
              onTap: () {
                showDialog<void>(
                  context: context,
                  // 閉じるときは、ダイアログ自身のcontextで閉じる。画面のcontextで閉じると、
                  // 本文の領域のNavigatorから一覧の画面を外してしまい、ダイアログは残る。
                  builder: (dialog) => HubAlertDialog(
                    title: Text(intakeStateLabel(status.state)),
                    onClose: () => Navigator.pop(dialog),
                    content: SelectableText('${status.id}\n${status.detail}'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: const Text('閉じる'),
                      ),
                    ],
                  ),
                );
              },
            ),
        ]),
      );
    }
    // この端末で取り下げた依頼。受付の記録が後から届いたら、間に合わなかったと示す。
    if (c.withdrawnRequests.isNotEmpty) {
      children.add(
        sectionHeading(
          '取り下げた依頼',
          key: const Key('intake-withdrawn'),
          note:
              'この端末で取り下げた依頼です（$withdrawnKeepDays日間示します）。Mac miniへ削除が伝わる前に受け付けられた場合は「間に合いませんでした」と示します。',
        ),
      );
      children.add(
        groupCard([
          for (final w in c.withdrawnRequests.reversed)
            ListTile(
              key: Key('withdrawn-${w.requestId}'),
              title: Text(
                repo.snapshot.files.containsKey(
                      '90_system/intake/${w.requestId}.json',
                    )
                    ? '取り下げが間に合いませんでした'
                    : repo.snapshot.files.containsKey('Input/${w.requestId}.md')
                    ? '取り下げ中（依頼のファイルが残っています）'
                    : '取り下げました',
              ),
              subtitle: Text(
                [
                  w.title,
                  '${timeLabel(w.at)}に取り下げ',
                  if (repo.snapshot.files.containsKey(
                    '90_system/intake/${w.requestId}.json',
                  ))
                    'Mac miniが先に受け取りました。訂正・未解決に戻す・外すなど、その依頼に合う逆の操作をしてください。',
                ].join('\n'),
                style: const TextStyle(height: 1.7),
              ),
            ),
        ]),
      );
    }
    return children;
  }
}
