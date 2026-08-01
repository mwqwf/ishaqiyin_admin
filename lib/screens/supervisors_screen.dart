import 'package:flutter/material.dart';
import '../models.dart';
import '../services/admin_repository.dart';
import '../services/chat_repository.dart';
import '../services/auth_service.dart';
import '../theme.dart';

/// إدارة المشرفين (المالك فقط) — مطابقة لصفحة /admin/users/supervisors في
/// نبراس: قائمة بكل الحسابات المصرَّح لها (المالك + المشرفون)، مع حظر
/// مؤقّت/نهائي/إلغاء حظر/حذف. لا توجد إضافة يدوية بكتابة بريد — المشرف
/// الجديد يُعتمَد فقط عبر رمز الاعتماد (انظر AdminsScreen لعرضه).
/// لا يمكن التعديل على المالك ولا على حسابك أنت (نفس قيود نبراس).
class SupervisorsScreen extends StatefulWidget {
  const SupervisorsScreen({super.key});

  @override
  State<SupervisorsScreen> createState() => _SupervisorsScreenState();
}

class _SupervisorsScreenState extends State<SupervisorsScreen> {
  List<DashAdmin> _admins = [];
  bool _loading = true;
  String? _error;
  String? _busyEmail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await AdminRepository.fetchDashAdmins();
      if (mounted) {
        setState(() {
          _admins = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذّر جلب المشرفين: $e';
        });
      }
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  bool _canActOn(DashAdmin a) {
    if (a.isOwner) return false;
    if (a.email == (AuthService.currentUser?.email ?? '').toLowerCase()) {
      return false;
    }
    return true;
  }

  Future<void> _confirm({
    required String title,
    required String body,
    required Color color,
    required String confirmLabel,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (ok != true) throw _Cancelled();
  }

  Future<void> _block(DashAdmin a, String mode) async {
    try {
      await _confirm(
        title: mode == 'permanent' ? 'حظر نهائي' : 'حظر مؤقّت',
        body: mode == 'permanent'
            ? 'سيتم حظر "${a.email}" بشكل نهائي. يمكنك إلغاء الحظر لاحقاً إن رغبت.'
            : 'سيتم تعليق وصول "${a.email}" فوراً. يمكنك إلغاء الحظر لاحقاً.',
        color: kDanger,
        confirmLabel: 'تأكيد',
      );
    } on _Cancelled {
      return;
    }
    setState(() => _busyEmail = a.email);
    try {
      await AdminRepository.setDashAdminBlocked(a.email, true, mode: mode);
      await ChatRepository.instance.removeMemberByEmail(a.email);
    } catch (e) {
      _snack('تعذّر التعديل: $e');
    }
    setState(() => _busyEmail = null);
    _load();
  }

  Future<void> _unblock(DashAdmin a) async {
    setState(() => _busyEmail = a.email);
    try {
      await AdminRepository.setDashAdminBlocked(a.email, false);
    } catch (e) {
      _snack('تعذّر التعديل: $e');
    }
    setState(() => _busyEmail = null);
    _load();
  }

  Future<void> _remove(DashAdmin a) async {
    try {
      await _confirm(
        title: 'حذف نهائي',
        body:
            'سيتم حذف "${a.email}" من قائمة المشرفين نهائيّاً. '
            'لا يمكن التراجع إلّا بإعادة اعتماده عبر رمز جديد.',
        color: kDanger,
        confirmLabel: 'حذف',
      );
    } on _Cancelled {
      return;
    }
    setState(() => _busyEmail = a.email);
    try {
      await AdminRepository.removeDashAdmin(a.email);
      await ChatRepository.instance.removeMemberByEmail(a.email);
    } catch (e) {
      _snack('تعذّر الحذف: $e');
    }
    setState(() => _busyEmail = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة المشرفين'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kDanger),
                ),
              ),
            )
          : _admins.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'لا يوجد مشرفون بعد.\n'
                  'يُعتمَد المشرف عبر رمز اعتماد (انظر «الحساب والمشرفون»).',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _admins.length,
              itemBuilder: (context, i) {
                final a = _admins[i];
                final locked = !_canActOn(a);
                final busy = _busyEmail == a.email;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: a.blocked ? kDanger : kTeal,
                              backgroundImage: a.photoURL.isNotEmpty
                                  ? NetworkImage(a.photoURL)
                                  : null,
                              child: a.photoURL.isEmpty
                                  ? Icon(
                                      a.blocked ? Icons.block : Icons.person,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.displayName.isNotEmpty
                                        ? a.displayName
                                        : a.email,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    a.email,
                                    textDirection: TextDirection.ltr,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (a.isOwner)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  'المالك',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.amber,
                                  ),
                                ),
                              )
                            else
                              Text(
                                a.blocked
                                    ? 'محظور${a.blockMode == 'permanent' ? ' (نهائي)' : ''}'
                                    : 'نشِط',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: a.blocked ? kDanger : Colors.green,
                                ),
                              ),
                          ],
                        ),
                        if (!locked) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (a.blocked)
                                OutlinedButton(
                                  onPressed: busy ? null : () => _unblock(a),
                                  child: const Text('إلغاء الحظر'),
                                )
                              else ...[
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : () => _block(a, 'temporary'),
                                  child: const Text('حظر مؤقّت'),
                                ),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: kDanger,
                                  ),
                                  onPressed: busy
                                      ? null
                                      : () => _block(a, 'permanent'),
                                  child: const Text('حظر نهائي'),
                                ),
                              ],
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: kDanger,
                                ),
                                onPressed: busy ? null : () => _remove(a),
                                icon: busy
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                      ),
                                label: const Text('حذف'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _Cancelled implements Exception {}
