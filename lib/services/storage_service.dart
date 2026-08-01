import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';

/// مقبض إلغاء لرفع جارٍ: تمرّره الشاشة إلى [StorageService.uploadFile]
/// وتستدعي [cancel] من زر «إلغاء» — فيتوقف الرفع فوراً ويرمي
/// FirebaseException بكود 'canceled' تعالجه الشاشة برسالة لطيفة.
class UploadCanceller {
  UploadTask? _task;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  void attach(UploadTask task) {
    _task = task;
    if (_cancelled) task.cancel();
  }

  Future<void> cancel() async {
    _cancelled = true;
    try {
      await _task?.cancel();
    } catch (_) {}
  }
}

/// رفع/حذف الملفات في Firebase Storage (نفس بنية المشروع الأصلي).
/// المسارات: الصوتيات في `lessons/`، الكتب في `books/`.
class StorageService {
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  /// هل هذا الخطأ إلغاءً مقصوداً من المستخدم؟
  static bool isCancellation(Object e) =>
      e is FirebaseException && e.code == 'canceled';

  static String mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'aac':
        return 'audio/aac';
      case 'm4a':
        return 'audio/mp4';
      case 'amr':
        return 'audio/amr';
      case 'flac':
        return 'audio/flac';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  /// يرفع ملفاً ويعيد (downloadUrl, storagePath).
  /// [folder] إمّا 'lessons' أو 'books'. [filename] يجب أن يكون فريداً.
  static Future<({String url, String path})> uploadFile({
    required String localPath,
    required String folder,
    required String filename,
    void Function(double percent)? onProgress,
    UploadCanceller? canceller,
  }) async {
    final ext = filename.contains('.') ? filename.split('.').last : '';
    final storagePath = '$folder/$filename';
    final ref = _storage.ref(storagePath);
    final task = ref.putFile(
      File(localPath),
      SettableMetadata(contentType: mimeForExt(ext)),
    );
    canceller?.attach(task);
    task.snapshotEvents.listen((s) {
      if (s.totalBytes > 0 && onProgress != null) {
        onProgress(s.bytesTransferred / s.totalBytes * 100);
      }
    }, onError: (_) {});
    await task;
    final url = await ref.getDownloadURL();
    return (url: url, path: storagePath);
  }

  /// يستخرج مسار التخزين من رابط تنزيل Firebase أو يقبل مساراً مباشراً.
  static String? _resolvePath(String urlOrPath) {
    if (urlOrPath.isEmpty) return null;
    if (!urlOrPath.startsWith('http')) return urlOrPath;
    // .../o/lessons%2Ffile.mp3?alt=media&token=...
    final afterO = urlOrPath.split('/o/');
    if (afterO.length >= 2) {
      final encoded = afterO[1].split('?').first;
      return Uri.decodeComponent(encoded);
    }
    final m = RegExp(r'(lessons/[^?]+|books/[^?]+)').firstMatch(urlOrPath);
    return m?.group(0);
  }

  /// يحذف ملفاً من التخزين. يعتبر «الملف غير موجود» نجاحاً.
  static Future<bool> deleteFile(String urlOrPath) async {
    final path = _resolvePath(urlOrPath);
    if (path == null) return false;
    try {
      await _storage.ref(path).delete();
      return true;
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// نسخة صارمة للحذف: لا تسمح بحذف وثيقة Firestore إن بقي ملفها الصوتي.
  static Future<void> deleteFileOrThrow(String urlOrPath) async {
    final path = _resolvePath(urlOrPath);
    if (path == null) {
      throw ArgumentError.value(urlOrPath, 'urlOrPath', 'مسار تخزين غير صالح');
    }
    try {
      await _storage.ref(path).delete();
    } on FirebaseException catch (e) {
      if (e.code != 'object-not-found') rethrow;
    }
  }
}
