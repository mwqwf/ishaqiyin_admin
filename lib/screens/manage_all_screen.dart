import 'package:flutter/material.dart';
import '../models.dart';
import '../services/admin_repository.dart';
import '../theme.dart';

class ManageAllScreen extends StatefulWidget {
  const ManageAllScreen({super.key});

  @override
  State<ManageAllScreen> createState() => _ManageAllScreenState();
}

class _ManageAllScreenState extends State<ManageAllScreen> {
  List<Category> _categories = [];
  List<Subcategory> _subcategories = [];
  List<Lesson> _lessons = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait([
        AdminRepository.fetchCategories(),
        AdminRepository.fetchSubcategories(),
        AdminRepository.fetchLessons(),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = r[0] as List<Category>;
        _subcategories = r[1] as List<Subcategory>;
        _lessons = r[2] as List<Lesson>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  List<T> _filter<T>(List<T> list, String Function(T) name) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final scored = <(T, int)>[];
    for (final item in list) {
      final idx = name(item).toLowerCase().indexOf(q);
      if (idx != -1) scored.add((item, idx));
    }
    scored.sort((a, b) => a.$2.compareTo(b.$2));
    return scored.map((e) => e.$1).toList();
  }

  Future<String?> _editDialog(String title, String current) {
    final ctrl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تعديل $title'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'الاسم الجديد'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(String label, {String? note}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: Text(
          note == null
              ? 'هل أنت متأكد من حذف "$label"؟'
              : 'هل أنت متأكد من حذف "$label"؟\n\n$note',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ---- Categories ----
  Future<void> _editCategory(Category c) async {
    final name = await _editDialog('القسم الرئيسي', c.name);
    if (name == null || name.isEmpty || name == c.name) return;
    await AdminRepository.updateCategory(c.id, name);
    _snack('تم التعديل.');
    _load();
  }

  Future<void> _deleteCategory(Category c) async {
    if (!await _confirmDelete(
      c.name,
      note:
          'سيُحذف القسم مع كل أقسامه الفرعية ودروسها وملفاتها الصوتية '
          'من التخزين. لا يمكن التراجع.',
    )) {
      return;
    }
    setState(() => _loading = true);
    try {
      await AdminRepository.deleteCategory(c.id);
      _snack('تم حذف القسم ومحتوياته بالكامل.');
    } catch (e) {
      _snack('تعذّر الحذف: $e');
    }
    _load();
  }

  // ---- Subcategories ----
  Future<void> _editSubcategory(Subcategory s) async {
    final name = await _editDialog('القسم الفرعي', s.name);
    if (name == null || name.isEmpty || name == s.name) return;
    await AdminRepository.updateSubcategory(s.id, name);
    _snack('تم التعديل.');
    _load();
  }

  Future<void> _deleteSubcategory(Subcategory s) async {
    if (!await _confirmDelete(
      s.name,
      note:
          'سيُحذف القسم الفرعي مع كل دروسه وملفاتها الصوتية من التخزين. '
          'لا يمكن التراجع.',
    )) {
      return;
    }
    setState(() => _loading = true);
    try {
      await AdminRepository.deleteSubcategory(s.id);
      _snack('تم حذف القسم الفرعي ومحتوياته بالكامل.');
    } catch (e) {
      _snack('تعذّر الحذف: $e');
    }
    _load();
  }

  // ---- Lessons ----
  Future<void> _editLesson(Lesson l) async {
    final title = await _editDialog('عنوان الدرس', l.title);
    if (title == null || title.isEmpty || title == l.title) return;
    await AdminRepository.updateLessonTitle(l.id, title);
    _snack('تم التعديل.');
    _load();
  }

  Future<void> _deleteLesson(Lesson l) async {
    if (!await _confirmDelete(l.title)) return;
    try {
      await AdminRepository.deleteLesson(l);
      _snack('تم حذف الدرس والملف الصوتي.');
    } catch (e) {
      _snack('تعذّر الحذف: $e');
    }
    _load();
  }

  Future<void> _toggleFeatured(Lesson l) async {
    try {
      await AdminRepository.setLessonFeatured(l.id, !l.featured);
      _snack(
        l.featured ? 'أُلغي التمييز.' : 'تم التمييز — سيظهر أعلى التطبيق.',
      );
    } catch (e) {
      _snack('تعذّر التعديل: $e');
    }
    _load();
  }

  Future<void> _scheduleLesson(Lesson l) async {
    final now = DateTime.now();
    if (l.publishAt != null && l.publishAt!.isAfter(now)) {
      // مجدول بالفعل → اعرض خيار إلغاء الجدولة (نشر فوري).
      final cancel = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('النشر مجدول'),
          content: Text('هذا الدرس مجدول للظهور في:\n${l.publishAt}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إبقاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('نشر الآن'),
            ),
          ],
        ),
      );
      if (cancel == true) {
        try {
          // النشر عبر الخادم يرسل إشعار «درس جديد» أيضاً — حذف الجدولة
          // وحده كان ينشر بصمت بلا إشعار.
          await AdminRepository.publishScheduledNow(l.id);
          _snack('نُشر الدرس فوراً وأُرسل إشعار «درس جديد».');
        } catch (e) {
          _snack('تعذّر النشر الفوري: $e');
        }
        _load();
      }
      return;
    }
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null) return;
    final when = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await AdminRepository.setLessonPublishAt(l.id, when);
    _snack('جُدول النشر.');
    _load();
  }

  Widget _lessonRow(Lesson l) {
    final scheduled =
        l.publishAt != null && l.publishAt!.isAfter(DateTime.now());
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(l.title.isEmpty ? 'بدون عنوان' : l.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_subName(l.subcategoryId).isNotEmpty)
              Text('القسم الفرعي: ${_subName(l.subcategoryId)}'),
            Row(
              children: [
                if (l.views > 0)
                  Text(
                    '${l.views} استماع',
                    style: const TextStyle(fontSize: 12, color: kTeal),
                  ),
                if (scheduled) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.schedule, size: 14, color: kOrange),
                  const Text(
                    ' مجدول',
                    style: TextStyle(fontSize: 12, color: kOrange),
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: l.featured ? 'إلغاء التمييز' : 'تمييز',
              icon: Icon(
                l.featured ? Icons.star : Icons.star_border,
                color: l.featured ? kGold : Colors.grey,
              ),
              onPressed: () => _toggleFeatured(l),
            ),
            IconButton(
              tooltip: 'جدولة النشر',
              icon: Icon(
                Icons.schedule,
                color: scheduled ? kOrange : Colors.grey,
              ),
              onPressed: () => _scheduleLesson(l),
            ),
            IconButton(
              tooltip: 'تعديل',
              icon: const Icon(Icons.edit, color: kTeal),
              onPressed: () => _editLesson(l),
            ),
            IconButton(
              tooltip: 'حذف',
              icon: const Icon(Icons.delete_outline, color: kDanger),
              onPressed: () => _deleteLesson(l),
            ),
          ],
        ),
      ),
    );
  }

  String _subName(String id) {
    final s = _subcategories.where((x) => x.id == id);
    return s.isNotEmpty ? s.first.name : '';
  }

  @override
  Widget build(BuildContext context) {
    final cats = _filter(_categories, (c) => c.name);
    final subs = _filter(_subcategories, (s) => s.name);
    final lessons = _filter(_lessons, (l) => l.title);
    final hasQuery = _query.trim().isNotEmpty;
    final empty = hasQuery && cats.isEmpty && subs.isEmpty && lessons.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('التعديل والحذف / البحث')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'ابحث في الأقسام والدروس...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: !hasQuery
                ? const Center(
                    child: Text(
                      'أدخل كلمة للبحث في كل العناصر.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : empty
                ? const Center(child: Text('لا توجد نتائج'))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    children: [
                      if (cats.isNotEmpty) _header('الأقسام الرئيسية'),
                      ...cats.map(
                        (c) => _row(
                          title: c.name,
                          onEdit: () => _editCategory(c),
                          onDelete: () => _deleteCategory(c),
                        ),
                      ),
                      if (subs.isNotEmpty) _header('الأقسام الفرعية'),
                      ...subs.map(
                        (s) => _row(
                          title: s.name,
                          onEdit: () => _editSubcategory(s),
                          onDelete: () => _deleteSubcategory(s),
                        ),
                      ),
                      if (lessons.isNotEmpty) _header('الدروس الصوتية'),
                      ...lessons.map(_lessonRow),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: kTeal,
      ),
    ),
  );

  Widget _row({
    required String title,
    String? subtitle,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle) : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'تعديل',
              icon: const Icon(Icons.edit, color: kTeal),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'حذف',
              icon: const Icon(Icons.delete_outline, color: kDanger),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
