import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../../app/controller.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../storage/basket_store.dart';
import '../labels.dart';
import '../notice.dart';
import '../parts.dart';
import '../save_checks.dart';
import 'hub_common.dart';
import 'hub_view.dart';
import 'unassigned_section.dart';

/// 一致箇所の前後を抜き出す。最初に見つかった語の少し前から始める。
/// 本文は検索と同じくNFKCで正規化してから探す（全角・半角の違いでも一致箇所を示す）。
String searchSnippet(String body, List<String> words) {
  final text = unicode.nfkc(body).replaceAll(RegExp(r'\s+'), ' ').trim();
  var start = 0;
  for (final w in words) {
    final m = RegExp(RegExp.escape(w), caseSensitive: false).firstMatch(text);
    if (m != null) {
      start = m.start > 40 ? m.start - 40 : 0;
      break;
    }
  }
  if (start > text.length) start = text.length;
  var end = start + 160 < text.length ? start + 160 : text.length;
  // サロゲートペアの途中で切らない。
  bool low(int i) =>
      i > 0 && i < text.length && (text.codeUnitAt(i) & 0xFC00) == 0xDC00;
  if (low(start)) start--;
  if (low(end)) end--;
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}

/// 抜粋の中の検索語を強調する。大文字・小文字は区別しない。
List<TextSpan> highlightSpans(String text, List<String> words, Color color) {
  // 長い語を先に試し、「a|ab」のように一部だけ強調しない。
  final pattern =
      (words.where((w) => w.isNotEmpty).toList()
            ..sort((a, b) => b.length.compareTo(a.length)))
          .map(RegExp.escape)
          .join('|');
  if (pattern.isEmpty) return [TextSpan(text: text)];
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in RegExp(pattern, caseSensitive: false).allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    spans.add(
      TextSpan(
        text: m.group(0),
        style: TextStyle(fontWeight: FontWeight.bold, backgroundColor: color),
      ),
    );
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

/// 検索と文脈かご。
extension HubSearch on HubViewState {
  /// 検索条件を変えたら、表示件数を最初のページに戻す。
  void updateSearch(void Function() change) => refresh(() {
    change();
    shown = HubViewState.pageSize;
  });

  SearchFilter get searchFilter {
    final now = DateTime.now();
    return SearchFilter(
      project: searchProject,
      kinds: {...selectedKinds},
      since: searchDays == null
          ? null
          : now.subtract(Duration(days: searchDays!)),
      sort: searchSort,
    );
  }

  /// 文脈かご。選んだ記録を並べ、出典・方針付きの1つの文章としてコピーする。
  List<Widget> basketView() {
    final ids = c.basket.ids, missing = c.missingInBasket.toSet();
    final out = <Widget>[
      title(
        '文脈かご',
        '別のAIに渡す記録を集めます。コピーすると、出典と注意書き付きの1つの文章になります。中身はこの端末だけに残ります。',
      ),
    ];
    if (ids.isEmpty) {
      out.add(
        const Text(
          'かごは空です。記録の一覧や詳細で ⊕ を押すと、ここに入ります。',
          key: Key('basket-empty'),
        ),
      );
      return out;
    }
    out.add(
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            key: const Key('copy-bundle'),
            onPressed: c.loading || missing.isNotEmpty
                ? null
                : () async {
                    try {
                      final result = await c.bundleContext();
                      await Clipboard.setData(ClipboardData(text: result.text));
                      if (mounted) {
                        notice(
                          context,
                          result.omitted.isEmpty
                              ? '${result.included.length}件をまとめてコピーしました'
                              : '${result.included.length}件をコピーしました。上限に収まらない${result.omitted.length}件は省き、末尾にIDを示しています',
                        );
                      }
                    } catch (e) {
                      if (mounted) notice(context, HubController.message(e));
                    }
                  },
            icon: const Icon(Icons.copy, size: 18),
            label: Text('${ids.length}件をまとめてコピー'),
          ),
          SegmentedButton<int>(
            key: const Key('basket-limit'),
            segments: [
              for (final limit in Basket.limits)
                ButtonSegment(value: limit, label: Text('$limit字')),
            ],
            selected: {c.basket.maxChars},
            onSelectionChanged: (v) => c.setBasketLimit(v.first),
          ),
          TextButton(
            key: const Key('basket-clear'),
            onPressed: () async {
              final yes = await showDialog<bool>(
                context: context,
                builder: (dialog) => HubAlertDialog(
                  title: const Text('かごを空にしますか'),
                  onClose: () => Navigator.pop(dialog, false),
                  content: Text('${ids.length}件をかごから外します。記録そのものは消えません。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('やめる'),
                    ),
                    FilledButton(
                      key: const Key('basket-clear-confirm'),
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('空にする'),
                    ),
                  ],
                ),
              );
              if (yes == true) await c.clearBasket();
            },
            child: const Text('かごを空にする'),
          ),
        ],
      ),
    );
    out.add(const SizedBox(height: 8));
    out.add(
      Text(
        '上限（${c.basket.maxChars}字）に収まらない記録は、本文の途中で切らずに丸ごと省きます。方針は必ず含めます。',
        style: noteStyle(context),
      ),
    );
    if (missing.isNotEmpty) {
      out.add(
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: NoticeBox(
            'このVaultで見つからない記録があります。同期を待つか、かごから外してからコピーしてください。',
            error: true,
          ),
        ),
      );
    }
    out.add(const SizedBox(height: 16));
    final rows = <Widget>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i], record = repo.records[id];
      rows.add(
        ListTile(
          key: Key('basket-item-$i'),
          contentPadding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          leading: Text(
            '${i + 1}',
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          title: Text(
            record == null || missing.contains(id) ? '見つからない記録' : record.title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: record == null || missing.contains(id)
              ? const Text('同期で消えたか、まだ届いていません。')
              : Text(
                  '${searchKindLabels[HubRepository.searchKindOf(record)] ?? record.kind} · ${originLabel(record.origin)} · ${recordWhen(record)}'
                  '${(repo.correctionChainOf(id)?.length ?? 1) > 1 ? '\n訂正あり（最新の訂正の本文を渡します）' : ''}',
                  style: noteStyle(context),
                ),
          onTap: record == null || missing.contains(id) ? null : () => open(id),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('basket-up-$i'),
                tooltip: '上へ',
                onPressed: i == 0 ? null : () => c.moveInBasket(i, i - 1),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                key: Key('basket-down-$i'),
                tooltip: '下へ',
                onPressed: i == ids.length - 1
                    ? null
                    : () => c.moveInBasket(i, i + 1),
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                key: Key('basket-remove-$i'),
                tooltip: 'かごから外す',
                onPressed: () => c.removeFromBasket(id),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      );
    }
    if (rows.isNotEmpty) out.add(groupCard(rows));
    return out;
  }

  /// 検索画面。検索語と、プロジェクト・種類・期間・並び順の絞り込み。
  List<Widget> searchView() {
    // 同期で消えたプロジェクトが選ばれたままにならないようにする。
    if (searchProject != null && !repo.projects.containsKey(searchProject)) {
      searchProject = null;
    }
    final words = HubRepository.searchTokens(query);
    final filter = searchFilter;
    final unassignedShelf =
        repo.referenceIndex != null &&
        (repo.unassignedReferences.isNotEmpty ||
            repo.unassignedRemovedReferences.isNotEmpty);
    final out = <Widget>[
      title('検索', 'タイトルと本文から探します。語は空白で区切ります。絞り込みだけでも一覧できます。'),
      if (unassignedShelf)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('unassigned-shelf'),
              style: compactOutlinedStyle(context),
              onPressed: showUnassignedShelf,
              icon: const Icon(Icons.bookmarks_outlined, size: 18),
              label: Text('プロジェクト未定の資料（${repo.unassignedReferences.length}件）'),
            ),
          ),
        ),
      TextField(
        key: const Key('search-query'),
        controller: queryController,
        focusNode: widget.searchFocus,
        decoration: const InputDecoration(
          hintText: '思い出したいことを入力',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (v) => updateSearch(() => query = v),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: DropdownButtonFormField<String>(
              key: const Key('search-project'),
              style: fieldTextStyle(context),
              initialValue: searchProject ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'プロジェクト'),
              items: [
                const DropdownMenuItem(value: '', child: Text('すべて')),
                for (final p in repo.orderedProjects)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(p.title, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) =>
                  updateSearch(() => searchProject = v == '' ? null : v),
            ),
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<int>(
              key: const Key('search-period'),
              style: fieldTextStyle(context),
              initialValue: searchDays ?? 0,
              decoration: const InputDecoration(labelText: '期間'),
              items: const [
                DropdownMenuItem(value: 0, child: Text('すべて')),
                DropdownMenuItem(value: 7, child: Text('直近7日')),
                DropdownMenuItem(value: 30, child: Text('直近30日')),
                DropdownMenuItem(value: 90, child: Text('直近90日')),
                DropdownMenuItem(value: 365, child: Text('直近1年')),
              ],
              onChanged: (v) =>
                  updateSearch(() => searchDays = v == 0 ? null : v),
            ),
          ),
          SegmentedButton<String>(
            key: const Key('search-sort'),
            segments: const [
              ButtonSegment(value: 'relevance', label: Text('一致の多い順')),
              ButtonSegment(value: 'newest', label: Text('新しい順')),
            ],
            selected: {words.isEmpty ? 'newest' : searchSort},
            onSelectionChanged: words.isEmpty
                ? null
                : (v) => updateSearch(() => searchSort = v.first),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kind in searchKinds)
            FilterChip(
              key: Key('search-kind-$kind'),
              // 複数を選べる札は、色だけに頼らず印でも選んだことを示す。
              showCheckmark: true,
              label: Text(searchKindLabels[kind]!),
              selected: selectedKinds.contains(kind),
              onSelected: (on) => updateSearch(
                () => on ? selectedKinds.add(kind) : selectedKinds.remove(kind),
              ),
            ),
          if (filter.active)
            TextButton(
              key: const Key('search-clear'),
              onPressed: () => updateSearch(() {
                searchProject = null;
                selectedKinds.clear();
                searchDays = null;
              }),
              child: const Text('条件をクリア'),
            ),
        ],
      ),
      const SizedBox(height: 20),
    ];
    if (words.isEmpty && !filter.active) {
      out.add(const Text('語を入力するか、条件で絞り込んでください。'));
      return out;
    }
    // 画面の再構築（入力・続きの読み込み・保存中の通知）ごとに全件を検索し直さない。
    final key = (
      repo,
      query,
      searchProject,
      (selectedKinds.toList()..sort()).join(','),
      searchDays,
      searchSort,
    );
    if (searchCacheKey != key) {
      searchCacheKey = key;
      searchCache = repo.search(query, filter);
    }
    final results = searchCache;
    out.add(
      Text(
        '${results.length}件',
        key: const Key('search-count'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
    out.add(const SizedBox(height: 10));
    if (results.isNotEmpty) {
      out.add(
        recordList(
          results.take(shown),
          keyOf: (_) => const Key('search-result'),
          words: words,
          badgeOf: (r) =>
              searchProject != null &&
                  repo.projectRelation(r, searchProject!) == 'estimated'
              ? 'AI推定の関連（帰属未確定）'
              : null,
        ),
      );
    }
    out.add(moreButton(results.length));
    return out;
  }
}
