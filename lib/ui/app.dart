import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app/controller.dart';
import 'views.dart';
import 'preference_sync_view.dart';
import 'guided_view.dart';
import '../core/models.dart';
import '../core/home_widget.dart';
import '../core/capture_progress.dart';
import '../app_version.dart';
import 'shortcuts.dart';
import 'theme.dart';

class ContextHubApp extends StatelessWidget {
  const ContextHubApp({super.key, required this.controller});
  final HubController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ContextHub',
    debugShowCheckedModeBanner: false,
    theme: hubTheme(Brightness.light),
    darkTheme: hubTheme(Brightness.dark),
    home: HubShell(controller: controller),
  );
}

class HubShell extends StatefulWidget {
  const HubShell({super.key, required this.controller});
  final HubController controller;
  @override
  State<HubShell> createState() => _HubShellState();
}

class _HubShellState extends State<HubShell> {
  String page = 'home';
  final searchFocus = FocusNode(debugLabel: 'search-query');

  /// 本文の領域の画面の重なり。記録や候補の詳細はここへ開き、サイドバーを残す。
  final contentNavigator = GlobalKey<NavigatorState>();
  final shellScaffold = GlobalKey<ScaffoldState>();

  /// 詳細を開いたときのVault。Vaultが変わったら、前のVaultの詳細を閉じる。
  String? shownVault;

  /// 画面全体のショートカットを受けるフォーカス。入力欄が消えて画面の外へ外れたら、ここへ戻す。
  final shellFocus = FocusNode(debugLabel: 'hub-shell');
  HubController get c => widget.controller;

  /// 前面に戻ったこと・前面にある間の時間の経過を受けて、同期で届いた変更を確かめる。
  late final AppLifecycleListener _lifecycle;
  Timer? _autoReloadTimer;

  /// 前面に戻ったときは、この時間より前に読み込んでいたら確かめる（すぐ切り替えたときに読み直さない）。
  static const _resumeAfter = Duration(seconds: 20);
  @override
  void initState() {
    super.initState();
    // ショートカットやウィジェットからの起動は、保存先を読み終えてから扱う。
    c.restore().whenComplete(_launch);
    c.access.listenLaunchActions(_launch);
    FocusManager.instance.addListener(keepFocus);
    c.addListener(_announce);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        final checked = c.lastCheckedAt;
        if (checked == null ||
            DateTime.now().difference(checked) >= _resumeAfter) {
          _autoReload();
        }
        _startAutoReloadTimer();
      },
      onHide: () => _autoReloadTimer?.cancel(),
    );
    _startAutoReloadTimer();
  }

  void _startAutoReloadTimer() {
    _autoReloadTimer?.cancel();
    final every = c.autoReloadInterval;
    if (every == null) return;
    _autoReloadTimer = Timer.periodic(every, (_) => _autoReload());
  }

  /// 同期で届いた変更を、表示を止めずに読み込む。入力・確認の途中や読込中は、次の機会に回す。
  Future<void> _autoReload() async {
    if (!mounted || !c.autoReload || !idle) return;
    await c.refreshQuietly();
  }

  /// この端末から保存したメモが、Miniで受け付けられた・整理された・受け付けられなかったことを知らせる。
  void _announce() {
    if (!mounted || !c.hasCaptureNotices) return;
    // 入力・確認の途中は待ち、閉じた後の次の変化で知らせる。
    if (c.saving || c.composing) return;
    final notices = c.takeCaptureNotices();
    final message = captureNoticeText(notices);
    if (message.text.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notice(
        context,
        message.text,
        action: (
          label: message.page == 'intake' ? '保存と反映' : '最近のメモ',
          onPressed: () {
            if (idle && c.repository != null) show(message.page);
          },
        ),
      );
    });
  }

  /// 読込が終わるまで待つ。
  Future<void> _idle() {
    if (!c.loading) return Future.value();
    final done = Completer<void>();
    void check() {
      if (!c.loading && !done.isCompleted) {
        c.removeListener(check);
        done.complete();
      }
    }

    c.addListener(check);
    return done.future;
  }

  /// アイコン長押しのショートカットやウィジェットで選んだ操作を開く。
  /// 開くだけで、保存や依頼は通常の画面と同じ確認を通る。
  Future<void> _launch() async {
    String? action;
    try {
      action = await c.access.takeLaunchAction();
      if (action != null) await _idle();
    } catch (_) {
      // 起動時の操作を読めなくても、通常の画面は使える。
      return;
    }
    if (action == null || !mounted) return;
    final navigator = Navigator.of(context);
    // 入力・保存・確認の途中には割り込まず、開けなかったことを知らせる。
    // 本文の領域に開いた選択肢の一覧なども、確認の途中として扱う。
    if (c.composing ||
        c.saving ||
        topRoute(navigator) is PopupRoute ||
        contentPopupOpen) {
      notice(context, '開いている入力や確認を閉じてから、もう一度お試しください。');
      return;
    }
    if (c.repository == null) {
      notice(
        context,
        c.location == null
            ? '先にVaultフォルダーを選んでください。'
            : 'Vaultを読み込めていません。再読込してから、もう一度お試しください。',
      );
      return;
    }
    if ((action == 'attention' || action == 'due') &&
        DateTime.now().difference(c.repository!.snapshot.loadedAt) >
            const Duration(seconds: 10)) {
      // アプリを開いたままだった場合は、通知のもとになった同期済みの内容を読み込んでから開く。
      await c.reload();
      if (!mounted) return;
    }
    if (action == 'next' || action == 'attention' || action == 'due') {
      // 記録の詳細などを開いていたら閉じて、次の一手の一覧（確認待ちの通知からは、増えた判断待ちを判断できる画面）へ戻る。
      navigator.popUntil((route) => route.isFirst);
      if (action == 'due') c.dueOpened++;
      show(action == 'attention' ? c.attentionLanding : 'next');
      return;
    }
    if (c.captureWarning != null) {
      notice(context, '保存の確認情報を読めません。保存と反映を確認してください。');
      return;
    }
    // 記録の詳細などを開いていても、その上に開く。
    if (action == 'capture') {
      await showCapture(context, c);
    } else if (action == 'guided') {
      await showGuided(context, c);
    }
  }

  @override
  void dispose() {
    _autoReloadTimer?.cancel();
    _lifecycle.dispose();
    c.removeListener(_announce);
    FocusManager.instance.removeListener(keepFocus);
    searchFocus.dispose();
    shellFocus.dispose();
    super.dispose();
  }

  /// 入力欄が閉じたり画面が変わったりしてフォーカスがこの画面のルートへ戻ったときだけ、ショートカットが届くよう戻す。
  /// フォームや確認（別のルート）を開いている間は奪わない。
  /// アプリが背後に回ったとき（フォーカスが最上位へ移る）は触らず、OSが元の入力欄へ戻すのに任せる。
  void keepFocus() {
    if (!mounted ||
        shellFocus.hasFocus ||
        !shellFocus.canRequestFocus ||
        !idle) {
      return;
    }
    final scope = shellFocus.enclosingScope;
    if (scope != null &&
        scope != FocusManager.instance.rootScope &&
        FocusManager.instance.primaryFocus == scope) {
      shellFocus.requestFocus();
    }
  }

  /// フォームや確認が開いている間は、メニューからの操作を受け付けない（画面のショートカットはその外に届かない）。
  bool get idle =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      !contentPopupOpen;

  /// [navigator]のいちばん上の画面（何も閉じない）。
  static Route<dynamic>? topRoute(NavigatorState? navigator) {
    Route<dynamic>? top;
    navigator?.popUntil((route) {
      top ??= route;
      return true;
    });
    return top;
  }

  /// 本文の領域に、選択肢の一覧などのポップアップが開いているか。
  bool get contentPopupOpen =>
      topRoute(contentNavigator.currentState) is PopupRoute;

  /// メニュー（drawer）が開いているか。Androidの「戻る」では先にメニューを閉じる。
  bool drawerOpen = false;
  bool get canCompose =>
      c.repository != null && c.captureWarning == null && !c.loading;
  bool get canReload => c.location != null && !c.loading;
  String? get openProject =>
      page.startsWith('project:') ? page.substring(8) : null;

  /// 画面を切り替える。開いた画面で判断できる判断待ちは、見たものとして既読にする。
  /// 本文の領域に開いている詳細（記録・候補など）は閉じて、選んだ画面を出す。
  void show(String target) {
    // 保存の途中で詳細を閉じると、結果の案内を出せなくなるため、終わるまで待ってもらう。
    if (c.saving && (contentNavigator.currentState?.canPop() ?? false)) {
      notice(context, '保存が終わってから、ほかの画面へ移ってください。');
      return;
    }
    closeDetails();
    setState(() => page = target);
    c.showPage(target);
  }

  /// 本文の領域に重ねて開いた詳細をすべて閉じる。
  void closeDetails() =>
      contentNavigator.currentState?.popUntil((route) => route.isFirst);

  /// メニューに出す件数。[fresh]（まだ見ていない件数）があれば色と「新着」で示す。
  Widget? countBadge(String name, int count, {int fresh = 0}) {
    if (count == 0) return null;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: fresh > 0 ? '$count件、うち新着$fresh件' : '$count件',
      excludeSemantics: true,
      child: Container(
        key: Key('badge-$name'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: fresh > 0 ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          fresh > 0 ? '$count · 新着$fresh' : '$count',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: fresh > 0 ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// [target]の画面で判断できる判断待ちの件数。
  Widget? attentionBadge(String target) => countBadge(
    target,
    c.attentionCount(target),
    fresh: c.attentionFresh(target),
  );

  void goTo(String target) {
    if (!idle || c.repository == null) return;
    show(target);
    if (target == 'search') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) searchFocus.requestFocus();
      });
    }
  }

  /// キーボード・メニューからの操作。ボタンと同じ条件で受け付ける。
  Future<void> command(HubCommand command) async {
    if (!idle) return;
    switch (command) {
      case HubCommand.newMemo:
        if (canCompose) await showCapture(context, c);
      case HubCommand.guided:
        if (canCompose) await showGuided(context, c);
      case HubCommand.search:
        goTo('search');
      case HubCommand.reload:
        if (canReload) await run(c.reload);
      case HubCommand.copyContext:
        await copyContext();
      case HubCommand.settings:
        // Vaultを読めていないときは、ようこそ画面（Vaultを選ぶ・サンプル）から進める。
        if (c.repository != null) show('settings');
      case HubCommand.keyboardHelp:
        await showKeyboardHelp(context);
    }
  }

  /// プロジェクト画面の「別のAIに渡す文章をコピー」と同じ確認を経てコピーする。
  Future<void> copyContext() async {
    final id = openProject;
    if (c.repository == null || c.loading) return;
    if (id == null) {
      notice(context, 'プロジェクトを開いてからコピーしてください。');
      return;
    }
    try {
      final text = await c.context(id);
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) notice(context, '別のAIに渡す文章をコピーしました');
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }

  /// Macのメニューバー。項目とキーは画面のショートカットと同じ表から作る。
  List<PlatformMenuItem> menus() {
    final has = c.repository != null;
    PlatformMenuItem item(HubCommand command, bool enabled) => PlatformMenuItem(
      label: command.label,
      shortcut: command.activator,
      onSelected: enabled ? () => this.command(command) : null,
    );
    PlatformMenuItem provided(PlatformProvidedMenuItemType type) =>
        PlatformProvidedMenuItem(type: type);
    bool hasMenu(PlatformProvidedMenuItemType type) =>
        PlatformProvidedMenuItem.hasMenu(type);
    // 入力欄などフォーカスのある部品へ、標準の編集操作をそのまま渡す。
    PlatformMenuItem edit(
      String label,
      LogicalKeyboardKey key,
      Intent intent, {
      bool shift = false,
    }) => PlatformMenuItem(
      label: label,
      shortcut: primaryKey(key, shift: shift),
      onSelected: () {
        final target = FocusManager.instance.primaryFocus?.context;
        if (target != null) Actions.maybeInvoke(target, intent);
      },
    );
    return [
      PlatformMenu(
        label: 'ContextHub',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'ContextHub Flutterについて',
                onSelected: () {
                  if (idle) about();
                },
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [item(HubCommand.settings, has)],
          ),
          if (hasMenu(PlatformProvidedMenuItemType.servicesSubmenu))
            PlatformMenuItemGroup(
              members: [provided(PlatformProvidedMenuItemType.servicesSubmenu)],
            ),
          PlatformMenuItemGroup(
            members: [
              for (final type in [
                PlatformProvidedMenuItemType.hide,
                PlatformProvidedMenuItemType.hideOtherApplications,
                PlatformProvidedMenuItemType.showAllApplications,
              ])
                if (hasMenu(type)) provided(type),
            ],
          ),
          if (hasMenu(PlatformProvidedMenuItemType.quit))
            provided(PlatformProvidedMenuItemType.quit),
        ],
      ),
      PlatformMenu(
        label: 'ファイル',
        menus: [
          PlatformMenuItemGroup(
            members: [
              item(HubCommand.newMemo, canCompose),
              item(HubCommand.guided, canCompose),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              item(HubCommand.reload, canReload),
              item(
                HubCommand.copyContext,
                has && openProject != null && !c.loading,
              ),
            ],
          ),
        ],
      ),
      // 独自のメニューバーは標準の「編集」を置き換えるため、入力欄の編集操作を同じキーで並べ直す。
      PlatformMenu(
        label: '編集',
        menus: [
          PlatformMenuItemGroup(
            members: [
              edit(
                '取り消す',
                LogicalKeyboardKey.keyZ,
                const UndoTextIntent(SelectionChangedCause.keyboard),
              ),
              edit(
                'やり直す',
                LogicalKeyboardKey.keyZ,
                const RedoTextIntent(SelectionChangedCause.keyboard),
                shift: true,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              edit(
                'カット',
                LogicalKeyboardKey.keyX,
                const CopySelectionTextIntent.cut(
                  SelectionChangedCause.keyboard,
                ),
              ),
              edit(
                'コピー',
                LogicalKeyboardKey.keyC,
                CopySelectionTextIntent.copy,
              ),
              edit(
                'ペースト',
                LogicalKeyboardKey.keyV,
                const PasteTextIntent(SelectionChangedCause.keyboard),
              ),
              edit(
                'すべてを選択',
                LogicalKeyboardKey.keyA,
                const SelectAllTextIntent(SelectionChangedCause.keyboard),
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: '移動',
        menus: [
          for (var i = 0; i < shortcutPages.length; i++)
            PlatformMenuItem(
              label: shortcutPages[i].$2,
              shortcut: pageActivator(i),
              onSelected: has ? () => goTo(shortcutPages[i].$1) : null,
            ),
        ],
      ),
      PlatformMenu(
        label: 'ウインドウ',
        menus: [
          for (final type in [
            PlatformProvidedMenuItemType.minimizeWindow,
            PlatformProvidedMenuItemType.zoomWindow,
            PlatformProvidedMenuItemType.toggleFullScreen,
          ])
            if (hasMenu(type)) provided(type),
        ],
      ),
      PlatformMenu(label: 'ヘルプ', menus: [item(HubCommand.keyboardHelp, true)]),
    ];
  }

  void about() => showAboutDialog(
    context: context,
    applicationName: 'ContextHub Flutter',
    applicationVersion: appVersion,
    applicationLegalese: 'MIT License · mozuq-lab',
  );

  /// 画面全体のショートカット。Macではメニューバーにも同じ操作を並べる。
  Widget keyboard(Widget child) {
    final shortcuts = Shortcuts(
      shortcuts: hubShortcuts(),
      child: Actions(
        actions: {
          HubCommandIntent: CallbackAction<HubCommandIntent>(
            onInvoke: (intent) {
              command(intent.command);
              return null;
            },
          ),
          GoToPageIntent: CallbackAction<GoToPageIntent>(
            onInvoke: (intent) {
              goTo(intent.page);
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: shellFocus,
          autofocus: true,
          skipTraversal: true,
          child: child,
        ),
      ),
    );
    return defaultTargetPlatform == TargetPlatform.macOS
        ? PlatformMenuBar(menus: menus(), child: shortcuts)
        : shortcuts;
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        notice(context, HubController.message(e));
      }
    }
  }

  /// メニューの項目が選ばれているか。ふりかえりは週次レビューを、人は一人ひとりの画面も含む。
  bool selectedPage(String target) =>
      page == target ||
      (target == 'digest' && page == 'weekly') ||
      (target == 'people' && page.startsWith('person:'));

  /// 下のタブに置く、毎日使う画面（狭い画面）。広い画面ではサイドバーの上段に同じ順で並べる。
  static const primaryPages = [
    ('home', 'ホーム', Icons.home_outlined, Icons.home),
    ('next', '次の一手', Icons.checklist_outlined, Icons.checklist),
    ('review', '確認待ち', Icons.fact_check_outlined, Icons.fact_check),
    ('recent', '最近のメモ', Icons.notes_outlined, Icons.notes),
  ];

  /// メニューの見出し。[trailing]は見出しの右に置く小さな操作。
  Widget navHeading(String text, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 4, 4),
    child: SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );

  /// サイドバー（広い画面）とメニュー（狭い画面の「その他」）。
  /// 毎日使う画面を上に、プロジェクトを中ほどに、ときどき使う画面を下にまとめ、設定は下端の1か所にまとめる。
  /// 狭い画面では、毎日使う画面と検索・メモの追加は下のタブと上の帯にあるので、ここには出さない。
  Widget navigation(bool drawer) {
    final scheme = Theme.of(context).colorScheme;
    final repo = c.repository;
    void go(String target) {
      show(target);
      if (drawer) Navigator.pop(context);
    }

    Widget item(
      String target,
      String label,
      IconData icon, {
      IconData? selectedIcon,
      Widget? trailing,
    }) {
      final selected = selectedPage(target);
      return ListTile(
        key: Key('nav-$target'),
        leading: Icon(selected ? selectedIcon ?? icon : icon, size: 20),
        title: Text(label),
        trailing: trailing,
        selected: selected,
        onTap: () => go(target),
      );
    }

    final composing = repo != null && c.captureWarning == null && !c.loading;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.auto_stories_outlined,
                    size: 17,
                    color: scheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ContextHub',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      if (c.location != null)
                        Text(
                          c.location!.name,
                          key: const Key('nav-vault'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontSize: 11.5, height: 1.3),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!drawer && repo != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 検索は入力欄の形にして、いつでも探せることを示す。
                  Material(
                    color: scheme.surfaceContainerLowest,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(hubRadiusSmall),
                      side: BorderSide(
                        color: page == 'search'
                            ? scheme.primary
                            : scheme.outlineVariant,
                      ),
                    ),
                    child: InkWell(
                      key: const Key('nav-search'),
                      borderRadius: BorderRadius.circular(hubRadiusSmall),
                      onTap: () => goTo('search'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '検索',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Text(
                              keyLabel(HubCommand.search.activator),
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const Key('new-memo'),
                    onPressed: composing ? () => showCapture(context, c) : null,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('メモを追加'),
                  ),
                  const SizedBox(height: 2),
                  TextButton.icon(
                    key: const Key('open-guided'),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: scheme.onSurfaceVariant,
                    ),
                    onPressed: composing ? () => showGuided(context, c) : null,
                    icon: const Icon(Icons.forum_outlined, size: 18),
                    label: const Text('質問に答えてまとめる'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListTileTheme.merge(
              // 項目を詰めて、低いウインドウでもプロジェクトの一覧まで見えるようにする。
              dense: true,
              visualDensity: const VisualDensity(vertical: -2),
              minVerticalPadding: 0,
              titleTextStyle: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
              subtitleTextStyle: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontSize: 11.5, height: 1.3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(hubRadiusSmall),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              minLeadingWidth: 20,
              horizontalTitleGap: 12,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                children: [
                  if (!drawer)
                    for (final (target, label, icon, selectedIcon)
                        in primaryPages)
                      item(
                        target,
                        label,
                        icon,
                        selectedIcon: selectedIcon,
                        // 確認待ちは、採用・却下を待つ候補の件数。
                        trailing: target == 'review'
                            ? attentionBadge('review')
                            : null,
                      ),
                  if (drawer && repo != null)
                    ListTile(
                      key: const Key('nav-guided'),
                      leading: const Icon(Icons.forum_outlined, size: 20),
                      title: const Text('質問に答えてまとめる'),
                      enabled: c.captureWarning == null && !c.loading,
                      onTap: () async {
                        Navigator.pop(context);
                        await showGuided(context, c);
                      },
                    ),
                  navHeading(
                    'プロジェクト',
                    trailing: repo == null
                        ? null
                        : IconButton(
                            key: const Key('new-project'),
                            tooltip: '新しいプロジェクト',
                            visualDensity: VisualDensity.compact,
                            iconSize: 18,
                            onPressed:
                                !c.loading &&
                                    !c.saving &&
                                    c.error == null &&
                                    c.captureWarning == null
                                ? () async {
                                    if (drawer) Navigator.pop(context);
                                    await showProjectCreate(context, c);
                                  }
                                : null,
                            icon: const Icon(Icons.add),
                          ),
                  ),
                  for (final project
                      in repo?.orderedProjects ?? const <HubProject>[])
                    ListTile(
                      key: Key('project-${project.id}'),
                      leading: Icon(
                        repo!.isPinned(project.id)
                            ? Icons.push_pin_outlined
                            : project.active
                            ? Icons.folder_outlined
                            : Icons.folder_off_outlined,
                        size: 19,
                        semanticLabel: repo.isPinned(project.id)
                            ? 'ピン留め'
                            : null,
                      ),
                      title: Text(
                        project.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: project.merged
                          ? const Text('統合済み')
                          : project.lifecycle != 'active'
                          ? Text(project.lifecycleLabel)
                          : project.stale(DateTime.now())
                          ? const Text('停滞')
                          : null,
                      // 作業記録の下書きと、手で書き換えて止まったNOW。
                      trailing: attentionBadge('project:${project.id}'),
                      selected: page == 'project:${project.id}',
                      onTap: () => go('project:${project.id}'),
                    ),
                  for (final pending
                      in repo?.pendingProjectCreations ??
                          const <PendingProjectCreation>[])
                    ListTile(
                      key: Key('pending-project-${pending.projectId}'),
                      enabled: false,
                      leading: const Icon(
                        Icons.create_new_folder_outlined,
                        size: 19,
                      ),
                      title: Text(
                        pending.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        pending.state == 'accepted' ? '作成済み・同期待ち' : '作成依頼中',
                      ),
                    ),
                  if (repo != null && repo.orderedProjects.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text(
                        'まだありません',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  navHeading('見直す・調べる'),
                  item('digest', 'ふりかえり', Icons.event_note_outlined),
                  // いつかやるは、一覧に行があるとき（または開いている間）だけメニューに出す。
                  // 空のうちは、項目の「…」やアイデアの画面から置くと現れる。
                  if ((repo?.somedayEntries.isNotEmpty ?? false) ||
                      page == 'someday')
                    item('someday', 'いつかやる', Icons.inventory_2_outlined),
                  item('ideas', 'アイデア', Icons.lightbulb_outline),
                  item('people', '人', Icons.people_outline),
                  // 記録に聞くは、本体が対応しているとき（または問いがあるとき）だけメニューに出す。
                  if (repo?.intakeFeatures.ask == true ||
                      (repo?.asks.isNotEmpty ?? false) ||
                      page == 'ask')
                    item('ask', '記録に聞く', Icons.question_answer_outlined),
                  // 文脈かごは、記録を入れたとき（または開いている間）だけメニューに出す。
                  if (c.basket.ids.isNotEmpty || page == 'basket')
                    item(
                      'basket',
                      c.basket.ids.isNotEmpty
                          ? '文脈かご（${c.basket.ids.length}）'
                          : '文脈かご',
                      Icons.shopping_basket_outlined,
                    ),
                ],
              ),
            ),
          ),
          if (repo != null || c.location != null)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              child: ListTileTheme.merge(
                dense: true,
                visualDensity: const VisualDensity(vertical: -2),
                minVerticalPadding: 0,
                titleTextStyle: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(hubRadiusSmall),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                minLeadingWidth: 20,
                horizontalTitleGap: 12,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Column(
                    children: [
                      // 保存と反映は、この端末で保存を確かめられていない操作があるときだけ件数を出す。
                      if (repo != null)
                        item(
                          'intake',
                          '保存と反映',
                          Icons.sync_outlined,
                          trailing: countBadge('intake', c.pending.length),
                        ),
                      item(
                        'settings',
                        '設定',
                        Icons.settings_outlined,
                        selectedIcon: Icons.settings,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 本文の領域に詳細などを重ねているか。右下の「メモを追加」を隠すのに使う。
  bool detailOpen = false;

  /// 本文の領域の画面の重なりの変化を受けて、[detailOpen]を更新する。
  late final _contentObserver = _ContentObserver(() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final open = contentNavigator.currentState?.canPop() ?? false;
      if (open != detailOpen) setState(() => detailOpen = open);
    });
  });

  /// 狭い画面の右下の「メモを追加」。押せないとき（読込中・保存の確認情報を読めないとき）は薄く示す。
  Widget memoButton() {
    final scheme = Theme.of(context).colorScheme;
    final enabled = c.captureWarning == null && !c.loading;
    return FloatingActionButton.extended(
      key: const Key('new-memo'),
      onPressed: enabled ? () => showCapture(context, c) : null,
      backgroundColor: enabled ? null : scheme.surfaceContainerHighest,
      foregroundColor: enabled
          ? null
          : scheme.onSurface.withValues(alpha: .38),
      icon: const Icon(Icons.edit_outlined),
      label: const Text('メモを追加'),
    );
  }

  /// 狭い画面の下のタブ。毎日使う4つの画面と、それ以外を開く「その他」。
  Widget bottomBar() {
    final index = primaryPages.indexWhere((p) => selectedPage(p.$1));
    final reviewCount = c.attentionCount('review'),
        reviewFresh = c.attentionFresh('review');
    return NavigationBar(
      key: const Key('bottom-bar'),
      selectedIndex: index < 0 ? primaryPages.length : index,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      onDestinationSelected: (i) {
        // 本文の領域に選択肢の一覧などを開いている間は、ほかの画面へ移らない（サイドバー以外の移動と同じ扱い）。
        if (!idle) return;
        if (i == primaryPages.length) {
          shellScaffold.currentState?.openDrawer();
        } else {
          show(primaryPages[i].$1);
        }
      },
      destinations: [
        for (final (target, label, icon, selectedIcon) in primaryPages)
          NavigationDestination(
            key: Key('nav-$target'),
            icon: target == 'review' && reviewCount > 0
                ? Badge(
                    key: const Key('badge-review'),
                    label: Text('$reviewCount'),
                    // 新着がなければ、目立たない色にする（メニューの件数と同じ）。
                    backgroundColor: reviewFresh > 0
                        ? null
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    textColor: reviewFresh > 0
                        ? null
                        : Theme.of(context).colorScheme.onSurface,
                    child: Icon(icon),
                  )
                : Icon(icon),
            selectedIcon: Icon(selectedIcon),
            label: label,
          ),
        const NavigationDestination(
          key: Key('nav-more'),
          icon: Icon(Icons.menu),
          label: 'その他',
        ),
      ],
    );
  }

  /// 設定。この端末での表示・通知と、Vaultの切り替え、ヘルプをまとめる。
  Widget settingsView({required bool wide}) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    Widget group(List<Widget> children) => Card(
      child: Column(
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const Divider(indent: 16, endIndent: 16),
            child,
          ],
        ],
      ),
    );
    const chevron = Icon(Icons.chevron_right, size: 20);
    final has = c.repository != null;
    final device = [
      if (c.homeScreenSupported && has)
        ListTile(
          key: const Key('home-widget-settings'),
          leading: const Icon(Icons.widgets_outlined),
          title: const Text('ウィジェットの表示'),
          subtitle: const Text('ホーム画面のウィジェットに出す内容'),
          trailing: chevron,
          enabled: !c.loading,
          onTap: () => showHomeWidgetSettings(context, c),
        ),
      if (c.attentionNotificationsSupported && has)
        ListTile(
          key: const Key('attention-settings'),
          leading: const Icon(Icons.notifications_none_outlined),
          title: const Text('確認待ちの通知'),
          subtitle: Text(c.attentionNotify ? 'オン' : 'オフ'),
          trailing: chevron,
          enabled: !c.loading,
          onTap: () => showAttentionSettings(context, c),
        ),
      if (c.attentionNotificationsSupported && has)
        ListTile(
          key: const Key('due-settings'),
          leading: const Icon(Icons.event_outlined),
          title: const Text('期日の通知'),
          subtitle: Text(c.dueNotify ? 'オン' : 'オフ'),
          trailing: chevron,
          enabled: !c.loading,
          onTap: () => showDueSettings(context, c),
        ),
      if (has && (c.preferenceSyncSupported || c.preferenceSyncEnabled))
        ListTile(
          key: const Key('preference-sync-settings'),
          leading: const Icon(Icons.devices_outlined),
          title: Text(
            c.preferenceSyncEnabled ? '好みを端末間でそろえています' : '好みを端末間でそろえる',
          ),
          subtitle: const Text('ピン留めと並び順・ひな形・かごの上限'),
          trailing: chevron,
          enabled: !c.loading,
          onTap: () => showPreferenceSync(context, c),
        ),
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const ValueKey('settings'),
          padding: EdgeInsets.fromLTRB(
            wide ? 40 : 16,
            wide ? 32 : 12,
            wide ? 40 : 16,
            40,
          ),
          children: [
            heading('Vault'),
            group([
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(c.location?.name ?? '未選択'),
                subtitle: const Text('手元のMarkdownを表示しています'),
              ),
              ListTile(
                key: const Key('choose-vault'),
                leading: const Icon(Icons.drive_folder_upload_outlined),
                title: const Text('Vaultを選び直す'),
                trailing: chevron,
                enabled: !c.loading,
                onTap: () => run(c.chooseVault),
              ),
            ]),
            if (has) ...[
              heading('読み込み'),
              group([
                SwitchListTile(
                  key: const Key('auto-reload'),
                  secondary: const Icon(Icons.sync_outlined),
                  title: const Text('同期した変更を自動で読み込む'),
                  subtitle: const Text('開いている間と、アプリに戻ったときに確かめます'),
                  value: c.autoReload,
                  onChanged: c.loading
                      ? null
                      : (v) => run(() => c.setAutoReload(v)),
                ),
              ]),
            ],
            if (device.isNotEmpty) ...[heading('この端末'), group(device)],
            heading('ヘルプ'),
            group([
              if (wide)
                ListTile(
                  key: const Key('keyboard-help-button'),
                  leading: const Icon(Icons.keyboard_outlined),
                  title: const Text('キーボード操作'),
                  trailing: Text(
                    keyLabel(HubCommand.keyboardHelp.activator),
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap: () => showKeyboardHelp(context),
                ),
              ListTile(
                key: const Key('about'),
                leading: const Icon(Icons.info_outline),
                title: const Text('このアプリについて'),
                subtitle: Text('バージョン $appVersion'),
                trailing: chevron,
                onTap: about,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 820;
      final has = c.repository != null;
      final vault = c.location?.identity;
      if (vault != shownVault) {
        shownVault = vault;
        // 前のVaultの記録を開いたまま、別のVaultへ依頼を書かないよう閉じる。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) closeDetails();
        });
      }
      final scheme = Theme.of(context).colorScheme;
      return keyboard(
        Scaffold(
          key: shellScaffold,
          drawer: wide || !has ? null : Drawer(child: navigation(true)),
          onDrawerChanged: (open) => setState(() => drawerOpen = open),
          bottomNavigationBar: wide || !has ? null : bottomBar(),
          // 狭い画面では、メモの追加を右下のボタンから行う。案内（SnackBar）と位置を調整し合うよう、外側に置く。
          // 詳細や一覧を本文の領域に重ねている間と設定の画面では出さない。
          floatingActionButton: has && !wide && page != 'settings' && !detailOpen
              ? memoButton()
              : null,
          body: Row(
            children: [
              if (wide && has)
                Container(
                  width: 252,
                  foregroundDecoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  // 選んでいる項目の背景はMaterialの上に描かれるため、色はMaterialで付ける。
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    child: navigation(false),
                  ),
                ),
              Expanded(
                // Androidの「戻る」は、開いている詳細を先に閉じる。
                // メニューが開いている間はメニューを先に閉じる（詳細は閉じない）。
                child: NavigatorPopHandler<Object?>(
                  enabled: !drawerOpen,
                  onPopWithResult: (_) {
                    final scaffold = shellScaffold.currentState;
                    if (scaffold?.isDrawerOpen ?? false) {
                      scaffold!.closeDrawer();
                    } else {
                      contentNavigator.currentState?.maybePop();
                    }
                  },
                  child: Navigator(
                    key: contentNavigator,
                    observers: [_contentObserver],
                    pages: [
                      MaterialPage<void>(
                        key: const ValueKey('hub-main'),
                        child: _main(context, wide: wide, has: has),
                      ),
                    ],
                    onDidRemovePage: (_) {},
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  /// 本文の領域のいちばん下の画面。選んでいる画面の題名・操作と、その内容。
  Widget _main(
    BuildContext context, {
    required bool wide,
    required bool has,
  }) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: Text(
        has
            ? switch (page) {
                'next' => '次の一手',
                'someday' => 'いつかやる',
                'digest' => 'ふりかえり',
                'weekly' => '週次レビュー',
                'recent' => '最近のメモ',
                'ideas' => 'アイデア',
                'review' => '確認待ち',
                'search' => '検索',
                'ask' => '記録に聞く',
                'basket' => '文脈かご',
                'people' => '人',
                _ when page.startsWith('person:') => '人',
                'intake' => '保存と反映',
                'settings' => '設定',
                _ when openProject != null => 'プロジェクト',
                _ => 'ホーム',
              }
            : 'ContextHub',
      ),
      actions: [
        // 狭い画面では、検索を上の帯から開く（広い画面ではサイドバーの検索欄）。
        if (has && !wide)
          IconButton(
            key: const Key('nav-search'),
            tooltip: '検索',
            isSelected: page == 'search',
            icon: const Icon(Icons.search),
            onPressed: () => goTo('search'),
          ),
        if (c.location != null)
          IconButton(
            tooltip: '再読込',
            onPressed: c.loading ? null : () => run(c.reload),
            icon: const Icon(Icons.refresh),
          ),
        if (!has)
          IconButton(
            tooltip: 'このアプリについて',
            icon: const Icon(Icons.info_outline),
            onPressed: about,
          ),
        const SizedBox(width: 8),
      ],
    ),
    body: Column(
      children: [
        if (c.loading) const LinearProgressIndicator(minHeight: 2),
        for (final notice in [
          if (c.error != null) NoticeBox(c.error!, error: true),
          if (c.captureWarning != null)
            NoticeBox(c.captureWarning!, error: true),
          if (c.pending.isNotEmpty)
            NoticeBox('保存確認待ちが${c.pending.length}件あります。保存と反映から同じ操作を確認できます。'),
        ])
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 10, wide ? 24 : 12, 0),
            child: notice,
          ),
        Expanded(
          // Vaultを読めていないときは、設定を開いていても、ようこそ画面（Vaultを選ぶ・サンプル）を出す。
          child: !has
              ? _welcome()
              : page == 'settings'
              ? settingsView(wide: wide)
              : HubView(
                  controller: c,
                  page: page,
                  onNavigate: show,
                  searchFocus: searchFocus,
                ),
        ),
      ],
    ),
  );

  Widget _welcome() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.auto_stories_outlined, size: 48),
            const SizedBox(height: 24),
            const Text(
              '散らばった考えに、\n戻れる場所を。',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                height: 1.35,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'プロジェクトの現在地を読み、原文をたどり、思いつきを残す。\nいつものMarkdown Vaultを、この端末でも。',
              style: TextStyle(fontSize: 16, height: 1.8),
            ),
            const SizedBox(height: 32),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: c.loading ? null : () => run(c.chooseVault),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Vaultフォルダーを選ぶ'),
                ),
                OutlinedButton(
                  onPressed: c.loading ? null : () => run(c.useSample),
                  child: const Text('サンプルで試す'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'サンプルは架空の内容です。同期はSyncthing等で行い、更新は「再読込」で確認します。',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Androidのホーム画面ウィジェットに何を出すかを選ぶ。
Future<void> showHomeWidgetSettings(
  BuildContext context,
  HubController c,
) async {
  final repo = c.repository;
  if (repo == null) return;
  final projects = repo.actionableProjects;
  var showText = c.homeWidget.showText;
  var project = projects.any((p) => p.id == c.homeWidget.projectId)
      ? c.homeWidget.projectId
      : null;
  final saved = await showDialog<HomeWidgetSettings>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: const Key('home-widget-dialog'),
        title: const Text('ホーム画面ウィジェットの表示'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ホーム画面は周りの人からも見えます。既定では件数と読込時刻だけを出します。'
                  '内容はアプリで読み込んだ時点のもので、アプリを開くと更新されます。',
                  style: TextStyle(fontSize: 13, height: 1.6),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  key: const Key('home-widget-text'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('次の一手の本文とプロジェクト名を出す'),
                  subtitle: const Text('3件まで。秘密情報らしい文字列は伏せます'),
                  value: showText,
                  onChanged: (v) => setState(() => showText = v),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  key: const Key('home-widget-project'),
                  initialValue: project,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '対象のプロジェクト'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('進行中のすべて'),
                    ),
                    for (final p in projects)
                      DropdownMenuItem<String?>(
                        value: p.id,
                        child: Text(p.title, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => project = v),
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
            key: const Key('home-widget-save'),
            onPressed: () => Navigator.pop(
              context,
              HomeWidgetSettings(showText: showText, projectId: project),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (saved == null || !context.mounted) return;
  try {
    await c.setHomeWidget(saved);
  } catch (e) {
    if (context.mounted) notice(context, HubController.message(e));
  }
}

/// アプリを閉じている間に確認待ちが増えたとき、端末へ通知するかを選ぶ（Androidだけ）。
Future<void> showAttentionSettings(BuildContext context, HubController c) =>
    _showNotificationSettings(
      context,
      name: 'attention',
      title: '確認待ちの通知',
      description:
          'アプリを閉じている間も、数時間おきにこの端末に同期済みのVaultを読み、'
          '確認待ちの候補・作業記録の下書き・更新が止まった現状が増えたときだけ通知します。'
          '通知に出すのは件数と種類だけで、本文は出しません。'
          '読むのは端末内のフォルダーだけで、ネットワークには接続しません。'
          '同期が遅れていると、通知も遅れます。'
          '端末を再起動した後は、アプリを一度開くと確認を再開します。',
      label: '確認待ちが増えたら通知する',
      channel: '確認待ちのお知らせ',
      enabled: c.attentionNotify,
      blocked: c.attentionNotifyBlocked,
      change: c.setAttentionNotify,
    );

/// 期限切れか今日が期日の項目があるとき、端末へ通知するかを選ぶ（Androidだけ）。
Future<void> showDueSettings(BuildContext context, HubController c) =>
    _showNotificationSettings(
      context,
      name: 'due',
      title: '期日の通知',
      description:
          'アプリを閉じている間も、数時間おきにこの端末に同期済みのVaultを読み、'
          '次の一手・未解決に期限切れか今日が期日の項目があれば、1日（日本時間の日付）に1回まで通知します。'
          '数え方は「次の一手」の画面と同じで、完了・解決にした項目、誤りとして外した項目、'
          '連絡待ち・「いつかやる」の項目、見直す日まで休ませている項目は数えません。'
          '見直す日が来ただけの項目と、明日以降の期日は通知しません。'
          '通知に出すのは件数だけで、本文とプロジェクト名は出しません。'
          '夜（22時〜7時）は通知せず、朝以降の確認で知らせます。'
          '読むのは端末内のフォルダーだけで、ネットワークには接続しません。'
          '確認は数時間おきで、端末の省電力の都合で遅れることがあります。時刻どおりに知りたい期日は、カレンダーへ入れてください。'
          '同期が止まっていると、古い内容で数えます。'
          '端末を再起動した後は、アプリを一度開くと確認を再開します。',
      label: '期日が来たら通知する',
      channel: '期日のお知らせ',
      enabled: c.dueNotify,
      blocked: c.dueNotifyBlocked,
      change: c.setDueNotify,
    );

/// アプリを閉じている間の通知の設定画面。[name]は画面の要素の鍵に使う。
Future<void> _showNotificationSettings(
  BuildContext context, {
  required String name,
  required String title,
  required String description,
  required String label,
  required String channel,
  required bool enabled,
  required bool blocked,
  required Future<bool> Function(bool) change,
}) async {
  var busy = false;
  // アプリの通知そのものか、このお知らせの種類だけが、端末の設定で止められている。
  final howTo = '端末の設定で、ContextHub Flutterの通知と、その中の「$channel」を許可してください。';
  String? problem = enabled && blocked
      ? '通知が止められているため、いまは通知されません。$howToその後、アプリを開き直してください。'
      : null;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: Key('$name-dialog'),
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: const TextStyle(fontSize: 13, height: 1.6),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  key: Key('$name-notify'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  value: enabled,
                  onChanged: busy
                      ? null
                      : (v) async {
                          setState(() {
                            busy = true;
                            problem = null;
                          });
                          var ok = false;
                          try {
                            ok = await change(v);
                            if (!ok) {
                              problem =
                                  '通知が止められているため、有効にできません。$howToその後、もう一度お試しください。';
                            }
                          } catch (e) {
                            problem = HubController.message(e);
                          }
                          if (!context.mounted) return;
                          setState(() {
                            busy = false;
                            if (ok) enabled = v;
                          });
                        },
                ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      problem!,
                      key: Key('$name-problem'),
                      style: TextStyle(
                        fontSize: 13,
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
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    ),
  );
}

/// 本文の領域の画面が重なったり閉じたりしたことを知らせる。
class _ContentObserver extends NavigatorObserver {
  _ContentObserver(this.changed);
  final VoidCallback changed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      changed();
}
