import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 📤 استقبال «المشاركة إلى إدارة منبر» من الجانب الأصلي (MainActivity.kt).
///
/// المشرف يشارك ملفاً صوتياً (أو عدة ملفات) من أي تطبيق إلى «إدارة منبر
/// ادكصهك»، فتصل مساراتها المنسوخة إلى cache هنا، وتفتح اللوحة نموذج
/// «إضافة درس» معبّأً بها ملفاً تلو الآخر.
class ShareIntakeService {
  ShareIntakeService._();

  static const MethodChannel _channel = MethodChannel('menbar_admin/share');
  static Future<void> Function(List<String> paths)? _onShared;
  static final Set<String> _activePaths = <String>{};
  static bool _initialized = false;

  /// [onShared] يُستدعى بقائمة مسارات ملفات محلية جاهزة للقراءة.
  static Future<void> init(
    Future<void> Function(List<String> paths) onShared,
  ) async {
    _onShared = onShared;
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShared') {
        final paths =
            (call.arguments as List?)
                ?.map((e) => e.toString())
                .where((p) => p.isNotEmpty)
                .toList() ??
            const <String>[];
        await _deliver(paths);
      }
    });

    // ملفات وصلت قبل جاهزية Dart (التطبيق فُتح بالمشاركة نفسها).
    try {
      final initial = await _channel.invokeMethod<List<dynamic>>(
        'getPendingShared',
      );
      final paths =
          initial
              ?.map((e) => e.toString())
              .where((p) => p.isNotEmpty)
              .toList() ??
          const <String>[];
      await _deliver(paths);
    } catch (e) {
      debugPrint('ShareIntake getInitialShared failed: $e');
    }
  }

  static Future<void> _deliver(List<String> paths) async {
    final fresh = paths.where(_activePaths.add).toList();
    if (fresh.isEmpty) return;
    final handler = _onShared;
    if (handler == null) return;
    await handler(fresh);
  }

  /// يؤكد أن نموذج الإضافة أُغلق (نجاحاً أو إلغاءً)، فيحذف الملف المؤقت
  /// من cache ويزيل الحدث pending من الجانب الأصلي.
  static Future<void> acknowledge(List<String> paths) async {
    if (paths.isEmpty) return;
    try {
      await _channel.invokeMethod<bool>('acknowledgeShared', paths);
    } catch (e) {
      debugPrint('ShareIntake acknowledgeShared failed: $e');
    } finally {
      _activePaths.removeAll(paths);
    }
  }

  /// يسمح بإعادة تسليم حدث بقي pending إذا أُغلقت شاشة اللوحة قبل معالجته.
  static void release(List<String> paths) {
    _activePaths.removeAll(paths);
  }
}
