import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../models.dart';
import '../services/submissions_repository.dart';
import '../theme.dart';

/// 🗳️ «طلبات النشر» — مراجعة مساهمات المستمعين القادمة من تطبيق منبر
/// العام. المشرف يستمع للصوت ثم: يوافق كما هي / يعدّل (العنوان/الأقسام)
/// وينشر / يرفض بسبب. النتيجة تصل المساهم إشعاراً.
class SubmissionsScreen extends StatefulWidget {
  final List<Category> categories;
  final List<Subcategory> subcategories;
  const SubmissionsScreen({
    super.key,
    required this.categories,
    required this.subcategories,
  });

  @override
  State<SubmissionsScreen> createState() => _SubmissionsScreenState();
}

class _SubmissionsScreenState extends State<SubmissionsScreen> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _playerStateSub;
  String _playingId = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        _playingId = '';
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _playerStateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(LessonSubmission s) async {
    try {
      if (_playingId == s.id && _player.playing) {
        await _player.pause();
        setState(() {});
        return;
      }
      if (_playingId != s.id) {
        setState(() => _playingId = s.id);
        await _player.setUrl(s.audioUrl);
      }
      unawaited(_player.play());
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تعذّر تشغيل الصوت.')));
      }
    }
  }

  Future<void> _run(Future<void> Function() action, String doneMsg) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && doneMsg.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(doneMsg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر تنفيذ العملية. حاول مجدداً.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approveAsIs(LessonSubmission s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('نشر المساهمة كما هي؟'),
        content: Text(
          '«${s.title}»\n${s.categoryName} ← ${s.subcategoryName}\n\n'
          'سيُنشر الدرس فوراً ويصل المساهم إشعار شكر.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('نشر'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () => SubmissionsRepository.approveAndPublish(s),
      'نُشرت المساهمة وأُخطر المساهم. ✅',
    );
  }

  Future<void> _editThenPublish(LessonSubmission s) async {
    final titleCtrl = TextEditingController(text: s.title);
    String? categoryId = widget.categories.any((c) => c.id == s.categoryId)
        ? s.categoryId
        : null;
    String? subcategoryId =
        widget.subcategories.any(
          (x) => x.id == s.subcategoryId && x.categoryId == categoryId,
        )
        ? s.subcategoryId
        : null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final subs = widget.subcategories
              .where((x) => x.categoryId == categoryId)
              .toList();
          return AlertDialog(
            title: const Text('تعديل ثم نشر'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleCtrl,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'العنوان',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: categoryId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'القسم الرئيسي',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final c in widget.categories)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setSheet(() {
                      categoryId = v;
                      subcategoryId = null;
                    }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: subcategoryId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'القسم الفرعي',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final x in subs)
                        DropdownMenuItem(value: x.id, child: Text(x.name)),
                    ],
                    onChanged: (v) => setSheet(() => subcategoryId = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed:
                    titleCtrl.text.trim().isNotEmpty &&
                        categoryId != null &&
                        subcategoryId != null
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: const Text('نشر المعدَّل'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || categoryId == null || subcategoryId == null) {
      return;
    }
    final cat = widget.categories.firstWhere((c) => c.id == categoryId);
    final sub = widget.subcategories.firstWhere((x) => x.id == subcategoryId);
    await _run(
      () => SubmissionsRepository.approveAndPublish(
        s,
        editedTitle: titleCtrl.text,
        editedCategoryId: cat.id,
        editedCategoryName: cat.name,
        editedSubcategoryId: sub.id,
        editedSubcategoryName: sub.name,
      ),
      'نُشرت المساهمة بعد التعديل وأُخطر المساهم. ✅',
    );
  }

  Future<void> _reject(LessonSubmission s) async {
    const presets = [
      'المحتوى لا يناسب طبيعة التطبيق',
      'جودة الصوت ضعيفة أو غير واضحة',
      'المحتوى مكرّر (منشور سابقاً)',
      'القسم المختار غير مناسب والمحتوى غير مكتمل',
    ];
    String? selected;
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text('سبب الرفض'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'يصل السبب للمساهم كما هو — اكتبه بلطف ووضوح.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                RadioGroup<String>(
                  groupValue: selected,
                  onChanged: (v) => setSheet(() => selected = v),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final p in presets)
                        RadioListTile<String>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(p, style: const TextStyle(fontSize: 13)),
                          value: p,
                        ),
                      const RadioListTile<String>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('سبب آخر…', style: TextStyle(fontSize: 13)),
                        value: '_other',
                      ),
                    ],
                  ),
                ),
                if (selected == '_other')
                  TextField(
                    controller: noteCtrl,
                    maxLength: 300,
                    maxLines: 2,
                    onChanged: (_) => setSheet(() {}),
                    decoration: const InputDecoration(
                      labelText: 'اكتب السبب',
                      border: OutlineInputBorder(),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kDanger),
              // «سبب آخر» بلا نص فعلي يرفضه الخادم (سبب ≥ حرفين) — نعطّل
              // الزر بدل تركه يفشل برسالة مبهمة.
              onPressed: selected == null ||
                      (selected == '_other' &&
                          noteCtrl.text.trim().length < 2)
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('رفض'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || selected == null) return;
    final reason = selected == '_other' ? noteCtrl.text.trim() : selected!;
    await _run(
      () => SubmissionsRepository.reject(s, reason),
      'رُفضت المساهمة وأُبلغ المساهم بالسبب.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('طلبات النشر (مساهمات المستمعين)')),
      body: StreamBuilder<List<LessonSubmission>>(
        stream: SubmissionsRepository.watchAll(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'تعذّر تحميل طلبات النشر: ${snap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final items = snap.data ?? const <LessonSubmission>[];
          if (snap.connectionState == ConnectionState.waiting &&
              items.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'لا توجد مساهمات بعد.\nعندما يرسل المستمعون دروساً من '
                  '«شارك درساً» ستظهر هنا للمراجعة.',
                  textAlign: TextAlign.center,
                  style: TextStyle(height: 1.6),
                ),
              ),
            );
          }
          return AbsorbPointer(
            absorbing: _busy,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (ctx, i) => _buildTile(items[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTile(LessonSubmission s) {
    final isPlaying = _playingId == s.id && _player.playing;
    final pending = s.isPending;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: isPlaying ? 'إيقاف' : 'استماع',
                  onPressed: () => _togglePlay(s),
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${s.categoryName} ← ${s.subcategoryName}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                _statusChip(s),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'المساهم: ${s.submitterName.isEmpty ? 'بدون اسم' : s.submitterName}'
              '${s.fileSize > 0 ? ' • ${(s.fileSize / (1024 * 1024)).toStringAsFixed(1)}MB' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (s.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'ملاحظة المساهم: ${s.note}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            if (!pending &&
                s.status == 'rejected' &&
                s.rejectReason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'سبب الرفض: ${s.rejectReason}',
                style: const TextStyle(fontSize: 12, color: kDanger),
              ),
            ],
            const SizedBox(height: 8),
            if (pending)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _approveAsIs(s),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('نشر كما هي'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _editThenPublish(s),
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: const Text('تعديل ثم نشر'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'رفض',
                    style: IconButton.styleFrom(foregroundColor: kDanger),
                    onPressed: () => _reject(s),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              )
            else
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: () =>
                      _run(() => SubmissionsRepository.deleteDecided(s), ''),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('إزالة من السجل'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(LessonSubmission s) {
    final (color, label) = switch (s.status) {
      'approved' => (Colors.green, 'نُشرت'),
      'approved_edited' => (Colors.teal, 'نُشرت معدَّلة'),
      'rejected' => (kDanger, 'مرفوضة'),
      _ => (Colors.orange, 'معلّقة'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
