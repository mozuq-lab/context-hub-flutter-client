import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../core/preferences.dart';
import 'views.dart' show timeLabel;

/// 好み（ピン留めと並び順・メモのひな形・文脈かごの上限）をほかの端末とそろえるかを選ぶ。Vaultごとに選ぶ。
Future<void> showPreferenceSync(BuildContext context, HubController c) async {
  var busy = false;
  String? problem;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final enabled = c.preferenceSyncEnabled;
        final shared = c.repository?.sharedPreferences ?? const {};
        Future<void> run(Future<void> Function() action) async {
          setState(() {
            busy = true;
            problem = null;
          });
          try {
            await action();
          } catch (e) {
            problem = HubController.message(e);
          }
          if (context.mounted) setState(() => busy = false);
        }

        return AlertDialog(
          key: const Key('preference-sync-dialog'),
          title: const Text('好みを端末間でそろえる'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${preferenceGroups.map((g) => preferenceGroupLabels[g]).join('・')}を、同じVaultを使うほかの端末（MacとAndroid）とそろえます。'
                    '変えたときに受付ファイルでMiniへ送り、Miniがまとまりごとに新しい方を残します。ほかの端末は読み込んだときに取り込みます。'
                    '既読・ウインドウ・通知・APIキーのような、この端末だけの設定は送りません。',
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  if (!c.preferenceSyncSupported && !enabled)
                    const Text(
                      'Mac miniの本体が好みの共有に対応していません。本体を更新してください。',
                      key: Key('preference-sync-unsupported'),
                    )
                  else if (enabled) ...[
                    const Text('このVaultでは、ほかの端末とそろえています。'),
                    for (final g in preferenceGroups)
                      if (shared[g] case final entry?)
                        Text(
                          '${preferenceGroupLabels[g]}: ${timeLabel(entry.updatedAt)}の変更',
                          style: const TextStyle(fontSize: 12),
                        ),
                    if (c.preferenceNotice case final text?)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          text,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ] else ...[
                    Text(
                      shared.isEmpty
                          ? 'Vaultにはまだ好みの記録がありません。この端末の好みを送ってそろえ始めます。'
                          : 'Vaultには、ほかの端末が送った好み（${shared.keys.map((g) => preferenceGroupLabels[g]).join('・')}）があります。どちらにそろえるか選んでください。',
                    ),
                  ],
                  if (problem case final text?)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        text,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
            if (enabled)
              TextButton(
                key: const Key('preference-sync-off'),
                onPressed: busy ? null : () => run(c.disablePreferenceSync),
                child: const Text('そろえるのをやめる'),
              )
            else if (c.preferenceSyncSupported) ...[
              if (shared.isNotEmpty)
                TextButton(
                  key: const Key('preference-sync-use-vault'),
                  onPressed: busy
                      ? null
                      : () => run(() => c.enablePreferenceSync(useVault: true)),
                  child: const Text('Vaultにある設定を使う'),
                ),
              FilledButton(
                key: const Key('preference-sync-use-device'),
                onPressed: busy
                    ? null
                    : () => run(() => c.enablePreferenceSync(useVault: false)),
                child: const Text('この端末の設定でそろえる'),
              ),
            ],
          ],
        );
      },
    ),
  );
}
