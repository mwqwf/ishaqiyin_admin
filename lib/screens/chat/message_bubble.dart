import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;
import 'package:open_filex/open_filex.dart';

import '../../services/chat_media_store.dart';
import '../../services/chat_repository.dart';
import 'chat_media.dart';
import 'chat_ui.dart';
import 'linkified_text.dart';

/// بوّابة وسائط بنمط واتساب: تعرض المحتوى إن كان منزَّلاً على الجهاز،
/// وإلّا زرّ تنزيل. لا يُشغَّل شيء بثّاً من الشبكة.
class _MediaGate extends StatelessWidget {
  const _MediaGate({required this.attachment, required this.builder});

  final ChatAttachment attachment;
  final Widget Function(BuildContext context, File file) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaStatus>(
      valueListenable: ChatMediaStore.instance.statusOf(attachment),
      builder: (context, status, _) => status.isReady
          ? builder(context, status.file!)
          : MediaDownloadOverlay(attachment: attachment, status: status),
    );
  }
}

/// ألوان أسماء المرسِلين (مثل واتساب — لون ثابت لكلّ عضو)، دَرَجات داكنة
/// تقرأ جيّداً على سمة منبر الفاتحة.
const List<Color> _senderColors = [
  Color(0xFF059669),
  Color(0xFF2563EB),
  Color(0xFFDB2777),
  Color(0xFFD97706),
  Color(0xFF7C3AED),
  Color(0xFFDC2626),
  Color(0xFF0D9488),
  Color(0xFFEA580C),
];

Color senderColor(String uid) =>
    _senderColors[uid.hashCode.abs() % _senderColors.length];

/// صورة عضو دائريّة (المخصّصة أولاً ثم Google ثم الحرف الأوّل) مع نقطة
/// «متصل الآن» اختياريّة.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.uid,
    required this.name,
    required this.photo,
    this.radius = 16,
    this.showOnline = false,
    this.online = false,
  });

  final String uid;
  final String name;
  final String photo;
  final double radius;
  final bool showOnline;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: senderColor(uid).withValues(alpha: 0.18),
      backgroundImage: photo.isNotEmpty
          ? CachedNetworkImageProvider(photo)
          : null,
      child: photo.isEmpty
          ? Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color: senderColor(uid),
                fontSize: radius * 0.85,
                fontWeight: FontWeight.w700,
              ),
            )
          : null,
    );
    if (!showOnline) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        PositionedDirectional(
          bottom: -1,
          end: -1,
          child: Container(
            width: radius * 0.62,
            height: radius * 0.62,
            decoration: BoxDecoration(
              color: online ? ChatColors.online : ChatColors.textMuted,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

/// فقاعة رسالة بنمط واتساب: يمين للمرسِل، يسار للبقيّة، مع صورة واسم
/// المرسِل (وسام 👑 للمالك)، معاينة الردّ، المحتوى، التفاعلات، الوقت
/// وعلامات القراءة ✓✓.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.msg,
    required this.showSenderHeader,
    required this.members,
    required this.readByAll,
    required this.onLongPress,
    required this.onReplyTap,
    required this.onReactionsTap,
  });

  final ChatMessage msg;
  final bool showSenderHeader;

  /// خريطة الأعضاء الحاليّة {uid: ChatMember} — للصور الحيّة ووسام المالك.
  final Map<String, ChatMember> members;

  /// هل قرأ الرسالةَ كلُّ الأعضاء الآخرين (✓✓ زرقاء).
  final bool readByAll;

  final void Function(ChatMessage) onLongPress;
  final void Function(ChatReplyRef) onReplyTap;
  final void Function(ChatMessage) onReactionsTap;

  ChatMember? get _sender => members[msg.senderId];

  @override
  Widget build(BuildContext context) {
    // رسائل النظام (إن وُجدت مستقبلاً) — بطاقة وسطيّة مميّزة.
    if (msg.senderId == 'system') return _systemCard(context);

    final mine = msg.isMine;
    final bubbleColor = mine ? ChatColors.mineBubble : ChatColors.surface;
    final radius = BorderRadius.only(
      topRight: const Radius.circular(14),
      topLeft: const Radius.circular(14),
      bottomRight: Radius.circular(mine ? 3 : 14),
      bottomLeft: Radius.circular(mine ? 14 : 3),
    );

    final bubble = GestureDetector(
      onLongPress: () => onLongPress(msg),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: radius,
          border: Border.all(
            color: mine ? ChatColors.mineBubbleBorder : ChatColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine && showSenderHeader) _senderHeader(),
            if (msg.replyTo != null) _replyPreview(context),
            if (msg.deleted) _deletedBody() else _body(context),
            const SizedBox(height: 2),
            _footer(),
          ],
        ),
      ),
    );

    // صورة المرسِل تظهر بجوار أوّل رسالة في كلّ سلسلة (مثل واتساب).
    final withAvatar = mine
        ? bubble
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (showSenderHeader)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: MemberAvatar(
                    uid: msg.senderId,
                    name: _sender?.displayName ?? msg.senderName,
                    photo: _sender?.displayPhoto ?? msg.senderPhoto,
                    radius: 15,
                  ),
                )
              else
                const SizedBox(width: 36),
              Flexible(child: bubble),
            ],
          );

    return Align(
      // في RTL: رسائلي على اليمين (start)، رسائل الآخرين على اليسار (end).
      alignment: mine
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            withAvatar,
            if (msg.reactions.isNotEmpty && !msg.deleted)
              _reactionsBar(context),
          ],
        ),
      ),
    );
  }

  Widget _systemCard(BuildContext context) {
    return Center(
      child: GestureDetector(
        onLongPress: () => onLongPress(msg),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.86,
          ),
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ChatColors.highlight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: ChatColors.accentDark.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.auto_awesome, size: 14, color: ChatColors.accent),
                  SizedBox(width: 6),
                  Text(
                    'منبر',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: ChatColors.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                msg.deleted ? 'تم حذف هذه الرسالة' : msg.text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 4),
              Text(
                intl.DateFormat('HH:mm').format(msg.createdAt),
                style: const TextStyle(
                  fontSize: 9.5,
                  color: ChatColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _senderHeader() {
    final isOwner = _sender?.isOwner ?? false;
    final isMod = !isOwner && (_sender?.isChatModerator ?? false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              _sender?.displayName ?? msg.senderName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isOwner ? ChatColors.amber : senderColor(msg.senderId),
              ),
            ),
          ),
          if (isOwner) ...[
            const SizedBox(width: 4),
            const Text('👑', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 2),
            const Text(
              'المالك',
              style: TextStyle(fontSize: 10, color: ChatColors.amber),
            ),
          ] else if (isMod) ...[
            const SizedBox(width: 4),
            const Text('⭐', style: TextStyle(fontSize: 10)),
            const SizedBox(width: 2),
            const Text(
              'مشرف',
              style: TextStyle(fontSize: 10, color: ChatColors.accent),
            ),
          ],
        ],
      ),
    );
  }

  /// شريط التفاعلات أسفل الفقاعة (مجمَّع بالإيموجي مع العدد).
  Widget _reactionsBar(BuildContext context) {
    final counts = <String, int>{};
    for (final e in msg.reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final myEmoji = msg.reactions[FirebaseAuth.instance.currentUser?.uid ?? ''];
    return GestureDetector(
      onTap: () => onReactionsTap(msg),
      child: Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: ChatColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: myEmoji != null ? ChatColors.accentDark : ChatColors.border,
          ),
        ),
        child: Text(
          counts.entries
              .map((e) => e.value > 1 ? '${e.key} ${e.value}' : e.key)
              .join('  '),
          style: const TextStyle(fontSize: 12.5),
        ),
      ),
    );
  }

  Widget _replyPreview(BuildContext context) {
    final r = msg.replyTo!;
    return InkWell(
      onTap: () => onReplyTap(r),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: BorderDirectional(
            start: BorderSide(color: senderColor(r.senderId), width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              r.senderName,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: senderColor(r.senderId),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              r.preview.isEmpty ? chatTypeLabel(r.type) : r.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                color: ChatColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deletedBody() {
    final byOther = msg.deletedBy.isNotEmpty && msg.deletedBy != msg.senderId;
    final deleter = members[msg.deletedBy];
    final label = !byOther
        ? 'تم حذف هذه الرسالة'
        : (deleter?.isOwner ?? true)
        ? 'حذفها المالك 👑'
        : 'حذفها مشرف المجموعة ⭐';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.block, size: 15, color: ChatColors.textMuted),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: ChatColors.textMuted,
            fontStyle: FontStyle.italic,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final att = msg.attachment;
    final caption = msg.text.trim();
    Widget content;
    switch (msg.type) {
      case ChatMessageType.text:
        // الروابط والبُرد والأرقام قابلة للنقر (نمط واتساب).
        content = ChatLinkText(
          msg.text,
          style: const TextStyle(fontSize: 14.5, height: 1.45),
        );
      case ChatMessageType.image:
        content = att == null
            ? _missingAttachment()
            : _MediaGate(
                attachment: att,
                builder: (context, file) => InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ImageViewerPage(file: file, name: att.name),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 260,
                        maxWidth: 260,
                      ),
                      child: Image.file(
                        file,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 220,
                          height: 120,
                          color: ChatColors.surfaceAlt,
                          child: const Icon(
                            Icons.broken_image,
                            color: ChatColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
      case ChatMessageType.video:
        content = att == null
            ? _missingAttachment()
            : _MediaGate(
                attachment: att,
                builder: (context, file) => InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          VideoPlayerPage(file: file, name: att.name),
                    ),
                  ),
                  child: Container(
                    width: 240,
                    height: 140,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: ChatColors.border),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const Icon(
                          Icons.play_circle_fill,
                          size: 48,
                          color: Colors.white70,
                        ),
                        PositionedDirectional(
                          bottom: 6,
                          start: 8,
                          end: 8,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.download_done,
                                size: 12,
                                color: Colors.white54,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${att.name}${att.size > 0 ? ' • ${formatBytes(att.size)}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
      case ChatMessageType.audio:
      case ChatMessageType.voice:
        // فقاعة الصوت تدير التنزيل بنفسها (زرّ تنزيل ← تشغيل محلّي).
        content = att == null
            ? _missingAttachment()
            : AudioBubblePlayer(
                attachment: att,
                isVoice: msg.type == ChatMessageType.voice,
                mine: msg.isMine,
              );
      case ChatMessageType.file:
        content = att == null ? _missingAttachment() : _fileTile(att);
    }

    if (msg.type != ChatMessageType.text && caption.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          const SizedBox(height: 6),
          // تعليق المرفق يدعم الروابط أيضاً.
          ChatLinkText(
            caption,
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
        ],
      );
    }
    return content;
  }

  Widget _missingAttachment() {
    return const Text(
      'مرفق غير متاح',
      style: TextStyle(color: ChatColors.textMuted, fontSize: 12),
    );
  }

  /// بطاقة ملفّ: تنزيل ثم فتح بتطبيق النظام (يعمل دون إنترنت بعد التنزيل).
  Widget _fileTile(ChatAttachment att) {
    final store = ChatMediaStore.instance;
    return ValueListenableBuilder<MediaStatus>(
      valueListenable: store.statusOf(att),
      builder: (context, status, _) {
        final downloading = status.state == MediaState.downloading;
        return InkWell(
          onTap: downloading
              ? null
              : () async {
                  final f = status.isReady
                      ? status.file
                      : await store.download(att);
                  if (f != null) await OpenFilex.open(f.path);
                },
          child: Container(
            width: 244,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: downloading
                      ? CircularProgressIndicator(
                          strokeWidth: 2.4,
                          value: status.progress > 0
                              ? status.progress / 100
                              : null,
                        )
                      : Icon(
                          status.isReady
                              ? Icons.insert_drive_file
                              : Icons.download_for_offline,
                          color: status.isReady
                              ? ChatColors.amber
                              : ChatColors.accentDark,
                          size: 32,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        att.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        downloading
                            ? 'جارٍ التنزيل… ${status.progress.toStringAsFixed(0)}%'
                            : status.state == MediaState.failed
                            ? (status.error ?? 'تعذّر التنزيل')
                            : status.isReady
                            ? 'مُنزَّل • اضغط للفتح'
                            : 'اضغط للتنزيل${att.size > 0 ? ' • ${formatBytes(att.size)}' : ''}',
                        style: TextStyle(
                          fontSize: 11,
                          color: status.state == MediaState.failed
                              ? ChatColors.rose
                              : ChatColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _footer() {
    final time = intl.DateFormat('HH:mm').format(msg.createdAt);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          time,
          style: const TextStyle(fontSize: 10, color: ChatColors.textMuted),
        ),
        if (msg.isMine) ...[
          const SizedBox(width: 4),
          if (msg.pending)
            const Icon(Icons.access_time, size: 13, color: ChatColors.textMuted)
          else
            Icon(
              readByAll ? Icons.done_all : Icons.done,
              size: 14,
              color: readByAll
                  ? ChatColors
                        .readBlue // ✓✓ زرقاء: قرأها الجميع.
                  : ChatColors.textMuted,
            ),
        ],
      ],
    );
  }
}
