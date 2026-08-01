import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import '../../services/chat_media_store.dart';
import '../../services/chat_notifications.dart';
import '../../services/chat_repository.dart';
import 'chat_ui.dart';
import 'dm_screen.dart';
import 'message_bubble.dart';
import 'profile_dialog.dart';

/// صفحة معلومات المجموعة (مثل واتساب): صورة المجموعة واسمها (يعدّلهما
/// المالك)، قفل الإرسال، صورتي الشخصيّة، وقائمة الأعضاء مع الحضور المباشر.
class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({super.key, required this.isOwner});

  final bool isOwner;

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  final _repo = ChatRepository.instance;
  bool _busy = false;
  bool _muted = false;
  bool _autoDownload = true;
  int _mediaBytes = 0;

  @override
  void initState() {
    super.initState();
    ChatNotifications.isMuted().then((v) {
      if (mounted) setState(() => _muted = v);
    });
    ChatMediaStore.autoDownloadEnabled().then((v) {
      if (mounted) setState(() => _autoDownload = v);
    });
    _refreshMediaSize();
  }

  Future<void> _refreshMediaSize() async {
    final b = await ChatMediaStore.instance.totalBytes();
    if (mounted) setState(() => _mediaBytes = b);
  }

  Future<void> _clearMedia() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('مسح الوسائط المنزَّلة'),
          content: const Text(
            'ستُحذف نسخ الوسائط من هذا الجهاز فقط — تبقى الرسائل كما هي '
            'ويمكن تنزيلها مجدّداً في أيّ وقت.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: ChatColors.rose),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('مسح'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await ChatMediaStore.instance.clearAll();
    await _refreshMediaSize();
    if (mounted) showChatSnack(context, 'مُسحت الوسائط المحفوظة.');
  }

  String get _myUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Future<void> _run(Future<void> Function() action, String okMsg) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showChatSnack(context, okMsg);
    } catch (e) {
      if (mounted) showChatSnack(context, 'فشل: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _pickImagePath() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: false,
    );
    return res?.files.firstOrNull?.path;
  }

  Future<void> _changeGroupPhoto() async {
    final path = await _pickImagePath();
    if (path == null) return;
    await _run(
      () =>
          _repo.setGroupPhotoFromPath(path, path.split(RegExp(r'[\\/]')).last),
      'تم تحديث صورة المجموعة.',
    );
  }

  Future<void> _changeMyPhoto() async {
    final path = await _pickImagePath();
    if (path == null) return;
    await _run(
      () => _repo.setMyPhotoFromPath(path, path.split(RegExp(r'[\\/]')).last),
      'تم تحديث صورتك الشخصيّة.',
    );
  }

  Future<void> _editGroupName(String current) async {
    final ctrl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('اسم المجموعة'),
          content: TextField(
            controller: ctrl,
            maxLength: 60,
            decoration: const InputDecoration(hintText: 'اسم المجموعة…'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok == true && name.isNotEmpty) {
      await _run(() => _repo.setGroupName(name), 'تم تحديث اسم المجموعة.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('معلومات المجموعة')),
      body: StreamBuilder<ChatGroupMeta>(
        stream: _repo.metaStream(),
        builder: (context, metaSnap) {
          final meta = metaSnap.data ?? ChatGroupMeta.fallback;
          return StreamBuilder<List<ChatMember>>(
            stream: _repo.membersStream(),
            builder: (context, memSnap) {
              final members = memSnap.data ?? [];
              final online = members.where((m) => m.isOnline).length;
              final me = members
                  .where((m) => m.uid == _myUid)
                  .cast<ChatMember?>()
                  .firstOrNull;
              return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  const SizedBox(height: 20),
                  _groupHeader(meta, members.length, online),
                  const SizedBox(height: 16),
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  _sectionCard([
                    // صورة المجموعة واسمها: متاحان لكلّ المشرفين (نمط واتساب).
                    ListTile(
                      leading: const Icon(
                        Icons.photo_camera,
                        color: ChatColors.accent,
                      ),
                      title: const Text('تغيير صورة المجموعة'),
                      subtitle: const Text(
                        'متاح لكلّ المشرفين',
                        style: TextStyle(fontSize: 11),
                      ),
                      onTap: _busy ? null : _changeGroupPhoto,
                    ),
                    if (meta.photoUrl.isNotEmpty)
                      ListTile(
                        leading: const Icon(
                          Icons.hide_image_outlined,
                          color: ChatColors.textMuted,
                        ),
                        title: const Text('إزالة صورة المجموعة'),
                        onTap: _busy
                            ? null
                            : () => _run(
                                () => _repo.clearGroupPhoto(),
                                'أُزيلت صورة المجموعة.',
                              ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.edit, color: ChatColors.accent),
                      title: const Text('تغيير اسم المجموعة'),
                      subtitle: const Text(
                        'متاح لكلّ المشرفين',
                        style: TextStyle(fontSize: 11),
                      ),
                      onTap: _busy ? null : () => _editGroupName(meta.name),
                    ),
                    if (widget.isOwner) ...[
                      SwitchListTile(
                        secondary: Icon(
                          meta.locked ? Icons.lock : Icons.lock_open,
                          color: meta.locked
                              ? ChatColors.rose
                              : ChatColors.accent,
                        ),
                        title: const Text('قفل المجموعة'),
                        subtitle: const Text(
                          'عند القفل لا يرسل أحد غير المالك (وضع الإعلانات)',
                          style: TextStyle(fontSize: 11),
                        ),
                        value: meta.locked,
                        onChanged: _busy
                            ? null
                            : (v) => _run(
                                () => _repo.setLocked(v),
                                v ? 'قُفلت المجموعة.' : 'فُتحت المجموعة.',
                              ),
                      ),
                      if (meta.pinned != null)
                        ListTile(
                          leading: const Icon(
                            Icons.push_pin,
                            color: ChatColors.amber,
                          ),
                          title: const Text('إلغاء تثبيت الرسالة'),
                          subtitle: Text(
                            meta.pinned!.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: _busy
                              ? null
                              : () => _run(
                                  () => _repo.setPinned(null),
                                  'أُلغي التثبيت.',
                                ),
                        ),
                    ],
                    SwitchListTile(
                      secondary: Icon(
                        _muted
                            ? Icons.notifications_off
                            : Icons.notifications_active,
                        color: _muted
                            ? ChatColors.textMuted
                            : ChatColors.accent,
                      ),
                      title: const Text('إشعارات المجموعة'),
                      subtitle: const Text(
                        'تنبيه عند وصول رسائل جديدة',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: !_muted,
                      onChanged: (v) async {
                        setState(() => _muted = !v);
                        await ChatNotifications.setMuted(!v);
                      },
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.badge_outlined,
                        color: ChatColors.accent,
                      ),
                      title: const Text('ملفّي الشخصي (الاسم والصورة)'),
                      subtitle: Text(
                        me == null
                            ? 'اختر اسمك وصورتك في المجموعة'
                            : 'أظهر باسم: ${me.displayName}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: me == null
                          ? null
                          : MemberAvatar(
                              uid: me.uid,
                              name: me.displayName,
                              photo: me.displayPhoto,
                              radius: 17,
                            ),
                      onTap: _busy
                          ? null
                          : () => showProfileDialog(context, firstRun: false),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.account_circle,
                        color: ChatColors.accent,
                      ),
                      title: const Text('تغيير صورتي الشخصيّة فقط'),
                      subtitle: const Text(
                        'تظهر تلقائيّاً مع اسمك في الدردشة',
                        style: TextStyle(fontSize: 11),
                      ),
                      onTap: _busy ? null : _changeMyPhoto,
                    ),
                    if ((me?.customPhoto ?? '').isNotEmpty)
                      ListTile(
                        leading: const Icon(
                          Icons.no_photography,
                          color: ChatColors.textMuted,
                        ),
                        title: const Text('إزالة صورتي المخصّصة'),
                        subtitle: const Text(
                          'العودة إلى صورة Google',
                          style: TextStyle(fontSize: 11),
                        ),
                        onTap: _busy
                            ? null
                            : () => _run(
                                () => _repo.clearMyPhoto(),
                                'أُزيلت الصورة.',
                              ),
                      ),
                  ]),
                  const SizedBox(height: 16),
                  // إدارة الوسائط المنزَّلة (نمط واتساب: التخزين والبيانات).
                  _sectionCard([
                    SwitchListTile(
                      secondary: const Icon(
                        Icons.download_for_offline,
                        color: ChatColors.accent,
                      ),
                      title: const Text('التنزيل التلقائي للوسائط الصغيرة'),
                      subtitle: const Text(
                        'الرسائل الصوتيّة والصور الصغيرة (أقلّ من 3 م.ب) '
                        'تُنزَّل تلقائيّاً لتُفتح فوراً وبلا إنترنت',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _autoDownload,
                      onChanged: (v) async {
                        setState(() => _autoDownload = v);
                        await ChatMediaStore.setAutoDownload(v);
                      },
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.sd_storage_outlined,
                        color: ChatColors.accent,
                      ),
                      title: const Text('وسائط محفوظة على الجهاز'),
                      subtitle: Text(
                        _mediaBytes > 0
                            ? '${formatBytes(_mediaBytes)} — تُشغَّل بلا إنترنت'
                            : 'لا وسائط منزَّلة بعد',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: _mediaBytes > 0
                          ? TextButton(
                              onPressed: _busy ? null : _clearMedia,
                              child: const Text(
                                'مسح',
                                style: TextStyle(color: ChatColors.rose),
                              ),
                            )
                          : null,
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'الأعضاء (${members.length}) — $online متصل الآن',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _sectionCard([
                    if (memSnap.connectionState == ConnectionState.waiting)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      ...members.map(_memberTile),
                  ]),
                  if (widget.isOwner) ...[
                    const SizedBox(height: 10),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'العضويّة تُدار تلقائيّاً: كلّ من يدخل تطبيق الإدارة ينضمّ، '
                        'ومن يُزال أو يُحظر من «الحساب والمشرفون» يخرج فوراً.',
                        style: TextStyle(
                          fontSize: 11,
                          color: ChatColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _groupHeader(ChatGroupMeta meta, int total, int online) {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: meta.photoUrl.isEmpty
                ? const LinearGradient(
                    colors: [ChatColors.accentDark, ChatColors.accent],
                  )
                : null,
            border: Border.all(color: ChatColors.border, width: 2),
          ),
          clipBehavior: Clip.antiAlias,
          child: meta.photoUrl.isEmpty
              ? const Icon(Icons.groups, color: Colors.white, size: 44)
              : CachedNetworkImage(imageUrl: meta.photoUrl, fit: BoxFit.cover),
        ),
        const SizedBox(height: 12),
        Text(
          meta.name,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          '$total عضو • $online متصل الآن${meta.locked ? ' • 🔒 مقفلة' : ''}',
          style: const TextStyle(fontSize: 12, color: ChatColors.textMuted),
        ),
      ],
    );
  }

  Widget _sectionCard(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(child: Column(children: children)),
    );
  }

  Widget _memberTile(ChatMember m) {
    final lastSeen = m.lastSeenAt != null
        ? intl.DateFormat('yyyy-MM-dd HH:mm').format(m.lastSeenAt!)
        : '';
    // المالك يعيّن/يزيل مشرفي المجموعة ⭐ (صلاحيّات داخل الدردشة فقط).
    final canManage = widget.isOwner && m.uid != _myUid && !m.isOwner;
    return ListTile(
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
              style: const TextStyle(fontSize: 14),
            ),
          ),
          if (m.uid == _myUid)
            const Padding(
              padding: EdgeInsetsDirectional.only(start: 6),
              child: Text(
                '(أنا)',
                style: TextStyle(fontSize: 11, color: ChatColors.textMuted),
              ),
            ),
          if (m.isOwner)
            _roleBadge('👑 المالك', ChatColors.amber)
          else if (m.isChatModerator)
            _roleBadge('⭐ مشرف المجموعة', ChatColors.accent),
        ],
      ),
      subtitle: Text(
        m.isOnline
            ? 'متصل الآن'
            : (lastSeen.isEmpty ? m.email : 'آخر ظهور: $lastSeen'),
        style: TextStyle(
          fontSize: 11,
          color: m.isOnline ? ChatColors.online : ChatColors.textMuted,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // مراسلة خاصّة — متاحة لأيّ عضو (عدا نفسي).
          if (m.uid != _myUid)
            IconButton(
              tooltip: 'مراسلة خاصّة',
              icon: const Icon(
                Icons.chat_bubble_outline,
                size: 19,
                color: ChatColors.accent,
              ),
              onPressed: () => openDm(context, m.uid, m.displayName),
            ),
          if (canManage)
            PopupMenuButton<String>(
              icon: const Icon(
                Icons.more_vert,
                size: 18,
                color: ChatColors.textMuted,
              ),
              onSelected: (v) {
                if (v == 'mod') {
                  _run(
                    () => _repo.setChatRole(m.uid, 'moderator'),
                    'صار ${m.displayName} مشرفاً للمجموعة ⭐',
                  );
                } else if (v == 'unmod') {
                  _run(
                    () => _repo.setChatRole(m.uid, null),
                    'أُزيل إشراف المجموعة عن ${m.displayName}',
                  );
                }
              },
              itemBuilder: (_) => [
                if (!m.isChatModerator)
                  const PopupMenuItem(
                    value: 'mod',
                    child: Text('تعيين مشرفاً للمجموعة ⭐'),
                  ),
                if (m.isChatModerator)
                  const PopupMenuItem(
                    value: 'unmod',
                    child: Text('إزالة إشراف المجموعة'),
                  ),
              ],
            ),
        ],
      ),
      onTap: m.uid == _myUid
          ? null
          : () => openDm(context, m.uid, m.displayName),
    );
  }

  Widget _roleBadge(String label, Color color) {
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, color: color)),
    );
  }
}
