import 'package:flutter/material.dart';

/// Design tokens for Oriont Clipper matching the quiet-confidence,
/// monochrome-first editorial Style DNA reference.
class AppColors {
  // Light Palette
  static const Color lightBackground = Color(0xFFFAFAFA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceElevated = Color(0xFFF4F4F5);
  static const Color lightTextPrimary = Color(0xFF0A0A0A);
  static const Color lightTextSecondary = Color(0xFF6B6B6B);
  static const Color lightBorder = Color(0xFFEAEAEA);
  static const Color lightDivider = Color(0xFFF0F0F0);

  // Dark Palette (True Dark)
  static const Color darkBackground = Color(0xFF0D0D0D);
  static const Color darkSurface = Color(0xFF161616);
  static const Color darkSurfaceElevated = Color(0xFF202020);
  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFF9A9A9A);
  static const Color darkBorder = Color(0xFF262626);
  static const Color darkDivider = Color(0xFF1F1F1F);

  // Functional Status Colors (minimal & purposeful)
  static const Color statusActive = Color(0xFF10B981); // Emerald green for live indicators
  static const Color statusWarning = Color(0xFFF59E0B);
  static const Color statusDanger = Color(0xFFEF4444);
}

class AppRadius {
  static const double card = 24.0;
  static const double input = 14.0;
  static const double button = 16.0;
  static const double pill = 999.0;
  static const double bubble = 18.0;
}

class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double hero = 32.0;
}

class AppTypography {
  static const String fontFamily = 'Segoe UI';

  static TextStyle displayHero(bool isDark) => TextStyle(
        fontFamily: fontFamily,
        fontSize: 30,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.8,
        color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
        height: 1.15,
      );

  static TextStyle sectionTitle(bool isDark) => TextStyle(
        fontFamily: fontFamily,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
        color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
        height: 1.25,
      );

  static TextStyle microHeader(bool isDark) => TextStyle(
        fontFamily: fontFamily,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.6,
        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
      );

  static TextStyle body(bool isDark) => TextStyle(
        fontFamily: fontFamily,
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46),
        height: 1.5,
      );

  static TextStyle label(bool isDark) => TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
      );
}

class AppTheme {
  static ThemeData light() {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.lightBackground,
      canvasColor: AppColors.lightSurface,
      colorScheme: const ColorScheme.light(
        primary: AppColors.lightTextPrimary,
        onPrimary: AppColors.lightSurface,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightTextPrimary,
        outline: AppColors.lightBorder,
      ),
      fontFamily: AppTypography.fontFamily,
      dividerColor: AppColors.lightDivider,
      splashFactory: InkRipple.splashFactory,
    );
  }

  static ThemeData dark() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.darkBackground,
      canvasColor: AppColors.darkSurface,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.darkTextPrimary,
        onPrimary: AppColors.darkBackground,
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkTextPrimary,
        outline: AppColors.darkBorder,
      ),
      fontFamily: AppTypography.fontFamily,
      dividerColor: AppColors.darkDivider,
      splashFactory: InkRipple.splashFactory,
    );
  }
}
