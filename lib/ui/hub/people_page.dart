import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/controller.dart';
import '../../core/people.dart';
import '../../core/repository.dart';
import '../../storage/capture_service.dart';
import '../labels.dart';
import '../markdown_view.dart';
import '../notice.dart';
import '../parts.dart';
import '../people_view.dart';
import '../save_checks.dart';
import 'hub_common.dart';
import 'hub_view.dart';

/// 人ごとの見返しの画面と、人の登録・変更・外す。
extension HubPeople on HubViewState {
  /// 人の一覧。最後に出てきた日の新しい順。登録の依頼もここから送る。
  List<Widget> peopleView() {
    final people = repo.orderedPeople,
        waiting = repo.pendingPersonAdds,
        supported = repo.intakeFeatures.people;
    return [
      title('人', '登録した人の名前が出てくる記録と、関わる次の一手・未解決を集めます。名前の一致はAIを使わずに判定します。'),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: const Key('person-add'),
          onPressed:
              !supported || c.captureWarning != null || c.loading || c.saving
              ? null
              : addPerson,
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: const Text('人を登録'),
        ),
      ),
      if (!supported)
        const Padding(
          key: Key('people-unsupported'),
          padding: EdgeInsets.only(top: 12),
          child: NoticeBox(
            'Mac miniの本体がまだ人ごとの見返しに対応していません。本体を更新すると、人を登録できるようになります。',
          ),
        ),
      const SizedBox(height: 16),
      if (people.isEmpty && waiting.isEmpty)
        emptyText(
          context,
          'まだ登録した人はいません。よく一緒に仕事をする人や、返事を待っている人を登録すると、その人が出てくる記録をまとめて見返せます。',
          key: const Key('people-empty'),
        ),
      // 1人ずつの枠を並べず、1枚の面に行を並べる（最近のメモなどの一覧とそろえる）。
      if (people.isNotEmpty || waiting.isNotEmpty)
        groupCard([
          for (final person in people)
            ListTile(
              key: Key('person-${person.id}'),
              leading: const Icon(Icons.person_outline),
              title: Text(person.name),
              subtitle: Text(
                [
                  if (person.aliases.isNotEmpty)
                    '呼び名: ${person.aliases.join('、')}',
                  person.page == null
                      ? '一覧はまだ作られていません（次のAI読み取りで作られます）'
                      : '最後に出てきた日: ${person.lastSeen == null ? 'まだありません' : displayTime(person.lastSeen).substring(0, 10)} · 記録 ${person.records}件 · 未完了の項目 ${person.openItems}件',
                ].join('\n'),
                style: const TextStyle(height: 1.6),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onNavigate('person:${person.id}'),
            ),
          for (final pending in waiting)
            ListTile(
              key: Key('pending-person-${pending.personId}'),
              enabled: false,
              leading: const Icon(Icons.hourglass_empty),
              title: Text(pending.name),
              subtitle: Text(
                pending.state == 'accepted'
                    ? 'Mac miniが受け取り済み。人の定義の同期を待っています。'
                    : '登録を依頼済み（Mac miniでの処理を待っています）',
              ),
            ),
        ]),
    ];
  }

  /// 1人の画面。本体が作った一覧（SUMMARY.md）を、元の記録へのリンク付きで読む。
  List<Widget> personView(HubPerson person) {
    final page = person.page,
        requested = repo.personRequestIdFor(person.id) != null,
        busy =
            !repo.intakeFeatures.people ||
            c.captureWarning != null ||
            c.loading ||
            c.saving ||
            requested;
    return [
      title(
        label: '人',
        person.name,
        [
          if (person.aliases.isNotEmpty) '呼び名: ${person.aliases.join('、')}',
          if (page != null)
            '生成: ${timeLabel(page.generatedAt)} · 読み込み: ${timeLabel(repo.snapshot.loadedAt)}',
        ].join('\n'),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('person-edit'),
            onPressed: busy ? null : () => editPerson(person),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('名前と呼び名'),
          ),
          OutlinedButton.icon(
            key: const Key('person-remove'),
            onPressed: busy ? null : () => removePerson(person),
            icon: const Icon(Icons.person_remove_outlined, size: 18),
            label: const Text('登録を外す'),
          ),
        ],
      ),
      if (requested)
        const Padding(
          key: Key('person-requested'),
          padding: EdgeInsets.only(top: 12),
          child: NoticeBox('この人への依頼が反映待ちです。Mac miniで処理されると反映されます。'),
        ),
      const SizedBox(height: 16),
      if (page == null)
        const Text(
          'まだ一覧が作られていません。Mac miniで次のAI読み取りが終わり、同期されると表示されます。',
          key: Key('person-page-missing'),
          style: TextStyle(height: 1.7),
        )
      else ...[
        for (final warning in page.warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NoticeBox(warning),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: SafeMarkdown(
              key: const Key('person-body'),
              text: page.body,
              sourcePath: personPagePath(person.id),
              controller: c,
              onRecord: open,
            ),
          ),
        ),
      ],
    ];
  }

  Future<void> addPerson() async {
    final personId = newPersonId();
    final next = await showDialog<PersonDraft>(
      context: context,
      builder: (_) => PersonDialog(people: repo.peopleForOverlap),
    );
    if (next == null || !mounted) return;
    await sendPerson(
      () => c.requestPerson(personId, 'add', draft: next),
      '「${next.name}」の登録を依頼しました。Mac miniで処理されると、次のAI読み取りから一覧が作られます。',
    );
  }

  Future<void> editPerson(HubPerson person) async {
    final next = await showDialog<PersonDraft>(
      context: context,
      builder: (_) =>
          PersonDialog(person: person, people: repo.peopleForOverlap),
    );
    if (next == null || !mounted) return;
    await sendPerson(
      () => c.requestPerson(
        person.id,
        'edit',
        expectedHash: person.definitionHash,
        draft: next,
      ),
      '名前と呼び名の変更を依頼しました。Mac miniで処理されると反映されます。',
    );
  }

  Future<void> removePerson(HubPerson person) async {
    if (!await confirmAction(
          '${person.name}の登録を外す',
          '人の登録と、この人の一覧（SUMMARY.md）を消すよう依頼します。メモや作業要約などの記録は消えません。あとでもう一度登録できます。',
          '登録を外す',
        ) ||
        !mounted) {
      return;
    }
    await sendPerson(
      () => c.requestPerson(
        person.id,
        'remove',
        expectedHash: person.definitionHash,
      ),
      '登録を外す依頼をしました。Mac miniで処理されると反映されます。',
    );
  }

  Future<void> sendPerson(
    Future<CaptureResult> Function() send,
    String done,
  ) async {
    try {
      final result = await send();
      if (mounted) {
        notice(
          context,
          result.saved ? done : '保存結果を確認できません。保存と反映から同じ操作を確認してください。',
        );
      }
    } catch (e) {
      if (mounted) notice(context, HubController.message(e));
    }
  }
}
