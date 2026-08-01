import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme.dart';

/// شاشة رمز الاعتماد — نظير step='owner_code' في نبراس، بفارق واحد فقط:
/// نبراس يُرسل الرمز إلى بريد المالك (SMTP)؛ هنا لا بريد مُعَدّاً، فالرمز
/// يظهر حيّاً للمالك داخل تطبيقه (شاشة «الحساب والمشرفون»)، وعلى المرشّح أن
/// يطلب من المالك إبلاغه به (مكالمة/واتساب) ثم يُدخله هنا. صلاحية الرمز 10
/// دقائق، 5 محاولات، وحدّ معدّل 60 ثانية بين الطلبات — مطابق تماماً لنبراس.
class OwnerCodeScreen extends StatefulWidget {
  final VoidCallback onApproved;
  const OwnerCodeScreen({super.key, required this.onApproved});

  @override
  State<OwnerCodeScreen> createState() => _OwnerCodeScreenState();
}

class _OwnerCodeScreenState extends State<OwnerCodeScreen> {
  final _codeCtrl = TextEditingController();
  bool _busy = false;
  bool _requested = false;
  String _error = '';
  String _info = '';
  int _cooldown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _requestCode(silent: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cooldown -= 1);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _requestCode({bool silent = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
      if (!silent) _info = '';
    });
    final res = await AuthService.requestOwnerCode();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.ok) {
        _requested = true;
        _info =
            'تمّ توليد الرمز. اطلب من المالك فتح «الحساب والمشرفون» في '
            'تطبيقه ليرى الرمز ويُبلّغك به (صلاحيته 10 دقائق).';
        _startCooldown(60);
        return;
      }
      switch (res.reason) {
        case 'rate_limited':
          _requested = true;
          _startCooldown(res.retryAfterSec ?? 60);
          if (!silent) {
            _error = 'رمز سابق ما يزال صالحاً. انتظر قليلاً قبل طلب رمز جديد.';
          }
          break;
        case 'blocked':
          _error = 'تم تعليق وصولك من قبل الإدارة.';
          break;
        case 'already_authorized':
          widget.onApproved();
          break;
        default:
          if (!silent) _error = 'تعذّر توليد الرمز. حاول مرة أخرى.';
      }
    });
  }

  Future<void> _verify() async {
    final code = _codeCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'أدخل الرمز المكوّن من 6 أرقام.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final res = await AuthService.verifyOwnerCode(code);
    if (!mounted) return;
    if (res.ok) {
      widget.onApproved();
      return;
    }
    setState(() {
      _busy = false;
      switch (res.reason) {
        case 'expired':
          _error = 'انتهت صلاحية الرمز. اطلب رمزاً جديداً.';
          _requested = false;
          break;
        case 'too_many_attempts':
          _error = 'محاولات كثيرة فاشلة. اطلب رمزاً جديداً.';
          _codeCtrl.clear();
          _requested = false;
          break;
        case 'no_code':
          _error = 'لا يوجد رمز معلَّق. اطلب رمزاً جديداً.';
          _requested = false;
          break;
        default:
          _error = 'الرمز غير صحيح.';
      }
    });
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    await AuthService.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final email = AuthService.currentUser?.email ?? '';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.verified_user, size: 64, color: kTeal),
                const SizedBox(height: 12),
                const Text(
                  'رمز اعتماد المشرف',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'سجّلت الدخول بـ:\n$email',
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(color: Colors.grey, height: 1.6),
                ),
                const SizedBox(height: 18),
                if (_info.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: kBoxBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _info,
                      textAlign: TextAlign.center,
                      style: const TextStyle(height: 1.6),
                    ),
                  ),
                if (_requested) ...[
                  TextField(
                    controller: _codeCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    maxLength: 6,
                    style: const TextStyle(fontSize: 28, letterSpacing: 10),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: '••••••',
                    ),
                    onSubmitted: (_) => _busy ? null : _verify(),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _verify,
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('تحقّق'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: (_busy || _cooldown > 0)
                        ? null
                        : () => _requestCode(),
                    child: Text(
                      _cooldown > 0
                          ? 'إعادة الإرسال خلال $_cooldown ث'
                          : 'طلب رمز جديد',
                    ),
                  ),
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _requestCode(),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.lock_clock),
                      label: const Text('طلب رمز اعتماد'),
                    ),
                  ),
                ],
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error,
                    style: const TextStyle(color: kDanger),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 18),
                TextButton(
                  onPressed: _busy ? null : _cancel,
                  child: const Text('إلغاء وتسجيل الخروج'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
