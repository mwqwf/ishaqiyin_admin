import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../screens/chat/dm_screen.dart';
import 'chat_notifications.dart';

/// يسجّل جهاز المالك/المشرف في مجموعة خاصة ويعرض رسائل FCM الواردة أثناء
/// فتح التطبيق. لا يُستدعى التسجيل إلا بعد نجاح التحقق من الدور والحظر.
class AdminNotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  static StreamSubscription<RemoteMessage>? _foregroundSub;
  static StreamSubscription<String>? _tokenSub;
  static bool _isOwner = false;

  static Future<void> registerCurrentDevice({required bool isOwner}) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final email = (user?.email ?? '').trim().toLowerCase();
      if (user == null || email.isEmpty) return;

      _isOwner = isOwner;
      await _ensureInitialized();
      await _messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _saveToken(user, email, token, isOwner);
      }
      await ChatNotifications.syncSubscription();

      await _tokenSub?.cancel();
      _tokenSub = _messaging.onTokenRefresh.listen((newToken) {
        final current = FirebaseAuth.instance.currentUser;
        final currentEmail = (current?.email ?? '').trim().toLowerCase();
        if (current != null && currentEmail.isNotEmpty) {
          unawaited(
            _saveToken(current, currentEmail, newToken, _isOwner).catchError(
              (Object error) => debugPrint('FCM token refresh failed: $error'),
            ),
          );
        }
      });
    } catch (e) {
      // لا نعطّل لوحة الإدارة إن رفض النظام إذن الإشعارات أو انقطعت الشبكة.
      debugPrint('Admin notifications registration failed: $e');
    }
  }

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(const InitializationSettings(android: android));
    final androidImpl = _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImpl?.requestNotificationsPermission();
    // القناة التي تستهدفها رسائل الخادم (pushToAdmins: channelId=admin_alerts)
    // يجب أن تكون منشأة مسبقاً وإلا سقطت رسائل الخلفية على قناة افتراضية صماء.
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        'admin_alerts',
        'تنبيهات الإدارة',
        description: 'مساهمات المستمعين ورموز الاعتماد ورسائل مجموعة الإدارة',
        importance: Importance.max,
      ),
    );

    _foregroundSub = FirebaseMessaging.onMessage.listen(_showForeground);
    _initialized = true;
  }

  static Future<void> _saveToken(
    User user,
    String email,
    String token,
    bool isOwner,
  ) async {
    final chatMuted = await ChatNotifications.isMuted();
    await _db.collection('admin_device_tokens').doc(user.uid).set({
      'uid': user.uid,
      'email': email,
      'role': isOwner ? 'owner' : 'supervisor',
      'token': token,
      'platform': kIsWeb ? 'web' : Platform.operatingSystem,
      'chatMuted': chatMuted,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> _showForeground(RemoteMessage message) async {
    final type = message.data['type']?.toString() ?? '';
    if (type == 'admin_chat' &&
        (ChatNotifications.isChatOpen || await ChatNotifications.isMuted())) {
      return;
    }
    // رسالة خاصّة: لا تُزعج إن كانت محادثتها نفسها مفتوحة أمام المستخدم.
    if (type == 'admin_dm') {
      final threadId = message.data['threadId']?.toString() ?? '';
      if (threadId.isNotEmpty && DmScreen.openThreadId == threadId) return;
      if (await ChatNotifications.isMuted()) return;
    }
    final title =
        message.notification?.title ??
        message.data['title']?.toString() ??
        'تنبيه الإدارة';
    final body =
        message.notification?.body ?? message.data['body']?.toString() ?? '';
    if (body.isEmpty && title.isEmpty) return;
    await _local.show(
      message.messageId?.hashCode ??
          DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'admin_urgent_alerts',
          'تنبيهات الإدارة العاجلة',
          channelDescription:
              'طلبات النشر والدروس المشبوهة والتنبيهات الإدارية',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );
  }

  static Future<void> unregisterCurrentDevice() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await _db.collection('admin_device_tokens').doc(user.uid).delete();
      } catch (_) {
        // تسجيل الخروج يجب ألا يُحتجز بسبب تعذّر تنظيف الرمز.
      }
    }
    await _tokenSub?.cancel();
    _tokenSub = null;
    await ChatNotifications.unsubscribe();
  }

  static Future<void> dispose() async {
    await _foregroundSub?.cancel();
    await _tokenSub?.cancel();
  }
}
