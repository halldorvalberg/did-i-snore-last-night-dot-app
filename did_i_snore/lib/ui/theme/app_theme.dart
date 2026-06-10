/// Assembles the dark [ThemeData] for "Did I Snore?".
///
/// One dark theme, no light variant — the app is used in a dark bedroom
/// and a groggy morning. Typography is Hanken Grotesk for UI text and IBM
/// Plex Mono for times/durations/numbers (both vendored under
/// `assets/fonts/`, declared in `pubspec.yaml`). Use [AppText.mono] for
/// the tabular/mono runs the mockup marks with `className="mono"`.
///
/// Screens should pull colors from [AppColors] / [CategoryStyle] and reach
/// for `Theme.of(context).textTheme` for type. The [ColorScheme] below
/// maps the design tokens onto Material's slots so stock widgets
/// (SnackBar, Dialog, etc.) inherit the right colors without bespoke
/// styling everywhere.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Font family names — must match the `family:` entries in pubspec.yaml.
abstract final class AppFonts {
  static const String sans = 'HankenGrotesk';
  static const String mono = 'IBMPlexMono';
}

/// Convenience text styles for the mono runs and other recurring shapes
/// that don't map cleanly onto a Material text-theme slot.
abstract final class AppText {
  /// IBM Plex Mono with tabular figures — times, durations, counters.
  static const TextStyle mono = TextStyle(
    fontFamily: AppFonts.mono,
    fontFeatures: [FontFeature.tabularFigures()],
    color: AppColors.text2,
    fontSize: 12.5,
  );

  /// Uppercase mono eyebrow label (`letter-spacing: 0.12em` in the mockup).
  static const TextStyle eyebrow = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 11.5,
    letterSpacing: 1.4,
    color: AppColors.text3,
  );
}

abstract final class AppTheme {
  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.accent,
      onPrimary: AppColors.bg,
      secondary: AppColors.accent,
      onSecondary: AppColors.bg,
      surface: AppColors.surface,
      onSurface: AppColors.text1,
      surfaceContainerHighest: AppColors.surface2,
      onSurfaceVariant: AppColors.text2,
      outline: AppColors.lineStrong,
      outlineVariant: AppColors.line,
      error: Color(0xFFE6634E),
      onError: AppColors.bg,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      canvasColor: AppColors.bg,
      fontFamily: AppFonts.sans,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.text1,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: AppColors.text2),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surface2,
        contentTextStyle: const TextStyle(
          color: AppColors.text1,
          fontFamily: AppFonts.sans,
        ),
        actionTextColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.lineStrong),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base) {
    return base
        .apply(
          bodyColor: AppColors.text1,
          displayColor: AppColors.text1,
          fontFamily: AppFonts.sans,
        )
        .copyWith(
          headlineMedium: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
            color: AppColors.text1,
          ),
          titleLarge: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.text1,
          ),
          titleMedium: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w600,
            color: AppColors.text1,
          ),
          bodyLarge: const TextStyle(fontSize: 15, color: AppColors.text1),
          bodyMedium: const TextStyle(fontSize: 14, color: AppColors.text2),
          bodySmall: const TextStyle(fontSize: 12.5, color: AppColors.text3),
          labelLarge: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.text1,
          ),
        );
  }
}
