import 'package:flutter/material.dart';

/// Official Tri-Logis Brand Colors
class TriLogisColors {
  TriLogisColors._();

  /// Pantone Black - #000000
  static const Color black = Color(0xFF000000);

  /// Pantone 200 - #D11848 (Vibrant Red)
  static const Color red = Color(0xFFD11848);

  /// Pantone 188 - #8A110E (Dark Red/Burgundy)
  static const Color darkRed = Color(0xFF8A110E);

  /// Pantone 730 - #BA8041 (Gold/Ochre)
  static const Color gold = Color(0xFFBA8041);

  /// Background and Surface colors
  static const Color background = Color(0xFFF8F9FA);
  static const Color surface = Colors.white;
}

/// Tri-Logis Theme Configuration
class TriLogisTheme {
  TriLogisTheme._();

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: TriLogisColors.red,
        primary: TriLogisColors.red,
        onPrimary: Colors.white,
        secondary: TriLogisColors.gold,
        onSecondary: Colors.white,
        tertiary: TriLogisColors.darkRed,
        surface: TriLogisColors.surface,
        onSurface: TriLogisColors.black,
        error: TriLogisColors.darkRed,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: TriLogisColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: TriLogisColors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TriLogisColors.red,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TriLogisColors.black,
          side: const BorderSide(color: TriLogisColors.gold, width: 2),
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE9ECEF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE9ECEF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TriLogisColors.gold, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TriLogisColors.darkRed),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFE9ECEF), width: 1),
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: TriLogisColors.red,
        primary: TriLogisColors.red,
        onPrimary: Colors.white,
        secondary: TriLogisColors.gold,
        surface: const Color(0xFF121212),
        onSurface: Colors.white,
        brightness: Brightness.dark,
      ),
    );
  }
}
