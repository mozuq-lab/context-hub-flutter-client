import 'package:flutter/material.dart';

/// 画面下に案内を出す。
///
/// 前の案内が表示中・順番待ちでも待たせず、新しい案内に置き換える。
/// SnackBarの既定では前の案内が消えるまで（約4秒）次が出ないため、続けて操作したときの結果が遅れて見えていた。
///
/// [action]を渡すと、案内の右に押せる操作を出す。
void notice(
  BuildContext context,
  String text, {
  ({String label, VoidCallback onPressed})? action,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final wide = MediaQuery.sizeOf(context).width >= 820;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        duration: noticeDuration(text),
        behavior: SnackBarBehavior.floating,
        // 広い画面では読みやすい幅にとどめ、狭い画面では左右の余白だけ空ける。
        width: wide ? 560 : null,
        showCloseIcon: true,
        action: action == null
            ? null
            : SnackBarAction(label: action.label, onPressed: action.onPressed),
      ),
    );
}

/// 案内を出しておく時間。長い文ほど長く出す（4〜10秒）。
Duration noticeDuration(String text) =>
    Duration(milliseconds: (2000 + text.length * 80).clamp(4000, 10000));
