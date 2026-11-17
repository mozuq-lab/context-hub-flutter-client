import 'package:flutter/material.dart';

/// 画面全体の枠（サイドバー・メニュー）を、その中に開いた詳細画面から使えるようにする。
///
/// 詳細画面は本文の領域の中に重ねて開くため、広い画面ではサイドバーが残り、
/// 「戻る」を経ずにほかの画面へ移れる。狭い画面ではメニュー（drawer）を開くボタンを出す。
class HubShellScope extends InheritedWidget {
  const HubShellScope({
    super.key,
    required this.openMenu,
    required super.child,
  });

  /// 狭い画面でメニューを開く。広い画面（サイドバーが見えている）ではnull。
  final VoidCallback? openMenu;

  static HubShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HubShellScope>();

  @override
  bool updateShouldNotify(HubShellScope oldWidget) =>
      (openMenu == null) != (oldWidget.openMenu == null);
}

/// 詳細画面のAppBarに置く、メニューを開くボタン。サイドバーが見えている間は何も出さない。
class HubMenuButton extends StatelessWidget {
  const HubMenuButton({super.key});
  @override
  Widget build(BuildContext context) {
    final open = HubShellScope.maybeOf(context)?.openMenu;
    if (open == null) return const SizedBox.shrink();
    return IconButton(
      key: const Key('detail-menu'),
      tooltip: 'ほかの画面へ移る',
      icon: const Icon(Icons.menu),
      onPressed: open,
    );
  }
}
