import 'dart:io';
import 'dart:typed_data';

/// 🔗 دمج عدة ملفات MP3 في ملف واحد بلا إعادة ترميز (Dart خالص، بلا ffmpeg).
///
/// الفكرة: ملف MP3 هو تيّار إطارات MPEG مستقلّة، فيكفي قصّ الأجزاء غير
/// الصوتية من كل ملف — وسم ID3v2 في البداية، وسم ID3v1 في النهاية، وإطار
/// Xing/Info/VBRI الوصفي (يصف ملفاً واحداً فقط، وإبقاؤه يجعل المدة الظاهرة
/// بعد الدمج خاطئة) — ثم لصق الإطارات تباعاً بالترتيب المطلوب.
/// الناتج ملف MP3 صالح يقرؤه كل المشغّلات.
class AudioMerger {
  AudioMerger._();

  /// الحد الأقصى لعدد الملفات القابلة للدمج في درس واحد.
  static const int maxFiles = 10;

  static bool isMp3(String fileName) =>
      fileName.toLowerCase().trim().endsWith('.mp3');

  /// يدمج [inputs] بترتيبها في ملف جديد على [outputPath] ويعيده.
  /// يرمي [FormatException] إن لم يُعثر على صوت MPEG داخل أحد الملفات.
  static Future<File> mergeMp3({
    required List<File> inputs,
    required String outputPath,
    void Function(double percent)? onProgress,
  }) async {
    if (inputs.isEmpty) throw ArgumentError('لا توجد ملفات للدمج');
    if (inputs.length > maxFiles) {
      throw ArgumentError('الحد الأقصى $maxFiles ملفات');
    }
    final out = File(outputPath);
    final sink = out.openWrite();
    try {
      for (var i = 0; i < inputs.length; i++) {
        final bytes = await inputs[i].readAsBytes();
        sink.add(_audioFramesOnly(bytes));
        onProgress?.call((i + 1) / inputs.length * 100);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return out;
  }

  /// يقصّ الوسوم ويعيد نطاق الإطارات الصوتية فقط.
  static Uint8List _audioFramesOnly(Uint8List b) {
    var start = 0;
    var end = b.length;

    // ID3v2: "ID3" + إصدار(2) + أعلام(1) + حجم syncsafe(4)
    if (end >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
      final size =
          ((b[6] & 0x7F) << 21) |
          ((b[7] & 0x7F) << 14) |
          ((b[8] & 0x7F) << 7) |
          (b[9] & 0x7F);
      var s = 10 + size;
      if ((b[5] & 0x10) != 0) s += 10; // ذيل ID3v2 الاختياري
      if (s < end) start = s;
    }

    // ID3v1: "TAG" في آخر 128 بايت
    if (end - start > 128 &&
        b[end - 128] == 0x54 &&
        b[end - 127] == 0x41 &&
        b[end - 126] == 0x47) {
      end -= 128;
    }

    // أول إطار MPEG صالح (نتحقق أن ما يليه إطار صالح أيضاً لتفادي
    // بايتات صدفة تشبه رأس إطار داخل بيانات عشوائية).
    var p = start;
    while (p + 4 <= end) {
      if (b[p] == 0xFF && (b[p + 1] & 0xE0) == 0xE0) {
        final len = _frameLength(b, p);
        if (len > 0) {
          final next = p + len;
          if (next + 4 > end ||
              (b[next] == 0xFF && (b[next + 1] & 0xE0) == 0xE0)) {
            break;
          }
        }
      }
      p++;
    }
    if (p + 4 > end) {
      throw const FormatException('لم يُعثر على صوت MPEG في الملف');
    }
    start = p;

    // إطار Xing/Info/VBRI الوصفي — يُحذف كي لا تظهر مدة خاطئة بعد الدمج.
    final firstLen = _frameLength(b, start);
    if (firstLen > 0 && start + firstLen <= end) {
      if (_hasVbrMarker(b, start, start + firstLen)) start += firstLen;
    }

    return Uint8List.sublistView(b, start, end);
  }

  /// هل يحوي النطاق علامة "Xing" أو "Info" أو "VBRI"؟
  static bool _hasVbrMarker(Uint8List b, int from, int to) {
    for (var i = from; i + 4 <= to; i++) {
      final c = b[i];
      if (c == 0x58 &&
          b[i + 1] == 0x69 &&
          b[i + 2] == 0x6E &&
          b[i + 3] == 0x67) {
        return true; // Xing
      }
      if (c == 0x49 &&
          b[i + 1] == 0x6E &&
          b[i + 2] == 0x66 &&
          b[i + 3] == 0x6F) {
        return true; // Info
      }
      if (c == 0x56 &&
          b[i + 1] == 0x42 &&
          b[i + 2] == 0x52 &&
          b[i + 3] == 0x49) {
        return true; // VBRI
      }
    }
    return false;
  }

  /// طول إطار MPEG بالبايتات انطلاقاً من رأسه في [p]، أو -1 إن كان الرأس فاسداً.
  static int _frameLength(Uint8List b, int p) {
    if (p + 4 > b.length) return -1;
    final h1 = b[p + 1], h2 = b[p + 2];
    final version = (h1 >> 3) & 0x03; // 0=MPEG2.5 1=محجوز 2=MPEG2 3=MPEG1
    final layer = (h1 >> 1) & 0x03; // 1=III 2=II 3=I
    final brIdx = (h2 >> 4) & 0x0F;
    final srIdx = (h2 >> 2) & 0x03;
    final padding = (h2 >> 1) & 0x01;
    if (version == 1 || layer == 0 || brIdx == 0 || brIdx == 15 || srIdx == 3) {
      return -1;
    }

    const srV1 = [44100, 48000, 32000];
    final base = srV1[srIdx];
    final sampleRate = version == 3
        ? base
        : (version == 2 ? base ~/ 2 : base ~/ 4);

    const brV1L1 = [
      0,
      32,
      64,
      96,
      128,
      160,
      192,
      224,
      256,
      288,
      320,
      352,
      384,
      416,
      448,
    ];
    const brV1L2 = [
      0,
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
      384,
    ];
    const brV1L3 = [
      0,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
    ];
    const brV2L1 = [
      0,
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
      176,
      192,
      224,
      256,
    ];
    const brV2L23 = [
      0,
      8,
      16,
      24,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
    ];

    final isV1 = version == 3;
    final List<int> table;
    if (layer == 3) {
      table = isV1 ? brV1L1 : brV2L1; // Layer I
    } else if (layer == 2) {
      table = isV1 ? brV1L2 : brV2L23; // Layer II
    } else {
      table = isV1 ? brV1L3 : brV2L23; // Layer III
    }
    final bitrate = table[brIdx] * 1000;
    if (bitrate == 0) return -1;

    if (layer == 3) {
      // Layer I
      return (12 * bitrate ~/ sampleRate + padding) * 4;
    }
    // Layer II دائماً 144؛ Layer III: للـ MPEG2/2.5 المعامل 72
    final coef = (layer == 1 && !isV1) ? 72 : 144;
    return coef * bitrate ~/ sampleRate + padding;
  }
}
