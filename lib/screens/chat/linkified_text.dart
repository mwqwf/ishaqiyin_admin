import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'chat_ui.dart';

/// 🔗 نصّ رسالة مع روابط قابلة للنقر (نمط واتساب):
/// يتعرّف على الروابط (https/http/www) والبُرد الإلكترونيّة وأرقام الهواتف،
/// فيلوّنها ويسطّرها؛ النقر يفتحها بالتطبيق المناسب، والضغط المطوّل ينسخها.
///
/// ملاحظة تقنيّة: مُتعرِّفات الإيماءات (TapGestureRecognizer) تُنشأ مرّة
/// وتُتلَف في dispose — إنشاؤها في كلّ بناء يسرّب الذاكرة.
class ChatLinkText extends StatefulWidget {
  const ChatLinkText(
    this.text, {
    super.key,
    this.style,
    this.linkColor = ChatColors.accentDark,
  });

  final String text;
  final TextStyle? style;
  final Color linkColor;

  @override
  State<ChatLinkText> createState() => _ChatLinkTextState();
}

class _ChatLinkTextState extends State<ChatLinkText> {
  final List<TapGestureRecognizer> _recognizers = [];

  /// روابط كاملة، أو نطاقات تبدأ بـ www، أو بريد، أو رقم هاتف دوليّ.
  static final RegExp _pattern = RegExp(
    r'(https?:\/\/[^\s<>"]+)'
    r'|(www\.[^\s<>"]+)'
    r'|([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'
    r'|(\+[0-9][0-9\s\-]{7,}[0-9])',
    caseSensitive: false,
  );

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatLinkText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      for (final r in _recognizers) {
        r.dispose();
      }
      _recognizers.clear();
    }
  }

  /// يحوّل المطابقة إلى رابط قابل للفتح.
  static Uri? _uriFor(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      return Uri.tryParse(s);
    }
    if (s.toLowerCase().startsWith('www.')) return Uri.tryParse('https://$s');
    if (s.contains('@')) return Uri.tryParse('mailto:$s');
    if (s.startsWith('+')) {
      return Uri.tryParse('tel:${s.replaceAll(RegExp(r'[\s-]'), '')}');
    }
    return Uri.tryParse(s);
  }

  Future<void> _open(String raw) async {
    final uri = _uriFor(raw);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showChatSnack(context, 'تعذّر فتح الرابط.', error: true);
      }
    } catch (_) {
      if (mounted) showChatSnack(context, 'تعذّر فتح الرابط.', error: true);
    }
  }

  Future<void> _copy(String raw) async {
    await Clipboard.setData(ClipboardData(text: raw));
    if (mounted) showChatSnack(context, 'نُسخ الرابط.');
  }

  @override
  Widget build(BuildContext context) {
    final base =
        widget.style ?? const TextStyle(fontSize: 14.5, height: 1.45);
    final matches = _pattern.allMatches(widget.text).toList();
    if (matches.isEmpty) return Text(widget.text, style: base);

    // نعيد بناء المُتعرِّفات مرّة واحدة لكلّ نصّ.
    if (_recognizers.length != matches.length) {
      for (final r in _recognizers) {
        r.dispose();
      }
      _recognizers
        ..clear()
        ..addAll(List.generate(matches.length, (_) => TapGestureRecognizer()));
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, m.start)));
      }
      final raw = widget.text.substring(m.start, m.end);
      _recognizers[i].onTap = () => _open(raw);
      spans.add(
        TextSpan(
          text: raw,
          style: base.copyWith(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
            fontWeight: FontWeight.w600,
          ),
          recognizer: _recognizers[i],
        ),
      );
      cursor = m.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    // ضغطة مطوّلة على النصّ كلّه تنسخ أوّل رابط فيه (سلوك عمليّ ومريح).
    return GestureDetector(
      onLongPress: () => _copy(widget.text.substring(
        matches.first.start,
        matches.first.end,
      )),
      child: Text.rich(TextSpan(style: base, children: spans)),
    );
  }
}
