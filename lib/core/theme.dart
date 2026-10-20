import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Quiet Aurora design tokens, ported from the ui.html design study.
/// Dark is the base identity; light is the "bone" companion palette.
class AppColors {
  // Dark tokens
  static const darkBg = Color(0xFF07090C);
  static const darkBgDeep = Color(0xFF040507);
  static const darkSurface = Color(0xFF12171D);
  /// Matches `--surface: rgba(18, 23, 29, .72)` in the ui.html study.
  static const darkSurfaceGlass = Color(0xB812171D);
  static const darkSurface2 = Color(0xFF171D24);
  static const darkSurface3 = Color(0xFF1F2730);
  static const darkText = Color(0xFFF3F6F4);
  static const darkText2 = Color(0xFFA0AAB1);
  static const darkText3 = Color(0xFF6D7780);
  static const darkLine = Color(0x13FFFFFF); // white @ .075
  static const darkLineStrong = Color(0x24FFFFFF); // white @ .14

  // Light tokens
  static const lightBg = Color(0xFFF3F5F1);
  static const lightBgDeep = Color(0xFFE9ECE6);
  static const lightSurface = Color(0xFFFFFFFF);
  /// Matches `--surface: rgba(255, 255, 255, .76)` in the ui.html study.
  static const lightSurfaceGlass = Color(0xC2FFFFFF);
  static const lightSurface2 = Color(0xFFECEFE9);
  static const lightSurface3 = Color(0xFFE1E5DE);
  static const lightText = Color(0xFF101511);
  static const lightText2 = Color(0xFF5D6861);
  static const lightText3 = Color(0xFF8D968F);
  static const lightLine = Color(0x14101511); // ink @ .08
  static const lightLineStrong = Color(0x24101511); // ink @ .14

  // Accent per appearance (mint on dark, jade on light)
  static const accentDark = Color(0xFF9AF4D2);
  static const accentStrongDark = Color(0xFF61E6B8);
  static const accentInkDark = Color(0xFF06241B);
  static const accentLight = Color(0xFF0E9F78);
  static const accentStrongLight = Color(0xFF0A8060);
  static const accentInkLight = Color(0xFFFFFFFF);

  static const coralDark = Color(0xFFFF8F7A);
  static const coralLight = Color(0xFFD65E48);
  static const goldDark = Color(0xFFF2D08C);
  static const goldLight = Color(0xFFA67A26);

  /// Brand gradient shared by the local-music hero card and big covers.
  static const brandGradient = <Color>[Color(0xFF0F766E), Color(0xFF14B8A6)];

  static const danger = coralDark;
  static const accent = accentDark;
  static const accentSoft = accentDark;
  static const darkBackground = darkBg;
  static const darkSurfaceHigh = darkSurface3;
  static const lightBackground = lightBg;
  static const lightSurfaceHigh = lightSurface2;
}

/// Motion curves from the design study.
class AuroraMotion {
  static const Curve ease = Cubic(0.22, 1, 0.36, 1);
  static const Curve spring = Cubic(0.16, 1, 0.3, 1);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 260);
}

bool auroraIsDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// The aurora layout is a phone layout: rows, pills and the pendant are sized
/// for a ~390-430dp viewport. On a tablet or an unfolded foldable the content
/// column is centred at this width instead of stretching a song row across
/// 900dp.
const double kAuroraContentMaxWidth = 560.0;

/// iOS-style scrolling on every platform.
///
/// Android's default behaviour paints the blue Material glow over the content
/// when a list is dragged past its end, which fights the frosted panels, and
/// it clamps hard instead of rubber-banding. Both are replaced here so the
/// gesture feel matches the look the design was drawn for.
class AuroraScrollBehavior extends MaterialScrollBehavior {
  const AuroraScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}

Color bgFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkBg : AppColors.lightBg;

Color bgDeepFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkBgDeep : AppColors.lightBgDeep;

/// The frosted "surface" from the design study. Use it for chrome that should
/// blend into the aurora (cards, chips, tab bar, floating controls).
Color surfaceFor(BuildContext context) => auroraIsDark(context)
    ? AppColors.darkSurfaceGlass
    : AppColors.lightSurfaceGlass;

/// Opaque card color (`--surface-solid`): sheets, dialogs and segmented
/// controls sit above other content, so they must not show it through.
Color panelFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkSurface : AppColors.lightSurface;

Color surface2For(BuildContext context) => auroraIsDark(context)
    ? AppColors.darkSurface2
    : AppColors.lightSurface2;

Color surfaceHighFor(BuildContext context) => auroraIsDark(context)
    ? AppColors.darkSurface3
    : AppColors.lightSurface3;

Color textFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkText : AppColors.lightText;

/// Secondary text (was mutedFor).
Color mutedFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkText2 : AppColors.lightText2;

/// Tertiary, overline-grade text.
Color faintFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkText3 : AppColors.lightText3;

Color lineColor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkLine : AppColors.lightLine;

Color lineStrongColor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.darkLineStrong : AppColors.lightLineStrong;

Color accentFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.accentDark : AppColors.accentLight;

Color accentStrongFor(BuildContext context) => auroraIsDark(context)
    ? AppColors.accentStrongDark
    : AppColors.accentStrongLight;

/// Text/ink color to place on top of an accent-filled surface.
Color accentInkFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.accentInkDark : AppColors.accentInkLight;

Color accentSoftColor(BuildContext context) =>
    accentFor(context).withValues(alpha: 0.12);

Color accentBorderColor(BuildContext context) =>
    accentFor(context).withValues(alpha: 0.26);

Color coralFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.coralDark : AppColors.coralLight;

Color goldFor(BuildContext context) =>
    auroraIsDark(context) ? AppColors.goldDark : AppColors.goldLight;

ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final accent = isDark ? AppColors.accentDark : AppColors.accentLight;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF14B8A6),
    brightness: brightness,
  ).copyWith(
    primary: accent,
    secondary: isDark ? AppColors.accentStrongDark : AppColors.accentStrongLight,
    surface: isDark ? AppColors.darkSurface : AppColors.lightSurface,
    error: isDark ? AppColors.coralDark : AppColors.coralLight,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    highlightColor: accentSoftColor0(accent),
    visualDensity: VisualDensity.standard,
    dividerColor: isDark ? AppColors.darkLine : AppColors.lightLine,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accentSoftColor0(accent),
      selectionHandleColor: accent,
    ),
    textTheme: TextTheme(
      titleLarge: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: isDark ? AppColors.darkText : AppColors.lightText,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: isDark ? AppColors.darkText : AppColors.lightText,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        color: isDark ? AppColors.darkText2 : AppColors.lightText2,
      ),
      bodySmall: TextStyle(
        fontSize: 11,
        color: isDark ? AppColors.darkText3 : AppColors.lightText3,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent,
      inactiveTrackColor:
          isDark ? const Color(0xFF1F2730) : const Color(0xFFE1E5DE),
      trackHeight: 3,
      thumbColor: accent,
      overlayShape: SliderComponentShape.noOverlay,
      valueIndicatorColor: isDark ? AppColors.darkSurface3 : AppColors.lightSurface3,
      valueIndicatorTextStyle: TextStyle(
        color: isDark ? AppColors.darkText : AppColors.lightText,
        fontSize: 11,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? const Color(0xFF1F2730) : const Color(0xFF101511),
      contentTextStyle: const TextStyle(color: Color(0xFFF3F6F4), fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: Color(0x99000000),
    ),
    // Every pushed page slides in from the right and can be dismissed with an
    // edge swipe from the left, on every platform. iOS does this by default;
    // being explicit also keeps Android/desktop consistent and makes the
    // gesture available to any RouteBuilder we add later.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      },
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: isDark ? AppColors.darkLine : AppColors.lightLine),
      ),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: isDark ? AppColors.darkText : AppColors.lightText,
      ),
      contentTextStyle: TextStyle(
        fontSize: 13,
        height: 1.45,
        color: isDark ? AppColors.darkText2 : AppColors.lightText2,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? AppColors.darkSurface2 : AppColors.lightSurface2,
      hintStyle: TextStyle(
        color: isDark ? AppColors.darkText3 : AppColors.lightText3,
        fontSize: 13.5,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: isDark ? AppColors.darkLine : AppColors.lightLine,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: isDark ? AppColors.darkLine : AppColors.lightLine,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
    ),
  );
}

Color accentSoftColor0(Color accent) => accent.withValues(alpha: 0.10);

CupertinoThemeData buildCupertinoTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return CupertinoThemeData(
    brightness: brightness,
    primaryColor: isDark ? AppColors.accentDark : AppColors.accentLight,
    scaffoldBackgroundColor:
        isDark ? AppColors.darkBg : AppColors.lightBg,
    barBackgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
    textTheme: CupertinoTextThemeData(
      textStyle: TextStyle(
        color: isDark ? AppColors.darkText : AppColors.lightText,
        fontSize: 14,
      ),
    ),
  );
}
