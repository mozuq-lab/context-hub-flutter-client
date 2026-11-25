import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../notice.dart';
import '../parts.dart';

/// ピン留めしたプロジェクトの並びを変える。並びはこの端末にだけ保存し、Vaultには書かない。
class PinOrderDialog extends StatelessWidget {
  const PinOrderDialog({super.key, required this.controller});
  final HubController controller;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) notice(context, HubController.message(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final projects =
          controller.repository?.pinnedProjects ?? const <HubProject>[];
      return HubAlertDialog(
        key: const Key('pin-order-dialog'),
        title: const Text('ピン留めの並び'),
        onClose: () => Navigator.pop(context),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: DialogScroll(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ピン留めしたプロジェクトは、メニュー・ホーム・「次の一手」の先頭にこの順で並びます。並びはこの端末にだけ保存し、Vaultやほかの端末には伝わりません。',
                  style: noteStyle(context),
                ),
                const SizedBox(height: 8),
                if (projects.isEmpty) const Text('ピン留めしたプロジェクトはありません。'),
                // 幅の狭い端末でも題名を読めるよう、題名を1行使い、操作のボタンはその下に置く。
                for (final (index, project) in projects.indexed)
                  Padding(
                    key: Key('pin-row-${project.id}'),
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          project.title,
                          key: Key('pin-title-${project.id}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (project.lifecycle != 'active')
                          Text(
                            '${project.lifecycleLabel}（「次の一手」には出ません）',
                            style: noteStyle(context),
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              key: Key('pin-up-${project.id}'),
                              tooltip: '前へ',
                              onPressed: index == 0
                                  ? null
                                  : () => _run(
                                      context,
                                      () => controller.movePin(project.id, -1),
                                    ),
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              key: Key('pin-down-${project.id}'),
                              tooltip: '後ろへ',
                              onPressed: index == projects.length - 1
                                  ? null
                                  : () => _run(
                                      context,
                                      () => controller.movePin(project.id, 1),
                                    ),
                              icon: const Icon(Icons.arrow_downward, size: 18),
                            ),
                            IconButton(
                              key: Key('pin-remove-${project.id}'),
                              tooltip: 'ピン留めを外す',
                              onPressed: () => _run(
                                context,
                                () => controller.setPinned(project.id, false),
                              ),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('pin-order-close'),
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      );
    },
  );
}
