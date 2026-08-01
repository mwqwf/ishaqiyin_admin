import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:video_player/video_player.dart';

import '../../services/chat_media_store.dart';
import '../../services/chat_repository.dart';
import 'chat_ui.dart';

/// مشغّل صوت مشترك — مشغّل واحد فقط يعمل في أيّ لحظة (مثل واتساب).
/// يشغّل **ملفّاً محليّاً** دائماً (بعد التنزيل) فلا يتأثّر بالشبكة إطلاقاً.
class SharedAudioPlayer {
  SharedAudioPlayer._();
  static final SharedAudioPlayer instance = SharedAudioPlayer._();

  final AudioPlayer player = AudioPlayer();

  /// مفتاح المقطع النشط حاليّاً — تراقبه الفقاعات لتعرف أيّها يعمل.
  final ValueNotifier<String?> activeKey = ValueNotifier<String?>(null);

  /// سرعة التشغيل (تُطبَّق على المقطع الحالي والتالي — مثل واتساب).
  final ValueNotifier<double> speed = ValueNotifier<double>(1.0);

  Future<void> playFile(String key, File file) async {
    if (activeKey.value == key) {
      await player.play();
      return;
    }
    activeKey.value = key;
    await player.stop();
    await player.setFilePath(file.path);
    await player.setSpeed(speed.value);
    await player.play();
  }

  Future<void> setSpeed(double v) async {
    speed.value = v;
    try {
      await player.setSpeed(v);
    } catch (_) {}
  }

  Future<void> pause() => player.pause();

  Future<void> stop() async {
    activeKey.value = null;
    await player.stop();
  }
}

/// فقاعة صوت بنمط واتساب: زرّ تنزيل أوّلاً، ثم تشغيل من الملفّ المحلّي مع
/// شريط تقدّم وسرعة تشغيل — ويعمل دون إنترنت بعد التنزيل.
class AudioBubblePlayer extends StatefulWidget {
  const AudioBubblePlayer({
    super.key,
    required this.attachment,
    this.isVoice = false,
    this.mine = false,
  });

  final ChatAttachment attachment;
  final bool isVoice;
  final bool mine;

  @override
  State<AudioBubblePlayer> createState() => _AudioBubblePlayerState();
}

class _AudioBubblePlayerState extends State<AudioBubblePlayer> {
  final _shared = SharedAudioPlayer.instance;
  final _store = ChatMediaStore.instance;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  late final String _key = _store.keyOf(widget.attachment);

  bool get _isActive => _shared.activeKey.value == _key;

  @override
  void initState() {
    super.initState();
    _dur = Duration(milliseconds: widget.attachment.durationMs ?? 0);
    _shared.activeKey.addListener(_onSharedChange);
    _shared.player.positionStream.listen((d) {
      if (mounted && _isActive) setState(() => _pos = d);
    });
    _shared.player.durationStream.listen((d) {
      if (mounted && _isActive && d != null && d > Duration.zero) {
        setState(() => _dur = d);
      }
    });
    _shared.player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (_isActive && s.processingState == ProcessingState.completed) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
        _shared.stop();
        return;
      }
      setState(() => _playing = _isActive && s.playing);
    });
  }

  void _onSharedChange() {
    if (mounted) setState(() => _playing = false);
  }

  @override
  void dispose() {
    _shared.activeKey.removeListener(_onSharedChange);
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _toggle(MediaStatus status) async {
    if (status.state == MediaState.downloading) return;
    if (!status.isReady) {
      final f = await _store.download(widget.attachment);
      if (f == null || !mounted) return;
      await _shared.playFile(_key, f);
      return;
    }
    if (_playing) {
      await _shared.pause();
    } else {
      await _shared.playFile(_key, status.file!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaStatus>(
      valueListenable: _store.statusOf(widget.attachment),
      builder: (context, status, _) {
        final active = _isActive && status.isReady;
        final pos = active ? _pos : Duration.zero;
        final total = _dur > Duration.zero ? _dur : const Duration(seconds: 1);
        return SizedBox(
          width: 236,
          child: Row(
            children: [
              _actionButton(status),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: ChatColors.accent,
                        inactiveTrackColor: ChatColors.border,
                        thumbColor: ChatColors.accent,
                      ),
                      child: Slider(
                        value: pos.inMilliseconds
                            .clamp(0, total.inMilliseconds)
                            .toDouble(),
                        max: total.inMilliseconds.toDouble(),
                        onChanged: active
                            ? (v) => _shared.player.seek(
                                Duration(milliseconds: v.toInt()),
                              )
                            : null,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Row(
                        children: [
                          Text(
                            _statusLine(status, pos),
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: ChatColors.textMuted,
                            ),
                          ),
                          const Spacer(),
                          if (active)
                            ValueListenableBuilder<double>(
                              valueListenable: _shared.speed,
                              builder: (_, sp, _) => InkWell(
                                onTap: () {
                                  const steps = [1.0, 1.5, 2.0];
                                  final next =
                                      steps[(steps.indexOf(sp) + 1) %
                                          steps.length];
                                  _shared.setSpeed(next);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: ChatColors.surfaceAlt,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${sp % 1 == 0 ? sp.toStringAsFixed(0) : sp}×',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: ChatColors.accentDark,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                widget.isVoice ? Icons.mic : Icons.music_note,
                size: 18,
                color: ChatColors.textMuted,
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusLine(MediaStatus status, Duration pos) {
    if (status.state == MediaState.downloading) {
      return 'جارٍ التنزيل… ${status.progress.toStringAsFixed(0)}%';
    }
    if (status.state == MediaState.failed) {
      return status.error ?? 'تعذّر التنزيل';
    }
    if (!status.isReady) {
      final size = widget.attachment.size;
      return size > 0 ? 'اضغط للتنزيل • ${formatBytes(size)}' : 'اضغط للتنزيل';
    }
    return _dur > Duration.zero ? '${_fmt(pos)} / ${_fmt(_dur)}' : _fmt(pos);
  }

  Widget _actionButton(MediaStatus status) {
    final downloading = status.state == MediaState.downloading;
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _toggle(status),
      child: Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          color: ChatColors.accentDark,
          shape: BoxShape.circle,
        ),
        child: downloading
            ? Padding(
                padding: const EdgeInsets.all(9),
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                  value: status.progress > 0 ? status.progress / 100 : null,
                ),
              )
            : Icon(
                !status.isReady
                    ? Icons.download
                    : (_playing ? Icons.pause : Icons.play_arrow),
                color: Colors.white,
              ),
      ),
    );
  }
}

/// عارض صورة بملء الشاشة من ملفّ محلّي.
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.file, required this.name});

  final File file;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, style: const TextStyle(fontSize: 14)),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.file(
            file,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.broken_image, color: Colors.white54, size: 60),
          ),
        ),
      ),
    );
  }
}

/// صفحة تشغيل فيديو بملء الشاشة — من ملفّ محلّي (يعمل دون إنترنت).
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.file, required this.name});

  final File file;
  final String name;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final VideoPlayerController _controller;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // إيقاف أيّ صوت جارٍ قبل تشغيل الفيديو.
    SharedAudioPlayer.instance.stop();
    _controller = VideoPlayerController.file(widget.file)
      ..initialize()
          .then((_) {
            if (!mounted) return;
            setState(() => _ready = true);
            _controller.play();
          })
          .catchError((e) {
            if (mounted) setState(() => _error = 'تعذّر تشغيل الفيديو: $e');
          });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.name, style: const TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            tooltip: 'فتح بتطبيق آخر',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => OpenFilex.open(widget.file.path),
          ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              )
            : !_ready
            ? const CircularProgressIndicator()
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio == 0
                          ? 16 / 9
                          : _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                  VideoProgressIndicator(
                    _controller,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: ChatColors.accent,
                      bufferedColor: Colors.white24,
                      backgroundColor: Colors.white10,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          iconSize: 34,
                          color: Colors.white,
                          icon: const Icon(Icons.replay_10),
                          onPressed: () async {
                            final p =
                                await _controller.position ?? Duration.zero;
                            _controller.seekTo(p - const Duration(seconds: 10));
                          },
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          iconSize: 48,
                          color: Colors.white,
                          icon: Icon(
                            _controller.value.isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                          ),
                          onPressed: () {
                            setState(() {
                              _controller.value.isPlaying
                                  ? _controller.pause()
                                  : _controller.play();
                            });
                          },
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          iconSize: 34,
                          color: Colors.white,
                          icon: const Icon(Icons.forward_10),
                          onPressed: () async {
                            final p =
                                await _controller.position ?? Duration.zero;
                            _controller.seekTo(p + const Duration(seconds: 10));
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// غلاف تنزيل موحَّد للصور/الفيديو/الملفّات: يعرض المحتوى إن كان منزَّلاً،
/// وإلّا زرّ تنزيل دائريّ فوق معاينة رماديّة — تماماً كواتساب.
class MediaDownloadOverlay extends StatelessWidget {
  const MediaDownloadOverlay({
    super.key,
    required this.attachment,
    required this.status,
    this.compact = false,
  });

  final ChatAttachment attachment;
  final MediaStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final store = ChatMediaStore.instance;
    final downloading = status.state == MediaState.downloading;
    final failed = status.state == MediaState.failed;
    return InkWell(
      onTap: downloading ? null : () => store.download(attachment),
      child: Container(
        width: compact ? 56 : 220,
        height: compact ? 56 : 150,
        decoration: BoxDecoration(
          color: ChatColors.surfaceAlt,
          borderRadius: BorderRadius.circular(compact ? 10 : 12),
          border: Border.all(color: ChatColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: compact ? 32 : 44,
              height: compact ? 32 : 44,
              decoration: BoxDecoration(
                color: failed ? ChatColors.rose : ChatColors.accentDark,
                shape: BoxShape.circle,
              ),
              child: downloading
                  ? Padding(
                      padding: const EdgeInsets.all(9),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                        value: status.progress > 0
                            ? status.progress / 100
                            : null,
                      ),
                    )
                  : Icon(
                      failed ? Icons.refresh : Icons.download,
                      color: Colors.white,
                      size: compact ? 18 : 24,
                    ),
            ),
            if (!compact) ...[
              const SizedBox(height: 8),
              Text(
                downloading
                    ? '${status.progress.toStringAsFixed(0)}%'
                    : failed
                    ? (status.error ?? 'تعذّر التنزيل — أعد المحاولة')
                    : attachment.size > 0
                    ? 'اضغط للتنزيل • ${formatBytes(attachment.size)}'
                    : 'اضغط للتنزيل',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: failed ? ChatColors.rose : ChatColors.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
