import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import '../core/config.dart';
import '../models.dart';
import '../services/admin_repository.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import 'supervisors_screen.dart';

/// شاشة الحساب والصلاحية (مطابقة لنمط لوحة نبراس: مالك / مشرف).
/// المالك فقط يرى بطاقة الرمز المعلَّق الحيّة ويفتح «إدارة المشرفين».
/// الكتابة مفروضة في قواعد Firestore على الخادم.
class AdminsScreen extends StatelessWidget {
  final bool isOwner;
  const AdminsScreen({super.key, required this.isOwner});

  @override
  Widget build(BuildContext context) {
    final email = AuthService.currentUser?.email ?? '—';
    return Scaffold(
      appBar: AppBar(title: const Text('الحساب والصلاحية')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: kTeal,
                child: Icon(
                  isOwner ? Icons.verified_user : Icons.person,
                  color: Colors.white,
                ),
              ),
              title: Text(email, textDirection: TextDirection.ltr),
              subtitle: Text(
                isOwner
                    ? 'المالك — صلاحية كاملة'
                    : 'مشرف — صلاحية إدارة المحتوى',
              ),
            ),
          ),
          if (isOwner) ...[
            const SizedBox(height: 12),
            const _PendingOwnerCodeCard(),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: kTeal,
                  child: Icon(Icons.supervisor_account, color: Colors.white),
                ),
                title: const Text('إدارة المشرفين'),
                subtitle: const Text('حظر مؤقّت/نهائي/إلغاء حظر/حذف'),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SupervisorsScreen()),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kBoxBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              isOwner
                  ? 'أنت المالك (${AppConfig.ownerEmail}). أي حساب Google جديد '
                        'يسجّل الدخول ويطلب رمز اعتماد — يظهر لك حيّاً أعلاه '
                        'فتُبلّغ به صاحبه (مكالمة/واتساب)، فيُدخله ويصبح مشرفاً '
                        'تلقائياً. لا حاجة لإضافة بريده يدوياً.'
                  : 'صلاحياتك كمشرف تشمل إضافة وتعديل وحذف المحتوى. '
                        'إدارة المشرفين متاحة للمالك فقط.',
              style: const TextStyle(height: 1.6, fontSize: 14),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => AuthService.signOut(),
            icon: const Icon(Icons.logout, color: kDanger),
            label: const Text('تسجيل الخروج', style: TextStyle(color: kDanger)),
          ),
        ],
      ),
    );
  }
}

/// بطاقة حيّة (StreamBuilder) تعرض للمالك رمز الاعتماد المعلَّق الحالي،
/// إن وُجد — بديل بريد نبراس الإلكتروني لتوصيل الرمز.
class _PendingOwnerCodeCard extends StatefulWidget {
  const _PendingOwnerCodeCard();

  @override
  State<_PendingOwnerCodeCard> createState() => _PendingOwnerCodeCardState();
}

class _PendingOwnerCodeCardState extends State<_PendingOwnerCodeCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _cancel(BuildContext context, PendingOwnerCode code) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء الرمز'),
        content: Text(
          'سيُبطَل رمز «${code.candidateEmail}» نهائياً ولن يقبله الخادم. متابعة؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إلغاء الرمز'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AdminRepository.cancelOwnerCode(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PendingOwnerCode>>(
      stream: AdminRepository.watchPendingOwnerCodes(),
      builder: (context, snap) {
        final codes = snap.data ?? const <PendingOwnerCode>[];
        if (codes.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final pending in codes) _codeCard(context, pending),
          ],
        );
      },
    );
  }

  Widget _codeCard(BuildContext context, PendingOwnerCode pending) {
    final remaining = pending.expiresAt.difference(DateTime.now());
        final minutes = remaining.inMinutes.clamp(0, 99);
        final seconds = (remaining.inSeconds % 60).clamp(0, 59);
        return Card(
          color: kTeal.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: kTeal.withValues(alpha: 0.3)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock_clock, color: kTeal),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'طلب انضمام مشرف معلَّق',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      '$minutes:${seconds.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        color: kTeal,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  pending.candidateName.isNotEmpty
                      ? '${pending.candidateName} — ${pending.candidateEmail}'
                      : pending.candidateEmail,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    pending.code,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 10,
                      color: kTeal,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'بلّغ المرشّح بهذا الرمز (مكالمة/واتساب) ليُدخله في تطبيقه '
                  'ويُعتمَد مشرفاً فوراً.',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: pending.code));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تم نسخ الرمز.')),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('نسخ'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: kDanger),
                      onPressed: () => _cancel(context, pending),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('إلغاء'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
  }
}
