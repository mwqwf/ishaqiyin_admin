import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../services/chat_repository.dart';
import '../../services/dm_repository.dart';
import 'chat_media.dart';
import 'chat_ui.dart';
import 'message_bubble.dart';

/// يفتح محادثة خاصّة مع عضو (وينشئها إن لم تكن موجودة).
/// [quotedFromGroup] يمرَّر عند «الردّ بشكل خاص» على رسالة من المجموعة.
Future<void> openDm(
  BuildContext context,
  String otherUid,
  String otherName, {
  ChatReplyRef? quotedFromGroup,
}) async {
  final threadId = await DmRepository.instance.ensureThread(otherUid);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DmScreen(
        threadId: threadId,
        otherUid: otherUid,
        otherName: otherName,
        quotedFromGroup: quotedFromGroup,
      ),
    ),
  );
}

/// 💬 محادثة خاصّة بين مشرفَين — بنفس مزايا المجموعة: نصّ/صور/فيديو/صوت/
/// رسائل صوتيّة/ملفّات، ردود، تفاعلات، حضور، «يكتب…»، وعلامة قراءة ✓✓،
/// والوسائط تُنزَّل أوّلاً ثم تُشغَّل محليّاً (نمط واتساب).
class DmScreen extends StatefulWidget {
  const DmScreen({
    super.key,
    required this.threadId,
    required this.otherUid,
    required this.otherName,
    this.quotedFromGroup,
  });

  final String threadId;
  final String otherUid;
  final String otherName;
  final ChatReplyRef? quotedFromGroup;

  /// هل شاشة محادثة خاصّة مفتوحة الآن؟ (لكتم الإشعار المحلّي أثناء العرض)
  static String openThreadId = '';

  @override
  State<DmScreen> createState() => _DmScreenState();
}

class _DmScreenState extends State<DmScreen> {
  final _repo = DmRepository.instance;
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();

  int _limit = 60;
  ChatReplyRef? _replyTo;
  ChatReplyRef? _quotedFromGroup;
  bool _sending = false;

  bool _uploading = false;
  double _uploadPct = 0;
  String _uploadName = '';
  bool _uploadAborted = false;

  bool _recording = false;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;
  String? _recordPath;

  Timer? _presenceTimer;
  int _lastTypingSentMs = 0;
  int _lastReadMarkMs = 0;

  String get _myUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    DmScreen.openThreadId = widget.threadId;
    _quotedFromGroup = widget.quotedFromGroup;
    _repo.markRead(widget.threadId);
    ChatRepository.instance.presenceTick();
    _presenceTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => ChatRepository.instance.presenceTick(),
    );
    _scrollCtrl.addListener(() {
      if (_scrollCtrl.position.pixels >
          _scrollCtrl.position.maxScrollExtent - 300) {
        if (mounted && _limit < 2000) setState(() => _limit += 60);
      }
    });
  }

  @override
  void dispose() {
    DmScreen.openThreadId = '';
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _recordTimer?.cancel();
    _presenceTimer?.cancel();
    _recorder.dispose();
    SharedAudioPlayer.instance.stop();
    super.dispose();
  }

  // ─── الإرسال ─────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final reply = _replyTo;
      final quoted = _quotedFromGroup;
      _textCtrl.clear();
      setState(() {
        _replyTo = null;
        _quotedFromGroup = null;
      });
      await _repo.sendText(
        threadId: widget.threadId,
        otherUid: widget.otherUid,
        text: text,
        replyTo: reply,
        fromGroup: quoted,
      );
    } catch (e) {
      if (mounted) showChatSnack(context, 'تعذّر الإرسال: $e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onTextChanged(String v) {
    if (v.trim().isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTypingSentMs > 3000) {
      _lastTypingSentMs = now;
      _repo.typingTick(widget.threadId);
    }
  }

  Future<void> _pickAndSend(FileType type) async {
    final res = await FilePicker.platform.pickFiles(
      type: type,
      withData: false,
    );
    final f = res?.files.firstOrNull;
    final path = f?.path;
    if (f == null || path == null || !mounted) return;
    final contentType = guessContentType(f.name);
    await _uploadAndSend(
      filePath: path,
      filename: f.name,
      contentType: contentType,
      type: chatTypeForMime(contentType),
    );
  }

  Future<void> _uploadAndSend({
    required String filePath,
    required String filename,
    required String contentType,
    required ChatMessageType type,
    String caption = '',
    int? durationMs,
    bool deleteAfter = false,
  }) async {
    final reply = _replyTo;
    setState(() {
      _uploading = true;
      _uploadPct = 0;
      _uploadName = filename;
      _uploadAborted = false;
      _replyTo = null;
    });
    try {
      await _repo.sendAttachmentFromPath(
        threadId: widget.threadId,
        otherUid: widget.otherUid,
        filePath: filePath,
        filename: filename,
        contentType: contentType,
        type: type,
        caption: caption,
        durationMs: durationMs,
        replyTo: reply,
        onProgress: (pct) {
          if (mounted) setState(() => _uploadPct = pct);
        },
        isAborted: () => _uploadAborted,
      );
    } catch (e) {
      if (mounted && !_uploadAborted) {
        showChatSnack(context, 'فشل رفع "$filename": $e', error: true);
      }
    } finally {
      if (deleteAfter) {
        try {
          await File(filePath).delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ─── التسجيل الصوتي ──────────────────────────────────────

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          showChatSnack(context, 'يلزم إذن الميكروفون.', error: true);
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/dm_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _recordElapsed += const Duration(seconds: 1));
        }
      });
      setState(() {
        _recording = true;
        _recordElapsed = Duration.zero;
        _recordPath = path;
      });
    } catch (e) {
      if (mounted) showChatSnack(context, 'تعذّر بدء التسجيل: $e', error: true);
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    _recordTimer?.cancel();
    final elapsed = _recordElapsed;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {}
    path ??= _recordPath;
    setState(() {
      _recording = false;
      _recordElapsed = Duration.zero;
    });
    if (!send) {
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      return;
    }
    if (path == null || elapsed.inSeconds < 1) {
      if (mounted) showChatSnack(context, 'التسجيل قصير جدّاً.', error: true);
      return;
    }
    final name =
        'رسالة صوتيّة ${intl.DateFormat('yyyy-MM-dd HH-mm-ss').format(DateTime.now())}.m4a';
    await _uploadAndSend(
      filePath: path,
      filename: name,
      contentType: 'audio/mp4',
      type: ChatMessageType.voice,
      durationMs: elapsed.inMilliseconds,
      deleteAfter: true,
    );
  }

  // ─── إجراءات الرسالة ─────────────────────────────────────

  Future<void> _showMessageActions(ChatMessage msg) async {
    final myReaction = msg.reactions[_myUid];
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ChatColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!msg.deleted)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final e in kQuickReactions)
                        InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () => Navigator.pop(context, 'react:$e'),
                          child: Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: myReaction == e
                                  ? ChatColors.highlight
                                  : Colors.transparent,
                            ),
                            child: Text(
                              e,
                              style: const TextStyle(fontSize: 26),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (!msg.deleted) const Divider(height: 14),
              if (!msg.deleted)
                ListTile(
                  leading: const Icon(Icons.reply, color: ChatColors.accent),
                  title: const Text('ردّ'),
                  onTap: () => Navigator.pop(context, 'reply'),
                ),
              if (!msg.deleted && msg.text.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy, color: ChatColors.textMuted),
                  title: const Text('نسخ النصّ'),
                  onTap: () => Navigator.pop(context, 'copy'),
                ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: ChatColors.amber,
                ),
                title: const Text('حذف عندي فقط'),
                onTap: () => Navigator.pop(context, 'delete_me'),
              ),
              if (msg.isMine && !msg.deleted)
                ListTile(
                  leading: const Icon(
                    Icons.delete_forever,
                    color: ChatColors.rose,
                  ),
                  title: const Text(
                    'حذف عند الطرفين',
                    style: TextStyle(color: ChatColors.rose),
                  ),
                  onTap: () => Navigator.pop(context, 'delete_all'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;

    if (action.startsWith('react:')) {
      final e = action.substring('react:'.length);
      await _repo.setReaction(
        widget.threadId,
        msg.id,
        msg.reactions[_myUid] == e ? null : e,
      );
      return;
    }
    switch (action) {
      case 'reply':
        setState(() => _replyTo = msg.asRef());
      case 'copy':
        await Clipboard.setData(ClipboardData(text: msg.text));
        if (mounted) showChatSnack(context, 'نُسخ النصّ.');
      case 'delete_me':
        await _repo.deleteForMe(widget.threadId, msg.id);
      case 'delete_all':
        await _repo.deleteForEveryone(widget.threadId, msg);
    }
  }

  // ─── البناء ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ChatColors.bg,
      body: SafeArea(
        child: StreamBuilder<List<ChatMember>>(
          stream: ChatRepository.instance.membersStream(),
          builder: (context, memSnap) {
            final members = {
              for (final m in memSnap.data ?? const <ChatMember>[]) m.uid: m,
            };
            final other = members[widget.otherUid];
            return Column(
              children: [
                _header(other),
                Expanded(child: _messagesList(members)),
                if (_uploading) _uploadBanner(),
                if (_quotedFromGroup != null) _quotedGroupBanner(),
                if (_replyTo != null) _replyBanner(),
                _inputBar(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(ChatMember? other) {
    return Material(
      color: ChatColors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: 'رجوع',
              icon: const Icon(
                Icons.arrow_back,
                color: ChatColors.textMuted,
                size: 20,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            MemberAvatar(
              uid: widget.otherUid,
              name: other?.displayName ?? widget.otherName,
              photo: other?.displayPhoto ?? '',
              radius: 20,
              showOnline: true,
              online: other?.isOnline ?? false,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StreamBuilder<bool>(
                stream: _repo.otherTypingStream(
                  widget.threadId,
                  widget.otherUid,
                ),
                builder: (context, typingSnap) {
                  final typing = typingSnap.data ?? false;
                  final online = other?.isOnline ?? false;
                  final lastSeen = other?.lastSeenAt;
                  final subtitle = typing
                      ? 'يكتب الآن…'
                      : online
                      ? 'متصل الآن'
                      : lastSeen != null
                      ? 'آخر ظهور: ${intl.DateFormat('yyyy-MM-dd HH:mm').format(lastSeen)}'
                      : 'محادثة خاصّة';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              other?.displayName ?? widget.otherName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14.5,
                              ),
                            ),
                          ),
                          if (other?.isOwner ?? false)
                            const Padding(
                              padding: EdgeInsetsDirectional.only(start: 5),
                              child: Text('👑', style: TextStyle(fontSize: 12)),
                            ),
                        ],
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: typing
                              ? ChatColors.accent
                              : online
                              ? ChatColors.online
                              : ChatColors.textMuted,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.lock, size: 15, color: ChatColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messagesList(Map<String, ChatMember> members) {
    return StreamBuilder<List<ChatMessage>>(
      stream: _repo.messagesStream(widget.threadId, limit: _limit),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'تعذّر تحميل الرسائل.\n${snap.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: ChatColors.rose, fontSize: 12),
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final msgs = snap.data!;
        final newestMs = msgs.isEmpty ? 0 : msgs.first.sentAtMs;
        if (newestMs > _lastReadMarkMs) {
          _lastReadMarkMs = newestMs;
          _repo.markRead(widget.threadId);
        }
        if (msgs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 44,
                    color: ChatColors.textMuted,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'محادثة خاصّة مع ${widget.otherName}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'لا يراها بقيّة المشرفين ولا المجموعة.',
                    style: TextStyle(
                      fontSize: 12,
                      color: ChatColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return StreamBuilder<DmThread?>(
          stream: _repo.threadStream(widget.threadId),
          builder: (context, threadSnap) {
            final otherRead =
                threadSnap.data?.readAtMs[widget.otherUid] ?? 0;
            return ListView.builder(
              controller: _scrollCtrl,
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 10),
              itemCount: msgs.length,
              itemBuilder: (context, i) {
                final msg = msgs[i];
                final older = i + 1 < msgs.length ? msgs[i + 1] : null;
                final showDateChip =
                    older == null || !_sameDay(older.createdAt, msg.createdAt);
                return Column(
                  children: [
                    if (showDateChip) _dateChip(msg.createdAt),
                    MessageBubble(
                      // محادثة ثنائيّة: لا حاجة لاسم المرسِل فوق كلّ سلسلة.
                      msg: msg,
                      showSenderHeader: false,
                      members: members,
                      readByAll: otherRead >= msg.sentAtMs,
                      onLongPress: _showMessageActions,
                      onReplyTap: (_) {},
                      onReactionsTap: (_) {},
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _dateChip(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final label = day == today
        ? 'اليوم'
        : day == today.subtract(const Duration(days: 1))
        ? 'أمس'
        : intl.DateFormat('yyyy/MM/dd').format(d);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: ChatColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, color: ChatColors.textMuted),
        ),
      ),
    );
  }

  Widget _uploadBanner() {
    return Container(
      color: ChatColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'جارٍ رفع: $_uploadName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: _uploadPct > 0 ? _uploadPct / 100 : null,
                  minHeight: 3,
                  color: ChatColors.accent,
                  backgroundColor: ChatColors.border,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: ChatColors.rose),
            onPressed: () => setState(() => _uploadAborted = true),
          ),
        ],
      ),
    );
  }

  /// شريط الاقتباس من المجموعة عند «الردّ بشكل خاص» (نمط واتساب).
  Widget _quotedGroupBanner() {
    final q = _quotedFromGroup!;
    return Container(
      color: ChatColors.highlight,
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.groups, size: 16, color: ChatColors.accentDark),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ردّ خاصّ على رسالة ${q.senderName} في المجموعة',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: ChatColors.accentDark,
                  ),
                ),
                Text(
                  q.preview.isEmpty ? chatTypeLabel(q.type) : q.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: ChatColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.close,
              size: 18,
              color: ChatColors.textMuted,
            ),
            onPressed: () => setState(() => _quotedFromGroup = null),
          ),
        ],
      ),
    );
  }

  Widget _replyBanner() {
    final r = _replyTo!;
    return Container(
      color: ChatColors.surface,
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Container(width: 3, height: 34, color: senderColor(r.senderId)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ردّ على ${r.senderName}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: senderColor(r.senderId),
                  ),
                ),
                Text(
                  r.preview.isEmpty ? chatTypeLabel(r.type) : r.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: ChatColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.close,
              size: 18,
              color: ChatColors.textMuted,
            ),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _inputBar() {
    if (_recording) return _recordingBar();
    return Container(
      color: ChatColors.surface,
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file, color: ChatColors.textMuted),
              onPressed: _uploading ? null : _showAttachMenu,
              tooltip: 'إرفاق',
            ),
            Expanded(
              child: TextField(
                controller: _textCtrl,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'رسالة خاصّة…',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
                onChanged: _onTextChanged,
              ),
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _textCtrl,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                return FloatingActionButton.small(
                  heroTag: 'dm_send',
                  backgroundColor: ChatColors.accentDark,
                  onPressed: _sending
                      ? null
                      : hasText
                      ? _sendText
                      : _startRecording,
                  child: Icon(
                    hasText ? Icons.send : Icons.mic,
                    color: Colors.white,
                    size: 20,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _recordingBar() {
    final m = _recordElapsed.inMinutes.toString().padLeft(2, '0');
    final s = _recordElapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Container(
      color: ChatColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.delete, color: ChatColors.rose),
              onPressed: () => _stopRecording(send: false),
            ),
            const Icon(
              Icons.fiber_manual_record,
              color: ChatColors.rose,
              size: 14,
            ),
            const SizedBox(width: 8),
            Text(
              '$m:$s',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: 12),
                child: Text(
                  'جارٍ التسجيل…',
                  style: TextStyle(color: ChatColors.textMuted, fontSize: 12),
                ),
              ),
            ),
            FloatingActionButton.small(
              heroTag: 'dm_send_voice',
              backgroundColor: ChatColors.accentDark,
              onPressed: () => _stopRecording(send: true),
              child: const Icon(Icons.send, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  void _showAttachMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ChatColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _attachOption(Icons.image, 'صورة', ChatColors.accent, () {
                  Navigator.pop(context);
                  _pickAndSend(FileType.image);
                }),
                _attachOption(Icons.videocam, 'فيديو', ChatColors.amber, () {
                  Navigator.pop(context);
                  _pickAndSend(FileType.video);
                }),
                _attachOption(
                  Icons.music_note,
                  'صوت',
                  const Color(0xFF2563EB),
                  () {
                    Navigator.pop(context);
                    _pickAndSend(FileType.audio);
                  },
                ),
                _attachOption(
                  Icons.insert_drive_file,
                  'ملفّ',
                  const Color(0xFF7C3AED),
                  () {
                    Navigator.pop(context);
                    _pickAndSend(FileType.any);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _attachOption(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: ChatColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
