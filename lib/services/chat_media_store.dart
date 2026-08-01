import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_repository.dart';

/// حالة مرفق على هذا الجهاز (نمط واتساب).
enum MediaState { notDownloaded, downloading, downloaded, failed }

/// حالة تنزيل مرفق واحد — تراقبها الفقاعة فتعرض زرّ التنزيل أو التقدّم أو
/// المشغّل.
class MediaStatus {
  const MediaStatus({
    required this.state,
    this.progress = 0,
    this.file,
    this.error,
  });

  final MediaState state;
  final double progress; // 0..100
  final File? file;
  final String? error;

  bool get isReady => state == MediaState.downloaded && file != null;

  static const MediaStatus idle = MediaStatus(state: MediaState.notDownloaded);
}

/// 📥 مخزن وسائط الدردشة — **لا تُشغَّل الوسائط بثّاً من الشبكة إطلاقاً**؛
/// تُنزَّل أولاً إلى الجهاز ثم تُفتح من الملفّ المحلّي (تماماً كواتساب).
///
/// لماذا هذا هو الحلّ الصحيح لا مجرّد تحسين:
///  • **يصلح «الصوتيات لا تفتح عند بعض المشرفين»**: التنزيل يتمّ عبر
///    Firebase Storage SDK (`writeToFile`) بهويّة المستخدم الموثّقة، فيمرّ
///    عبر قواعد Storage مباشرةً. أمّا التشغيل السابق فكان بثّاً خامّاً عبر
///    رابط التنزيل (HTTP + إعادة توجيه + طلبات Range) وهو ما يفشل على بعض
///    الأجهزة والشبكات ومع بعض صيغ m4a — وهذا سبب اختلاف السلوك بين مشرف
///    وآخر رغم أنّ الرابط نفسه.
///  • **يعمل دون إنترنت**: ما نُزّل مرّة يبقى ويُشغَّل لاحقاً بلا شبكة.
///  • **يوفّر البيانات**: لا يُنزَّل شيء إلّا بطلب المستخدم (عدا ما هو صغير
///    جدّاً كالرسائل الصوتيّة، مثل واتساب تماماً).
class ChatMediaStore {
  ChatMediaStore._();
  static final ChatMediaStore instance = ChatMediaStore._();

  static const String _prefsAutoDownload = 'chat_auto_download_v1';

  /// أقصى حجم يُنزَّل تلقائيّاً (رسائل صوتيّة وصور صغيرة) — كواتساب.
  static const int autoDownloadMaxBytes = 3 * 1024 * 1024;

  final Map<String, ValueNotifier<MediaStatus>> _notifiers = {};
  final Set<String> _running = {};
  Directory? _dir;

  /// مفتاح ثابت للمرفق: مسار Storage إن وُجد، وإلّا الرابط (للرسائل القديمة).
  String keyOf(ChatAttachment att) =>
      att.path.isNotEmpty ? att.path : att.url;

  ValueNotifier<MediaStatus> statusOf(ChatAttachment att) {
    final key = keyOf(att);
    final existing = _notifiers[key];
    if (existing != null) return existing;
    final n = ValueNotifier<MediaStatus>(MediaStatus.idle);
    _notifiers[key] = n;
    // فحص وجود الملفّ محليّاً (غير متزامن) ثم تحديث الحالة.
    unawaited(_hydrate(att, n));
    return n;
  }

  Future<Directory> _mediaDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/chat_media');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  /// اسم ملفّ محلّي فريد ومستقرّ: بصمة المفتاح + الامتداد الأصلي.
  String _localName(ChatAttachment att) {
    final digest = sha1.convert(utf8.encode(keyOf(att))).toString();
    final name = att.name;
    final dot = name.lastIndexOf('.');
    final ext = (dot > 0 && name.length - dot <= 6)
        ? name.substring(dot).toLowerCase()
        : _extFromMime(att.contentType);
    return '$digest$ext';
  }

  static String _extFromMime(String mime) => switch (mime) {
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/webp' => '.webp',
    'image/gif' => '.gif',
    'video/mp4' => '.mp4',
    'video/quicktime' => '.mov',
    'audio/mpeg' => '.mp3',
    'audio/mp4' => '.m4a',
    'audio/aac' => '.aac',
    'audio/ogg' => '.ogg',
    'audio/wav' => '.wav',
    'application/pdf' => '.pdf',
    _ => '.bin',
  };

  Future<File> localFile(ChatAttachment att) async {
    final dir = await _mediaDir();
    return File('${dir.path}/${_localName(att)}');
  }

  Future<void> _hydrate(
    ChatAttachment att,
    ValueNotifier<MediaStatus> n,
  ) async {
    try {
      final f = await localFile(att);
      if (await f.exists() && await f.length() > 0) {
        n.value = MediaStatus(state: MediaState.downloaded, file: f);
        return;
      }
      // تنزيل تلقائي للملفّات الصغيرة جدّاً (رسائل صوتيّة/صور) إن كان مُفعّلاً.
      if (att.size > 0 &&
          att.size <= autoDownloadMaxBytes &&
          await autoDownloadEnabled()) {
        unawaited(download(att));
      }
    } catch (_) {
      // يبقى بحالة «غير منزَّل» — يستطيع المستخدم التنزيل يدويّاً.
    }
  }

  static Future<bool> autoDownloadEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_prefsAutoDownload) ?? true;
  }

  static Future<void> setAutoDownload(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_prefsAutoDownload, v);
  }

  /// تنزيل المرفق إلى الجهاز. آمن للاستدعاء المتكرّر (لا يبدأ تنزيلين).
  Future<File?> download(ChatAttachment att) async {
    final key = keyOf(att);
    final n = statusOf(att);
    if (n.value.isReady) return n.value.file;
    if (_running.contains(key)) return null;
    _running.add(key);
    n.value = const MediaStatus(state: MediaState.downloading);

    File? target;
    try {
      final f = await localFile(att);
      // ملفّ مؤقّت ثم إعادة تسمية — يمنع بقاء ملفّ نصف منزَّل يبدو سليماً.
      final tmp = File('${f.path}.part');
      if (await tmp.exists()) await tmp.delete();
      target = tmp;

      final ref = att.path.isNotEmpty
          ? FirebaseStorage.instance.ref(att.path)
          : FirebaseStorage.instance.refFromURL(att.url);

      final task = ref.writeToFile(tmp);
      task.snapshotEvents.listen((s) {
        final total = s.totalBytes > 0 ? s.totalBytes : att.size;
        if (total > 0) {
          n.value = MediaStatus(
            state: MediaState.downloading,
            progress: (s.bytesTransferred / total) * 100,
          );
        }
      }, onError: (_) {});
      await task;

      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
      n.value = MediaStatus(state: MediaState.downloaded, file: f);
      return f;
    } catch (e) {
      try {
        if (target != null && await target.exists()) await target.delete();
      } catch (_) {}
      n.value = MediaStatus(
        state: MediaState.failed,
        error: _friendlyError(e),
      );
      return null;
    } finally {
      _running.remove(key);
    }
  }

  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('object-not-found') || s.contains('404')) {
      return 'الملفّ لم يعد موجوداً على الخادم.';
    }
    if (s.contains('unauthorized') || s.contains('403')) {
      return 'لا تملك صلاحيّة تنزيل هذا الملفّ.';
    }
    if (s.contains('retry-limit') || s.contains('network')) {
      return 'انقطع الاتصال أثناء التنزيل.';
    }
    return 'تعذّر التنزيل.';
  }

  /// حذف النسخة المحليّة (تحرير مساحة) — تعود الحالة إلى «غير منزَّل».
  Future<void> deleteLocal(ChatAttachment att) async {
    try {
      final f = await localFile(att);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    statusOf(att).value = MediaStatus.idle;
  }

  /// إجمالي حجم الوسائط المخزَّنة على الجهاز (لشاشة معلومات المجموعة).
  Future<int> totalBytes() async {
    try {
      final dir = await _mediaDir();
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// مسح كلّ وسائط الدردشة المخزَّنة.
  Future<void> clearAll() async {
    try {
      final dir = await _mediaDir();
      await for (final e in dir.list()) {
        if (e is File) await e.delete();
      }
    } catch (_) {}
    for (final n in _notifiers.values) {
      n.value = MediaStatus.idle;
    }
  }
}
