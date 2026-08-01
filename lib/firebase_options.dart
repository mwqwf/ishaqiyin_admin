import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// إعداد Firebase للوحة إدارة الإسحاقيين.
/// نفس مشروع التطبيق (mxqp-8d1e8) — لإدارة نفس المحتوى مباشرةً.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('غير مهيّأ للويب.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return android;
      default:
        return android;
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCWAHqbzhfQ-ZcjSSVCAhFFqCTgQ66SdCs',
    // appId الخاص بحزمة com.ali.ishaqiyin_admin (مُسجَّلة في mxqp-8d1e8).
    appId: '1:502388954405:android:21ab2f65113166c689b6cc',
    messagingSenderId: '502388954405',
    projectId: 'mxqp-8d1e8',
    storageBucket: 'mxqp-8d1e8.firebasestorage.app',
  );
}
