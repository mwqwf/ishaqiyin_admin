import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/auth_service.dart';
import '../services/owner_review_repository.dart';
import '../theme.dart';

/// شاشة لا تُضاف لمسار المشرف إطلاقاً، كما تتحقق ثانيةً من بريد المالك.
/// الحماية الحقيقية تبقى في قواعد Firestore وcallables على الخادم.
class OwnerReviewScreen extends StatefulWidget {
  const OwnerReviewScreen({super.key});

  @override
  State<OwnerReviewScreen> createState() => _OwnerReviewScreenState();
}

class _OwnerReviewScreenState extends State<OwnerReviewScreen> {
  final AudioPlayer _player = AudioPlayer();
  String _playingId = '';
  String _busyId = '';
  bool _scanning = false;

  bool get _isOwner => AuthService.isOwnerEmail(AuthService.currentUser?.email);

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle(SuspiciousLessonReview review) async {
    if (review.audioUrl.isEmpty) return;
    try {
      if (_playingId == review.id && _player.playing) {
        await _player.pause();
        return;
      }
      if (_playingId != review.id) {
        setState(() => _playingId = review.id);
        await _player.setUrl(review.audioUrl);
      }
      unawaited(_player.play());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّرت معاينة الملف الصوتي.')),
        );
      }
    }
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final count = await OwnerReviewRepository.scanAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count > 0
                  ? 'اكتمل الفحص: أضيف $count درساً للمراجعة.'
                  : 'اكتمل الفحص ولم تُكتشف نتائج جديدة.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذّر إكمال الفحص: $e')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _resolve(SuspiciousLessonReview review, String action) async {
    final deleting = action == 'delete';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(deleting ? 'حذف الدرس نهائياً؟' : 'تأكيد سلامة الدرس؟'),
        content: Text(
          deleting
              ? 'سيُحذف «${review.title}» وملفه الصوتي نهائياً. لا يمكن التراجع عن ذلك.'
              : 'سيُعلَّم «${review.title}» بأنه راجعه المالك وتم التحقق منه.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            style: deleting
                ? FilledButton.styleFrom(backgroundColor: kDanger)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(deleting ? 'حذف نهائي' : 'تم التحقق'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyId = review.id);
    try {
      await OwnerReviewRepository.resolve(review, action: action);
      if (_playingId == review.id) {
        await _player.stop();
        _playingId = '';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deleting ? 'حُذف الدرس نهائياً.' : 'وُضعت علامة تم التحقق.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذّر تنفيذ القرار: $e')));
      }
    } finally {
      if (mounted) setState(() => _busyId = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isOwner) {
      return const Scaffold(
        body: Center(child: Text('هذه الصفحة خاصة بمالك التطبيق فقط.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('مراجعة الدروس المشبوهة'),
        actions: [
          TextButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.security),
            label: const Text('فحص شامل'),
          ),
        ],
      ),
      body: StreamBuilder<List<SuspiciousLessonReview>>(
        stream: OwnerReviewRepository.watchPending(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'تعذّر تحميل قائمة المراجعة: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_user, size: 58, color: Colors.green),
                    SizedBox(height: 12),
                    Text(
                      'لا توجد دروس مشبوهة معلّقة الآن.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'يمكنك تشغيل فحص شامل من الزر أعلى الشاشة.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) => _reviewCard(items[index]),
          );
        },
      ),
    );
  }

  Widget _reviewCard(SuspiciousLessonReview review) {
    final busy = _busyId == review.id;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snapshot) {
                    final playing =
                        _playingId == review.id &&
                        snapshot.data?.playing == true &&
                        snapshot.data?.processingState !=
                            ProcessingState.completed;
                    return IconButton.filledTonal(
                      tooltip: review.audioUrl.isEmpty
                          ? 'لا يوجد رابط صوت'
                          : (playing ? 'إيقاف مؤقت' : 'معاينة'),
                      onPressed: review.audioUrl.isEmpty
                          ? null
                          : () => _toggle(review),
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    review.title.isEmpty ? '(درس بلا عنوان)' : review.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: kDanger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    'خطورة ${review.riskScore}',
                    style: const TextStyle(
                      color: kDanger,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (review.reasons.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'أسباب الاشتباه:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              for (final reason in review.reasons)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $reason'),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              'معرّف الدرس: ${review.lessonId}'
              '${review.addedBy.isEmpty ? '' : '\nأضيف بواسطة: ${review.addedBy}'}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (busy)
              const LinearProgressIndicator()
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _resolve(review, 'verified'),
                      icon: const Icon(Icons.verified, size: 18),
                      label: const Text('تم التحقق'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: kDanger),
                      onPressed: () => _resolve(review, 'delete'),
                      icon: const Icon(Icons.delete_forever, size: 18),
                      label: const Text('حذف نهائي'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
