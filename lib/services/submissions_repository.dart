import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// طلب نشر من مستمع (تطبيق منبر العام) بانتظار قرار المشرفين.
class LessonSubmission {
  final String id;
  final String uid;
  final String submitterName;
  final String title;
  final String categoryId;
  final String categoryName;
  final String subcategoryId;
  final String subcategoryName;
  final String note;
  final String audioUrl;
  final String storagePath;
  final String fileName;
  final int fileSize;
  final String fcmToken;
  final String status; // pending | approved | approved_edited | rejected
  final String rejectReason;
  final DateTime? createdAt;

  const LessonSubmission({
    required this.id,
    required this.uid,
    required this.submitterName,
    required this.title,
    required this.categoryId,
    required this.categoryName,
    required this.subcategoryId,
    required this.subcategoryName,
    required this.note,
    required this.audioUrl,
    required this.storagePath,
    required this.fileName,
    required this.fileSize,
    required this.fcmToken,
    required this.status,
    required this.rejectReason,
    this.createdAt,
  });

  factory LessonSubmission.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? const {};
    String s(dynamic v) => (v ?? '').toString();
    int i(dynamic v) => v is num ? v.toInt() : 0;
    DateTime? date(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    return LessonSubmission(
      id: doc.id,
      uid: s(d['uid']),
      submitterName: s(d['submitterName']),
      title: s(d['title']),
      categoryId: s(d['categoryId']),
      categoryName: s(d['categoryName']),
      subcategoryId: s(d['subcategoryId']),
      subcategoryName: s(d['subcategoryName']),
      note: s(d['note']),
      audioUrl: s(d['audioUrl']),
      storagePath: s(d['storagePath']),
      fileName: s(d['fileName']),
      fileSize: i(d['fileSize']),
      fcmToken: s(d['fcmToken']),
      status: s(d['status']).isEmpty ? 'pending' : s(d['status']),
      rejectReason: s(d['rejectReason']),
      createdAt: date(d['createdAt']),
    );
  }

  bool get isPending => status == 'pending';
}

/// 🗳️ مراجعة مساهمات المستمعين (قرار المالك): يوافق المشرف كما هي، أو
/// يعدّل (العنوان/الأقسام) ثم ينشر، أو يرفض بسبب يصل المساهم إشعاراً.
/// النشر الفعلي = إنشاء وثيقة درس عادية في `lessons` تشير لنفس ملف الصوت
/// المرفوع (لا نقل ولا إعادة رفع)، ثم تحديث حالة الطلب — ودالة السحابة
/// onSubmissionDecided ترسل الإشعار للمساهم.
class SubmissionsRepository {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;
  static const String collection = 'lesson_submissions';

  /// بثّ مباشر لكل الطلبات (المعلّقة أولاً ثم الأحدث قراراً).
  static Stream<List<LessonSubmission>> watchAll() {
    return _db.collection(collection).snapshots().map((snap) {
      final list = snap.docs.map(LessonSubmission.fromDoc).toList();
      list.sort((a, b) {
        if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
        return (b.createdAt ?? DateTime(0)).compareTo(
          a.createdAt ?? DateTime(0),
        );
      });
      return list;
    });
  }

  /// عدد الطلبات المعلّقة (شارة اللوحة).
  static Stream<int> watchPendingCount() => _db
      .collection(collection)
      .where('status', isEqualTo: 'pending')
      .snapshots()
      .map((s) => s.docs.length);

  /// الموافقة والنشر. مرِّر عنواناً/قسمين معدَّلين ليُنشر بالتعديل
  /// (status=approved_edited)، أو اتركها كما في الطلب (status=approved).
  static Future<void> approveAndPublish(
    LessonSubmission s, {
    String? editedTitle,
    String? editedCategoryId,
    String? editedCategoryName,
    String? editedSubcategoryId,
    String? editedSubcategoryName,
  }) async {
    final title = (editedTitle ?? s.title).trim();
    final categoryId = editedCategoryId ?? s.categoryId;
    final subcategoryId = editedSubcategoryId ?? s.subcategoryId;
    final edited =
        title != s.title.trim() ||
        categoryId != s.categoryId ||
        subcategoryId != s.subcategoryId;

    if (title.isEmpty || categoryId.isEmpty || subcategoryId.isEmpty) {
      throw ArgumentError('العنوان والقسمان مطلوبان قبل الموافقة.');
    }
    // callable ينفّذ إنشاء الدرس وتحديث الطلب في معاملة خادمية واحدة، ويمنع
    // الموافقات المتزامنة من إنشاء درسين مكررين.
    await _functions.httpsCallable('approveSubmission').call({
      'submissionId': s.id,
      'title': title,
      'categoryId': categoryId,
      'categoryName': editedCategoryName ?? s.categoryName,
      'subcategoryId': subcategoryId,
      'subcategoryName': editedSubcategoryName ?? s.subcategoryName,
      'edited': edited,
    });
  }

  /// الرفض بسبب (يصل المساهم نصّاً في الإشعار وشاشة «مساهماتي»).
  static Future<void> reject(LessonSubmission s, String reason) async {
    await _functions.httpsCallable('rejectSubmission').call({
      'submissionId': s.id,
      'reason': reason.trim(),
    });
  }

  /// حذف طلب نهائياً (بعد قرار قديم) — يحذف ملف الصوت أيضاً إن كان
  /// الطلب مرفوضاً (الملف غير مستعمل في أي درس منشور).
  /// اسم الدالة الخادمية `deleteSubmission` (كان الاستدعاء باسم غير موجود
  /// فيفشل زر «إزالة من السجل» دائماً).
  static Future<void> deleteDecided(LessonSubmission s) async {
    if (s.isPending) return;
    await _functions.httpsCallable('deleteSubmission').call({
      'submissionId': s.id,
    });
  }
}
