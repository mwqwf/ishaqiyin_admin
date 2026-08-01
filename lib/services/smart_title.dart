/// 🧠 استخراج عنوان نظيف من اسم ملف — بلا تدخل بشري.
///
/// يعالج الأنماط الشائعة في الملفات القادمة من المسجّلات وواتساب ومواقع
/// التنزيل: يزيل الامتداد والترقيم التسلسلي وبصمات المواقع والوسوم
/// الدعائية والفواصل الآلية، ويعيد عنواناً بشرياً مقروءاً.
///
/// إن كان الاسم آلياً بحتاً لا يحمل معنى (مثل `AUD-20240101-WA0001`)
/// يعيد `''` — فالأصح ترك الحقل فارغاً ليكتبه الإنسان بدل اقتراح خردة.
///
/// نسخ متطابقة من هذا الملف في مشاريع منبر — عدّلها جميعاً معاً.
String smartTitleFromFileName(String fileName) {
  var s = fileName.trim();
  if (s.isEmpty) return '';

  // اسم الملف فقط (بلا مسار) ثم بلا امتداد.
  s = s.split(RegExp(r'[/\\]')).last;
  final dot = s.lastIndexOf('.');
  if (dot > 0) s = s.substring(0, dot);

  // فكّ ترميز الروابط (%20 → مسافة) إن وُجد. decodeComponent يرمي على
  // خليط عربي غير مرمَّز + %20، فنسقط إلى استبدال المسافة المرمّزة فقط.
  if (s.contains('%')) {
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {
      s = s.replaceAll('%20', ' ');
    }
  }

  // أسماء آلية بحتة — لا شيء ذا معنى يُستخرج منها.
  final autoPatterns = <RegExp>[
    // واتساب: AUD-20240101-WA0001 وأخواتها + "WhatsApp Audio 2024-01-01 at…"
    RegExp(
      r'^(AUD|VID|PTT|IMG|DOC|GIF)[-_]\d{8}[-_]WA\d+',
      caseSensitive: false,
    ),
    RegExp(r'^WhatsApp\s+(Audio|Video|Ptt|Image)\b', caseSensitive: false),
    // مسجّلات: Recording 12 / New Recording / record_20240101_123456
    RegExp(r'^(new\s+)?record(ing)?[-_\s]*[\d_.\-\s]*$', caseSensitive: false),
    // أسماء عامة مرقّمة: Voice 003 / Audio 1 / Track05 / ملف 2 / تسجيل 7
    RegExp(
      r'^(voice|audio|video|sound|note|memo|track|file|item|untitled'
      r'|تسجيل|مقطع|ملف|صوت|بدون\s*عنوان)[-_\s]*[\d٠-٩_.\-\s]*$',
      caseSensitive: false,
    ),
    // أرقام/رموز فقط (طوابع زمنية 20240101_123456 وأمثالها)
    RegExp(r'^[\d٠-٩\s_.\-()~]+$'),
    // أجهزة تسجيل: REC001 / MIC_12 / ZOOM0004 / DS300012
    RegExp(r'^(REC|MIC|ZOOM|DS|DM|VN)[-_]?\d+$', caseSensitive: false),
  ];
  for (final p in autoPatterns) {
    if (p.hasMatch(s)) return '';
  }

  // أقواس بمحتوى دعائي/تقني تُحذف كاملة؛ الأقواس ذات النص العادي تبقى.
  final junkInside = RegExp(
    r'(www\.|https?:|\.com|\.net|\.org|\.info|kbps|kb/s|\d{3,4}p\b'
    r'|mp3|mp4|m4a|wav|flac|\bhd\b|\bhq\b|\b4k\b|official|lyrics'
    r'|audio\s*only|youtube|download|free|copy|نسخة|تحميل|موقع|بجودة|حصري)',
    caseSensitive: false,
  );
  s = s.replaceAllMapped(RegExp(r'[\[({]([^\])}]*)[\])}]'), (m) {
    final inner = m.group(1) ?? '';
    return junkInside.hasMatch(inner) ? ' ' : m.group(0)!;
  });

  // بصمة موقع طليقة في الاسم: "site.com - العنوان" أو العكس.
  s = s.replaceAll(
    RegExp(
      r'(^|\s)(www\.)?[\w-]+\.(com|net|org|info|me|tv|cc)(?=\s|$)',
      caseSensitive: false,
    ),
    ' ',
  );

  // ترقيم تسلسلي في البداية: "01 - " / "(12) " / "003." / "٧ ـ "
  final leadingIndex = RegExp(
    r'^[\s\-–—ـ_.]*[(\[]?\s*[0-9٠-٩]{1,4}\s*[)\]]?[\s\-–—ـ_.]+',
  );
  for (var i = 0; i < 2 && leadingIndex.hasMatch(s); i++) {
    s = s.replaceFirst(leadingIndex, '');
  }

  // فواصل آلية إلى مسافات: الشرطة السفلية والنقاط الداخلية والرموز الزخرفية.
  s = s.replaceAll(RegExp(r'[_~•·]+'), ' ');
  s = s.replaceAll(RegExp(r'(?<=\S)\.(?=\S)'), ' ');

  // وسوم جودة علقت وسط الاسم.
  s = s.replaceAll(
    RegExp(r'\b(64|96|128|192|256|320)\s?kbps\b', caseSensitive: false),
    ' ',
  );

  // اسم بلا مسافات إطلاقاً وفيه شرطات؟ فالشرطات فواصل لا جزء من العنوان.
  if (!s.contains(' ') && s.contains('-')) {
    s = s.replaceAll('-', ' ');
  }

  // تنظيف نهائي: مسافات مكرّرة وحواف رموز.
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(RegExp(r'^[\s\-–—ـ_.,،؛;:]+|[\s\-–—ـ_.,،؛;:]+$'), '').trim();

  // لا حروف عربية أو لاتينية باقية؟ إذن ليس عنواناً.
  if (!RegExp(r'[A-Za-z؀-ۿ]').hasMatch(s)) return '';
  if (s.length < 2) return '';
  return s;
}

/// مثل [smartTitleFromFileName] لكن لا يعيد `''` أبداً — يسقط إلى قصّ
/// الامتداد فقط. للمسارات الجماعية (رفع متعدد) حيث العنوان الفارغ يعطّل.
String smartTitleOrBasename(String fileName) {
  final smart = smartTitleFromFileName(fileName);
  if (smart.isNotEmpty) return smart;
  var s = fileName.split(RegExp(r'[/\\]')).last;
  final dot = s.lastIndexOf('.');
  if (dot > 0) s = s.substring(0, dot);
  return s
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
