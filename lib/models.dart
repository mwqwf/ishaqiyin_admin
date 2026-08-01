import 'package:cloud_firestore/cloud_firestore.dart';

/// بعض الوثائق القديمة مخزّنة ملفوفة بصيغة `{ data: {...} }`.
Map<String, dynamic> _unwrap(Map<String, dynamic> raw) {
  final inner = raw['data'];
  if (inner is Map) {
    return Map<String, dynamic>.from(inner);
  }
  return raw;
}

String _str(dynamic v) => v == null ? '' : v.toString().trim();

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// يحوّل createdAt بأي صيغة (Timestamp/ISO/رقم) إلى DateTime للترتيب.
DateTime parseDate(dynamic v) {
  if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  if (v is String) {
    return DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  if (v is Map && v['seconds'] != null) {
    return DateTime.fromMillisecondsSinceEpoch(
      (v['seconds'] as num).toInt() * 1000,
    );
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

class Category {
  final String id;
  final String name;
  final DateTime createdAt;

  Category({required this.id, required this.name, required this.createdAt});

  factory Category.fromDoc(String id, Map<String, dynamic> raw) {
    final d = _unwrap(raw);
    return Category(
      id: id,
      name: _str(d['name']),
      createdAt: parseDate(d['createdAt']),
    );
  }
}

class Subcategory {
  final String id;
  final String name;
  final String categoryId;
  final DateTime createdAt;

  Subcategory({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.createdAt,
  });

  factory Subcategory.fromDoc(String id, Map<String, dynamic> raw) {
    final d = _unwrap(raw);
    return Subcategory(
      id: id,
      name: _str(d['name']),
      categoryId: _str(d['categoryId']),
      createdAt: parseDate(d['createdAt']),
    );
  }
}

class Lesson {
  final String id;
  final String title;
  final String categoryId;
  final String subcategoryId;
  final String audioUrl;
  final String audioStoragePath;
  final DateTime createdAt;
  final dynamic rawCreatedAt; // للتشخيص (فحص التواريخ)
  final bool hasCreatedAt;
  final int views;
  final bool featured;
  final String addedBy;
  final DateTime? publishAt;

  Lesson({
    required this.id,
    required this.title,
    required this.categoryId,
    required this.subcategoryId,
    required this.audioUrl,
    required this.audioStoragePath,
    required this.createdAt,
    required this.rawCreatedAt,
    required this.hasCreatedAt,
    this.views = 0,
    this.featured = false,
    this.addedBy = '',
    this.publishAt,
  });

  static String _extractSubcategoryId(Map<String, dynamic> d) {
    if (d['subcategoryId'] != null && _str(d['subcategoryId']).isNotEmpty) {
      return _str(d['subcategoryId']);
    }
    final sub = d['subcategory'];
    if (sub is Map && sub['_id'] != null) return _str(sub['_id']);
    return '';
  }

  factory Lesson.fromDoc(String id, Map<String, dynamic> raw) {
    final d = _unwrap(raw);
    final rawCreated = d['createdAt'];
    return Lesson(
      id: id,
      title: _str(d['title']).isNotEmpty ? _str(d['title']) : _str(d['name']),
      categoryId: _str(d['categoryId']),
      subcategoryId: _extractSubcategoryId(d),
      audioUrl: _str(d['audioUrl']),
      audioStoragePath: _str(d['audioStoragePath']),
      createdAt: parseDate(rawCreated),
      rawCreatedAt: rawCreated,
      hasCreatedAt: rawCreated != null && _str(rawCreated).isNotEmpty,
      views: _int(d['views']),
      featured: d['featured'] == true,
      addedBy: _str(d['addedBy']),
      publishAt: d['publishAt'] == null ? null : parseDate(d['publishAt']),
    );
  }
}

/// مشرف لوحة التحكّم (نظير dashboard_users في نبراس) — مخزَّن في مجموعة
/// `dashboard_admins` بمعرّف وثيقة = البريد بحروف صغيرة. يُنشأ فقط عبر
/// Cloud Function (رمز الاعتماد)؛ المالك يحظر/يلغي الحظر/يحذف من التطبيق.
class DashAdmin {
  final String email; // = معرّف الوثيقة (lowercase)
  final String role; // 'supervisor' أو 'owner'
  final bool blocked;
  final String blockMode; // 'temporary' | 'permanent' | ''
  final String displayName;
  final String photoURL;
  final String addedBy;
  final DateTime addedAt;
  final DateTime? lastSignedInAt;

  DashAdmin({
    required this.email,
    required this.role,
    required this.blocked,
    required this.blockMode,
    required this.displayName,
    required this.photoURL,
    required this.addedBy,
    required this.addedAt,
    required this.lastSignedInAt,
  });

  bool get isOwner => role == 'owner';

  factory DashAdmin.fromDoc(String id, Map<String, dynamic> raw) {
    final d = _unwrap(raw);
    final lastSignIn = d['lastSignedInAt'];
    return DashAdmin(
      email: _str(d['email']).isNotEmpty ? _str(d['email']) : id,
      role: _str(d['role']).isNotEmpty ? _str(d['role']) : 'supervisor',
      blocked: d['blocked'] == true,
      blockMode: _str(d['blockMode']),
      displayName: _str(d['displayName']),
      photoURL: _str(d['photoURL']),
      addedBy: _str(d['addedBy']),
      addedAt: parseDate(d['addedAt']),
      lastSignedInAt: lastSignIn == null ? null : parseDate(lastSignIn),
    );
  }
}

/// رمز اعتماد مشرف معلَّق (نظير owner_codes في نبراس) — يقرؤه المالك فقط
/// ليُبلّغ به المرشّح يدوياً، إذ لا يوجد بريد مُعَدّ لإرساله تلقائياً.
class PendingOwnerCode {
  final String code;
  final String candidateEmail;
  final String candidateName;
  final String candidatePhotoURL;
  final DateTime expiresAt;

  PendingOwnerCode({
    required this.code,
    required this.candidateEmail,
    required this.candidateName,
    required this.candidatePhotoURL,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  factory PendingOwnerCode.fromDoc(Map<String, dynamic> raw) {
    final d = _unwrap(raw);
    return PendingOwnerCode(
      code: _str(d['code']),
      candidateEmail: _str(d['candidateEmail']),
      candidateName: _str(d['candidateName']),
      candidatePhotoURL: _str(d['candidatePhotoURL']),
      expiresAt: parseDate(d['expiresAt']),
    );
  }
}
