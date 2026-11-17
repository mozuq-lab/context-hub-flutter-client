import 'package:flutter/material.dart';

/// 操作と強調に使う色（落ち着いた藍色）。面の色には使わない。
const hubAccent = Color(0xff3f5bd6);

/// 面の色の組。色味のない灰色で、アクセントの色を目立たせる。
class _Surfaces {
  const _Surfaces({
    required this.background,
    required this.surface,
    required this.lowest,
    required this.low,
    required this.container,
    required this.high,
    required this.highest,
    required this.onSurface,
    required this.onVariant,
    required this.outline,
    required this.outlineVariant,
  });

  /// 本文の背景（ScaffoldとAppBar）。
  final Color background;

  /// サイドバーやダイアログなど、本文から一段持ち上げた面。
  final Color surface;
  final Color lowest, low, container, high, highest;
  final Color onSurface, onVariant, outline, outlineVariant;
}

const _light = _Surfaces(
  background: Color(0xfff6f7f9),
  surface: Color(0xffffffff),
  lowest: Color(0xffffffff),
  low: Color(0xffffffff),
  container: Color(0xfff1f2f5),
  high: Color(0xffebedf0),
  highest: Color(0xffe4e6ea),
  onSurface: Color(0xff1b1d22),
  onVariant: Color(0xff5a5f6a),
  outline: Color(0xff878c96),
  outlineVariant: Color(0xffe1e3e8),
);

const _dark = _Surfaces(
  background: Color(0xff121316),
  surface: Color(0xff18191d),
  lowest: Color(0xff0e0f11),
  low: Color(0xff1c1d21),
  container: Color(0xff212226),
  high: Color(0xff292a2f),
  highest: Color(0xff313238),
  onSurface: Color(0xffe5e6ea),
  onVariant: Color(0xffa6aab3),
  outline: Color(0xff6f737d),
  outlineVariant: Color(0xff2e3035),
);

/// アプリ全体の見た目。明るい表示と暗い表示で、余白・角丸・枠線をそろえる。
ThemeData hubTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final s = dark ? _dark : _light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: hubAccent,
        brightness: brightness,
      ).copyWith(
        // 明るい表示では、主な操作の色を指定した藍色そのものにする（既定の配色は色味が薄く、くすんで見える）。
        // 補助の色（secondaryContainerなど）は既定の落ち着いた色のまま使う。
        primary: dark ? null : hubAccent,
        onPrimary: dark ? null : Colors.white,
        surface: s.surface,
        surfaceDim: s.container,
        surfaceBright: s.surface,
        surfaceContainerLowest: s.lowest,
        surfaceContainerLow: s.low,
        surfaceContainer: s.container,
        surfaceContainerHigh: s.high,
        surfaceContainerHighest: s.highest,
        onSurface: s.onSurface,
        onSurfaceVariant: s.onVariant,
        outline: s.outline,
        outlineVariant: s.outlineVariant,
        surfaceTint: Colors.transparent,
      );
  final radius = BorderRadius.circular(10);
  final base = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
    scaffoldBackgroundColor: s.background,
    canvasColor: s.background,
    dividerTheme: DividerThemeData(color: s.outlineVariant, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: s.background,
      foregroundColor: s.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: s.outlineVariant)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: s.low,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: s.outlineVariant),
      ),
    ),
    listTileTheme: ListTileThemeData(
      selectedColor: scheme.primary,
      selectedTileColor: scheme.primary.withValues(alpha: dark ? .16 : .08),
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: s.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: s.surface,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: radius),
    ),
    snackBarTheme: SnackBarThemeData(
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
  );
  // 題名の文字は本文と同じ書体の設定から作る（書体を指定しないと端末によって既定の書体に変わる）。
  return base.copyWith(
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: s.onSurface,
      ),
    ),
  );
}
