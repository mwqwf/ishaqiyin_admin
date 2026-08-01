import 'package:flutter/material.dart';

import '../../theme.dart';

/// ألوان دردشة الإدارة — مكيَّفة لسمة منبر الفاتحة (المصدر: لوحة نبراس
/// الداكنة، فاستُبدلت القيم بما يقرأ جيّداً على خلفيّة فاتحة).
class ChatColors {
  ChatColors._();

  static const Color bg = kBg;
  static const Color surface = Colors.white;
  static const Color surfaceAlt = kBoxBg;
  static const Color border = Color(0xFFCCE3E3);
  static const Color textMuted = Color(0xFF64748B);
  static const Color accent = kTeal;
  static const Color accentDark = kTealDark;
  static const Color amber = Color(0xFFB45309);
  static const Color rose = kDanger;
  static const Color highlight = Color(0xFFDFF0EE);
  static const Color online = Color(0xFF16A34A);
  static const Color readBlue = Color(0xFF0284C7);

  /// فقاعة رسائلي (أخضر فاتح بنمط واتساب) وحدودها.
  static const Color mineBubble = Color(0xFFD9F2E7);
  static const Color mineBubbleBorder = Color(0xFFB8E3D2);
}

void showChatSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? ChatColors.rose : ChatColors.accentDark,
    ),
  );
}
