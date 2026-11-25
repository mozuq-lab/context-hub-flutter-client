import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../ask_view.dart';
import '../labels.dart';
import '../parts.dart';
import '../review_view.dart';
import '../save_checks.dart';
import 'home_page.dart';
import 'hub_common.dart';
import 'intake_page.dart';
import 'next_page.dart';
import 'people_page.dart';
import 'project_page.dart';
import 'search_page.dart';
import 'someday_page.dart';
import 'weekly_page.dart';

class HubView extends StatefulWidget {
  const HubView({
    super.key,
    required this.controller,
    required this.page,
    required this.onNavigate,
    this.searchFocus,
  });
  final HubController controller;
  final String page;
  final void Function(String) onNavigate;

  /// 検索欄のフォーカス。キーボード操作（⌘F）で検索を開いたときに入力欄へ移る。
  final FocusNode? searchFocus;
  @override
  State<HubView> createState() => HubViewState();
}

/// ホームの各画面（ホーム・次の一手・プロジェクト・検索・週次レビューなど）の状態。
/// 画面ごとの組み立てと操作は、同じフォルダーの拡張（`extension ... on HubViewState`）に分けている。
/// 状態（検索条件・表示件数・絞り込み）はこのクラスだけが持つ。
class HubViewState extends State<HubView> {
  String query = '';
  final queryController = TextEditingController();

  /// 検索の絞り込み。本体の `ctx find` の --project・--kind・期間・--sort に対応する。
  String? searchProject;
  final Set<String> selectedKinds = {};
  int? searchDays;
  String searchSort = 'relevance';

  /// 一覧・検索結果は[pageSize]件ずつ表示し、「さらに読み込む」で古い記録へさかのぼる。
  static const pageSize = 50;
  int shown = pageSize;
  Object? searchCacheKey;
  List<HubRecord> searchCache = const [];

  /// 「次の一手」画面で表示する欄（next または open）。
  String nextSection = 'next';

  /// 期日の通知から開いた回数（[HubController.dueOpened]）のうち、画面に反映した分。
  int dueOpenedShown = 0;

  /// 「次の一手」画面の手間の目安での絞り込み（[effortFilters]のキー）。nullならすべて。
  String? effortFilter;

  /// 「次の一手」画面の場所・道具の札での絞り込み。nullならすべて、[contextFilterNone]なら札なし、ほかは札そのもの。
  String? contextFilter;

  /// 「次の一手」画面のプロジェクト未定のメモは[unassignedPageSize]件ずつ並べ、「さらに表示」で残りを出す。
  static const unassignedPageSize = 10;
  int unassignedShown = unassignedPageSize;

  /// ホームに並べる、プロジェクト未定のメモと確認待ちのプロジェクト案の数。
  static const homeUnassigned = 3, homeProposals = 3;

  /// ホームの「今週の気づき」は、欄ごとに先頭の1件を出す。「ほかN件を表示」で残りも出す。
  bool insightsExpanded = false;
  HubController get c => widget.controller;
  HubRepository get repo => c.repository!;

  @override
  void initState() {
    super.initState();
    _visit();
  }

  @override
  void didUpdateWidget(HubView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      shown = pageSize;
      unassignedShown = unassignedPageSize;
      insightsExpanded = false;
      _visit();
    }
  }

  @override
  void dispose() {
    queryController.dispose();
    super.dispose();
  }

  /// プロジェクトを開いたら、前回見たときとの比較を固定してから既読にする。
  void _visit() {
    final page = widget.page;
    if (!page.startsWith('project:')) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.page == page) c.beginVisit(page.substring(8));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.page == 'review') return ReviewView(controller: c);
    final children = <Widget>[];
    if (repo.snapshot.limitReached) {
      children.add(
        const Padding(
          key: Key('snapshot-limit'),
          padding: EdgeInsets.only(bottom: 12),
          child: NoticeBox(
            'Vaultの記録が多く、アプリが一度に読める上限に達しました。一部の記録を読めていないため、読み取り済みのメモが「読み取り前」に見えたり、確認待ちの候補や方針が欠けたりすることがあります。文脈のコピーは止まります。Vaultの記録そのものは失われていません。',
            error: true,
          ),
        ),
      );
    }
    for (final warning in repo.warnings) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: NoticeBox(warning, error: true),
        ),
      );
    }
    final page = widget.page;
    if (page.startsWith('project:')) {
      final project = repo.projects[page.substring(8)];
      if (project == null) {
        children.add(const Text('このVaultにプロジェクトがありません。'));
      } else {
        children.addAll(projectView(project));
      }
    } else if (page == 'people') {
      children.addAll(peopleView());
    } else if (page.startsWith('person:')) {
      final person = repo.people[page.substring(7)];
      if (person == null) {
        children.add(
          const Text('この人は登録されていません。外された可能性があります。', key: Key('person-missing')),
        );
      } else {
        children.addAll(personView(person));
      }
    } else if (page == 'digest') {
      children.addAll(digestView());
    } else if (page == 'next') {
      children.addAll(nextView());
    } else if (page == 'someday') {
      children.addAll(somedayView());
    } else if (page == 'weekly') {
      children.addAll(weeklyView());
    } else if (page == 'home') {
      children.addAll(homeView());
    } else if (page == 'search') {
      children.addAll(searchView());
    } else if (page == 'ask') {
      children.add(
        title(
          '記録に聞く',
          'メモと作業要約だけを根拠に答えます。答えの文ごとに根拠の記録が付きます。\n読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
        ),
      );
      children.add(AskPanel(controller: c, onRecord: open));
    } else if (page == 'basket') {
      children.addAll(basketView());
    } else if (page == 'intake') {
      children.addAll(intakeView());
    } else {
      children.addAll(recordsView(page));
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: pageMaxWidth),
        child: ListView(
          key: ValueKey('${c.location?.handle}:$page'),
          padding: pagePadding(context),
          children: children,
        ),
      ),
    );
  }

  /// ホームのプロジェクト一覧の領域での絞り込み（この端末の表示だけ）。nullはすべて、[noAreaLabel]は領域なし。
  String? areaFilter;

  bool calendarOpening = false;

  /// 拡張から画面を描き直す（`setState`は`State`のサブクラスの中でしか呼べないため）。
  void refresh(VoidCallback change) => setState(change);
}
