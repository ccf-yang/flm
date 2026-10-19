import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppColors {
  static const accent = Color(0xFF14B8A6);
  static const accentSoft = Color(0xFF5EEAD4);
  static const darkBackground = Color(0xFF0B1220);
  static const darkSurface = Color(0xFF111A2B);
  static const darkSurfaceHigh = Color(0xFF18233A);
  static const lightBackground = Color(0xFFF6F8FB);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceHigh = Color(0xFFEDF2F7);
  static const danger = Color(0xFFEF4444);
}

ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: brightness,
  ).copyWith(
    primary: AppColors.accent,
    secondary: AppColors.accentSoft,
    surface: isDark ? AppColors.darkSurface : AppColors.lightSurface,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      foregroundColor: isDark ? Colors.white : const Color(0xFF111827),
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: isDark ? Colors.white : const Color(0xFF111827),
      ),
    ),
    dividerColor: isDark ? const Color(0x1AFFFFFF) : const Color(0x14000000),
    colorSchemeSeed: AppColors.accent,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    textTheme: TextTheme(
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: isDark ? Colors.white : const Color(0xFF111827),
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white : const Color(0xFF111827),
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF4B5563),
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF6B7280),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AppColors.accent,
      thumbColor: Colors.white,
      inactiveTrackColor: isDark ? const Color(0xFF24324A) : const Color(0xFFD9E2EC),
      trackHeight: 3,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.white : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? AppColors.accent : null,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? const Color(0xFF1F2A3E) : const Color(0xFF111827),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),
  );
}

Color surfaceFor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? AppColors.darkSurface : AppColors.lightSurface;
}

Color surfaceHighFor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? AppColors.darkSurfaceHigh : AppColors.lightSurfaceHigh;
}

Color mutedFor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF94A3B8) : const Color(0xFF6B7280);
}

Color textFor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? Colors.white : const Color(0xFF111827);
}

CupertinoThemeData buildCupertinoTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return CupertinoThemeData(
    brightness: brightness,
    primaryColor: AppColors.accent,
    scaffoldBackgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
    barBackgroundColor: isDark ? AppColors.darkBackground : AppColors.lightBackground,
    textTheme: CupertinoTextThemeData(
      textStyle: TextStyle(
        color: isDark ? Colors.white : const Color(0xFF111827),
        fontSize: 14,
      ),
    ),
  );
}
