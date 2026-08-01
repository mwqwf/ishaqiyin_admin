import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme.dart';

/// شاشة الدخول — مطابقة لنمط نبراس: ترحيب ثم Google فقط (لا بريد/كلمة مرور).
/// بعد نجاح الدخول، AuthGate في main.dart يحدّد الوجهة (لوحة/رمز اعتماد/محظور).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _loading = false;
  String _error = '';

  Future<void> _google() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final err = await AuthService.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (err != null) _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.admin_panel_settings, size: 72, color: kTeal),
                const SizedBox(height: 12),
                const Text(
                  'لوحة إدارة منبر ادكصهك',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: kTeal,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'سجّل الدخول بحساب Google. المالك يدخل مباشرة، '
                  'وأي حساب جديد يحتاج رمز اعتماد من المالك.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _google,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.login),
                    label: Text(
                      _loading ? 'جارٍ الدخول...' : 'تسجيل الدخول بـ Google',
                    ),
                  ),
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error,
                    style: const TextStyle(color: kDanger),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
