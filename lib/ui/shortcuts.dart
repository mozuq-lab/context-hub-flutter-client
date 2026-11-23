import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'parts.dart';

/// キーボード操作の対応表。画面のショートカット、Macのメニューバー、「キーボード操作」の一覧で共用する。
/// Macでは⌘、ほかの端末（Androidの物理キーボードなど）ではCtrlを使う。
bool get usesCommandKey => defaultTargetPlatform == TargetPlatform.macOS;

/// 修飾キー（⌘またはCtrl）付きのキー。
SingleActivator primaryKey(LogicalKeyboardKey key, {bool shift = false}) =>
    SingleActivator(
      key,
      meta: usesCommandKey,
      control: !usesCommandKey,
      shift: shift,
      // 押し続けても繰り返さない（文脈のコピーなどを重ねて実行しない）。
      includeRepeats: false,
    );

/// 一覧に出すキーの表記。
String keyLabel(SingleActivator a) {
  final mac = usesCommandKey;
  final name = switch (a.trigger) {
    LogicalKeyboardKey.enter => mac ? 'Return' : 'Enter',
    LogicalKeyboardKey.escape => 'Esc',
    final k => k.keyLabel.toUpperCase(),
  };
  final mods = [
    if (a.control) mac ? '⌃' : 'Ctrl+',
    if (a.shift) mac ? '⇧' : 'Shift+',
    if (a.meta) '⌘',
  ].join();
  return '$mods$name';
}

/// 画面の移動先。毎日使う画面（ナビゲーションの上段）から順に⌘1〜⌘8を割り当てる。
/// 中身や本体の対応があるときだけナビゲーションに出る画面（いつかやる・記録に聞く・文脈かご）には、番号を割り当てない。
const shortcutPages = [
  ('home', 'ホーム'),
  ('next', '次の一手'),
  ('review', '確認待ち'),
  ('recent', '最近のメモ'),
  ('digest', 'ふりかえり'),
  ('ideas', 'アイデア'),
  ('search', '検索'),
  ('intake', '保存と反映'),
];
const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
];

/// アプリ全体の操作。
enum HubCommand {
  newMemo('メモを追加'),
  guided('質問に答えてまとめる'),
  search('検索'),
  reload('再読込'),
  copyContext('表示中のプロジェクトの文脈をコピー'),
  settings('設定'),
  keyboardHelp('キーボード操作');

  const HubCommand(this.label);
  final String label;

  SingleActivator get activator => switch (this) {
    HubCommand.newMemo => primaryKey(LogicalKeyboardKey.keyN),
    HubCommand.guided => primaryKey(LogicalKeyboardKey.keyN, shift: true),
    HubCommand.search => primaryKey(LogicalKeyboardKey.keyF),
    HubCommand.reload => primaryKey(LogicalKeyboardKey.keyR),
    HubCommand.copyContext => primaryKey(LogicalKeyboardKey.keyC, shift: true),
    HubCommand.settings => primaryKey(LogicalKeyboardKey.comma),
    HubCommand.keyboardHelp => primaryKey(LogicalKeyboardKey.slash),
  };
}

/// 画面の移動（⌘1〜⌘8）。
SingleActivator pageActivator(int index) => primaryKey(_digits[index]);

/// 入力フォームで保存するキー（⌘Return / Ctrl+Enter）。
SingleActivator get saveFormActivator => primaryKey(LogicalKeyboardKey.enter);

class HubCommandIntent extends Intent {
  const HubCommandIntent(this.command);
  final HubCommand command;
}

class GoToPageIntent extends Intent {
  const GoToPageIntent(this.page);
  final String page;
}

/// 画面全体で受け付けるショートカット。
Map<ShortcutActivator, Intent> hubShortcuts() => {
  for (final command in HubCommand.values)
    command.activator: HubCommandIntent(command),
  for (var i = 0; i < shortcutPages.length; i++)
    pageActivator(i): GoToPageIntent(shortcutPages[i].$1),
};

/// 「キーボード操作」の一覧。
Future<void> showKeyboardHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) {
    final rows = <(String, String)>[
      for (final command in HubCommand.values)
        if (command != HubCommand.keyboardHelp)
          (keyLabel(command.activator), command.label),
      (
        '${keyLabel(pageActivator(0))}〜${keyLabel(pageActivator(shortcutPages.length - 1))}',
        shortcutPages.map((p) => p.$2).join('・'),
      ),
      (keyLabel(saveFormActivator), 'メモ・訂正のフォームで保存'),
      ('Esc', 'メモ・訂正のフォームを閉じる（書きかけがないとき）'),
      (keyLabel(HubCommand.keyboardHelp.activator), 'この一覧'),
    ];
    return AlertDialog(
      key: const Key('keyboard-help'),
      title: const Text('キーボード操作'),
      content: SizedBox(
        width: 520,
        child: DialogScroll(
          child: Table(
            columnWidths: const {0: IntrinsicColumnWidth()},
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (final (key, label) in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 6, 20, 6),
                      child: Text(
                        key,
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(label),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    );
  },
);
