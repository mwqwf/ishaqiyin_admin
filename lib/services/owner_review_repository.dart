import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// نتيجة فحص أمني خاصة بالمالك. المجموعة وقواعدها لا تُقرأ من المشرفين.
class SuspiciousLessonReview {
  final String id;
  final String lessonId;
  final String title;
  final String audioUrl;
  final String categoryId;
  final String subcategoryId;
  final String addedBy;
  final int riskScore;
  final List<String> reasons;
  final String status;
  final DateTime? detectedAt;

  const SuspiciousLessonReview({
    required this.id,
    required this.lessonId,
    required this.title,
    required this.audioUrl,
    required this.categoryId,
    required this.subcategoryId,
    required this.addedBy,
    required this.riskScore,
    required this.reasons,
    required this.status,
    required this.detectedAt,
  });

  factory SuspiciousLessonReview.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    final rawSnapshot = data['lessonSnapshot'] ?? data['lesson'];
    final lesson = rawSnapshot is Map
        ? Map<String, dynamic>.from(rawSnapshot)
        : const <String, dynamic>{};

    String text(String key) {
      final direct = (data[key] ?? '').toString().trim();
      if (direct.isNotEmpty) return direct;
      return (lesson[key] ?? '').toString().trim();
    }

    DateTime? date(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is String) return DateTime.tryParse(value);
      return null;
    }

    String reasonText(dynamic value) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        return (map['message'] ?? map['label'] ?? map['code'] ?? '')
            .toString()
            .trim();
      }
      return value.toString().trim();
    }

    final rawReasons = data['reasons'] ?? data['reasonCodes'];
    final reasons = rawReasons is Iterable
        ? rawReasons.map(reasonText).where((x) => x.isNotEmpty).toList()
        : <String>[];

    return SuspiciousLessonReview(
      id: doc.id,
      lessonId: text('lessonId').isNotEmpty ? text('lessonId') : doc.id,
      title: text('title'),
      audioUrl: text('audioUrl'),
      categoryId: text('categoryId'),
      subcategoryId: text('subcategoryId'),
      addedBy: text('addedBy'),
      riskScore:
          (data['riskScore'] as num?)?.round() ??
          (data['score'] as num?)?.round() ??
          0,
      reasons: reasons,
      status: (data['status'] ?? 'pending').toString(),
      detectedAt: date(data['detectedAt'] ?? data['createdAt']),
    );
  }

  bool get isPending => status == 'pending' || status == 'flagged';
}

class OwnerReviewRepository {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static Stream<List<SuspiciousLessonReview>> watchPending() {
    return _db.collection('owner_lesson_reviews').snapshots().map((snapshot) {
      final list = snapshot.docs
          .map(SuspiciousLessonReview.fromDoc)
          .where((review) => review.isPending)
          .toList();
      list.sort((a, b) {
        final score = b.riskScore.compareTo(a.riskScore);
        if (score != 0) return score;
        return (b.detectedAt ?? DateTime(0)).compareTo(
          a.detectedAt ?? DateTime(0),
        );
      });
      return list;
    });
  }

  static Future<int> scanAll() async {
    final result = await _functions
        .httpsCallable('scanSuspiciousLessons')
        .call<Object?>();
    final data = result.data;
    if (data is Map) {
      return ((data['flagged'] ?? data['created'] ?? data['count']) as num?)
              ?.toInt() ??
          0;
    }
    return 0;
  }

  static Future<void> resolve(
    SuspiciousLessonReview review, {
    required String action,
  }) async {
    if (action != 'verified' && action != 'delete') {
      throw ArgumentError.value(action, 'action', 'إجراء غير معروف');
    }
    await _functions.httpsCallable('resolveSuspiciousLesson').call({
      'reviewId': review.id,
      'lessonId': review.lessonId,
      'action': action,
    });
  }
}
