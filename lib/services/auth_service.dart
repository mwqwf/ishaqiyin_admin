import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../core/config.dart';
import 'admin_repository.dart';
import 'admin_notification_service.dart';

/// نتيجة صلاحية الدخول — مطابقة تماماً لتدفّق لوحة نبراس:
/// Google فقط، Owner Bypass فوري، ومشرف جديد يحتاج رمز اعتماد (needsOwnerCode).
enum AccessState { signedOut, owner, supervisor, needsOwnerCode, blocked }

class AccessVerificationException implements Exception {
  final String message;
  const AccessVerificationException(this.message);

  @override
  String toString() => message;
}

/// نتيجة طلب/تحقّق رمز الاعتماد (نظير /api/auth/request-code و
/// /api/auth/verify-code في نبراس).
class OwnerCodeResult {
  final bool ok;
  final String? reason;
  final int? retryAfterSec;
  OwnerCodeResult({required this.ok, this.reason, this.retryAfterSec});
}

/// مصادقة المشرف — مطابقة تماماً لنمط لوحة نبراس: تسجيل دخول بـ Google
/// حصراً (لا بريد/كلمة مرور). الصلاحية تُحدَّد بعد الدخول:
///   • المالك ([AppConfig.ownerEmail]) → Owner Bypass فوري بلا رمز.
///   • مستخدم معتمَد مسبقاً في `dashboard_admins` → مشرف (ما لم يكن محظوراً).
///   • مستخدم جديد → يحتاج رمز اعتماد يطلبه فيراه المالك حيّاً داخل تطبيقه
///     (بديل البريد الإلكتروني في نبراس) ثم يُبلَّغ به المرشّح يدوياً.
/// كل صلاحيات الكتابة مفروضة في قواعد Firestore على الخادم.
class AuthService {
  static FirebaseAuth get _a => FirebaseAuth.instance;
  static GoogleSignIn? _google;

  static GoogleSignIn _googleClient() {
    return _google ??= GoogleSignIn(
      scopes: const ['email', 'profile', 'openid'],
      serverClientId: AppConfig.googleServerClientId.isEmpty
          ? null
          : AppConfig.googleServerClientId,
    );
  }

  static User? get currentUser => _a.currentUser;
  static bool get isLoggedIn => _a.currentUser != null;
  static Stream<User?> get authState => _a.authStateChanges();

  static bool isOwnerEmail(String? email) =>
      (email ?? '').trim().toLowerCase() ==
      AppConfig.ownerEmail.trim().toLowerCase();

  // ─── تسجيل الدخول بـ Google (المطابق للوحة نبراس) ───────────────
  static Future<String?> signInWithGoogle() async {
    if (!AppConfig.googleSignInConfigured) {
      return 'تسجيل الدخول بـ Google غير مُهيّأ بعد (يلزم Web client id لمشروع '
          'mxqp-8d1e8). مرّره عبر --dart-define=GOOGLE_SERVER_CLIENT_ID=...';
    }
    try {
      final account = await _googleClient().signIn();
      if (account == null) return null; // ألغى المستخدم.
      final gAuth = await account.authentication;
      final cred = GoogleAuthProvider.credential(
        accessToken: gAuth.accessToken,
        idToken: gAuth.idToken,
      );
      await _a.signInWithCredential(cred);
      return null; // الصلاحية تُحدَّد لاحقاً عبر resolveAccess.
    } on FirebaseAuthException catch (e) {
      return _msg(e.code);
    } catch (e) {
      return 'فشل تسجيل الدخول بـ Google: $e';
    }
  }

  /// يحدّد صلاحية المستخدم الحاليّ بعد الدخول (نظير /api/auth/check في نبراس).
  static Future<AccessState> resolveAccess() async {
    final user = _a.currentUser;
    if (user == null) return AccessState.signedOut;
    final email = (user.email ?? '').trim().toLowerCase();
    if (email.isEmpty) return AccessState.needsOwnerCode;

    // بريد المالك وحده يملك bypass — والصلاحية تُشتق من ثابت البريد نفسه،
    // فلا يجوز حجب المالك خلف كتابة توثيقية قد تفشل مؤقتاً (إقلاع خلف قفل
    // الشاشة يخنق الشبكة فتظهر شاشة خطأ توحي بانهيار). القواعد على الخادم
    // تظل الحكم النهائي لأي عملية كتابة لاحقة.
    if (isOwnerEmail(email)) {
      unawaited(
        AdminRepository.upsertOwnerRecord(
          email,
          displayName: user.displayName ?? '',
          photoURL: user.photoURL ?? '',
        ).catchError((_) {
          // توثيق أفضل-جهد — يُعاد في الإقلاع التالي.
        }),
      );
      return AccessState.owner;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('dashboard_admins')
          .doc(email)
          .get();
      if (!doc.exists) return AccessState.needsOwnerCode;
      final data = doc.data() ?? const <String, dynamic>{};
      if (data['blocked'] == true) {
        return AccessState.blocked;
      }
      // لا تكفي مجرد وثيقة موجودة: يجب أن يكون الدور المعتمد صريحاً.
      if ((data['role'] ?? '').toString() != 'supervisor') {
        return AccessState.blocked;
      }
      // مصرَّح له بالفعل — حدّث وقت آخر دخول (لا يُفشل تسجيل الدخول إن تعذّر).
      unawaited(AdminRepository.touchLastSignedIn(email));
      return AccessState.supervisor;
    } catch (_) {
      throw const AccessVerificationException(
        'تعذّر الاتصال بالخادم للتحقق من الدور والحظر. لم تُمنح أي صلاحية مؤقتة.',
      );
    }
  }

  // ─── رمز اعتماد المشرف (نظير /api/auth/request-code و verify-code) ───
  // لا تتوفّر صلاحية استدعاء عامّة لدوالّ onCall في هذا المشروع، فالتنفيذ
  // عبر "طلب بوثيقة": نكتب وثيقة بمعرّف = بريدنا، ومُشغِّل Firestore على
  // الخادم يكتب النتيجة (result) رجوعاً في نفس الوثيقة، ونحذفها بعد القراءة.
  static Future<Map<String, dynamic>> _requestResponse(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> payload,
  ) async {
    try {
      await ref.delete();
    } catch (_) {}
    await ref.set(payload);
    try {
      final snap = await ref
          .snapshots()
          .where((s) => s.exists && s.data()?['result'] != null)
          .first
          .timeout(const Duration(seconds: 20));
      return Map<String, dynamic>.from(snap.data() ?? {});
    } finally {
      try {
        await ref.delete();
      } catch (_) {}
    }
  }

  static Future<OwnerCodeResult> requestOwnerCode() async {
    final user = _a.currentUser;
    final email = (user?.email ?? '').trim().toLowerCase();
    if (user == null || email.isEmpty) {
      return OwnerCodeResult(ok: false, reason: 'send_failed');
    }
    try {
      final ref = FirebaseFirestore.instance
          .collection('dashboard_code_requests')
          .doc(email);
      final data = await _requestResponse(ref, {
        'uid': user.uid,
        'name': user.displayName ?? '',
        'photoURL': user.photoURL ?? '',
        'requestedAt': DateTime.now().toUtc().toIso8601String(),
      });
      final result = data['result'] as String?;
      if (result == 'ok') return OwnerCodeResult(ok: true);
      return OwnerCodeResult(
        ok: false,
        reason: result ?? 'send_failed',
        retryAfterSec: (data['retryAfterSec'] as num?)?.toInt(),
      );
    } catch (_) {
      return OwnerCodeResult(ok: false, reason: 'send_failed');
    }
  }

  static Future<OwnerCodeResult> verifyOwnerCode(String code) async {
    final user = _a.currentUser;
    final email = (user?.email ?? '').trim().toLowerCase();
    if (user == null || email.isEmpty) {
      return OwnerCodeResult(ok: false, reason: 'server');
    }
    try {
      final ref = FirebaseFirestore.instance
          .collection('dashboard_code_verify')
          .doc(email);
      final data = await _requestResponse(ref, {'code': code.trim()});
      final result = data['result'] as String?;
      if (result == 'ok') return OwnerCodeResult(ok: true);
      return OwnerCodeResult(ok: false, reason: result ?? 'server');
    } catch (_) {
      return OwnerCodeResult(ok: false, reason: 'server');
    }
  }

  static Future<void> signOut() async {
    await AdminNotificationService.unregisterCurrentDevice();
    try {
      await _googleClient().signOut();
    } catch (_) {}
    await _a.signOut();
  }

  static String _msg(String code) {
    switch (code) {
      case 'invalid-email':
        return 'صيغة البريد غير صحيحة.';
      case 'user-disabled':
        return 'هذا الحساب معطّل.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'البريد أو كلمة المرور غير صحيحة.';
      case 'weak-password':
        return 'كلمة المرور ضعيفة (٦ أحرف على الأقل).';
      case 'operation-not-allowed':
        return 'طريقة الدخول غير مُفعّلة في Firebase. فعّلها من Console.';
      case 'network-request-failed':
        return 'لا يوجد اتصال بالإنترنت.';
      default:
        return 'تعذّر تسجيل الدخول ($code).';
    }
  }
}
