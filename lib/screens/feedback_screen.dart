import 'package:flutter/material.dart';
import '../models.dart';
import '../services/admin_repository.dart';
import '../theme.dart';

/// «تفاعل المستمعين» — يعرض التقييمات والبلاغات الواردة من التطبيق العام،
/// ليطّلع المشرف على نبض جمهوره ويصلح مشاكل الصوت.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  List<Map<String, dynamic>> _items = [];
  Map<String, String> _titles = {};
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
        AdminRepository.fetchFeedback(),
        AdminRepository.fetchLessons(),
      ]);
      final lessons = r[1] as List<Lesson>;
      if (!mounted) return;
      setState(() {
        _items = r[0] as List<Map<String, dynamic>>;
        _titles = {for (final l in lessons) l.id: l.title};
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  ({String label, IconData icon, Color color}) _kind(String type) {
    switch (type) {
      case 'benefited':
        return (label: 'استفاد', icon: Icons.thumb_up, color: kGreen);
      case 'audio_issue':
        return (label: 'مشكلة صوت', icon: Icons.volume_off, color: kDanger);
      default:
        return (label: 'بلاغ', icon: Icons.report, color: kOrange);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تفاعل المستمعين'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'لا توجد تفاعلات بعد.',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _items.length,
                itemBuilder: (context, i) {
                  final m = _items[i];
                  final k = _kind((m['type'] ?? '').toString());
                  final title = _titles[m['lessonId']] ?? '(درس محذوف)';
                  final note = (m['note'] ?? '').toString();
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: k.color,
                        child: Icon(k.icon, color: Colors.white, size: 20),
                      ),
                      title: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        note.isEmpty ? k.label : '${k.label} — $note',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: kDanger),
                        onPressed: () async {
                          await AdminRepository.deleteFeedback(
                            m['id'].toString(),
                          );
                          _load();
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
