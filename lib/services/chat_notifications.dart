import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// إشعارات دردشة الإدارة. يسجَّل تفضيل الكتم في رمز جهاز الإدارة نفسه،
/// فتدفع الدالة السحابية الرسالة إلى الأجهزة المعتمدة فقط وتستبعد المرسل.
/// نلغي اشتراك الموضوع القديم لأن موضوعات FCM العامة ليست قناة مناسبة
/// لمحتوى مجموعة خاصة.
class ChatNotifications {
  ChatNotifications._();

  static const String topic = 'menbar_admin_chat';
  static const String _mutePref = 'admin_chat_muted_v1';
  static bool isChatOpen = false;

  /// مزامنة الاشتراك مع تفضيل الكتم — تُستدعى بعد نجاح التحقق من الدور
  /// وعند تبديل مفتاح «إشعارات المجموعة».
  static Future<void> syncSubscription() async {
    final muted = await isMuted();
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('admin_device_tokens')
            .doc(user.uid)
            .set({'chatMuted': muted}, SetOptions(merge: true));
      }
    } catch (_) {
      // أفضل جهد — تُعاد المزامنة عند الفتح التالي.
    }
  }

  static Future<bool> isMuted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_mutePref) ?? false;
  }

  static Future<void> setMuted(bool muted) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_mutePref, muted);
    await syncSubscription();
  }

  static Future<void> unsubscribe() async {
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
    } catch (_) {}
  }
}
