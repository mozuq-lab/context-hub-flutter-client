import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// 操作と強調に使う色（落ち着いた藍色）。面の色には使わない。
const hubAccent = Color(0xff4f5bd5);

/// 面の色の組。色味のない灰色で、アクセントの色を目立たせる。
class _Surfaces {
  const _Surfaces({
    required this.background,
    required this.surface,
    required this.card,
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

  /// ダイアログ・メニューなど、本文から一段持ち上げた面。
  final Color surface;

  /// 本文の上に置くカードの面。
  final Color card;

  /// [low]はサイドバーと下のタブの面。
  final Color lowest, low, container, high, highest;
  final Color onSurface, onVariant, outline, outlineVariant;
}

const _light = _Surfaces(
  background: Color(0xfffafafb),
  surface: Color(0xffffffff),
  card: Color(0xffffffff),
  lowest: Color(0xffffffff),
  low: Color(0xfff3f3f5),
  container: Color(0xffefeff2),
  high: Color(0xffe8e8ec),
  highest: Color(0xffe1e1e6),
  onSurface: Color(0xff18181b),
  onVariant: Color(0xff62636e),
  outline: Color(0xff8b8c96),
  outlineVariant: Color(0xffe6e6eb),
);

const _dark = _Surfaces(
  background: Color(0xff161618),
  surface: Color(0xff1f1f22),
  card: Color(0xff1d1d20),
  lowest: Color(0xff111113),
  low: Color(0xff1a1a1d),
  container: Color(0xff242428),
  high: Color(0xff2b2b30),
  highest: Color(0xff333339),
  onSurface: Color(0xffededf0),
  onVariant: Color(0xffa3a4ae),
  outline: Color(0xff75767f),
  outlineVariant: Color(0xff2d2d32),
);

/// 角丸の大きさ。小さな部品・カード・ダイアログの3段にそろえる。
const hubRadiusSmall = 10.0, hubRadius = 14.0, hubRadiusLarge = 20.0;

/// アプリ全体の見た目。明るい表示と暗い表示で、余白・角丸・枠線・文字の段差をそろえる。
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
        primary: dark ? const Color(0xffa5adff) : hubAccent,
        onPrimary: dark ? const Color(0xff1b1f5c) : Colors.white,
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
  final small = BorderRadius.circular(hubRadiusSmall),
      radius = BorderRadius.circular(hubRadius),
      large = BorderRadius.circular(hubRadiusLarge);
  // 書体は端末の既定のまま使い（Macはヒラギノ、AndroidはNoto）、大きさと太さだけを決める。
  final t = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
  ).textTheme;
  final text = t
      .copyWith(
        headlineSmall: t.headlineSmall?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          height: 1.35,
          letterSpacing: -.2,
        ),
        titleLarge: t.titleLarge?.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        titleMedium: t.titleMedium?.copyWith(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          height: 1.45,
          letterSpacing: 0,
        ),
        titleSmall: t.titleSmall?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.45,
          letterSpacing: 0,
        ),
        bodyLarge: t.bodyLarge?.copyWith(
          fontSize: 15,
          height: 1.6,
          letterSpacing: 0,
        ),
        bodyMedium: t.bodyMedium?.copyWith(
          fontSize: 14,
          height: 1.55,
          letterSpacing: 0,
        ),
        bodySmall: t.bodySmall?.copyWith(
          fontSize: 12.5,
          height: 1.5,
          letterSpacing: 0,
        ),
        labelLarge: t.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        labelMedium: t.labelMedium?.copyWith(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      )
      .apply(bodyColor: s.onSurface, displayColor: s.onSurface);
  // 補足の文字は薄い色にして、本文と見分けやすくする。
  final textTheme = text.copyWith(
    bodySmall: text.bodySmall?.copyWith(color: s.onVariant),
  );
  final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(borderRadius: small),
  );
  const buttonPadding = WidgetStatePropertyAll<EdgeInsetsGeometry>(
    EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  );
  final buttonText = WidgetStatePropertyAll<TextStyle?>(text.labelLarge);
  final base = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
    textTheme: textTheme,
    scaffoldBackgroundColor: s.background,
    canvasColor: s.background,
    visualDensity: VisualDensity.standard,
    dividerTheme: DividerThemeData(color: s.outlineVariant, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: s.background,
      foregroundColor: s.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 60,
      titleSpacing: 20,
      titleTextStyle: text.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: s.onSurface,
      ),
      shape: Border(bottom: BorderSide(color: s.outlineVariant)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: s.card,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: s.outlineVariant),
      ),
    ),
    listTileTheme: ListTileThemeData(
      selectedColor: scheme.primary,
      selectedTileColor: scheme.primary.withValues(alpha: dark ? .16 : .08),
      iconColor: s.onVariant,
      titleTextStyle: text.bodyLarge?.copyWith(
        fontWeight: FontWeight.w500,
        color: s.onSurface,
      ),
      subtitleTextStyle: textTheme.bodySmall,
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        padding: buttonPadding,
        textStyle: buttonText,
        elevation: const WidgetStatePropertyAll(0),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        padding: buttonPadding,
        textStyle: buttonText,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? s.onSurface.withValues(alpha: .38)
              : s.onSurface,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.disabled)
                ? s.outlineVariant
                : s.highest,
          ),
        ),
      ),
    ),
    // 文字だけのボタンは、藍の文字の控えめな操作。項目の行に並べる操作は、rowActions（parts.dart）で文字を本文の色にする。
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        textStyle: WidgetStatePropertyAll(
          text.labelLarge?.copyWith(fontSize: 13.5, fontWeight: FontWeight.w500),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        // 見た目の高さは40。指で押すAndroidでは押せる範囲を48に広げ、マウスで押すMacでは見た目にそろえて行の間を詰める。
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        tapTargetSize: defaultTargetPlatform == TargetPlatform.android
            ? MaterialTapTargetSize.padded
            : MaterialTapTargetSize.shrinkWrap,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? s.onSurface.withValues(alpha: .38)
              : scheme.primary,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? s.onSurface.withValues(alpha: .38)
              : scheme.primary,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)
              ? scheme.primary.withValues(alpha: dark ? .14 : .08)
              : null,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? s.onSurface.withValues(alpha: .38)
              : states.contains(WidgetState.selected)
              ? scheme.primary
              : s.onVariant,
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: buttonShape,
        textStyle: WidgetStatePropertyAll(
          text.labelLarge?.copyWith(fontSize: 13.5),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: s.highest)),
        // 選んだ側は、札と同じく淡い藍の地と藍の文字にする。
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary.withValues(alpha: dark ? .22 : .12)
              : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? s.onSurface.withValues(alpha: .38)
              : states.contains(WidgetState.selected)
              ? scheme.primary
              : s.onSurface,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? s.onSurface.withValues(alpha: .38)
              : states.contains(WidgetState.selected)
              ? scheme.primary
              : s.onVariant,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide(color: s.highest),
      // 選んだ札は、地の色に加えて文字も藍にする（印を付けない分、選んだことが分かるように）。
      labelStyle: text.bodyMedium?.copyWith(
        fontSize: 13,
        color: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? s.onSurface.withValues(alpha: .38)
              : states.contains(WidgetState.selected)
              ? scheme.primary
              : s.onSurface,
        ),
      ),
      backgroundColor: s.card,
      selectedColor: scheme.primary.withValues(alpha: dark ? .22 : .12),
      checkmarkColor: scheme.primary,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: s.low,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 66,
      indicatorColor: scheme.primary.withValues(alpha: dark ? .22 : .12),
      indicatorShape: RoundedRectangleBorder(borderRadius: small),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelMedium?.copyWith(
          fontSize: 11.5,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : s.onVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : s.onVariant,
        ),
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: s.low,
      surfaceTintColor: Colors.transparent,
      width: 304,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: s.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: large),
      titleTextStyle: text.titleLarge,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: s.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(hubRadiusLarge),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: s.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: small,
        side: BorderSide(color: s.outlineVariant),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(s.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: small,
            side: BorderSide(color: s.outlineVariant),
          ),
        ),
      ),
    ),
    // 入力欄の補足・文字数・誤りの文字は、本文の補足と同じ大きさ・色にそろえ、長い説明は途中で切らずに折り返す。
    inputDecorationTheme: InputDecorationTheme(
      helperStyle: textTheme.bodySmall,
      counterStyle: textTheme.bodySmall,
      errorStyle: textTheme.bodySmall?.copyWith(color: scheme.error),
      helperMaxLines: 4,
      errorMaxLines: 4,
      border: OutlineInputBorder(borderRadius: small),
      enabledBorder: OutlineInputBorder(
        borderRadius: small,
        borderSide: BorderSide(color: s.highest),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: small,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      textStyle: TextStyle(fontSize: 12, color: dark ? s.onSurface : s.surface),
      decoration: BoxDecoration(
        color: dark ? s.highest : const Color(0xff2a2a30),
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      shape: RoundedRectangleBorder(borderRadius: small),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: scheme.primary,
      textColor: scheme.onPrimary,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: radius),
      collapsedShape: RoundedRectangleBorder(borderRadius: radius),
    ),
  );
  return base;
}

/// 狭い画面（スマートフォン）でのダイアログの外側の余白。既定（左右40）のままだと、本文の幅が狭くなり、欄が詰まって見える。
const narrowDialogInset = EdgeInsets.symmetric(horizontal: 16, vertical: 24);

/// 画面の幅に合わせて、ダイアログの外側の余白を変える。[MaterialApp.builder]から使う。
Widget hubThemeForWidth(BuildContext context, Widget? child) {
  final content = child ?? const SizedBox.shrink();
  if (MediaQuery.sizeOf(context).width >= 600) return content;
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      dialogTheme: theme.dialogTheme.copyWith(insetPadding: narrowDialogInset),
    ),
    child: content,
  );
}
