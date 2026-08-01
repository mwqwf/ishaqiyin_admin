import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme.dart';

/// تنبيه إداري واحد كما يُعرض في «تنبيهاتك».
class AdminAlert {
  final String id;
  final String email; // '' = عامّ لكل المشرفين.
  final String
  excludeEmail; // يُخفى عن هذا البريد (منعاً للتكرار مع تنبيهه الشخصي).
  final String title;
  final String body;
  final String type; // submission | milestone | owner_code | digest | ...
  final String refId;
  final int createdAtMs;
  final List<String> readBy;

  const AdminAlert({
    required this.id,
    required this.email,
    required this.excludeEmail,
    required this.title,
    required this.body,
    required this.type,
    required this.refId,
    required this.createdAtMs,
    required this.readBy,
  });

  factory AdminAlert.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? const {};
    final metadata = d['data'] is Map
        ? Map<String, dynamic>.from(d['data'] as Map)
        : const <String, dynamic>{};
    String s(dynamic v) => (v ?? '').toString();
    return AdminAlert(
      id: doc.id,
      email: s(d['email']).toLowerCase(),
      excludeEmail: s(d['excludeEmail'] ?? metadata['excludeEmail']).toLowerCase(),
      title: s(d['title']),
      body: s(d['body']),
      type: s(d['type'] ?? metadata['type']),
      refId: s(
        d['refId'] ??
            metadata['refId'] ??
            metadata['submissionId'] ??
            metadata['lessonId'] ??
            metadata['candidateEmail'],
      ),
      createdAtMs: (d['createdAtMs'] is num)
          ? (d['createdAtMs'] as num).toInt()
          : 0,
      readBy: (d['readBy'] is List)
          ? (d['readBy'] as List).map((e) => '$e'.toLowerCase()).toList()
          : const [],
    );
  }

  bool isReadBy(String email) => readBy.contains(email.toLowerCase());
}

/// مصدر تنبيهات الإدارة الحيّ + عمليّات القراءة/الحذف.
class AdminAlertsFeed {
  AdminAlertsFeed._();

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static String get myEmail =>
      (AuthService.currentUser?.email ?? '').trim().toLowerCase();

  /// بثّ التنبيهات المرئيّة لي: المالك يرى الكلّ، والمشرف تنبيهاته والعامّة
  /// (مع استبعاد excludeEmail الموجَّه لغيره).
  static Stream<List<AdminAlert>> stream({required bool isOwner}) {
    final e = myEmail;
    List<AdminAlert> visible(Iterable<DocumentSnapshot> docs) {
      final list = docs.map(AdminAlert.fromDoc).where((a) {
        if (a.excludeEmail == e) return false;
        if (!isOwner && a.email.isNotEmpty && a.email != e) return false;
        return true;
      }).toList();
      list.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
      return list;
    }

    if (isOwner) {
      return _db
          .collection('admin_alerts')
          .snapshots()
          .map((snap) => visible(snap.docs));
    }
    if (e.isEmpty) return Stream.value(const <AdminAlert>[]);

    late StreamController<List<AdminAlert>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? personalSub;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? generalSub;
    var personal = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    var general = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    void emit() {
      if (controller.isClosed) return;
      final merged = <String, DocumentSnapshot>{};
      for (final doc in [...personal, ...general]) {
        merged[doc.id] = doc;
      }
      controller.add(visible(merged.values));
    }

    controller = StreamController<List<AdminAlert>>(
      onListen: () {
        personalSub = _db
            .collection('admin_alerts')
            .where('email', isEqualTo: e)
            .snapshots()
            .listen((snap) {
          personal = snap.docs;
          emit();
        }, onError: controller.addError);
        generalSub = _db
            .collection('admin_alerts')
            .where('email', isEqualTo: '')
            .snapshots()
            .listen((snap) {
          general = snap.docs;
          emit();
        }, onError: controller.addError);
      },
      onCancel: () async {
        await personalSub?.cancel();
        await generalSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// عدد غير المقروء (لشارة بطاقة اللوحة).
  static Stream<int> unreadCount({required bool isOwner}) => stream(
    isOwner: isOwner,
  ).map((list) => list.where((a) => !a.isReadBy(myEmail)).length);

  /// تمييز تنبيه مقروءاً (إضافة بريدي إلى readBy — تسمح به القواعد).
  static Future<void> markRead(AdminAlert a) async {
    final e = myEmail;
    if (e.isEmpty || a.isReadBy(e)) return;
    try {
      await _db.collection('admin_alerts').doc(a.id).update({
        'readBy': FieldValue.arrayUnion([e]),
      });
    } catch (_) {
      // أفضل جهد — يبقى غير مقروء حتى المحاولة التالية.
    }
  }

  /// تمييز كلّ الظاهر مقروءاً.
  static Future<void> markAllRead(List<AdminAlert> alerts) async {
    final e = myEmail;
    if (e.isEmpty) return;
    final batch = _db.batch();
    var n = 0;
    for (final a in alerts.where((a) => !a.isReadBy(e))) {
      batch.update(_db.collection('admin_alerts').doc(a.id), {
        'readBy': FieldValue.arrayUnion([e]),
      });
      n++;
      if (n >= 400) break; // حدّ دفعة Firestore.
    }
    if (n > 0) {
      try {
        await batch.commit();
      } catch (_) {}
    }
  }

  /// حذف تنبيه — القواعد تسمح للمالك بحذف أيّ تنبيه، وللمشرف بحذف
  /// تنبيهه الشخصي فقط.
  static Future<void> delete(AdminAlert a) =>
      _db.collection('admin_alerts').doc(a.id).delete();

  static bool canDelete(AdminAlert a, {required bool isOwner}) =>
      isOwner || (a.email.isNotEmpty && a.email == myEmail);
}

/// شاشة «تنبيهاتك» الكاملة: قائمة حيّة، غير المقروء بارز، تمييز بالقراءة
/// عند الفتح، وحذف بالسحب (حسب الصلاحيّة).
class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key, required this.isOwner});

  final bool isOwner;

  IconData _icon(String type) => switch (type) {
    'submission' => Icons.how_to_vote,
    'milestone' => Icons.emoji_events,
    'owner_code' => Icons.verified_user,
    'digest' || 'weekly_digest' => Icons.insights,
    'engagement' => Icons.trending_up,
    'suspicious_lesson' => Icons.gpp_maybe,
    _ => Icons.campaign,
  };

  String _ago(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (d.inMinutes < 1) return 'الآن';
    if (d.inMinutes < 60) return 'قبل ${d.inMinutes} د';
    if (d.inHours < 24) return 'قبل ${d.inHours} س';
    return 'قبل ${d.inDays} ي';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تنبيهاتك'),
        actions: [
          StreamBuilder<List<AdminAlert>>(
            stream: AdminAlertsFeed.stream(isOwner: isOwner),
            builder: (ctx, snap) {
              final alerts = snap.data ?? const <AdminAlert>[];
              final hasUnread = alerts.any(
                (a) => !a.isReadBy(AdminAlertsFeed.myEmail),
              );
              if (!hasUnread) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'تمييز الكل مقروءاً',
                icon: const Icon(Icons.done_all),
                onPressed: () => AdminAlertsFeed.markAllRead(alerts),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<List<AdminAlert>>(
        stream: AdminAlertsFeed.stream(isOwner: isOwner),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'تعذّر تحميل التنبيهات.\n${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kDanger, fontSize: 12),
                ),
              ),
            );
          }
          final alerts = snap.data ?? const <AdminAlert>[];
          if (alerts.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'لا تنبيهات — كلّ شيء تحت السيطرة ✅',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ),
            );
          }
          final me = AdminAlertsFeed.myEmail;
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: alerts.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final a = alerts[i];
              final unread = !a.isReadBy(me);
              final deletable = AdminAlertsFeed.canDelete(a, isOwner: isOwner);
              final tile = ListTile(
                onTap: () => AdminAlertsFeed.markRead(a),
                leading: CircleAvatar(
                  backgroundColor: unread
                      ? kTeal
                      : kTeal.withValues(alpha: 0.35),
                  child: Icon(_icon(a.type), color: Colors.white, size: 20),
                ),
                title: Text(
                  a.title.isEmpty ? 'تنبيه' : a.title,
                  style: TextStyle(
                    fontWeight: unread ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
                subtitle: a.body.isEmpty
                    ? null
                    : Text(a.body, style: const TextStyle(height: 1.4)),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _ago(a.createdAtMs),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    if (unread)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: kOrange,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              );
              if (!deletable) return tile;
              return Dismissible(
                key: ValueKey(a.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: kDanger,
                  alignment: AlignmentDirectional.centerStart,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) => AdminAlertsFeed.delete(a),
                child: tile,
              );
            },
          );
        },
      ),
    );
  }
}
