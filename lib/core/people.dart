import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'models.dart';
import 'parser.dart';

/// 人ごとの見返し。本体が `40_people/` に作る、本人が登録した人の定義（person.md）と、
/// その人の名前が出てくる記録と未完了の項目の一覧（SUMMARY.md）を読む。
/// 名前の一致は本体がモデルを使わずに判定する。アプリは読むことと、登録・変更・外す依頼だけを行う。
const peopleDir = '40_people';
final personIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,40}$');
final _definitionPath = RegExp(r'^40_people/([^/]+)/person\.md$');
String personDefinitionPath(String id) => '$peopleDir/$id/person.md';
String personPagePath(String id) => '$peopleDir/$id/SUMMARY.md';

/// アプリから登録する人のID（本体のプロジェクト作成と同じ、時刻順の26文字）。
String newPersonId() => 'person-${newProjectId().substring('project-'.length)}';

class HubPerson {
  HubPerson({
    required this.id,
    required this.name,
    required this.aliases,
    required this.definitionHash,
  });
  final String id, name, definitionHash;
  final List<String> aliases;

  /// 本体が生成した一覧（SUMMARY.md）。まだ作られていない、または古い本体ならnull。
  HubDigest? page;

  /// SUMMARY.mdのfrontmatterにある件数と、名前が最後に出てきた日時。
  int records = 0, openItems = 0;
  DateTime? lastSeen;
}

/// 本体と同じ比べ方（NFKCで全角・半角をそろえ、小文字にし、前後の空白を除く）。
String foldName(String value) => unicode.nfkc(value).toLowerCase().trim();

/// アプリで入力した名前と呼び名。整えた値を持ち、上限は本体と同じにする。
class PersonDraft {
  PersonDraft({required String name, required List<String> aliases})
    : name = _clean(name),
      aliases = _aliases(_clean(name), aliases);
  final String name;
  final List<String> aliases;
  static const maxChars = 100, maxAliases = 20, minChars = 2;

  static String _clean(String value) =>
      value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

  /// 空の呼び名と、名前や前の呼び名と同じもの（全角・半角、大文字・小文字の違いを含む）を除く。
  static List<String> _aliases(String name, List<String> values) {
    final seen = {foldName(name)}, result = <String>[];
    for (final value in values) {
      final alias = _clean(value);
      if (alias.isEmpty || !seen.add(foldName(alias))) continue;
      result.add(alias);
    }
    return result;
  }

  /// カンマ・読点・改行で区切った呼び名。
  static List<String> splitNames(String value) => [
    for (final name in value.split(RegExp(r'[,、，\r\n]')).map((s) => s.trim()))
      if (name.isNotEmpty) name,
  ];

  List<String> get terms => [name, ...aliases];

  /// 本体の上限に合わなければ利用者向けの説明。問題なければnull。
  String? get problem {
    if (name.isEmpty) return '名前を入力してください。';
    if (aliases.length > maxAliases) return '呼び名は$maxAliases件までにしてください。';
    for (final term in terms) {
      if (term.length > maxChars) return '名前・呼び名は1件$maxChars文字までにしてください。';
      if (foldName(term).runes.length < minChars) {
        return '名前・呼び名は$minChars文字以上にしてください（1文字の名前はほかの語に紛れやすいため）。';
      }
    }
    return null;
  }

  /// ほかの人の名前・呼び名と重なれば、その人。本体も同じ理由で受け付けない。
  HubPerson? overlap(Iterable<HubPerson> people, {String? except}) {
    final mine = terms.map(foldName).toSet();
    for (final person in people) {
      if (person.id == except) continue;
      if ([
        person.name,
        ...person.aliases,
      ].any((t) => mine.contains(foldName(t)))) {
        return person;
      }
    }
    return null;
  }

  bool sameAs(HubPerson person) =>
      name == person.name &&
      aliases.length == person.aliases.length &&
      [for (var i = 0; i < aliases.length; i++) aliases[i] == person.aliases[i]]
          .every((x) => x);
}

/// `40_people/` の定義と一覧を読む。読めないファイルはproblemに渡し、表示から外す。
Map<String, HubPerson> readPeople(
  Map<String, String> files,
  void Function(String path) problem,
) {
  final people = <String, HubPerson>{};
  for (final e in files.entries) {
    final match = _definitionPath.firstMatch(e.key);
    if (match == null) continue;
    try {
      final m = parseMarkdown(e.value).meta, id = m['id'];
      if (id is! String ||
          !personIdPattern.hasMatch(id) ||
          id != match.group(1) ||
          m['name'] is! String ||
          (m['name'] as String).trim().isEmpty ||
          m['aliases'] is! List ||
          (m['aliases'] as List).any((a) => a is! String) ||
          // 本体と同じく、ほかの項目・短すぎる名前・長すぎる名前・多すぎる呼び名の定義は読まない
          // （本体が一覧を作らない人を、一覧待ちのまま出し続けないため）。
          m.keys.any((k) => !const {'id', 'name', 'aliases'}.contains(k)) ||
          (m['aliases'] as List).length > PersonDraft.maxAliases ||
          [m['name'], ...m['aliases'] as List].any(
            (t) =>
                (t as String).length > PersonDraft.maxChars ||
                foldName(t).runes.length < PersonDraft.minChars,
          )) {
        throw const FormatException();
      }
      people[id] = HubPerson(
        id: id,
        name: (m['name'] as String).trim(),
        aliases: [for (final a in m['aliases'] as List) (a as String).trim()],
        definitionHash: digest(e.value),
      );
    } catch (_) {
      problem(e.key);
    }
  }
  for (final person in people.values) {
    final path = personPagePath(person.id), raw = files[path];
    if (raw == null) continue;
    try {
      final doc = parseMarkdown(raw), m = doc.meta;
      if (m['schema_version'] != 1 || m['person'] != person.id) {
        throw const FormatException();
      }
      final page = HubDigest(
        body: doc.body,
        generatedAt: timestamp(m['generated_at']),
      );
      page.warnings
        ..clear()
        ..add('名前・呼び名が本文に出てくる記録を本体が集めた一覧です。同じ名前の別人や、名前を含む別の語も拾うことがあります。');
      if (!generatedIntact(raw, m)) {
        page.warnings.add('一覧の整合性を確認できません。手動変更や同期の途中の可能性があります。');
      }
      person.page = page;
      person.records = m['records'] is int ? m['records'] as int : 0;
      person.openItems = m['open_items'] is int ? m['open_items'] as int : 0;
      person.lastSeen = timestamp(m['last_seen']);
    } catch (_) {
      problem(path);
    }
  }
  return people;
}
