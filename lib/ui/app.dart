import 'package:flutter/material.dart';
import '../app/controller.dart';
import 'views.dart';
import '../core/models.dart';
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
    c.restore();
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
