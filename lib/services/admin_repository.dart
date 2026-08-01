import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models.dart';

/// كل عمليات القراءة/الكتابة على Firestore لإدارة محتوى منبر.
/// المجموعات: categories, subcategories, lessons,
/// dashboard_admins, dashboard_owner_codes.
class AdminRepository {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  // ---------------- جلب ----------------
  static Future<List<Category>> fetchCategories() async {
    final snap = await _db.collection('categories').get();
    final list = snap.docs
        .map((d) => Category.fromDoc(d.id, d.data()))
        .toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  static Future<List<Subcategory>> fetchSubcategories() async {
    final snap = await _db.collection('subcategories').get();
    return snap.docs.map((d) => Subcategory.fromDoc(d.id, d.data())).toList();
  }

  static Future<List<Lesson>> fetchLessons() async {
    final snap = await _db.collection('lessons').get();
    final list = snap.docs.map((d) => Lesson.fromDoc(d.id, d.data())).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  // ---------------- مشرفو لوحة التحكّم (dashboard_admins) ----------------
  // المشرف يُنشأ فقط عبر رمز الاعتماد (AuthService.verifyOwnerCode)، تماماً
  // كما في نبراس — لا يوجد هنا إضافة مشرف يدوياً بكتابة بريده.
  static const String _dashCol = 'dashboard_admins';
  static const String _ownerCodesCol = 'dashboard_owner_codes';

  /// قائمة كل الحسابات المصرَّح لها (المالك + المشرفون) — نظير صفحة
  /// المشرفين في نبراس. أحدث تسجيل دخول في الأعلى (fallback: addedAt).
  static Future<List<DashAdmin>> fetchDashAdmins() async {
    final snap = await _db.collection(_dashCol).get();
    final list = snap.docs
        .map((d) => DashAdmin.fromDoc(d.id, d.data()))
        .toList();
    list.sort((a, b) {
      final ax = (a.lastSignedInAt ?? a.addedAt).millisecondsSinceEpoch;
      final bx = (b.lastSignedInAt ?? b.addedAt).millisecondsSinceEpoch;
      return bx.compareTo(ax);
    });
    return list;
  }

  /// حالة بريد معيّن: null إن غير موجود، وإلا الوثيقة.
  static Future<DashAdmin?> getDashAdmin(String email) async {
    final id = email.trim().toLowerCase();
    if (id.isEmpty) return null;
    final doc = await _db.collection(_dashCol).doc(id).get();
    if (!doc.exists) return null;
    return DashAdmin.fromDoc(doc.id, doc.data() ?? {});
  }

  /// يثبّت دور المالك ويحدّث وقت آخر دخول (idempotent — نظير Owner Bypass
  /// في نبراس). يُستدعى من AuthService.resolveAccess عند كل دخول للمالك.
  static Future<void> upsertOwnerRecord(
    String email, {
    String displayName = '',
    String photoURL = '',
  }) async {
    final id = email.trim().toLowerCase();
    if (id.isEmpty) return;
    await _db.collection(_dashCol).doc(id).set({
      'email': id,
      'role': 'owner',
      'blocked': false,
      'blockMode': null,
      'displayName': displayName,
      'photoURL': photoURL,
      'addedBy': 'owner_bypass',
      'addedAt': _nowIso(),
      'lastSignedInAt': _nowIso(),
    }, SetOptions(merge: true));
  }

  /// يحدّث وقت آخر دخول لمشرف معتمَد (مسموح للمستخدم بتحديث وثيقته فقط
  /// طالما غير محظور — انظر firestore.rules).
  static Future<void> touchLastSignedIn(String email) async {
    final id = email.trim().toLowerCase();
    if (id.isEmpty) return;
    try {
      await _db.collection(_dashCol).doc(id).update({
        'lastSignedInAt': _nowIso(),
      });
    } catch (_) {}
  }

  /// حظر مؤقّت/نهائي أو إلغاء الحظر — نظير أزرار صفحة المشرفين في نبراس.
  static Future<void> setDashAdminBlocked(
    String email,
    bool blocked, {
    String mode = 'temporary',
  }) async {
    final id = email.trim().toLowerCase();
    await _db.collection(_dashCol).doc(id).update({
      'blocked': blocked,
      'blockMode': blocked ? mode : null,
      'blockedAt': blocked ? _nowIso() : null,
    });
  }

  static Future<void> removeDashAdmin(String email) async {
    final id = email.trim().toLowerCase();
    await _db.collection(_dashCol).doc(id).delete();
  }

  /// بثّ حيّ لكل رموز الاعتماد المعلَّقة (يقرؤها المالك فقط — firestore.rules).
  /// الرموز الحقيقية وثائق بمعرّف = بريد المرشّح؛ وثيقة `current` مرآة توافق
  /// قديمة تُستبعد كي لا يظهر الرمز نفسه مرتين.
  static Stream<List<PendingOwnerCode>> watchPendingOwnerCodes() {
    return _db.collection(_ownerCodesCol).snapshots().map((snap) {
      final list = <PendingOwnerCode>[];
      for (final doc in snap.docs) {
        if (doc.id == 'current') continue;
        final code = PendingOwnerCode.fromDoc(doc.data());
        if (!code.isExpired && code.code.isNotEmpty) list.add(code);
      }
      list.sort((a, b) => b.expiresAt.compareTo(a.expiresAt));
      return list;
    });
  }

  /// يُبطل رمز مرشّح فعلياً: يحذف وثيقة بريده (التي يتحقق منها الخادم)،
  /// ومرآة `current` إن كانت تخص المرشّح نفسه. (الحذف السابق كان يمسح
  /// المرآة فقط ويُبقي الرمز الحقيقي صالحاً.)
  static Future<void> cancelOwnerCode(PendingOwnerCode code) async {
    final email = code.candidateEmail.trim().toLowerCase();
    if (email.isNotEmpty) {
      await _db.collection(_ownerCodesCol).doc(email).delete();
    }
    try {
      final mirrorRef = _db.collection(_ownerCodesCol).doc('current');
      final mirror = await mirrorRef.get();
      final mirrorEmail =
          ((mirror.data() ?? const {})['candidateEmail'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
      if (mirror.exists && (mirrorEmail.isEmpty || mirrorEmail == email)) {
        await mirrorRef.delete();
      }
    } catch (_) {}
  }

  // ---------------- إضافة ----------------
  static Future<void> addCategory(String name) async {
    await _db.collection('categories').add({
      'name': name.trim(),
      'createdAt': _nowIso(),
    });
  }

  static Future<void> addSubcategory(String name, String categoryId) async {
    await _db.collection('subcategories').add({
      'name': name.trim(),
      'categoryId': categoryId,
      'createdAt': _nowIso(),
    });
  }

  static Future<void> addLesson({
    required String title,
    required String categoryId,
    required String subcategoryId,
    required String audioUrl,
    String? audioStoragePath,
    String addedBy = '',
    DateTime? publishAt,
    bool featured = false,
  }) async {
    final data = <String, dynamic>{
      'title': title.trim(),
      'categoryId': categoryId,
      'subcategoryId': subcategoryId,
      'audioUrl': audioUrl,
      'createdAt': _nowIso(),
    };
    if (audioStoragePath != null && audioStoragePath.isNotEmpty) {
      data['audioStoragePath'] = audioStoragePath;
    }
    if (featured) data['featured'] = true;
    if (addedBy.isNotEmpty) data['addedBy'] = addedBy.toLowerCase();
    if (publishAt != null) {
      data['publishAt'] = publishAt.toUtc().toIso8601String();
    }
    await _functions.httpsCallable('createLesson').call(data);
  }

  /// تمييز/إلغاء تمييز درس (يظهر في «المميّزة» أعلى التطبيق).
  static Future<void> setLessonFeatured(String id, bool featured) =>
      _updateCompat('lessons', id, {'featured': featured});

  /// جدولة/إلغاء جدولة نشر درس (يظهر للمستخدمين عند حلول الوقت).
  static Future<void> setLessonPublishAt(String id, DateTime? when) =>
      _updateCompat('lessons', id, {
        'publishAt': when == null
            ? FieldValue.delete()
            : when.toUtc().toIso8601String(),
      });

  /// «نشر الآن» لدرس مجدول: عبر الدالة الخادمية التي تنشر **وترسل إشعار
  /// «درس جديد»** (حذف publishAt وحده كان ينشر بصمت بلا أي إشعار).
  /// إن تعذّر الوصول للدالة نعود للسلوك القديم كي لا يعلق المشرف.
  static Future<void> publishScheduledNow(String lessonId) async {
    try {
      await _functions.httpsCallable('publishScheduledLesson').call<void>({
        'lessonId': lessonId,
      });
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'unimplemented' ||
          e.code == 'unavailable' ||
          e.code == 'internal' ||
          e.code == 'not-found') {
        await setLessonPublishAt(lessonId, null);
        return;
      }
      rethrow;
    }
  }

  // ---------------- تعديل ----------------
  static Future<void> updateCategory(String id, String name) =>
      _updateCompat('categories', id, {'name': name.trim()});

  static Future<void> updateSubcategory(String id, String name) =>
      _updateCompat('subcategories', id, {'name': name.trim()});

  static Future<void> updateLessonTitle(String id, String title) =>
      _updateCompat('lessons', id, {'title': title.trim()});

  /// يحافظ على شكل الوثائق القديمة `{data:{...}}` بدلاً من كتابة حقل جديد
  /// في الجذر لا يقرأه التطبيق العام.
  static Future<void> _updateCompat(
    String collection,
    String id,
    Map<String, dynamic> fields,
  ) async {
    final ref = _db.collection(collection).doc(id);
    final user = FirebaseAuth.instance.currentUser;
    final trackedFields = <String, dynamic>{
      ...fields,
      if (user != null) 'updatedByUid': user.uid,
      if ((user?.email ?? '').isNotEmpty)
        'updatedByEmail': user!.email!.trim().toLowerCase(),
      'updatedAt': _nowIso(),
    };
    await _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      if (!snapshot.exists) {
        throw StateError('المستند المطلوب غير موجود.');
      }
      final raw = snapshot.data() ?? const <String, dynamic>{};
      if (raw['data'] is Map) {
        transaction.update(ref, {
          for (final entry in trackedFields.entries)
            'data.${entry.key}': entry.value,
        });
      } else {
        transaction.update(ref, trackedFields);
      }
    });
  }

  // ---------------- حذف ----------------
  /// يحذف القسم الرئيسي حذفاً تعاقبياً كاملاً: كل أقسامه الفرعية ودروسها
  /// (مع ملفاتها الصوتية في التخزين)، ثم أي دروس مرتبطة به مباشرةً، ثم القسم.
  static Future<void> deleteCategory(String id) async {
    await _functions.httpsCallable('deleteCategoryCascade').call<void>({
      'categoryId': id,
    });
  }

  /// يحذف القسم الفرعي حذفاً تعاقبياً: كل دروسه (مع ملفاتها الصوتية في
  /// التخزين)، ثم وثيقة القسم الفرعي.
  static Future<void> deleteSubcategory(String id) async {
    await _functions.httpsCallable('deleteSubcategoryCascade').call<void>({
      'subcategoryId': id,
    });
  }

  /// يحذف الدرس: الملف الصوتي من التخزين (إن وُجد) ثم الوثيقة.
  static Future<void> deleteLesson(Lesson lesson) async {
    await _functions.httpsCallable('deleteLesson').call<void>({
      'lessonId': lesson.id,
    });
  }

  // ---------------- تفاعل المستمعين (feedback) ----------------
  static Future<List<Map<String, dynamic>>> fetchFeedback() async {
    final snap = await _db.collection('feedback').get();
    final list = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
    list.sort(
      (a, b) => (b['createdAtMs'] ?? 0).compareTo(a['createdAtMs'] ?? 0),
    );
    return list;
  }

  static Future<void> deleteFeedback(String id) =>
      _db.collection('feedback').doc(id).delete();

  // ---------------- تنبيهات المشرف (إنجازات/تقرير أسبوعي) ----------------
  /// يزيل خادمياً تنبيهات المساهمات التي حُسمت قبل الإصلاح الحالي.
  static Future<void> cleanupResolvedAdminAlerts() async {
    try {
      await _functions.httpsCallable('cleanupResolvedAdminAlerts').call<void>();
    } catch (_) {
      // لا نحجب اللوحة إذا كانت الدالة لم تُنشر بعد أو كان الاتصال ضعيفاً.
    }
  }

  /// المالك يرى كل التنبيهات؛ المشرف يرى تنبيهاته والعامة (email == '').
  static Future<List<Map<String, dynamic>>> fetchAdminAlerts(
    String email,
    bool isOwner,
  ) async {
    final e = email.trim().toLowerCase();
    final docs = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    if (isOwner) {
      final snapshot = await _db.collection('admin_alerts').get();
      for (final doc in snapshot.docs) {
        docs[doc.id] = doc;
      }
    } else {
      if (e.isEmpty) return const [];
      // تطابق قواعد القراءة: لا نجلب كل التنبيهات ثم نرشّحها محلياً.
      final results = await Future.wait([
        _db.collection('admin_alerts').where('email', isEqualTo: e).get(),
        _db.collection('admin_alerts').where('email', isEqualTo: '').get(),
      ]);
      for (final snapshot in results) {
        for (final doc in snapshot.docs) {
          docs[doc.id] = doc;
        }
      }
    }
    final list = docs.values.map((d) => {'id': d.id, ...d.data()}).toList();
    list.sort(
      (a, b) => (b['createdAtMs'] ?? 0).compareTo(a['createdAtMs'] ?? 0),
    );
    return list;
  }
}
