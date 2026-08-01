import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/chat_repository.dart';
import '../../services/chat_notifications.dart';
import '../../services/dm_repository.dart';
import 'chat_media.dart';
import 'chat_ui.dart';
import 'dm_list_screen.dart';
import 'dm_screen.dart';
import 'group_info_page.dart';
import 'message_bubble.dart';

/// دردشة إدارة منبر ادكصهك الجماعيّة — بنمط واتساب، على Firestore (زمن
/// حقيقي) و Storage للمرفقات. العضويّة تلقائيّة، والمجموعة خاصّة بتطبيق
/// الإدارة — لا يراها تطبيق منبر العامّ إطلاقاً.
///
/// الميزات (منقولة من لوحة نبراس بالكامل): نصّ/صور/فيديو/صوت/رسائل
/// صوتيّة/ملفّات ضخمة، ردود، تفاعلات إيموجي، حضور مباشر (متصل الآن)،
/// «يكتب…»، علامات قراءة ✓✓، تثبيت وقفل (المالك 👑)، مشرف مجموعة ⭐،
/// حذف عندي/عند الجميع، صور شخصيّة وصورة مجموعة.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.isOwner});

  final bool isOwner;

  /// هل شاشة الدردشة معروضة الآن؟ تفحصها خدمة الإشعارات كي لا تعرض
  /// إشعاراً محليّاً والمستخدم يرى الرسائل أمامه.
  static bool isOpen = false;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _repo = ChatRepository.instance;
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();

  int _limit = 60;
  ChatReplyRef? _replyTo;
  bool _sending = false;

  // حالة الرفع الجاري.
  bool _uploading = false;
  double _uploadPct = 0;
  String _uploadName = '';
  bool _uploadAborted = false;

  // حالة التسجيل الصوتي.
  bool _recording = false;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;
  String? _recordPath;

  // الحضور والقراءة والكتابة.
  Timer? _presenceTimer;
  Timer? _typingRefresh; // لإعادة رسم مؤشّر «يكتب…» والحضور دوريّاً.
  int _lastTypingSentMs = 0;
  int _lastReadMarkMs = 0;

  // زرّ النزول للأسفل.
  bool _showJumpDown = false;

  /// مفاتيح الرسائل المعروضة — للقفز إلى الرسالة الأصليّة عند نقر الاقتباس.
  final Map<String, GlobalKey> _msgKeys = {};

  /// الرسالة المُبرَزة مؤقّتاً بعد القفز إليها (وميض مثل واتساب).
  String _highlightedId = '';
  Timer? _highlightTimer;

  /// بحث داخل الرسائل المحمَّلة.
  bool _searching = false;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  String get _myUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    ChatScreen.isOpen = true;
    ChatNotifications.isChatOpen = true;
    // الانضمام التلقائي + أوّل نبضة حضور وقراءة.
    _repo.upsertSelf(role: widget.isOwner ? 'owner' : 'supervisor');
    _repo.presenceTick();
    _repo.markRead();
    _presenceTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => _repo.presenceTick(),
    );
    // إعادة رسم دوريّة خفيفة كي تنطفئ مؤشّرات «متصل/يكتب…» المنتهية.
    _typingRefresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
    _scrollCtrl.addListener(() {
      // ListView معكوس: نهاية التمرير = أقدم الرسائل → حمّل المزيد.
      if (_scrollCtrl.position.pixels >
          _scrollCtrl.position.maxScrollExtent - 300) {
        if (mounted && _limit < 2000) setState(() => _limit += 60);
      }
      final show = _scrollCtrl.position.pixels > 500;
      if (show != _showJumpDown && mounted) {
        setState(() => _showJumpDown = show);
      }
    });
  }

  @override
  void dispose() {
    ChatScreen.isOpen = false;
    ChatNotifications.isChatOpen = false;
    _textCtrl.dispose();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _recordTimer?.cancel();
    _presenceTimer?.cancel();
    _typingRefresh?.cancel();
    _highlightTimer?.cancel();
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
      _textCtrl.clear();
      setState(() => _replyTo = null);
      await _repo.sendText(text, replyTo: reply);
      _repo.markRead();
      // إشعار بقيّة الأعضاء تتكفّل به دالة السحابة onChatMessageCreated.
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
      _repo.typingTick();
    }
  }

  Future<void> _pickAndSend(FileType type, {List<String>? extensions}) async {
    final res = await FilePicker.platform.pickFiles(
      type: extensions != null ? FileType.custom : type,
      allowedExtensions: extensions,
      withData: false, // مسار فقط — البثّ من القرص يدعم الملفّات الضخمة.
    );
    final f = res?.files.firstOrNull;
    final path = f?.path;
    if (f == null || path == null || !mounted) return;

    final contentType = guessContentType(f.name);
    final msgType = chatTypeForMime(contentType);
    final caption = await _askCaption(f.name, f.size, msgType);
    if (caption == null) return; // ألغى.

    await _uploadAndSend(
      filePath: path,
      filename: f.name,
      contentType: contentType,
      type: msgType,
      caption: caption,
    );
  }

  /// حوار تأكيد الإرسال مع تعليق اختياري (مثل واتساب).
  Future<String?> _askCaption(String name, int size, ChatMessageType t) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('إرسال ${chatTypeLabel(t)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$name${size > 0 ? ' • ${formatBytes(size)}' : ''}',
                style: const TextStyle(
                  fontSize: 12,
                  color: ChatColors.textMuted,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  hintText: 'أضف تعليقاً (اختياري)…',
                ),
                maxLines: 3,
                minLines: 1,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.send, size: 16),
              label: const Text('إرسال'),
            ),
          ],
        ),
      ),
    );
    final caption = ctrl.text;
    ctrl.dispose();
    return ok == true ? caption : null;
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
      _repo.markRead();
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
          showChatSnack(
            context,
            'يلزم إذن الميكروفون لتسجيل رسالة صوتيّة.',
            error: true,
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
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
      if (mounted) {
        showChatSnack(context, 'التسجيل قصير جدّاً.', error: true);
      }
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

  // ─── التفاعلات ───────────────────────────────────────────

  Future<void> _react(ChatMessage msg, String emoji) async {
    try {
      // اختيار نفس الإيموجي مجدّداً يزيله (مثل واتساب).
      final current = msg.reactions[_myUid];
      await _repo.setReaction(msg.id, current == emoji ? null : emoji);
    } catch (e) {
      if (mounted) showChatSnack(context, 'تعذّر التفاعل: $e', error: true);
    }
  }

  /// لوحة إيموجي موسَّعة.
  Future<String?> _pickEmoji() {
    const emojis = [
      '👍',
      '👎',
      '❤️',
      '💚',
      '💙',
      '🤍',
      '💔',
      '❣️',
      '😂',
      '🤣',
      '😊',
      '😍',
      '🥰',
      '😘',
      '😉',
      '😎',
      '😮',
      '😱',
      '🤯',
      '😳',
      '🥺',
      '😢',
      '😭',
      '😤',
      '😡',
      '🤬',
      '😴',
      '🤔',
      '🤨',
      '🙄',
      '😬',
      '🤐',
      '🙏',
      '👏',
      '🤝',
      '💪',
      '✌️',
      '🤞',
      '👌',
      '🫡',
      '🔥',
      '⭐',
      '🌟',
      '✨',
      '⚡',
      '💯',
      '✅',
      '❌',
      '🎉',
      '🎊',
      '🏆',
      '🥇',
      '🎯',
      '📌',
      '📚',
      '📖',
      '☝️',
      '🖐️',
      '🫶',
      '🌹',
      '🌸',
      '☀️',
      '🌙',
      '☕',
    ];
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: ChatColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: GridView.count(
              shrinkWrap: true,
              crossAxisCount: 8,
              children: [
                for (final e in emojis)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.pop(context, e),
                    child: Center(
                      child: Text(e, style: const TextStyle(fontSize: 24)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// من تفاعل على الرسالة (مع إزالة تفاعلي بنقرة).
  void _showReactions(ChatMessage msg, Map<String, ChatMember> members) {
    showModalBottomSheet<void>(
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
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'التفاعلات',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in msg.reactions.entries)
                      ListTile(
                        leading: MemberAvatar(
                          uid: entry.key,
                          name: members[entry.key]?.displayName ?? 'عضو',
                          photo: members[entry.key]?.displayPhoto ?? '',
                          radius: 17,
                        ),
                        title: Text(
                          entry.key == _myUid
                              ? '${members[entry.key]?.displayName ?? 'أنا'} (أنا)'
                              : members[entry.key]?.displayName ?? 'عضو سابق',
                          style: const TextStyle(fontSize: 13.5),
                        ),
                        subtitle: entry.key == _myUid
                            ? const Text(
                                'اضغط للإزالة',
                                style: TextStyle(fontSize: 10.5),
                              )
                            : null,
                        trailing: Text(
                          entry.value,
                          style: const TextStyle(fontSize: 22),
                        ),
                        onTap: entry.key == _myUid
                            ? () {
                                Navigator.pop(context);
                                _react(msg, entry.value); // toggle → إزالة.
                              }
                            : null,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ─── إجراءات الرسالة (ضغطة مطوّلة) ───────────────────────

  Future<void> _showMessageActions(
    ChatMessage msg,
    Map<String, ChatMember> members,
  ) async {
    // صلاحيّات الإشراف داخل المجموعة: المالك 👑 أو مشرف المجموعة ⭐
    // (الأخير صلاحيّاته محصورة في الدردشة فقط، لا تمسّ التطبيق).
    final canModerate =
        widget.isOwner || (members[_myUid]?.isChatModerator ?? false);
    final canDeleteForAll = !msg.deleted && (msg.isMine || canModerate);
    final modBadge = widget.isOwner ? '👑' : '⭐';
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
              // شريط التفاعلات السريعة (مثل واتساب).
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
                      InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => Navigator.pop(context, 'react_more'),
                        child: Container(
                          padding: const EdgeInsets.all(9),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: ChatColors.surfaceAlt,
                          ),
                          child: const Icon(
                            Icons.add,
                            size: 22,
                            color: ChatColors.textMuted,
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
              // ردّ بشكل خاصّ: يفتح محادثة فرديّة مع المرسِل مع اقتباس
              // رسالته من المجموعة (نمط واتساب تماماً).
              if (!msg.deleted && !msg.isMine && msg.senderId != 'system')
                ListTile(
                  leading: const Icon(
                    Icons.forward_to_inbox,
                    color: ChatColors.accentDark,
                  ),
                  title: const Text('ردّ بشكل خاص'),
                  subtitle: Text(
                    'محادثة فرديّة مع ${members[msg.senderId]?.displayName ?? msg.senderName}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => Navigator.pop(context, 'reply_private'),
                ),
              if (!msg.deleted && msg.text.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy, color: ChatColors.textMuted),
                  title: const Text('نسخ النصّ'),
                  onTap: () => Navigator.pop(context, 'copy'),
                ),
              if (!msg.deleted && canModerate)
                ListTile(
                  leading: const Icon(Icons.push_pin, color: ChatColors.amber),
                  title: Text('تثبيت الرسالة $modBadge'),
                  onTap: () => Navigator.pop(context, 'pin'),
                ),
              if (msg.isMine && !msg.pending)
                ListTile(
                  leading: const Icon(
                    Icons.info_outline,
                    color: ChatColors.textMuted,
                  ),
                  title: const Text('معلومات الرسالة'),
                  onTap: () => Navigator.pop(context, 'info'),
                ),
              if (!msg.deleted && msg.attachment != null)
                ListTile(
                  leading: const Icon(
                    Icons.download,
                    color: ChatColors.textMuted,
                  ),
                  title: const Text('فتح / تنزيل المرفق'),
                  onTap: () => Navigator.pop(context, 'open'),
                ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: ChatColors.amber,
                ),
                title: const Text('حذف عندي فقط'),
                onTap: () => Navigator.pop(context, 'delete_me'),
              ),
              if (canDeleteForAll)
                ListTile(
                  leading: const Icon(
                    Icons.delete_forever,
                    color: ChatColors.rose,
                  ),
                  title: Text(
                    msg.isMine ? 'حذف عند الجميع' : 'حذف عند الجميع $modBadge',
                    style: const TextStyle(color: ChatColors.rose),
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
      await _react(msg, action.substring('react:'.length));
      return;
    }

    switch (action) {
      case 'react_more':
        final emoji = await _pickEmoji();
        if (emoji != null) await _react(msg, emoji);
      case 'reply':
        setState(() => _replyTo = msg.asRef());
      case 'reply_private':
        await openDm(
          context,
          msg.senderId,
          members[msg.senderId]?.displayName ?? msg.senderName,
          quotedFromGroup: msg.asRef(),
        );
      case 'copy':
        await Clipboard.setData(ClipboardData(text: msg.text));
        if (mounted) showChatSnack(context, 'نُسخ النصّ.');
      case 'pin':
        try {
          await _repo.setPinned(msg.asRef());
          if (mounted) showChatSnack(context, 'ثُبّتت الرسالة.');
        } catch (e) {
          if (mounted) showChatSnack(context, 'تعذّر التثبيت: $e', error: true);
        }
      case 'info':
        _showMessageInfo(msg, members);
      case 'open':
        final url = msg.attachment?.url;
        if (url != null) {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        }
      case 'delete_me':
        try {
          await _repo.deleteForMe(msg.id);
        } catch (e) {
          if (mounted) showChatSnack(context, 'تعذّر الحذف: $e', error: true);
        }
      case 'delete_all':
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('حذف عند الجميع'),
              content: const Text(
                'ستُحذف هذه الرسالة عند جميع الأعضاء ولا يمكن التراجع. متابعة؟',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ChatColors.rose,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('حذف'),
                ),
              ],
            ),
          ),
        );
        if (ok == true) {
          try {
            await _repo.deleteForEveryone(msg);
          } catch (e) {
            if (mounted) showChatSnack(context, 'تعذّر الحذف: $e', error: true);
          }
        }
    }
  }

  /// معلومات رسالتي: وقت الإرسال الكامل ومن قرأها.
  void _showMessageInfo(ChatMessage msg, Map<String, ChatMember> members) {
    final others = members.values.where((m) => m.uid != msg.senderId).toList();
    final readers = others
        .where((m) => m.lastReadAtMs >= msg.sentAtMs)
        .toList();
    final pending = others.where((m) => m.lastReadAtMs < msg.sentAtMs).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ChatColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'معلومات الرسالة',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.schedule,
                    size: 16,
                    color: ChatColors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'أُرسلت: ${intl.DateFormat('yyyy-MM-dd HH:mm:ss').format(msg.createdAt)}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(
                    Icons.done_all,
                    size: 16,
                    color: ChatColors.readBlue,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'قرأها (${readers.length})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (readers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'لم يقرأها أحد بعد.',
                    style: TextStyle(fontSize: 12, color: ChatColors.textMuted),
                  ),
                ),
              for (final m in readers) _readerTile(m),
              if (pending.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.done,
                      size: 16,
                      color: ChatColors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'لم يقرأها بعد (${pending.length})',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                for (final m in pending) _readerTile(m),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _readerTile(ChatMember m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          MemberAvatar(
            uid: m.uid,
            name: m.displayName,
            photo: m.displayPhoto,
            radius: 13,
          ),
          const SizedBox(width: 8),
          Text(m.displayName, style: const TextStyle(fontSize: 12.5)),
          if (m.isOwner)
            const Padding(
              padding: EdgeInsetsDirectional.only(start: 4),
              child: Text('👑', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  /// القفز إلى الرسالة الأصليّة عند نقر الاقتباس (نمط واتساب): تمرير سلس
  /// إليها ثم إبرازها لحظيّاً. إن لم تكن محمَّلة بعد نوسّع النافذة تدريجيّاً.
  Future<void> _jumpToMessage(ChatReplyRef r) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final key = _msgKeys[r.messageId];
      final ctx = key?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOut,
          alignment: 0.35,
        );
        if (!mounted) return;
        setState(() => _highlightedId = r.messageId);
        _highlightTimer?.cancel();
        _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
          if (mounted) setState(() => _highlightedId = '');
        });
        return;
      }
      // غير محمَّلة بعد — وسّع النافذة وانتظر إعادة البناء.
      if (_limit >= 2000) break;
      if (!mounted) return;
      setState(() => _limit += 200);
      await Future<void>.delayed(const Duration(milliseconds: 320));
    }
    if (mounted) {
      showChatSnack(context, 'الرسالة الأصليّة أقدم من المحمَّل حاليّاً.');
    }
  }

  // ─── قائمة الإرفاق ───────────────────────────────────────

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

  // ─── البناء ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isOwner = widget.isOwner;
    return Scaffold(
      backgroundColor: ChatColors.bg,
      body: SafeArea(
        child: StreamBuilder<ChatGroupMeta>(
          stream: _repo.metaStream(),
          builder: (context, metaSnap) {
            final meta = metaSnap.data ?? ChatGroupMeta.fallback;
            return StreamBuilder<List<ChatMember>>(
              stream: _repo.membersStream(),
              builder: (context, memSnap) {
                final membersList = memSnap.data ?? const <ChatMember>[];
                final members = {for (final m in membersList) m.uid: m};
                final canModerate =
                    isOwner || (members[_myUid]?.isChatModerator ?? false);
                return Column(
                  children: [
                    _groupHeader(meta, membersList, isOwner),
                    if (_searching) _searchBar(),
                    if (meta.pinned != null)
                      _pinnedBar(meta.pinned!, canModerate),
                    Expanded(
                      child: Stack(
                        children: [
                          _messagesList(members),
                          if (_showJumpDown)
                            PositionedDirectional(
                              bottom: 12,
                              start: 12,
                              child: FloatingActionButton.small(
                                heroTag: 'chat_jump_down',
                                backgroundColor: ChatColors.surfaceAlt,
                                onPressed: () => _scrollCtrl.animateTo(
                                  0,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOut,
                                ),
                                child: const Icon(
                                  Icons.keyboard_double_arrow_down,
                                  color: ChatColors.accent,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_uploading) _uploadBanner(),
                    if (_replyTo != null) _replyBanner(),
                    if (meta.locked && !isOwner) _lockedBar() else _inputBar(),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _groupHeader(
    ChatGroupMeta meta,
    List<ChatMember> members,
    bool isOwner,
  ) {
    final online = members.where((m) => m.isOnline).length;
    final typers = members
        .where((m) => m.uid != _myUid && m.isTyping)
        .map((m) => m.displayName)
        .toList();
    final String subtitle;
    final Color subtitleColor;
    if (typers.isNotEmpty) {
      subtitle = typers.length == 1
          ? '${typers.first} يكتب الآن…'
          : '${typers.take(2).join('، ')} يكتبون الآن…';
      subtitleColor = ChatColors.accent;
    } else if (members.isNotEmpty) {
      subtitle =
          '${members.length} عضو • $online متصل الآن${meta.locked ? ' • 🔒' : ''}';
      subtitleColor = online > 0 ? ChatColors.online : ChatColors.textMuted;
    } else {
      subtitle = 'خاصّة بمشرفي الإدارة';
      subtitleColor = ChatColors.textMuted;
    }

    return Material(
      color: ChatColors.surface,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => GroupInfoPage(isOwner: isOwner)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: meta.photoUrl.isEmpty
                      ? const LinearGradient(
                          colors: [ChatColors.accentDark, ChatColors.accent],
                        )
                      : null,
                  shape: BoxShape.circle,
                ),
                clipBehavior: Clip.antiAlias,
                child: meta.photoUrl.isEmpty
                    ? const Icon(Icons.groups, color: Colors.white, size: 22)
                    : CachedNetworkImage(
                        imageUrl: meta.photoUrl,
                        fit: BoxFit.cover,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: subtitleColor),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'بحث في الرسائل',
                icon: const Icon(
                  Icons.search,
                  size: 20,
                  color: ChatColors.textMuted,
                ),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) {
                    _searchCtrl.clear();
                    _searchQuery = '';
                  }
                }),
              ),
              StreamBuilder<int>(
                stream: DmRepository.instance.unreadThreadsStream(),
                builder: (context, snap) {
                  final n = snap.data ?? 0;
                  final btn = IconButton(
                    tooltip: 'الرسائل الخاصّة',
                    icon: const Icon(
                      Icons.forum_outlined,
                      size: 20,
                      color: ChatColors.textMuted,
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DmListScreen()),
                    ),
                  );
                  return n > 0 ? Badge.count(count: n, child: btn) : btn;
                },
              ),
              const Icon(
                Icons.info_outline,
                size: 18,
                color: ChatColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// شريط البحث داخل الرسائل المحمَّلة.
  Widget _searchBar() {
    return Container(
      color: ChatColors.surface,
      padding: const EdgeInsets.fromLTRB(14, 0, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.search, size: 18, color: ChatColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'ابحث في الرسائل…',
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.close,
              size: 18,
              color: ChatColors.textMuted,
            ),
            onPressed: () => setState(() {
              _searching = false;
              _searchCtrl.clear();
              _searchQuery = '';
            }),
          ),
        ],
      ),
    );
  }

  Widget _pinnedBar(ChatReplyRef pinned, bool canModerate) {
    return Material(
      color: ChatColors.highlight,
      child: InkWell(
        onTap: () => _jumpToMessage(pinned),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              const Icon(Icons.push_pin, size: 15, color: ChatColors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'رسالة مثبَّتة — ${pinned.senderName}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: ChatColors.amber,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      pinned.preview.isEmpty
                          ? chatTypeLabel(pinned.type)
                          : pinned.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (canModerate)
                InkWell(
                  onTap: () => _repo.setPinned(null),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: ChatColors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messagesList(Map<String, ChatMember> members) {
    return StreamBuilder<List<ChatMessage>>(
      stream: _repo.messagesStream(limit: _limit),
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
        final all = snap.data!;
        // تحديث مؤشّر قراءتي عند وصول رسائل أحدث (مقنَّن).
        final newestMs = all.isEmpty ? 0 : all.first.sentAtMs;
        if (newestMs > _lastReadMarkMs) {
          _lastReadMarkMs = newestMs;
          _repo.markRead();
        }
        // ترشيح البحث (داخل المحمَّل) — نمط واتساب.
        final q = _searchQuery.trim().toLowerCase();
        final msgs = q.isEmpty
            ? all
            : all
                  .where(
                    (m) =>
                        m.text.toLowerCase().contains(q) ||
                        (m.attachment?.name.toLowerCase().contains(q) ??
                            false) ||
                        m.senderName.toLowerCase().contains(q),
                  )
                  .toList();
        if (msgs.isEmpty) {
          return Center(
            child: Text(
              q.isEmpty
                  ? 'لا رسائل بعد — ابدأ النقاش!'
                  : 'لا نتائج لـ «$_searchQuery» ضمن المحمَّل.',
              style: const TextStyle(color: ChatColors.textMuted),
            ),
          );
        }
        return ListView.builder(
          controller: _scrollCtrl,
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 10),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final msg = msgs[i];
            // القائمة معكوسة: العنصر التالي (i+1) أقدم زمنيّاً.
            final older = i + 1 < msgs.length ? msgs[i + 1] : null;
            final showHeader = older == null || older.senderId != msg.senderId;
            final showDateChip =
                older == null || !_sameDay(older.createdAt, msg.createdAt);
            // ✓✓ زرقاء: قرأ الرسالةَ كلُّ الأعضاء الآخرين.
            final others = members.values
                .where((m) => m.uid != msg.senderId)
                .toList();
            final readByAll =
                others.isNotEmpty &&
                others.every((m) => m.lastReadAtMs >= msg.sentAtMs);
            final key = _msgKeys.putIfAbsent(msg.id, GlobalKey.new);
            return Column(
              key: key,
              children: [
                if (showDateChip) _dateChip(msg.createdAt),
                // سحب أفقي خفيف = ردّ سريع (مثل واتساب).
                GestureDetector(
                  onHorizontalDragEnd: msg.deleted
                      ? null
                      : (d) {
                          if ((d.primaryVelocity ?? 0).abs() > 220) {
                            setState(() => _replyTo = msg.asRef());
                          }
                        },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    color: _highlightedId == msg.id
                        ? ChatColors.highlight
                        : Colors.transparent,
                    child: MessageBubble(
                      msg: msg,
                      showSenderHeader: showHeader,
                      members: members,
                      readByAll: readByAll,
                      onLongPress: (m) => _showMessageActions(m, members),
                      onReplyTap: _jumpToMessage,
                      onReactionsTap: (m) => _showReactions(m, members),
                    ),
                  ),
                ),
              ],
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
          const SizedBox(width: 8),
          Text(
            '${_uploadPct.toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 11, color: ChatColors.textMuted),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: ChatColors.rose),
            onPressed: () => setState(() => _uploadAborted = true),
            tooltip: 'إلغاء الرفع',
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

  /// شريط بديل عن الإدخال عندما يقفل المالك المجموعة.
  Widget _lockedBar() {
    return Container(
      color: ChatColors.surface,
      padding: const EdgeInsets.all(14),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.lock, size: 16, color: ChatColors.textMuted),
            SizedBox(width: 8),
            Text(
              'المجموعة مقفلة — الإرسال متاح للمالك 👑 فقط',
              style: TextStyle(fontSize: 12.5, color: ChatColors.textMuted),
            ),
          ],
        ),
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
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'اكتب رسالة…',
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
                  heroTag: 'chat_send',
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
              tooltip: 'إلغاء التسجيل',
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
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'جارٍ التسجيل…',
                style: TextStyle(color: ChatColors.textMuted, fontSize: 12),
              ),
            ),
            FloatingActionButton.small(
              heroTag: 'chat_send_voice',
              backgroundColor: ChatColors.accentDark,
              onPressed: () => _stopRecording(send: true),
              child: const Icon(Icons.send, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}
