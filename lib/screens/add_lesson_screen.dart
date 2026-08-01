import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../services/admin_repository.dart';
import '../services/audio_merge.dart';
import '../services/smart_title.dart';
import '../services/auth_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import 'record_sheet.dart';

class AddLessonScreen extends StatefulWidget {
  final List<Category> categories;
  final List<Subcategory> subcategories;

  /// تعبئة مسبقة من «المشاركة إلى إدارة منبر» (ملف منسوخ إلى cache).
  final String? initialFilePath;
  final String? initialFileName;

  const AddLessonScreen({
    super.key,
    required this.categories,
    required this.subcategories,
    this.initialFilePath,
    this.initialFileName,
  });

  @override
  State<AddLessonScreen> createState() => _AddLessonScreenState();
}

class _AddLessonScreenState extends State<AddLessonScreen> {
  final _title = TextEditingController();
  String? _categoryId;
  String? _subcategoryId;

  /// الملفات المختارة بالترتيب — أكثر من ملف يعني دمجها في درس واحد.
  final List<({String path, String name})> _files = [];

  bool _uploading = false;
  bool _picking = false;
  bool _merging = false;
  double _progress = 0;
  String _message = '';
  bool _isError = false;
  bool _featured = false;
  DateTime? _publishAt;
  UploadCanceller? _canceller;

  @override
  void initState() {
    super.initState();
    // ملف وارد من مشاركة خارجية: عبّئ الحقل واقترح عنواناً من اسمه.
    final p = widget.initialFilePath;
    if (p != null && p.isNotEmpty) {
      final n = widget.initialFileName ?? p.split(RegExp(r'[/\\]')).last;
      _files.add((path: p, name: n));
      _title.text = smartTitleFromFileName(n);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  List<Subcategory> get _subsForCategory =>
      widget.subcategories.where((s) => s.categoryId == _categoryId).toList();

  void _setMsg(String m, {bool error = false}) {
    setState(() {
      _message = m;
      _isError = error;
    });
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _pickPublishAt() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _publishAt ?? now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _publishAt ?? now.add(const Duration(hours: 1)),
      ),
    );
    if (time == null) return;
    setState(() {
      _publishAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickAudio() async {
    // النسخ من منتقي النظام إلى ذاكرة التطبيق قد يستغرق ثواني للملفات
    // الكبيرة — نُظهر انشغالاً حتى لا يبدو النموذج «متجمّداً».
    setState(() => _picking = true);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      final picked =
          res?.files
              .where((f) => f.path != null)
              .map((f) => (path: f.path!, name: f.name))
              .toList() ??
          const <({String path, String name})>[];
      if (picked.isEmpty) return;

      final existing = _files.map((f) => f.path).toSet();
      final combined = [
        ..._files,
        ...picked.where((f) => !existing.contains(f.path)),
      ];

      // الدمج المباشر (لصق الإطارات) لا يصح إلا لملفات MP3.
      if (combined.length > 1) {
        final bad = combined.where((f) => !AudioMerger.isMp3(f.name));
        if (bad.isNotEmpty) {
          _setMsg(
            'لدمج عدة ملفات يجب أن تكون جميعها MP3 — «${bad.first.name}» ليس كذلك.',
            error: true,
          );
          return;
        }
      }

      setState(() {
        if (combined.length > AudioMerger.maxFiles) {
          _message =
              'الحد الأقصى ${AudioMerger.maxFiles} ملفات للدرس الواحد — أُبقي أولها.';
          _isError = true;
        } else {
          _message = '';
          _isError = false;
        }
        _files
          ..clear()
          ..addAll(combined.take(AudioMerger.maxFiles));
        if (_title.text.trim().isEmpty && _files.isNotEmpty) {
          // عنوان مقترح ذكيّ — يزيل الترقيم وبصمات المواقع وأنماط
          // المسجّلات؛ الاسم الآليّ البحت يُترك فارغاً ليكتبه المشرف.
          _title.text = smartTitleFromFileName(_files.first.name);
        }
      });
    } catch (e) {
      _setMsg('تعذّر اختيار الملفات: $e', error: true);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// طريق ثانوي: تسجيل صوتي مباشر من ميكروفون الجهاز.
  /// التسجيل (m4a) لا يُدمج مع ملفات — يحلّ محلّ الاختيار الحالي.
  Future<void> _recordAudio() async {
    try {
      final r = await showRecordSheet(context);
      if (r == null) return;
      setState(() {
        _files
          ..clear()
          ..add((path: r.path, name: r.name));
        _message = '';
        _isError = false;
      });
    } catch (e) {
      _setMsg('تعذّر التسجيل: $e', error: true);
    }
  }

  bool get _canUpload =>
      _title.text.trim().isNotEmpty &&
      _categoryId != null &&
      _subcategoryId != null &&
      _files.isNotEmpty &&
      !_uploading;

  Future<void> _upload() async {
    if (!_canUpload) {
      _setMsg('يرجى تعبئة جميع الحقول واختيار ملف صوتي.', error: true);
      return;
    }
    setState(() {
      _uploading = true;
      _merging = false;
      _progress = 0;
      _message = '';
      _isError = false;
    });
    _canceller = UploadCanceller();
    File? mergedTemp;
    try {
      // ملف واحد يُرفع كما هو؛ أكثر من ملف يُدمج محلياً أولاً ثم يُرفع
      // الناتج درساً واحداً متصلاً بالترتيب الظاهر في القائمة.
      String localPath;
      String srcName;
      if (_files.length == 1) {
        localPath = _files.single.path;
        srcName = _files.single.name;
      } else {
        setState(() => _merging = true);
        final tmp = await getTemporaryDirectory();
        final ts = DateTime.now().millisecondsSinceEpoch;
        mergedTemp = await AudioMerger.mergeMp3(
          inputs: [for (final f in _files) File(f.path)],
          outputPath: '${tmp.path}/merged_$ts.mp3',
        );
        if (mounted) setState(() => _merging = false);
        localPath = mergedTemp.path;
        srcName = 'merged.mp3';
      }

      final filename = '${DateTime.now().millisecondsSinceEpoch}_$srcName';
      final up = await StorageService.uploadFile(
        localPath: localPath,
        folder: 'lessons',
        filename: filename,
        canceller: _canceller,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      try {
        await AdminRepository.addLesson(
          title: _title.text,
          categoryId: _categoryId!,
          subcategoryId: _subcategoryId!,
          audioUrl: up.url,
          audioStoragePath: up.path,
          addedBy: AuthService.currentUser?.email ?? '',
          publishAt: _publishAt,
          featured: _featured,
        );
      } catch (writeError) {
        // لا نترك ملفاً يتيماً إن رفض الخادم إنشاء وثيقة الدرس.
        try {
          await StorageService.deleteFileOrThrow(up.path);
        } catch (cleanupError) {
          throw StateError(
            'فشل إنشاء الدرس، وتعذّر أيضاً تنظيف الملف المرفوع: '
            '$writeError / $cleanupError',
          );
        }
        rethrow;
      }
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _progress = 0;
        _title.clear();
        _files.clear();
        _featured = false;
        _publishAt = null;
      });
      _setMsg('تم رفع الملف وإضافة الدرس بنجاح!');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _merging = false;
        _progress = 0;
      });
      if (StorageService.isCancellation(e) ||
          (_canceller?.cancelled ?? false)) {
        _setMsg('أُلغي الرفع.');
      } else if (e is FormatException) {
        _setMsg('تعذّر دمج الملفات — تأكد أنها ملفات MP3 سليمة.', error: true);
      } else {
        _setMsg('خطأ أثناء الرفع: $e', error: true);
      }
    } finally {
      _canceller = null;
      // الملف المدموج مؤقت — يُحذف بعد الرفع (أو الفشل) لتوفير المساحة.
      mergedTemp?.delete().ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إضافة درس صوتي')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'عنوان الدرس الصوتي'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_uploading || _picking) ? null : _pickAudio,
                  icon: _picking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kTeal,
                          ),
                        )
                      : Icon(
                          _files.isEmpty
                              ? Icons.audio_file
                              : Icons.playlist_add,
                          color: kTeal,
                        ),
                  label: Text(
                    _picking
                        ? 'جارٍ تجهيز الملفات…'
                        : _files.isEmpty
                        ? 'اختر ملفاً (أو عدّة)'
                        : 'إضافة ملفات (${_files.length}/${AudioMerger.maxFiles})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _uploading ? null : _recordAudio,
                  icon: const Icon(Icons.mic, color: kDanger),
                  label: const Text(
                    'تسجيل مباشر',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          if (_files.length > 1) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kTeal.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'ستُدمج ${_files.length} ملفات بالترتيب أدناه في درس واحد '
                'متصل — اسحب المقبض ≡ لإعادة الترتيب.',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ),
          ],
          if (_files.isNotEmpty)
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _files.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  _files.insert(newIndex, _files.removeAt(oldIndex));
                });
              },
              itemBuilder: (ctx, i) {
                final f = _files[i];
                return ListTile(
                  key: ValueKey(f.path),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: CircleAvatar(
                    radius: 13,
                    backgroundColor: kTeal.withValues(alpha: 0.15),
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(fontSize: 12, color: kTeal),
                    ),
                  ),
                  title: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kTeal),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'إزالة',
                        icon: const Icon(Icons.close, size: 18, color: kDanger),
                        onPressed: _uploading
                            ? null
                            : () => setState(() => _files.removeAt(i)),
                      ),
                      if (_files.length > 1)
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _categoryId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'القسم الرئيسي'),
            items: widget.categories
                .map(
                  (c) => DropdownMenuItem(
                    value: c.id,
                    child: Text(c.name, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: _uploading
                ? null
                : (v) => setState(() {
                    _categoryId = v;
                    _subcategoryId = null;
                  }),
          ),
          if (_categoryId != null) ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _subcategoryId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'القسم الفرعي'),
              items: _subsForCategory
                  .map(
                    (s) => DropdownMenuItem(
                      value: s.id,
                      child: Text(s.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: _uploading
                  ? null
                  : (v) => setState(() => _subcategoryId = v),
            ),
            if (_subsForCategory.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'لا توجد أقسام فرعية لهذا القسم — أنشئ واحداً أولاً.',
                  style: TextStyle(color: kDanger, fontSize: 13),
                ),
              ),
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _featured,
            onChanged: _uploading
                ? null
                : (v) => setState(() => _featured = v ?? false),
            secondary: const Icon(Icons.star, color: kTeal),
            title: const Text('تمييز الدرس (يظهر أعلى التطبيق)'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule, color: kTeal),
            title: const Text('جدولة النشر'),
            subtitle: Text(
              _publishAt == null
                  ? 'ينشر فوراً'
                  : 'يظهر للمستخدمين في: ${_fmtDate(_publishAt!)}',
            ),
            trailing: _publishAt == null
                ? const Icon(Icons.chevron_left)
                : IconButton(
                    icon: const Icon(Icons.clear, color: kDanger),
                    onPressed: _uploading
                        ? null
                        : () => setState(() => _publishAt = null),
                  ),
            onTap: _uploading ? null : _pickPublishAt,
          ),
          const SizedBox(height: 18),
          if (_uploading) ...[
            LinearProgressIndicator(
              value: _merging ? null : _progress / 100,
              color: kTeal,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _merging
                      ? 'جارٍ دمج الملفات في مقطع واحد…'
                      : 'جارٍ الرفع… ${_progress.round()}%',
                  style: const TextStyle(color: kTeal),
                ),
                if (!_merging) ...[
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: () => _canceller?.cancel(),
                    icon: const Icon(Icons.close, size: 18, color: kDanger),
                    label: const Text(
                      'إلغاء الرفع',
                      style: TextStyle(color: kDanger),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _message,
                style: TextStyle(
                  color: _isError ? kDanger : Colors.green.shade700,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          FilledButton.icon(
            onPressed: _canUpload ? _upload : null,
            icon: const Icon(Icons.cloud_upload),
            label: const Text('رفع الدرس الصوتي'),
          ),
        ],
      ),
    );
  }
}
