import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:context_hub_client/app/controller.dart';
import 'package:context_hub_client/ui/markdown_view.dart';
import 'package:context_hub_client/ui/mermaid_block.dart';
import 'package:context_hub_client/ui/theme.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mermaid_flutter/mermaid_flutter.dart';
import 'widget_test.dart' show MemoryUIAccess;

const flow = '''```mermaid
flowchart TD
  A[メモを書く] --> B{整理する？}
  B -->|はい| C[次の一手]
  B -->|いいえ| D[あとで見る]
```''';

void main() {
  Future<void> show(
    WidgetTester tester,
    String text, {
    ThemeMode mode = ThemeMode.light,
  }) async {
    final c = HubController(MemoryUIAccess(), sampleLoader: () async => {});
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: hubTheme(Brightness.light),
        darkTheme: hubTheme(Brightness.dark),
        themeMode: mode,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SafeMarkdown(
              text: text,
              sourcePath: '00_inbox/a.md',
              controller: c,
              onRecord: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  group('Mermaidの囲みブロック', () {
    test('情報文字列の最初の語がmermaidのものだけを図の要素にする', () {
      List<String> tags(String text) => [
        for (final n in md.Document(
          blockSyntaxes: const [MermaidBlockSyntax()],
          extensionSet: md.ExtensionSet.gitHubFlavored,
          encodeHtml: false,
        ).parseLines(text.split('\n')))
          if (n is md.Element) n.tag,
      ];
      expect(tags(flow), [mermaidTag]);
      expect(tags('~~~ Mermaid title\ngraph LR\n  A-->B\n~~~'), [mermaidTag]);
      expect(tags('```dart\nvoid main() {}\n```'), ['pre']);
      expect(tags('```mermaidx\ngraph LR\n```'), ['pre']);
      expect(tags('```\ngraph LR\n```'), ['pre']);
      final node = md.Document(
        blockSyntaxes: const [MermaidBlockSyntax()],
        encodeHtml: false,
      ).parseLines(flow.split('\n')).single;
      expect(node.textContent, contains('A[メモを書く] --> B{整理する？}'));
    });

    testWidgets('図として表示し、ほかのコードブロックはコードのまま出す', (tester) async {
      await show(tester, '# 見出し\n\n$flow\n\n```dart\nfinal x = 1;\n```\n');
      expect(find.byType(MermaidDiagram), findsOneWidget);
      expect(find.byKey(const Key('mermaid-fallback')), findsNothing);
      // 図の原文は、開くまで出さない。
      expect(find.textContaining('flowchart TD'), findsNothing);
      expect(find.textContaining('final x = 1;'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('mermaid-source-toggle')));
      await tester.pump();
      expect(find.textContaining('flowchart TD'), findsOneWidget);
      expect(find.text('コードを閉じる'), findsOneWidget);
    });

    testWidgets('リスト・引用の中の囲みや、~~~の囲みも図にする', (tester) async {
      await show(
        tester,
        '- 手順\n\n  ```mermaid\n  graph LR\n    A-->B\n  ```\n\n'
        '> 引用\n>\n> ```mermaid\n> graph LR\n>   C-->D\n> ```\n\n'
        '~~~~ mermaid 題\ngraph LR\n  E-->F\n~~~~\n',
      );
      expect(find.byType(MermaidDiagram), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('拡大して見ると、全画面で拡大・移動でき、閉じて戻れる', (tester) async {
      await show(tester, flow);
      await tester.tap(find.byKey(const Key('mermaid-expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mermaid-expanded')), findsOneWidget);
      expect(find.byType(MermaidDiagram), findsNWidgets(2));
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mermaid-expanded')), findsNothing);
      expect(find.byType(MermaidDiagram), findsOneWidget);
    });

    testWidgets('図にできない原文は、理由を添えてコードのまま出す', (tester) async {
      await show(tester, '```mermaid\nこれは図ではない\n```');
      expect(find.byType(MermaidDiagram), findsNothing);
      expect(find.byKey(const Key('mermaid-fallback')), findsOneWidget);
      expect(find.textContaining('この図は表示できない'), findsOneWidget);
      expect(find.textContaining('これは図ではない'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('文の数は、空でない行と行の中の「;」区切りを数える', () {
      expect(mermaidStatements('graph TD\n  A-->B\n\n  B-->C\n'), 3);
      expect(mermaidStatements('graph TD; A-->B; B-->C'), 3);
    });

    testWidgets('文の数が上限ちょうどなら描き、超えたらコードのまま出す', (tester) async {
      String source(int statements) => [
        'graph TD',
        for (var i = 1; i < statements; i++) '  N$i --> N${i + 1}',
      ].join('\n');
      await show(tester, '```mermaid\n${source(mermaidMaxStatements)}\n```');
      expect(find.byType(MermaidDiagram), findsOneWidget);
      await show(
        tester,
        '```mermaid\n${source(mermaidMaxStatements + 1)}\n```',
      );
      expect(find.byType(MermaidDiagram), findsNothing);
      expect(find.textContaining('図が大きすぎる'), findsOneWidget);
    });

    testWidgets('1行に「;」で並べて上限を超える原文も、コードのまま出す', (tester) async {
      final body = [
        for (var i = 0; i < mermaidMaxStatements; i++) 'N$i-->N${i + 1}',
      ].join(';');
      await show(tester, '```mermaid\ngraph TD;$body\n```');
      expect(find.byType(MermaidDiagram), findsNothing);
      expect(find.textContaining('図が大きすぎる'), findsOneWidget);
    });

    testWidgets('原文が長すぎるときも、コードのまま出す', (tester) async {
      await show(
        tester,
        '```mermaid\ngraph TD\n  A["${'あ' * mermaidMaxChars}"]\n```',
      );
      expect(find.byType(MermaidDiagram), findsNothing);
      expect(find.textContaining('図が大きすぎる'), findsOneWidget);
    });

    testWidgets('設定で極端な大きさになる図は、描かずにコードのまま出す', (tester) async {
      for (final init in [
        '{"flowchart": {"nodeSpacing": 1e308, "rankSpacing": 1e308}}',
        '{"themeVariables": {"fontSize": "100000000px"}}',
      ]) {
        await show(
          tester,
          '```mermaid\n%%{init: $init}%%\ngraph TD\nA-->B\nA-->C\n```',
        );
        expect(find.byType(MermaidDiagram), findsNothing, reason: init);
        expect(find.byKey(const Key('mermaid-fallback')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: init);
      }
    });

    testWidgets('空のブロックは、空のコードとして出す', (tester) async {
      await show(tester, '```mermaid\n```');
      expect(find.byType(MermaidDiagram), findsNothing);
      expect(find.byKey(const Key('mermaid-source')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('再構築では描き直さず、明暗の切替では1回だけ描き直す', (tester) async {
      await show(tester, flow);
      final before = MermaidBlock.renderCount;
      // 「コードを見る」で図の部品だけを作り直しても、描き直さない。
      await tester.tap(find.byKey(const Key('mermaid-source-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mermaid-source-toggle')));
      await tester.pump();
      expect(MermaidBlock.renderCount, before);
      // 暗い表示へ切り替える間（色の補間中）も、描き直すのは明暗が変わる1回だけ。
      await show(tester, flow, mode: ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(MermaidBlock.renderCount, before + 1);
      expect(find.byType(MermaidDiagram), findsOneWidget);
    });

    testWidgets('画面より何倍も大きな図も、拡大の画面では全体が収まる倍率から始まる', (tester) async {
      final nodes = [for (var i = 0; i < 60; i++) 'N$i[段階$i]'].join(' --> ');
      await show(tester, '```mermaid\nflowchart LR\n  $nodes\n```');
      await tester.tap(find.byKey(const Key('mermaid-expand')));
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.byKey(const Key('mermaid-expanded')),
      );
      final scale = viewer.transformationController!.value.entry(0, 0);
      expect(scale, lessThan(0.2));
      expect(viewer.minScale, lessThanOrEqualTo(scale));
    });
  });
}
