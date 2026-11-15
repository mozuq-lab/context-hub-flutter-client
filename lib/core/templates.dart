/// メモのひな形。見出しを本文欄へ差し込み、書き漏れを減らすための端末内の補助。
/// Vaultには書かず、本体も関知しない（保存される本文はふつうのメモと同じ）。
class MemoTemplate {
  const MemoTemplate({
    required this.id,
    required this.name,
    required this.body,
    this.projects = const {},
  });
  final String id, name, body;

  /// Vaultのidentityごとの、このひな形の既定のプロジェクト。
  /// プロジェクトIDはVaultごとに別物なので、Vaultをまたいで使わない。
  final Map<String, String> projects;

  static const maxNameChars = 40;
  static const maxBodyChars = 1000;

  /// 1つのひな形が既定のプロジェクトを覚えておくVaultの数。超えたら古いものから忘れる。
  static const maxVaults = 5;

  MemoTemplate copyWith({
    String? name,
    String? body,
    Map<String, String>? projects,
  }) => MemoTemplate(
    id: id,
    name: name ?? this.name,
    body: body ?? this.body,
    projects: projects ?? this.projects,
  );

  /// このVaultでの既定のプロジェクトを[project]にする（nullなら外す）。
  MemoTemplate withProject(String identity, String? project) {
    final next = {...projects}..remove(identity);
    if (project != null) {
      while (next.length >= maxVaults) {
        next.remove(next.keys.first);
      }
      next[identity] = project;
    }
    return copyWith(projects: next);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'body': body,
    if (projects.isNotEmpty) 'projects': projects,
  };

  /// 形式や長さが合わない記録はnull（読み飛ばす）。
  static MemoTemplate? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'], name = value['name'], body = value['body'];
    final projects = value['projects'];
    if (id is! String ||
        !_id.hasMatch(id) ||
        name is! String ||
        body is! String ||
        templateNameError(name) != null ||
        templateBodyError(body) != null ||
        (projects != null && projects is! Map)) {
      return null;
    }
    final map = <String, String>{};
    if (projects is Map) {
      for (final e in projects.entries) {
        if (map.length >= maxVaults) break;
        final k = e.key, v = e.value;
        if (k is String && v is String && k.isNotEmpty && v.isNotEmpty) {
          map[k] = v;
        }
      }
    }
    return MemoTemplate(id: id, name: name, body: body, projects: map);
  }

  static final _id = RegExp(r'^[a-z0-9-]{1,64}$');
}

/// 端末に置けるひな形の数。
const maxTemplates = 12;

/// 最初から入っているひな形。本人が編集・削除・並べ替えするまではこの並びを使う。
const defaultTemplates = [
  MemoTemplate(
    id: 'default-meeting',
    name: '会議',
    body: '## 決まったこと\n\n## 次にやること\n\n## 持ち越し\n',
  ),
  MemoTemplate(
    id: 'default-bug',
    name: '不具合',
    body: '## 起きたこと\n\n## 再現手順\n\n## 気づき\n',
  ),
  MemoTemplate(
    id: 'default-reading',
    name: '読んだもの',
    body: '## 出典\n\n## 要点\n\n## 自分の考え\n',
  ),
  MemoTemplate(
    id: 'default-checkpoint',
    name: '作業の区切り',
    body: '## やったこと\n\n## 次にやること\n\n## 詰まっていること\n',
  ),
];

String? templateNameError(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > MemoTemplate.maxNameChars) {
    return '名前は1〜${MemoTemplate.maxNameChars}文字で入力してください。';
  }
  if (n.contains('\n') || n.contains('\r')) return '名前に改行は使えません。';
  return null;
}

String? templateBodyError(String body) {
  if (body.trim().isEmpty || body.length > MemoTemplate.maxBodyChars) {
    return '本文は1〜${MemoTemplate.maxBodyChars}文字で入力してください。';
  }
  return null;
}

final _heading = RegExp(r'^(#{1,6})[ \t]+\S');

/// コードブロックのフェンス。開いたときと同じ記号で、同じ長さ以上、後ろに文字のない行だけが閉じる。
final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// 行が見出しなら、その深さ（1〜6）。見出しでなければnull。
int? _level(String line) => _heading.firstMatch(line)?.group(1)!.length;

List<String> _lines(String text) => text.replaceAll('\r\n', '\n').split('\n');

/// ひな形の本文に含まれる見出しの行（行末の空白を除く）。
Set<String> templateHeadings(Iterable<MemoTemplate> templates) => {
  for (final t in templates)
    for (final line in _lines(t.body))
      if (_level(line) != null) line.trimRight(),
};

/// ひな形を本文へ差し込んだ結果と、書き始める位置（最初の見出しの次の行）。
///
/// カーソルの位置には関係なく、本文が空なら全体を、空でなければ末尾に空行を挟んで足す。
/// 途中へ割り込ませないので、書きかけの文を壊さない。
({String text, int cursor}) insertTemplate(String current, String body) {
  final template = _lines(body).join('\n').trim();
  final kept = current.trimRight();
  final head = kept.isEmpty ? '' : '$kept\n\n';
  final text = '$head$template\n';
  final lines = template.split('\n');
  final first = lines.indexWhere((l) => _level(l) != null);
  // 見出しの次の行の先頭へ。見出しがないひな形では末尾へ。
  var offset = head.length;
  if (first < 0) return (text: text, cursor: text.length);
  for (var i = 0; i <= first; i++) {
    offset += lines[i].length + 1;
  }
  return (text: text, cursor: offset > text.length ? text.length : offset);
}

/// 中身を書かなかったひな形の見出しを本文から取り除く。
///
/// 空の見出しをAIが「内容のある項目」と読み違えないようにするためで、取り除くのは
/// [headings]（この端末のひな形にある見出し）と同じ行で、次の同じ深さ以上の見出しまでに
/// 文章がないものだけ。ひな形にない見出しと、コードブロックの中は変えない。
/// 本人が自分で打った見出しでも、ひな形の見出しと同じ行で中身がなければ取り除く
/// （書きかけを開き直した後は、どの見出しが差し込みで入ったかを区別できないため）。
/// 取り除くものがなければ[text]をそのまま返す。取り除いたときは、改行をLFに揃え、末尾の空行を1つにする。
String stripEmptyTemplateHeadings(String text, Set<String> headings) {
  if (headings.isEmpty) return text;
  final lines = _lines(text);
  // 行ごとの種類: ひな形の見出しの深さ、ほかの見出しの深さ、文章かどうか。
  final template = List<int?>.filled(lines.length, null);
  final other = List<int?>.filled(lines.length, null);
  final content = List<bool>.filled(lines.length, false);
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final match = _fence.firstMatch(line), mark = match?.group(1);
    if (fence != null) {
      content[i] = true;
      if (mark != null &&
          mark[0] == fence[0] &&
          mark.length >= fence.length &&
          match!.group(2)!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (mark != null) {
      fence = mark;
      content[i] = true;
      continue;
    }
    final level = _level(line);
    if (level != null && headings.contains(line.trimRight())) {
      template[i] = level;
    } else if (level != null) {
      other[i] = level;
      content[i] = true;
    } else {
      content[i] = line.trim().isNotEmpty;
    }
  }
  final remove = <int>{};
  for (var i = 0; i < lines.length; i++) {
    final level = template[i];
    if (level == null) continue;
    var empty = true;
    for (var j = i + 1; j < lines.length; j++) {
      final next = template[j] ?? other[j];
      if (next != null && next <= level) break;
      if (content[j]) {
        empty = false;
        break;
      }
    }
    if (empty) remove.add(i);
  }
  if (remove.isEmpty) return text;
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (remove.contains(i)) {
      // 見出しの前後の空行が重ならないよう、直後の空行も一緒に除く。
      while (i + 1 < lines.length &&
          !remove.contains(i + 1) &&
          template[i + 1] == null &&
          other[i + 1] == null &&
          !content[i + 1]) {
        i++;
      }
      continue;
    }
    out.add(lines[i]);
  }
  final joined = out.join('\n').trimRight();
  return joined.isEmpty ? '' : '$joined\n';
}
