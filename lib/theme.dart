import 'package:flutter/material.dart';

const kTeal = Color(0xFF247172);
const kTealDark = Color(0xFF184B4B);
const kBg = Color(0xFFF8FCFC);
const kBoxBg = Color(0xFFE6F2F2);
const kDanger = Color(0xFFC0392B);
const kGold = Color(0xFFD4AF37);
const kOrange = Color(0xFFE67E22);
const kGreen = Color(0xFF27AE60);
const kBlue = Color(0xFF2980B9);
const kPurple = Color(0xFF7D3C98);

ThemeData buildAdminTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kTeal,
    primary: kTeal,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: kTeal,
      foregroundColor: Colors.white,
      centerTitle: true,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFCCE3E3)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFCCE3E3)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kTeal,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );
}
