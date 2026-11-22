import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mermaid_core/mermaid_core.dart' as core;
import 'package:mermaid_flutter/mermaid_flutter.dart';
import 'theme.dart';

/// Markdownの「```mermaid」ブロックを図として表示するときの要素名。
const mermaidTag = 'mermaid';

/// 図にする原文の上限。描画は画面の処理の中で同期して行うため、
/// 大きすぎる原文は図にせずコードのまま出して、画面が長く止まるのを避ける。
/// 文の数は行と「;」区切りを数える（1行に並べた文も数に入れる）。
const mermaidMaxChars = 10000, mermaidMaxStatements = 400;

/// 描いた図の一辺の上限（論理ピクセル）。原文の設定（間隔や文字の大きさ）で
/// 極端な大きさ・数でない大きさになった図は、描かずにコードのまま出す。
const mermaidMaxSide = 50000.0;

/// 原文の文の数（空でない行と、行の中の「;」区切り）。
int mermaidStatements(String source) => source
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .fold(0, (n, line) => n + 1 + ';'.allMatches(line).length);

/// 情報文字列の最初の語が `mermaid` の囲みコードブロックだけを、
/// [mermaidTag] の要素として取り出す。ほかのコードブロックは標準の処理に任せる。
class MermaidBlockSyntax extends md.FencedCodeBlockSyntax {
  const MermaidBlockSyntax();

  static final _info = RegExp(r'^ {0,3}(?:`{3,}([^`]*)|~{3,}(.*))$');

  @override
  bool canParse(md.BlockParser parser) {
    if (!super.canParse(parser)) {
      return false;
    }
    final m = _info.firstMatch(parser.current.content);
    final info = (m?.group(1) ?? m?.group(2) ?? '').trim();
    return info.split(RegExp(r'\s+')).first.toLowerCase() == 'mermaid';
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final pre = super.parse(parser);
    return md.Element.text(mermaidTag, pre.textContent);
  }
}

/// [mermaidTag] の要素を [MermaidBlock] にする。
class MermaidElementBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => MermaidBlock(source: element.textContent);
}

/// Mermaidの図。幅に収まらない図は縮めて全体を見せ、「拡大して見る」で
/// 拡大・移動できる画面を開く。図にできない原文はコードのまま表示する。
/// 図の中のリンクやクリック指定は扱わない（外部へは明示操作でだけ出る）。
class MermaidBlock extends StatefulWidget {
  const MermaidBlock({super.key, required this.source});
  final String source;

  /// 図を描いた回数（再構築で描き直していないことの確認に使う）。
  @visibleForTesting
  static int renderCount = 0;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  /// 明暗ごとの図の配色。明暗の切替の途中（色の補間中）に毎フレーム
  /// 描き直さないよう、補間中の色ではなくアプリのテーマの明暗から決める。
  static final _themes = <Brightness, core.MermaidTheme>{};

  bool _showSource = false;
  String? _builtSource;
  core.MermaidTheme? _builtTheme;
  core.RenderScene? _scene;

  bool get _tooLarge =>
      widget.source.length > mermaidMaxChars ||
      mermaidStatements(widget.source) > mermaidMaxStatements;

  /// 原文と配色が変わったときだけ描き直す。失敗したら図にしない。
  core.RenderScene? _render(core.MermaidTheme theme) {
    if (_builtSource != widget.source || _builtTheme != theme) {
      _builtSource = widget.source;
      _builtTheme = theme;
      MermaidBlock.renderCount++;
      try {
        final scene = core.Mermaid(
          measurer: const FlutterTextMeasurer(),
          theme: theme,
        ).render(widget.source);
        final w = scene.size.width, h = scene.size.height;
        _scene =
            w.isFinite &&
                h.isFinite &&
                w > 0 &&
                h > 0 &&
                w <= mermaidMaxSide &&
                h <= mermaidMaxSide
            ? scene
            : null;
      } catch (_) {
        _scene = null;
      }
    }
    return _scene;
  }

  /// [MermaidDiagram] に描いた結果を渡す。同じメソッドの参照は等しいので、
  /// 再構築のたびに描き直されない。
  core.RenderScene _sceneFor(String _, core.MermaidTheme _) => _scene!;

  @override
  Widget build(BuildContext context) {
    if (widget.source.trim().isEmpty) {
      return _MermaidSource(source: widget.source);
    }
    if (_tooLarge) {
      return _fallback(context, '図が大きすぎるため、コードのまま表示しています。');
    }
    final theme = Theme.of(context),
        mermaidTheme = _themes.putIfAbsent(
          theme.brightness,
          () => MaterialMermaidTheme.fromTheme(hubTheme(theme.brightness)),
        );
    if (_render(mermaidTheme) == null) {
      return _fallback(context, 'この図は表示できないため、コードのまま表示しています。');
    }
    return DecoratedBox(
      key: const Key('mermaid-block'),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 幅に収まらない図は縮めて全体を見せる（拡大はしない）。
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: MermaidDiagram(
                key: const Key('mermaid-diagram'),
                source: widget.source,
                theme: mermaidTheme,
                sceneRenderer: _sceneFor,
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                TextButton.icon(
                  key: const Key('mermaid-source-toggle'),
                  onPressed: () => setState(() => _showSource = !_showSource),
                  icon: Icon(
                    _showSource ? Icons.expand_less : Icons.code,
                    size: 18,
                  ),
                  label: Text(_showSource ? 'コードを閉じる' : 'コードを見る'),
                ),
                TextButton.icon(
                  key: const Key('mermaid-expand'),
                  onPressed: () => _expand(context, mermaidTheme),
                  icon: const Icon(Icons.zoom_out_map, size: 18),
                  label: const Text('拡大して見る'),
                ),
              ],
            ),
            if (_showSource)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _MermaidSource(source: widget.source),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context, String reason) => Column(
    key: const Key('mermaid-fallback'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        reason,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 4),
      _MermaidSource(source: widget.source),
    ],
  );

  /// 全画面で拡大・移動できるように開く。描いた結果をそのまま使う。
  void _expand(BuildContext context, core.MermaidTheme mermaidTheme) {
    final scene = _scene!, source = widget.source;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(leading: const CloseButton(), title: const Text('図')),
          body: _ExpandedDiagram(
            scene: scene,
            source: source,
            theme: mermaidTheme,
          ),
        ),
      ),
    );
  }
}

/// 拡大・移動できる図。開いたときは画面に収まる大きさから始める。
class _ExpandedDiagram extends StatefulWidget {
  const _ExpandedDiagram({
    required this.scene,
    required this.source,
    required this.theme,
  });
  final core.RenderScene scene;
  final String source;
  final core.MermaidTheme theme;

  @override
  State<_ExpandedDiagram> createState() => _ExpandedDiagramState();
}

class _ExpandedDiagramState extends State<_ExpandedDiagram> {
  static const _padding = 24.0;
  TransformationController? _transform;

  @override
  void dispose() {
    _transform?.dispose();
    super.dispose();
  }

  core.RenderScene _sceneFor(String _, core.MermaidTheme _) => widget.scene;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = widget.scene.size,
          width = size.width + _padding * 2,
          height = size.height + _padding * 2;
      final fit = [
        1.0,
        if (width > 0) constraints.maxWidth / width,
        if (height > 0) constraints.maxHeight / height,
      ].reduce(min).clamp(0.01, 1.0);
      _transform ??= TransformationController(
        Matrix4.diagonal3Values(fit, fit, 1),
      );
      return InteractiveViewer(
        key: const Key('mermaid-expanded'),
        transformationController: _transform,
        constrained: false,
        boundaryMargin: const EdgeInsets.all(200),
        // 画面の5倍より大きな図も全体を見られるよう、開いた倍率まで縮められる。
        minScale: min(0.2, fit),
        maxScale: 8,
        child: Padding(
          padding: const EdgeInsets.all(_padding),
          child: MermaidDiagram(
            source: widget.source,
            theme: widget.theme,
            sceneRenderer: _sceneFor,
          ),
        ),
      );
    },
  );
}

/// 図の原文。コードブロックと同じく選択でき、横にはみ出す行はスクロールする。
class _MermaidSource extends StatelessWidget {
  const _MermaidSource({required this.source});
  final String source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('mermaid-source'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        child: SelectableText(
          source.endsWith('\n')
              ? source.substring(0, source.length - 1)
              : source,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
    );
  }
}
