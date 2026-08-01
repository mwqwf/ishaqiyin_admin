import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../theme.dart';

/// نتيجة التسجيل: مسار الملف واسمه المقترح.
typedef RecordResult = ({String path, String name});

/// يفتح ورقة تسجيل صوتي مباشر ويعيد الملف المسجَّل (أو null إن أُلغي).
Future<RecordResult?> showRecordSheet(BuildContext context) {
  return showModalBottomSheet<RecordResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    showDragHandle: true,
    builder: (_) => const _RecordSheet(),
  );
}

class _RecordSheet extends StatefulWidget {
  const _RecordSheet();

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
  final AudioRecorder _rec = AudioRecorder();
  Timer? _timer;
  int _seconds = 0;
  bool _recording = false;
  bool _paused = false;
  String? _path;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  String get _timeLabel {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _recording && !_paused) setState(() => _seconds++);
    });
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = 'لم يُسمح باستخدام الميكروفون.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
        path: path,
      );
      setState(() {
        _recording = true;
        _paused = false;
        _seconds = 0;
        _path = path;
      });
      _startTimer();
    } catch (e) {
      setState(() => _error = 'تعذّر بدء التسجيل: $e');
    }
  }

  Future<void> _togglePause() async {
    try {
      if (_paused) {
        await _rec.resume();
      } else {
        await _rec.pause();
      }
      setState(() => _paused = !_paused);
    } catch (_) {}
  }

  Future<void> _stop() async {
    try {
      final out = await _rec.stop();
      _timer?.cancel();
      setState(() {
        _recording = false;
        _paused = false;
        _path = out ?? _path;
      });
    } catch (e) {
      setState(() => _error = 'تعذّر إيقاف التسجيل: $e');
    }
  }

  Future<void> _cancel() async {
    if (_recording) {
      try {
        await _rec.stop();
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  void _use() {
    if (_path == null) return;
    final name = 'تسجيل_${DateTime.now().millisecondsSinceEpoch}.m4a';
    Navigator.pop<RecordResult>(context, (path: _path!, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final done = !_recording && _path != null && _seconds > 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'تسجيل صوتي مباشر',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            // مؤشّر الحالة + المؤقّت
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (_recording && !_paused)
                    ? kDanger.withValues(alpha: 0.15)
                    : kBoxBg,
              ),
              child: Icon(
                done ? Icons.check_circle : Icons.mic,
                size: 56,
                color: done
                    ? kGreen
                    : (_recording && !_paused ? kDanger : kTeal),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _timeLabel,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.bold,
                color: kTeal,
              ),
            ),
            Text(
              _recording
                  ? (_paused ? 'موقوف مؤقتاً' : 'جارٍ التسجيل...')
                  : (done ? 'انتهى التسجيل — جاهز للرفع' : 'اضغط للبدء'),
              style: const TextStyle(color: Colors.grey),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kDanger),
              ),
            ],
            const SizedBox(height: 24),
            _controls(done),
          ],
        ),
      ),
    );
  }

  Widget _controls(bool done) {
    if (!_recording && !done) {
      // حالة البداية
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton(onPressed: _cancel, child: const Text('إلغاء')),
          FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.fiber_manual_record, color: Colors.red),
            label: const Text('بدء التسجيل'),
          ),
        ],
      );
    }
    if (_recording) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton.icon(
            onPressed: _togglePause,
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            label: Text(_paused ? 'متابعة' : 'إيقاف مؤقت'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            onPressed: _stop,
            icon: const Icon(Icons.stop),
            label: const Text('إنهاء'),
          ),
        ],
      );
    }
    // تم التسجيل: إعادة أو استخدام
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        TextButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.replay),
          label: const Text('إعادة التسجيل'),
        ),
        FilledButton.icon(
          onPressed: _use,
          icon: const Icon(Icons.check),
          label: const Text('استخدام هذا التسجيل'),
        ),
      ],
    );
  }
}
