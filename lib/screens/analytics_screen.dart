import 'package:flutter/material.dart';
import '../models.dart';
import '../services/admin_repository.dart';
import '../theme.dart';

/// «التحليلات والأثر» — يحوّل اللوحة من جرد أرقام إلى قصة وصول المحتوى:
/// إجمالي الاستماع، أكثر الدروس والأقسام، الجديد هذا الأسبوع، ولوحة شرف
/// المشرفين. كل الأرقام من عدّاد views المخزّن على كل درس.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  List<Lesson> _lessons = [];
  List<Subcategory> _subs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait([
        AdminRepository.fetchLessons(),
        AdminRepository.fetchSubcategories(),
      ]);
      if (!mounted) return;
      setState(() {
        _lessons = r[0] as List<Lesson>;
        _subs = r[1] as List<Subcategory>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _subName(String id) {
    final s = _subs.where((x) => x.id == id);
    return s.isNotEmpty ? s.first.name : '—';
  }

  @override
  Widget build(BuildContext context) {
    final totalViews = _lessons.fold<int>(0, (a, l) => a + l.views);
    final now = DateTime.now();
    final newThisWeek = _lessons
        .where((l) => now.difference(l.createdAt).inDays < 7)
        .length;
    final scheduled = _lessons
        .where((l) => l.publishAt != null && l.publishAt!.isAfter(now))
        .length;

    final topLessons = [..._lessons.where((l) => l.views > 0)]
      ..sort((a, b) => b.views.compareTo(a.views));

    final sectionViews = <String, int>{};
    for (final l in _lessons) {
      if (l.subcategoryId.isEmpty) continue;
      sectionViews[l.subcategoryId] =
          (sectionViews[l.subcategoryId] ?? 0) + l.views;
    }
    final topSections = sectionViews.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final byAdmin = <String, (int count, int views)>{};
    for (final l in _lessons) {
      if (l.addedBy.isEmpty) continue;
      final cur = byAdmin[l.addedBy] ?? (0, 0);
      byAdmin[l.addedBy] = (cur.$1 + 1, cur.$2 + l.views);
    }
    final leaderboard = byAdmin.entries.toList()
      ..sort((a, b) => b.value.$2.compareTo(a.value.$2));

    return Scaffold(
      appBar: AppBar(
        title: const Text('التحليلات والأثر'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _statsGrid([
                    ('إجمالي الاستماع', totalViews, Icons.headphones),
                    ('عدد الدروس', _lessons.length, Icons.audiotrack),
                    ('جديد هذا الأسبوع', newThisWeek, Icons.fiber_new),
                    ('مجدولة للنشر', scheduled, Icons.schedule),
                  ]),
                  const SizedBox(height: 20),
                  _section('الأكثر استماعاً'),
                  if (topLessons.isEmpty)
                    _empty('لا توجد بيانات استماع بعد.')
                  else
                    ...topLessons
                        .take(10)
                        .map(
                          (l) => _rankTile(
                            l.title.isEmpty ? 'بدون عنوان' : l.title,
                            '${l.views} استماع',
                            Icons.play_circle_outline,
                          ),
                        ),
                  const SizedBox(height: 16),
                  _section('أنشط الأقسام'),
                  if (topSections.isEmpty)
                    _empty('لا توجد بيانات بعد.')
                  else
                    ...topSections
                        .take(8)
                        .map(
                          (e) => _rankTile(
                            _subName(e.key),
                            '${e.value} استماع',
                            Icons.folder_open,
                          ),
                        ),
                  const SizedBox(height: 16),
                  _section('لوحة شرف المشرفين'),
                  if (leaderboard.isEmpty)
                    _empty('ستظهر هنا مساهمات المشرفين للدروس الجديدة.')
                  else
                    ...leaderboard.map(
                      (e) => _rankTile(
                        e.key,
                        '${e.value.$1} درساً · ${e.value.$2} استماع',
                        Icons.emoji_events,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _statsGrid(List<(String, int, IconData)> items) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: items.map((e) {
        return Container(
          width: 108,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            color: kBoxBg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Icon(e.$3, color: kTeal, size: 22),
              const SizedBox(height: 6),
              Text(
                '${e.$2}',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: kTeal,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                e.$1,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: kTeal),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 4),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: kTeal,
      ),
    ),
  );

  Widget _empty(String t) => Padding(
    padding: const EdgeInsets.all(12),
    child: Text(t, style: const TextStyle(color: Colors.grey)),
  );

  Widget _rankTile(String title, String trailing, IconData icon) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: kTeal),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(
          trailing,
          style: const TextStyle(fontWeight: FontWeight.bold, color: kTeal),
        ),
      ),
    );
  }
}
