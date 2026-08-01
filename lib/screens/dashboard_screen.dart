import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/admin_repository.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import 'manage_sections_screen.dart';
import 'add_lesson_screen.dart';
import 'admins_screen.dart';
import 'analytics_screen.dart';
import 'feedback_screen.dart';
import 'manage_all_screen.dart';
import 'notify_screen.dart';
import 'submissions_screen.dart';
import 'owner_review_screen.dart';
import 'alerts_screen.dart';
import 'chat/chat_screen.dart';
import 'chat/dm_list_screen.dart';
import 'chat/profile_dialog.dart';
import '../services/dm_repository.dart';
import '../services/share_intake_service.dart';
import '../services/submissions_repository.dart';
import '../services/owner_review_repository.dart';
import '../services/chat_notifications.dart';
import '../services/chat_repository.dart';

class DashboardScreen extends StatefulWidget {
  final bool isOwner;
  const DashboardScreen({super.key, required this.isOwner});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Category> categories = [];
  List<Subcategory> subcategories = [];
  List<Lesson> lessons = [];
  List<Map<String, dynamic>> alerts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_joinChatAndMaybeAskProfile());
    unawaited(ChatNotifications.syncSubscription());
    // 📤 «المشاركة إلى إدارة منبر»: ملفات صوتية تصل من تطبيقات أخرى —
    // نفتح نموذج «إضافة درس» معبّأً بكل ملف على التوالي.
    ShareIntakeService.init(_handleSharedFiles);
  }

  /// انضمام تلقائي للمجموعة، ثم حوار «اسمك وصورتك» مرة واحدة أول دخول
  /// (نمط نبراس) — لا يُلحّ إن تعذّر الجلب أو سبق ضبط الملف الشخصي.
  Future<void> _joinChatAndMaybeAskProfile() async {
    await ChatRepository.instance.upsertSelf(
      role: widget.isOwner ? 'owner' : 'supervisor',
    );
    final me = await ChatRepository.instance.fetchSelf();
    if (!mounted || me == null || me.profileSet) return;
    await showProfileDialog(context, firstRun: true);
  }

  Future<void> _handleSharedFiles(List<String> paths) async {
    // تأكد من جاهزية الأقسام قبل فتح النموذج (قد تصل المشاركة قبل _load).
    if (categories.isEmpty || subcategories.isEmpty) {
      try {
        categories = await AdminRepository.fetchCategories();
        subcategories = await AdminRepository.fetchSubcategories();
      } catch (_) {}
    }
    for (var index = 0; index < paths.length; index++) {
      final p = paths[index];
      if (!mounted) {
        ShareIntakeService.release(paths.skip(index).toList());
        return;
      }
      try {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddLessonScreen(
              categories: categories,
              subcategories: subcategories,
              initialFilePath: p,
              initialFileName: p
                  .split(RegExp(r'[/\\]'))
                  .last
                  .replaceFirst(RegExp(r'^\d+_'), ''),
            ),
          ),
        );
      } finally {
        // النموذج انتهى؛ احذف نسخة shared_intake سواء رُفعت أو أُلغي العمل.
        await ShareIntakeService.acknowledge([p]);
      }
    }
    if (mounted) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AdminRepository.cleanupResolvedAdminAlerts();
      final email = AuthService.currentUser?.email ?? '';
      final results = await Future.wait([
        AdminRepository.fetchCategories(),
        AdminRepository.fetchSubcategories(),
        AdminRepository.fetchLessons(),
        AdminRepository.fetchAdminAlerts(email, widget.isOwner),
      ]);
      if (!mounted) return;
      setState(() {
        categories = results[0] as List<Category>;
        subcategories = results[1] as List<Subcategory>;
        lessons = results[2] as List<Lesson>;
        alerts = results[3] as List<Map<String, dynamic>>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذّر جلب البيانات. تحقّق من الاتصال بالإنترنت.';
      });
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _load(); // حدّث الأرقام بعد الرجوع
  }

  Future<void> _logout() async {
    // بوّابة المصادقة في main تتكفّل بالعودة لشاشة الدخول تلقائياً.
    await AuthService.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('لوحة الإدارة'),
        actions: [
          StreamBuilder<int>(
            stream: AdminAlertsFeed.unreadCount(isOwner: widget.isOwner),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              final button = IconButton(
                tooltip: 'تنبيهاتك',
                icon: const Icon(Icons.notifications_active_outlined),
                onPressed: () => _open(
                  AlertsScreen(isOwner: widget.isOwner),
                ),
              );
              return count > 0 ? Badge.count(count: count, child: button) : button;
            },
          ),
          IconButton(
            tooltip: 'إرسال إشعار',
            icon: const Icon(Icons.campaign_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotifyScreen()),
            ),
          ),
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            tooltip: 'تسجيل الخروج',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Card(
                color: kDanger.withValues(alpha: 0.1),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: kDanger),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            if (alerts.isNotEmpty) ...[
              _alertsCard(),
              const SizedBox(height: 12),
            ],
            _statsGrid(),
            const SizedBox(height: 24),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'الإجراءات',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: kTealDark,
                ),
              ),
            ),
            _actionsGrid(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// شبكة الإجراءات: بطاقتان في الصف، مساحات مريحة، أيقونة ملوّنة داخل
  /// حاوية ناعمة، وشارة عدّ حيّة عند وجود معلّقات.
  Widget _actionsGrid() {
    final cards = <Widget>[
      StreamBuilder<int>(
        stream: ChatRepository.instance.unreadCountStream(),
        builder: (context, snapshot) => _ActionCard(
          icon: Icons.groups_rounded,
          color: kTeal,
          label: 'مجموعة الإدارة',
          subtitle: 'دردشة المالك والمشرفين',
          badge: snapshot.data ?? 0,
          onTap: () => _open(ChatScreen(isOwner: widget.isOwner)),
        ),
      ),
      StreamBuilder<int>(
        stream: DmRepository.instance.unreadThreadsStream(),
        builder: (context, snapshot) => _ActionCard(
          icon: Icons.forum_rounded,
          color: kBlue,
          label: 'الرسائل الخاصّة',
          subtitle: 'مراسلة مشرف على حدة',
          badge: snapshot.data ?? 0,
          onTap: () => _open(const DmListScreen()),
        ),
      ),
      StreamBuilder<int>(
        stream: SubmissionsRepository.watchPendingCount(),
        builder: (ctx, snap) => _ActionCard(
          icon: Icons.how_to_vote_rounded,
          color: kGold,
          label: 'طلبات النشر',
          subtitle: 'مساهمات المستمعين',
          badge: snap.data ?? 0,
          onTap: () => _open(
            SubmissionsScreen(
              categories: categories,
              subcategories: subcategories,
            ),
          ),
        ),
      ),
      _ActionCard(
        icon: Icons.library_music_rounded,
        color: kOrange,
        label: 'إضافة درس صوتي',
        subtitle: 'رفع ملفات أو تسجيل مباشر',
        onTap: () => _open(
          AddLessonScreen(
            categories: categories,
            subcategories: subcategories,
          ),
        ),
      ),
      _ActionCard(
        icon: Icons.account_tree_rounded,
        color: kTealDark,
        label: 'إدارة الأقسام',
        subtitle: 'إنشاء رئيسي وفرعي',
        onTap: () => _open(ManageSectionsScreen(categories: categories)),
      ),
      _ActionCard(
        icon: Icons.manage_search_rounded,
        color: kBlue,
        label: 'التعديل والبحث',
        subtitle: 'تعديل وحذف وجدولة',
        onTap: () => _open(const ManageAllScreen()),
      ),
      _ActionCard(
        icon: Icons.insights_rounded,
        color: kPurple,
        label: 'التحليلات والأثر',
        subtitle: 'الاستماع والأقسام النشطة',
        onTap: () => _open(const AnalyticsScreen()),
      ),
      _ActionCard(
        icon: Icons.forum_rounded,
        color: kGreen,
        label: 'تفاعل المستمعين',
        subtitle: 'الملاحظات والبلاغات',
        onTap: () => _open(const FeedbackScreen()),
      ),
      _ActionCard(
        icon: Icons.verified_user_rounded,
        color: kTeal,
        label: widget.isOwner ? 'الحساب والمشرفون' : 'الحساب والصلاحية',
        subtitle: widget.isOwner ? 'الاعتماد والحظر والحذف' : 'صلاحيتك وخروجك',
        onTap: () => _open(AdminsScreen(isOwner: widget.isOwner)),
      ),
      // لا تُنشأ الشجرة أو الـ stream لغير المالك، فلا يظهر له أي أثر.
      if (widget.isOwner)
        StreamBuilder<List<SuspiciousLessonReview>>(
          stream: OwnerReviewRepository.watchPending(),
          builder: (context, snapshot) => _ActionCard(
            icon: Icons.gpp_maybe_rounded,
            color: kDanger,
            label: 'الدروس المشبوهة',
            subtitle: 'مراجعة خاصة بالمالك',
            badge: snapshot.data?.length ?? 0,
            onTap: () => _open(const OwnerReviewScreen()),
          ),
        ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 122,
      ),
      itemCount: cards.length,
      itemBuilder: (context, i) => cards[i],
    );
  }

  Widget _alertsCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _open(AlertsScreen(isOwner: widget.isOwner)),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [kTeal, kTealDark],
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.campaign, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'تنبيهاتك',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...alerts
              .take(5)
              .map(
                (a) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '• ${(a['title'] ?? '').toString()} — ${(a['body'] ?? '').toString()}',
                    style: const TextStyle(color: Colors.white, height: 1.4),
                  ),
                ),
              ),
        ],
        ),
      ),
    );
  }

  Widget _statsGrid() {
    // أُزيلت إحصائية «الأجهزة»: مصدرها مجموعة legacy توقفت تغذيتها منذ
    // التحويل إلى Flutter، فكان الرقم تاريخياً مضللاً لا حالياً.
    final items = [
      ('الأقسام الرئيسية', categories.length, Icons.folder),
      ('الأقسام الفرعية', subcategories.length, Icons.folder_open),
      ('الصوتيات', lessons.length, Icons.audiotrack),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: items.map((e) => _statBox(e.$1, e.$2, e.$3)).toList(),
    );
  }

  Widget _statBox(String label, int value, IconData icon) {
    return Container(
      width: 108,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: kBoxBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: kTeal, size: 22),
          const SizedBox(height: 6),
          _loading
              ? const SizedBox(
                  height: 30,
                  width: 30,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: kTeal,
                  ),
                ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: kTeal),
          ),
        ],
      ),
    );
  }

}

/// بطاقة إجراء واحدة في شبكة اللوحة.
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String subtitle;
  final int badge;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.subtitle = '',
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.22)),
            color: color.withValues(alpha: 0.05),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const Spacer(),
                  if (badge > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badge > 99 ? '+99' : '$badge',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: kTealDark,
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
