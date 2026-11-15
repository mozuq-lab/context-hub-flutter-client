import 'dart:async';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'views.dart';
import 'guided_view.dart';
import '../core/models.dart';
import '../core/home_widget.dart';
import '../app_version.dart';

class ContextHubApp extends StatelessWidget {
  const ContextHubApp({super.key, required this.controller});
  final HubController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ContextHub',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff237363)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff5f6f3),
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff73c9b4),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
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
  HubController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    // ショートカットやウィジェットからの起動は、保存先を読み終えてから扱う。
    c.restore().whenComplete(_launch);
    c.access.listenLaunchActions(_launch);
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
    // いちばん上の画面を調べる（何も閉じない）。
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top ??= route;
      return true;
    });
    // 入力・保存・確認の途中には割り込まず、開けなかったことを知らせる。
    if (c.composing || c.saving || top is PopupRoute) {
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
    if (action == 'next') {
      // 記録の詳細などを開いていたら閉じて、次の一手の一覧へ戻る。
      navigator.popUntil((route) => route.isFirst);
      setState(() => page = 'next');
      return;
    }
    if (c.captureWarning != null) {
      notice(context, '保存の確認情報を読めません。受付状況を確認してください。');
      return;
    }
    // 記録の詳細などを開いていても、その上に開く。
    if (action == 'capture') {
      await showCapture(context, c);
    } else if (action == 'guided') {
      await showGuided(context, c);
    }
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

  Widget navigation(bool drawer) => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 28, 20, 4),
          child: Text(
            'ContextHub',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 20, 28),
          child: Text('考えを、次の一歩へ。', style: TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final item in [
                ('home', 'ホーム', Icons.space_dashboard_outlined),
                ('next', '次の一手', Icons.checklist_outlined),
                ('digest', 'ふりかえり', Icons.event_note_outlined),
                ('recent', '最近のメモ', Icons.notes_outlined),
                ('ideas', 'アイデア', Icons.lightbulb_outline),
                ('review', '確認待ち', Icons.fact_check_outlined),
                ('search', '検索', Icons.search),
                ('intake', '受付状況', Icons.inbox_outlined),
              ])
                ListTile(
                  key: Key('nav-${item.$1}'),
                  leading: Icon(item.$3, size: 20),
                  title: Text(item.$2),
                  selected: page == item.$1,
                  onTap: () {
                    setState(() => page = item.$1);
                    if (drawer) {
                      Navigator.pop(context);
                    }
                  },
                ),
              if (drawer && c.repository != null)
                ListTile(
                  key: const Key('nav-guided'),
                  leading: const Icon(Icons.checklist, size: 20),
                  title: const Text('選んで深掘り'),
                  enabled: c.captureWarning == null && !c.loading,
                  onTap: () async {
                    Navigator.pop(context);
                    await showGuided(context, c);
                  },
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 24, 20, 8),
                child: Text(
                  'プロジェクト',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
              for (final project
                  in c.repository?.orderedProjects ?? const <HubProject>[])
                ListTile(
                  key: Key('project-${project.id}'),
                  leading: Icon(
                    project.lifecycle == 'active'
                        ? Icons.folder_outlined
                        : Icons.folder_off_outlined,
                    size: 20,
                  ),
                  title: Text(
                    project.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: project.lifecycle != 'active'
                      ? Text(project.lifecycleLabel)
                      : project.stale(DateTime.now())
                      ? const Text('停滞')
                      : null,
                  selected: page == 'project:${project.id}',
                  onTap: () {
                    setState(() => page = 'project:${project.id}');
                    if (drawer) {
                      Navigator.pop(context);
                    }
                  },
                ),
              for (final pending
                  in c.repository?.pendingProjectCreations ??
                      const <PendingProjectCreation>[])
                ListTile(
                  key: Key('pending-project-${pending.projectId}'),
                  enabled: false,
                  leading: const Icon(
                    Icons.create_new_folder_outlined,
                    size: 20,
                  ),
                  title: Text(
                    pending.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    pending.state == 'accepted' ? '作成済み・同期待ち' : '作成依頼中',
                  ),
                ),
              if (c.repository != null)
                ListTile(
                  key: const Key('new-project'),
                  leading: const Icon(Icons.add, size: 20),
                  title: const Text('新しいプロジェクト'),
                  enabled:
                      !c.loading &&
                      !c.saving &&
                      c.error == null &&
                      c.captureWarning == null,
                  onTap: () async {
                    if (drawer) Navigator.pop(context);
                    await showProjectCreate(context, c);
                  },
                ),
            ],
          ),
        ),
        if (c.location != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.location!.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                const Text('手元のMarkdownを表示', style: TextStyle(fontSize: 11)),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: c.loading ? null : () => run(c.chooseVault),
                  icon: const Icon(
                    Icons.drive_folder_upload_outlined,
                    size: 18,
                  ),
                  label: const Text('Vaultを選び直す'),
                ),
                if (c.homeScreenSupported && c.repository != null)
                  TextButton.icon(
                    key: const Key('home-widget-settings'),
                    onPressed: c.loading
                        ? null
                        : () async {
                            if (drawer) Navigator.pop(context);
                            await showHomeWidgetSettings(context, c);
                          },
                    icon: const Icon(Icons.widgets_outlined, size: 18),
                    label: const Text('ウィジェットの表示'),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 820;
      final has = c.repository != null;
      return Scaffold(
        drawer: wide || !has ? null : Drawer(child: navigation(true)),
        appBar: AppBar(
          title: Text(
            has
                ? switch (page) {
                    'next' => '次の一手',
                    'digest' => 'ふりかえり',
                    'recent' => '最近のメモ',
                    'ideas' => 'アイデア',
                    'review' => '確認待ち',
                    'search' => '検索',
                    'intake' => '受付状況',
                    _ => 'ContextHub',
                  }
                : 'ContextHub',
          ),
          actions: [
            IconButton(
              tooltip: 'このアプリについて',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showAboutDialog(
                context: context,
                applicationName: 'ContextHub Flutter',
                applicationVersion: appVersion,
                applicationLegalese: 'MIT License · mozuq-lab',
              ),
            ),
            if (c.location != null)
              IconButton(
                tooltip: '再読込',
                onPressed: c.loading ? null : () => run(c.reload),
                icon: const Icon(Icons.refresh),
              ),
            // 狭い画面では題名の幅を残すため、ナビゲーションから開く。
            if (has && wide)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.tonalIcon(
                  key: const Key('open-guided'),
                  onPressed: c.captureWarning != null || c.loading
                      ? null
                      : () => showGuided(context, c),
                  icon: const Icon(Icons.checklist, size: 18),
                  label: const Text('選んで深掘り'),
                ),
              ),
            if (has)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: FilledButton.icon(
                  key: const Key('new-memo'),
                  onPressed: c.captureWarning != null || c.loading
                      ? null
                      : () => showCapture(context, c),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('メモを追加'),
                ),
              ),
          ],
        ),
        body: Row(
          children: [
            if (wide && has)
              SizedBox(
                width: 246,
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: navigation(false),
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  if (c.loading) const LinearProgressIndicator(minHeight: 2),
                  if (c.error != null) NoticeBox(c.error!, error: true),
                  if (c.captureWarning != null)
                    NoticeBox(c.captureWarning!, error: true),
                  if (c.pending.isNotEmpty)
                    NoticeBox(
                      '保存確認待ちが${c.pending.length}件あります。受付状況から同じ操作を確認できます。',
                    ),
                  Expanded(
                    child: has
                        ? HubView(
                            controller: c,
                            page: page,
                            onNavigate: (p) => setState(() => page = p),
                          )
                        : _welcome(),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
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
