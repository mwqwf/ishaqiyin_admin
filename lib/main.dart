import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

import 'firebase_options.dart';
import 'services/auth_service.dart';
import 'services/admin_notification_service.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/owner_code_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Object? initializationError;
  try {
    await _initializeFirebase();
  } catch (e) {
    initializationError = e;
    debugPrint('Firebase init error: $e');
  }
  runApp(AdminApp(initializationError: initializationError));
}

Future<void> _initializeFirebase() async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kDebugMode
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
    );
  } catch (e) {
    // الخادم في وضع مراقبة (غير مُنفِذ بعد) — فشل تفعيل App Check لا يبرر
    // حجب اللوحة كلها خلف شاشة خطأ توحي بالانهيار.
    debugPrint('App Check activate failed (non-fatal): $e');
  }
}

class AdminApp extends StatefulWidget {
  final Object? initializationError;

  const AdminApp({super.key, this.initializationError});

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  Object? _initializationError;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _initializationError = widget.initializationError;
  }

  Future<void> _retryFirebase() async {
    setState(() => _retrying = true);
    try {
      await _initializeFirebase();
      if (mounted) setState(() => _initializationError = null);
    } catch (e) {
      if (mounted) setState(() => _initializationError = e);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إدارة منبر ادكصهك',
      debugShowCheckedModeBanner: false,
      theme: buildAdminTheme(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: _initializationError == null
          ? const _AuthGate()
          : _FirebaseInitErrorView(
              retrying: _retrying,
              onRetry: _retryFirebase,
            ),
    );
  }
}

/// يوجّه حسب الصلاحية: دخول / لوحة (مالك أو مشرف) / قيد اعتماد / محظور.
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> with WidgetsBindingObserver {
  StreamSubscription<User?>? _sub;
  AccessState _state = AccessState.signedOut;
  bool _loading = true;
  String? _error;
  int _resolveSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = AuthService.authState.listen((_) => _resolve());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // إقلاع خلف قفل الشاشة يخنق الشبكة فيفشل التحقق مؤقتاً؛ عند عودة
    // التطبيق للمقدمة أعد المحاولة تلقائياً بدل ترك شاشة الخطأ مسدودة.
    if (state == AppLifecycleState.resumed && _error != null && !_loading) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final seq = ++_resolveSeq;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    // ثلاث محاولات بمهلة متصاعدة قبل إظهار شاشة الخطأ — الفشل الشائع
    // عابر (شبكة/إقلاع)، وشاشة الخطأ توحي للمستخدم بانهيار التطبيق.
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(seconds: attempt * 2));
        if (!mounted || seq != _resolveSeq) return;
      }
      try {
        final s = await AuthService.resolveAccess();
        if (!mounted || seq != _resolveSeq) return;
        setState(() {
          _state = s;
          _loading = false;
        });
        if (s == AccessState.owner || s == AccessState.supervisor) {
          unawaited(
            AdminNotificationService.registerCurrentDevice(
              isOwner: s == AccessState.owner,
            ),
          );
        }
        return;
      } catch (e) {
        lastError = e;
      }
    }
    if (!mounted || seq != _resolveSeq) return;
    setState(() {
      _loading = false;
      _error = lastError is AccessVerificationException
          ? lastError.message
          : 'تعذّر التحقق من الصلاحية. تحقق من الاتصال ثم أعد المحاولة.';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return _AccessErrorView(message: _error!, onRetry: _resolve);
    }
    switch (_state) {
      case AccessState.owner:
        return const DashboardScreen(isOwner: true);
      case AccessState.supervisor:
        return const DashboardScreen(isOwner: false);
      case AccessState.needsOwnerCode:
        return OwnerCodeScreen(onApproved: _resolve);
      case AccessState.blocked:
        return const _BlockedView();
      case AccessState.signedOut:
        return const LoginScreen();
    }
  }
}

class _FirebaseInitErrorView extends StatelessWidget {
  final bool retrying;
  final Future<void> Function() onRetry;

  const _FirebaseInitErrorView({required this.retrying, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: kDanger),
              const SizedBox(height: 16),
              const Text(
                'تعذّر الاتصال بخدمات التطبيق',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                'لم تكتمل تهيئة Firebase أو App Check. لن نعرض شاشة دخول مضلّلة؛ أعد المحاولة بعد التحقق من الإنترنت.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: retrying ? null : onRetry,
                icon: retrying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccessErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _AccessErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.security_update_warning,
                size: 56,
                color: kDanger,
              ),
              const SizedBox(height: 16),
              const Text(
                'تعذّر التحقق من صلاحية الحساب',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
              TextButton(
                onPressed: AuthService.signOut,
                child: const Text('تسجيل الخروج'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlockedView extends StatelessWidget {
  const _BlockedView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.block, size: 56, color: kDanger),
              const SizedBox(height: 16),
              const Text(
                'تم تعليق وصولك',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: kDanger,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'تواصل مع المالك لإعادة التفعيل.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 22),
              TextButton(
                onPressed: AuthService.signOut,
                child: const Text('تسجيل الخروج'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
