import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import '../../services/chat_repository.dart';
import '../../services/dm_repository.dart';
import 'chat_ui.dart';
import 'dm_screen.dart';
import 'message_bubble.dart';

/// 💬 «الرسائل الخاصّة» — قائمة المحادثات الفرديّة بين المشرفين (نمط واتساب:
/// آخر رسالة، وقتها، وشارة غير المقروء)، مع زرّ لبدء محادثة مع أيّ عضو.
class DmListScreen extends StatelessWidget {
  const DmListScreen({super.key});

  String get _myUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ChatColors.bg,
      appBar: AppBar(title: const Text('الرسائل الخاصّة')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'dm_new',
        backgroundColor: ChatColors.accentDark,
        onPressed: () => _startNew(context),
        icon: const Icon(Icons.edit, color: Colors.white),
        label: const Text(
          'محادثة جديدة',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: StreamBuilder<List<ChatMember>>(
        stream: ChatRepository.instance.membersStream(),
        builder: (context, memSnap) {
          final members = {
            for (final m in memSnap.data ?? const <ChatMember>[]) m.uid: m,
          };
          return StreamBuilder<List<DmThread>>(
            stream: DmRepository.instance.threadsStream(),
            builder: (context, snap) {
              if (snap.hasError) {
                return _centered(
                  'تعذّر تحميل المحادثات.\n${snap.error}',
                  error: true,
                );
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final threads = snap.data!
                  .where((t) => t.lastAtMs > 0)
                  .toList();
              if (threads.isEmpty) {
                return _emptyState(context);
              }
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 90),
                itemCount: threads.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 76),
                itemBuilder: (context, i) =>
                    _threadTile(context, threads[i], members),
              );
            },
          );
        },
      ),
    );
  }

  Widget _centered(String text, {bool error = false}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: error ? ChatColors.rose : ChatColors.textMuted,
          fontSize: 13,
        ),
      ),
    ),
  );

  Widget _emptyState(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.forum_outlined,
            size: 64,
            color: ChatColors.textMuted,
          ),
          const SizedBox(height: 14),
          const Text(
            'لا محادثات خاصّة بعد',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 6),
          const Text(
            'تستطيع مراسلة أيّ مشرف على حدة — بعيداً عن المجموعة.\n'
            'ومن المجموعة: اضغط مطوّلاً على رسالة ثم «ردّ بشكل خاص».',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: ChatColors.textMuted),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => _startNew(context),
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('ابدأ محادثة'),
          ),
        ],
      ),
    ),
  );

  Widget _threadTile(
    BuildContext context,
    DmThread t,
    Map<String, ChatMember> members,
  ) {
    final otherUid = t.otherOf(_myUid);
    final other = members[otherUid];
    final unread = t.hasUnreadFor(_myUid);
    return ListTile(
      leading: MemberAvatar(
        uid: otherUid,
        name: other?.displayName ?? 'عضو',
        photo: other?.displayPhoto ?? '',
        radius: 24,
        showOnline: true,
        online: other?.isOnline ?? false,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              other?.displayName ?? 'عضو سابق',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
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
      subtitle: Text(
        t.previewFor(_myUid),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          color: unread ? ChatColors.accentDark : ChatColors.textMuted,
          fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _timeLabel(t.lastAtMs),
            style: TextStyle(
              fontSize: 10.5,
              color: unread ? ChatColors.accent : ChatColors.textMuted,
              fontWeight: unread ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 4),
          if (unread)
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: ChatColors.accent,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
      onTap: () => openDm(context, otherUid, other?.displayName ?? 'عضو'),
    );
  }

  static String _timeLabel(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return intl.DateFormat('HH:mm').format(d);
    if (day == today.subtract(const Duration(days: 1))) return 'أمس';
    return intl.DateFormat('yyyy/MM/dd').format(d);
  }

  /// اختيار عضو لبدء محادثة معه (كلّ الأعضاء عداي).
  Future<void> _startNew(BuildContext context) async {
    final members = await ChatRepository.instance.membersStream().first;
    final others = members.where((m) => m.uid != _myUid).toList();
    if (!context.mounted) return;
    if (others.isEmpty) {
      showChatSnack(context, 'لا يوجد مشرفون آخرون بعد.', error: true);
      return;
    }
    final picked = await showModalBottomSheet<ChatMember>(
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
                  'اختر مشرفاً للمراسلة',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in others)
                      ListTile(
                        leading: MemberAvatar(
                          uid: m.uid,
                          name: m.displayName,
                          photo: m.displayPhoto,
                          radius: 20,
                          showOnline: true,
                          online: m.isOnline,
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                m.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (m.isOwner)
                              const Padding(
                                padding: EdgeInsetsDirectional.only(start: 5),
                                child: Text(
                                  '👑',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          m.isOnline ? 'متصل الآن' : m.email,
                          style: TextStyle(
                            fontSize: 11,
                            color: m.isOnline
                                ? ChatColors.online
                                : ChatColors.textMuted,
                          ),
                        ),
                        onTap: () => Navigator.pop(context, m),
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
    if (picked != null && context.mounted) {
      await openDm(context, picked.uid, picked.displayName);
    }
  }
}
