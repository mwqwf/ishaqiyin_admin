/// إعدادات لوحة إدارة الإسحاقيين.
/// كل القيم قابلة للتجاوز وقت البناء عبر --dart-define.
class AppConfig {
  AppConfig._();

  /// بريد المالك المخوّل بالكتابة — نفس البريد المستعمل في لوحة نبراس.
  /// يجب أن يطابق القيمة في قواعد Firestore/Storage.
  static const String ownerEmail = String.fromEnvironment(
    'ADMIN_OWNER_EMAIL',
    defaultValue: 'bdalmjydtbwn812@gmail.com',
  );

  /// Web OAuth client (نوع 3) لمشروع mxqp-8d1e8 — مطلوب ليُصدِر google_sign_in
  /// على Android رمز ID صالحاً لـ Firebase Auth (الدخول بـ Google هو الطريقة
  /// الوحيدة، نظير نبراس). مرّره عبر:
  ///   --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxxx.apps.googleusercontent.com
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    // Web client (نوع 3) المُولَّد تلقائياً عند تفعيل Google في mxqp-8d1e8.
    defaultValue:
        '502388954405-gak0aso996p37run9ohovjbinv31r3vk.apps.googleusercontent.com',
  );

  static bool get googleSignInConfigured => googleServerClientId.isNotEmpty;
}
