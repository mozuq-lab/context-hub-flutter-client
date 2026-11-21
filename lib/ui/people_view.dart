import 'package:flutter/material.dart';
import '../core/people.dart';
import 'views.dart' show NoticeBox;

/// 人の登録と、名前・呼び名の変更。整えた内容（[PersonDraft]）を返し、依頼は呼び出し側が送る。
class PersonDialog extends StatefulWidget {
  const PersonDialog({super.key, this.person, required this.people});

  /// 変更する人。登録のときはnull。
  final HubPerson? person;

  /// 登録済みの人（名前・呼び名の重なりを送る前に知らせるため）。
  final Iterable<HubPerson> people;
  @override
  State<PersonDialog> createState() => _PersonDialogState();
}

class _PersonDialogState extends State<PersonDialog> {
  late final name = TextEditingController(text: widget.person?.name ?? ''),
      aliases = TextEditingController(
        text: widget.person?.aliases.join('\n') ?? '',
      );

  PersonDraft get draft => PersonDraft(
    name: name.text,
    aliases: PersonDraft.splitNames(aliases.text),
  );

  @override
  void initState() {
    super.initState();
    for (final t in [name, aliases]) {
      t.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    name.dispose();
    aliases.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = draft, person = widget.person;
    final overlap = next.overlap(widget.people, except: person?.id);
    final problem =
        (name.text.trim().isEmpty ? null : next.problem) ??
        (overlap == null
            ? null
            : '名前か呼び名が「${overlap.name}」と重なります。同じ名前・呼び名を2人に付けることはできません。');
    final unchanged = person != null && next.sameAs(person);
    return AlertDialog(
      key: const Key('person-dialog'),
      title: Text(person == null ? '人を登録' : '${person.name}の名前と呼び名'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'メモに書く呼び方で登録すると、その名前が出てくる記録と、名前が出てくる未完了の次の一手・未解決を、Mac miniが人ごとに集めます（AIは使いません）。同じ名前の別人や、名前を含む別の語も拾うことがあるため、呼び名は2文字以上にしてください。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('person-name'),
                controller: name,
                autofocus: person == null,
                maxLength: PersonDraft.maxChars,
                decoration: const InputDecoration(
                  labelText: '名前',
                  hintText: '例: 田中さん',
                ),
              ),
              TextField(
                key: const Key('person-aliases'),
                controller: aliases,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: '呼び名（1行に1つ、または読点で区切る）',
                  hintText: '例: 田中\nTanaka',
                  helperText:
                      '${next.aliases.length}/${PersonDraft.maxAliases}件',
                ),
              ),
              const SizedBox(height: 12),
              if (problem != null)
                NoticeBox(problem, error: true)
              else
                const Text(
                  '依頼は保存され、Mac miniで処理されると、次のAI読み取りから一覧が作られます。人の名前はこの端末と同期先のVaultにだけ残り、別のAIへ渡す文脈には含めません。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('やめる'),
        ),
        FilledButton(
          key: const Key('person-submit'),
          onPressed: next.problem != null || problem != null || unchanged
              ? null
              : () => Navigator.pop(context, next),
          child: Text(person == null ? '登録を依頼' : '変更を依頼'),
        ),
      ],
    );
  }
}
