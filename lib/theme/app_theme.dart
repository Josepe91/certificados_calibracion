import 'package:flutter/material.dart';

class AppTheme {
  static const Color azulBTMC = Color(0xFF0B3C8A);
  static const Color verdeBTMC = Color(0xFF6AA84F);
  static const Color naranjaBTMC = Color(0xFFF28C38);

  static const Color background = Color(0xFFF4F6F8);
  static const Color textPrimary = Color(0xFF263238);
  static const Color textSecondary = Color(0xFF607D8B);

  static ThemeData lightTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: azulBTMC,
        primary: azulBTMC,
        secondary: verdeBTMC,
        tertiary: naranjaBTMC,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: azulBTMC,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
    );
  }
}
