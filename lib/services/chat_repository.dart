import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// دردشة إدارة منبر ادكصهك الجماعيّة — منقولة من لوحة نبراس بكامل مزاياها،
/// خاصّة بتطبيق الإدارة فقط (لا يقرأها تطبيق منبر العامّ إطلاقاً، وتحميها
/// قواعد Firestore/Storage بدور المالك/المشرف).
///
/// المجموعات:
///   • `admin_chat_messages/{msgId}` — الرسائل (زمن حقيقي عبر snapshots)
///     مع خريطة تفاعلات `reactions: {uid: emoji}`.
///   • `admin_chat_members/{uid}`   — الأعضاء (عضويّة تلقائيّة) + حضور
///     (lastActiveAtMs) + قراءة (lastReadAtMs) + كتابة (typingAtMs).
///   • `admin_chat_meta/group`      — هويّة المجموعة (اسم/صورة/قفل/تثبيت)،
///     يكتبها المالك وحده (التثبيت متاح أيضاً لمشرف المجموعة ⭐).
class ChatPaths {
  ChatPaths._();
  static const String messages = 'admin_chat_messages';
  static const String members = 'admin_chat_members';
  static const String meta = 'admin_chat_meta';

  /// مجلّد مرفقات الدردشة في Storage (قاعدة خاصّة به في storage.rules).
  static const String storageFolder = 'admin_chat/files';
  static const String avatarsFolder = 'admin_chat/avatars';
  static const String metaFolder = 'admin_chat/meta';
}

/// نافذة اعتبار العضو «متصلاً الآن»: آخر نبضة حضور خلال هذه المدّة.
const Duration kOnlineWindow = Duration(seconds: 95);

/// نافذة اعتبار العضو «يكتب الآن…».
const Duration kTypingWindow = Duration(seconds: 6);

/// التفاعلات السريعة (مطابقة لواتساب).
const List<String> kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// نوع الرسالة — يحدّد شكل الفقاعة في الواجهة.
enum ChatMessageType { text, image, video, audio, voice, file }

ChatMessageType chatTypeFromString(String? s) => switch (s) {
  'image' => ChatMessageType.image,
  'video' => ChatMessageType.video,
  'audio' => ChatMessageType.audio,
  'voice' => ChatMessageType.voice,
  'file' => ChatMessageType.file,
  _ => ChatMessageType.text,
};

String chatTypeToString(ChatMessageType t) => t.name;

/// تسمية عربيّة مختصرة للنوع (تظهر في معاينة الردّ/التثبيت).
String chatTypeLabel(ChatMessageType t) => switch (t) {
  ChatMessageType.text => 'رسالة',
  ChatMessageType.image => '📷 صورة',
  ChatMessageType.video => '🎬 فيديو',
  ChatMessageType.audio => '🎵 مقطع صوتي',
  ChatMessageType.voice => '🎙️ رسالة صوتيّة',
  ChatMessageType.file => '📎 ملفّ',
};

/// مرفق رسالة (صورة/فيديو/صوت/ملفّ) مرفوع إلى Storage.
class ChatAttachment {
  const ChatAttachment({
    required this.url,
    required this.path,
    required this.name,
    required this.size,
    required this.contentType,
    this.durationMs,
  });

  final String url;
  final String path; // مسار Storage — يلزم لحذف الملفّ عند "حذف عند الجميع".
  final String name;
  final int size;
  final String contentType;
  final int? durationMs; // للرسائل الصوتيّة.

  Map<String, dynamic> toMap() => {
    'url': url,
    'path': path,
    'name': name,
    'size': size,
    'contentType': contentType,
    if (durationMs != null) 'durationMs': durationMs,
  };

  static ChatAttachment? fromMap(dynamic m) {
    if (m is! Map) return null;
    final map = m.cast<String, dynamic>();
    final url = '${map['url'] ?? ''}';
    if (url.isEmpty) return null;
    return ChatAttachment(
      url: url,
      path: '${map['path'] ?? ''}',
      name: '${map['name'] ?? 'ملفّ'}',
      size: (map['size'] is num) ? (map['size'] as num).toInt() : 0,
      contentType: '${map['contentType'] ?? 'application/octet-stream'}',
      durationMs: (map['durationMs'] is num)
          ? (map['durationMs'] as num).toInt()
          : null,
    );
  }
}

/// مقتطف رسالة مُشار إليها (ردّ أو تثبيت) — يُخزَّن ذاتيّاً داخل الوثيقة.
class ChatReplyRef {
  const ChatReplyRef({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.preview,
    required this.type,
  });

  final String messageId;
  final String senderId;
  final String senderName;
  final String preview;
  final ChatMessageType type;

  Map<String, dynamic> toMap() => {
    'messageId': messageId,
    'senderId': senderId,
    'senderName': senderName,
    'preview': preview,
    'type': chatTypeToString(type),
  };

  static ChatReplyRef? fromMap(dynamic m) {
    if (m is! Map) return null;
    final map = m.cast<String, dynamic>();
    final id = '${map['messageId'] ?? ''}';
    if (id.isEmpty) return null;
    return ChatReplyRef(
      messageId: id,
      senderId: '${map['senderId'] ?? ''}',
      senderName: '${map['senderName'] ?? ''}',
      preview: '${map['preview'] ?? ''}',
      type: chatTypeFromString('${map['type'] ?? 'text'}'),
    );
  }
}

/// رسالة دردشة.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.senderPhoto,
    required this.type,
    required this.text,
    required this.attachment,
    required this.replyTo,
    required this.createdAt,
    required this.sentAtMs,
    required this.deleted,
    required this.deletedBy,
    required this.hiddenFor,
    required this.reactions,
    required this.pending,
  });

  final String id;
  final String senderId;
  final String senderName;
  final String senderPhoto;
  final ChatMessageType type;
  final String text;
  final ChatAttachment? attachment;
  final ChatReplyRef? replyTo;
  final DateTime createdAt;
  final int sentAtMs;
  final bool deleted;
  final String deletedBy;
  final List<String> hiddenFor;

  /// تفاعلات الإيموجي: {uid: emoji}.
  final Map<String, String> reactions;
  final bool pending; // كتابة محليّة لم يؤكّدها الخادم بعد.

  bool get isMine => senderId == FirebaseAuth.instance.currentUser?.uid;

  /// نصّ معاينة مختصر (للردود والتثبيت).
  String get preview {
    if (deleted) return 'رسالة محذوفة';
    if (type == ChatMessageType.text) {
      return text.length > 90 ? '${text.substring(0, 90)}…' : text;
    }
    final label = chatTypeLabel(type);
    final name = attachment?.name ?? '';
    return type == ChatMessageType.voice || name.isEmpty
        ? label
        : '$label $name';
  }

  ChatReplyRef asRef() => ChatReplyRef(
    messageId: id,
    senderId: senderId,
    senderName: senderName,
    preview: preview,
    type: type,
  );

  static ChatMessage fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map?)?.cast<String, dynamic>() ?? {};
    final ts = d['createdAt'];
    final sentAtMs = (d['sentAtMs'] is num)
        ? (d['sentAtMs'] as num).toInt()
        : DateTime.now().millisecondsSinceEpoch;
    final reactions = <String, String>{};
    if (d['reactions'] is Map) {
      (d['reactions'] as Map).forEach((k, v) {
        final e = '$v';
        if (e.isNotEmpty) reactions['$k'] = e;
      });
    }
    return ChatMessage(
      id: doc.id,
      senderId: '${d['senderId'] ?? ''}',
      senderName: '${d['senderName'] ?? 'مستخدم'}',
      senderPhoto: '${d['senderPhoto'] ?? ''}',
      type: chatTypeFromString('${d['type'] ?? 'text'}'),
      text: '${d['text'] ?? ''}',
      attachment: ChatAttachment.fromMap(d['att']),
      replyTo: ChatReplyRef.fromMap(d['replyTo']),
      // الكتابات المعلَّقة (serverTimestamp لم يصل بعد) تعود لوقت الإرسال المحلّي.
      createdAt: ts is Timestamp
          ? ts.toDate()
          : DateTime.fromMillisecondsSinceEpoch(sentAtMs),
      sentAtMs: sentAtMs,
      deleted: d['deleted'] == true,
      deletedBy: '${d['deletedBy'] ?? ''}',
      hiddenFor: (d['hiddenFor'] is List)
          ? (d['hiddenFor'] as List).map((e) => '$e').toList()
          : const [],
      reactions: reactions,
      pending: doc.metadata.hasPendingWrites,
    );
  }
}

/// عضو في المجموعة.
class ChatMember {
  const ChatMember({
    required this.uid,
    required this.name,
    required this.customName,
    required this.email,
    required this.photo,
    required this.customPhoto,
    required this.role,
    required this.chatRole,
    required this.profileSet,
    this.lastSeenAt,
    this.lastActiveAtMs = 0,
    this.lastReadAtMs = 0,
    this.typingAtMs = 0,
  });

  final String uid;
  final String name; // اسم Google.
  final String customName; // اسم مختار داخل المجموعة (له الأولويّة).
  final String email;
  final String photo; // صورة Google.
  final String customPhoto; // صورة شخصيّة مختارة داخل المجموعة (لها الأولويّة).
  final String role; // owner | supervisor (دور التطبيق).
  final String chatRole; // '' | moderator (دور داخل المجموعة فقط).
  final bool profileSet; // أكمل إعداد الملفّ الشخصي لأوّل مرّة.
  final DateTime? lastSeenAt;
  final int lastActiveAtMs;
  final int lastReadAtMs;
  final int typingAtMs;

  bool get isOwner => role == 'owner';

  /// مشرف مجموعة: صلاحيّات إشراف داخل الدردشة فقط (لا تمسّ التطبيق).
  bool get isChatModerator => chatRole == 'moderator';

  /// الاسم المعروض في المجموعة: المختار أولاً ثم اسم Google.
  String get displayName => customName.isNotEmpty ? customName : name;

  /// الصورة المعروضة في المجموعة: المخصّصة أولاً ثم صورة Google.
  String get displayPhoto => customPhoto.isNotEmpty ? customPhoto : photo;

  bool get isOnline =>
      DateTime.now().millisecondsSinceEpoch - lastActiveAtMs <
      kOnlineWindow.inMilliseconds;

  bool get isTyping =>
      DateTime.now().millisecondsSinceEpoch - typingAtMs <
      kTypingWindow.inMilliseconds;

  static ChatMember fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map?)?.cast<String, dynamic>() ?? {};
    final ts = d['lastSeenAt'];
    int msOf(dynamic v) => v is num ? v.toInt() : 0;
    return ChatMember(
      uid: doc.id,
      name: '${d['name'] ?? 'مستخدم'}',
      customName: '${d['customName'] ?? ''}',
      email: '${d['email'] ?? ''}',
      photo: '${d['photo'] ?? ''}',
      customPhoto: '${d['customPhoto'] ?? ''}',
      role: '${d['role'] ?? 'supervisor'}',
      chatRole: '${d['chatRole'] ?? ''}',
      profileSet: d['profileSet'] == true,
      lastSeenAt: ts is Timestamp ? ts.toDate() : null,
      lastActiveAtMs: msOf(d['lastActiveAtMs']),
      lastReadAtMs: msOf(d['lastReadAtMs']),
      typingAtMs: msOf(d['typingAtMs']),
    );
  }
}

/// هويّة المجموعة (يكتبها المالك وحده).
class ChatGroupMeta {
  const ChatGroupMeta({
    required this.name,
    required this.photoUrl,
    required this.locked,
    required this.pinned,
  });

  final String name;
  final String photoUrl;

  /// عند القفل لا يرسل غير المالك (نمط «إعلانات» في واتساب).
  final bool locked;

  /// الرسالة المثبَّتة (إن وُجدت).
  final ChatReplyRef? pinned;

  static const ChatGroupMeta fallback = ChatGroupMeta(
    name: 'مجموعة إدارة منبر ادكصهك',
    photoUrl: '',
    locked: false,
    pinned: null,
  );

  static ChatGroupMeta fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map?)?.cast<String, dynamic>() ?? {};
    final name = '${d['name'] ?? ''}'.trim();
    return ChatGroupMeta(
      name: name.isEmpty ? fallback.name : name,
      photoUrl: '${d['photoUrl'] ?? ''}',
      locked: d['locked'] == true,
      pinned: ChatReplyRef.fromMap(d['pinned']),
    );
  }
}

/// نتيجة رفع مرفق إلى Storage.
class ChatUploadResult {
  const ChatUploadResult({
    required this.url,
    required this.path,
    required this.contentType,
    required this.size,
  });

  final String url;
  final String path;
  final String contentType;
  final int size;
}

String _sanitizeSegment(String name) {
  final buffer = StringBuffer();
  for (final cu in name.trim().codeUnits) {
    if (cu <= 0x1F || cu == 0x7F) continue;
    buffer.writeCharCode(cu);
  }
  var s = buffer.toString();
  s = s.replaceAll(RegExp(r'[#$\[\]./\\:*?"<>|]+'), '_');
  if (s.length > 180) s = s.substring(0, 180);
  return s.isEmpty ? 'file' : s;
}

/// رفع ملفّ من المسار (بثّ من القرص — لا يُحمَّل كاملاً في الذاكرة، فيدعم
/// الملفّات الضخمة). الترتيب الثابت: Storage أولاً ثم وثيقة Firestore.
Future<ChatUploadResult> chatUploadFile({
  required File file,
  required String filename,
  String contentType = 'application/octet-stream',
  String folder = ChatPaths.storageFolder,
  void Function(double pct)? onProgress,
  bool Function()? isAborted,
}) async {
  final storage = FirebaseStorage.instance;
  final safeName = _sanitizeSegment(filename);
  final cleanFolder = folder.replaceAll(RegExp(r'^/+|/+$'), '');
  final path =
      '$cleanFolder/${DateTime.now().millisecondsSinceEpoch}_$safeName';
  final ref = storage.ref(path);
  final ct = contentType.trim().isEmpty
      ? 'application/octet-stream'
      : contentType;
  final size = await file.length();

  final task = ref.putFile(file, SettableMetadata(contentType: ct));
  task.snapshotEvents.listen((snap) {
    if (isAborted != null && isAborted()) {
      task.cancel();
      return;
    }
    final total = snap.totalBytes <= 0 ? size : snap.totalBytes;
    onProgress?.call((snap.bytesTransferred / total) * 100);
  }, onError: (_) {});

  try {
    await task;
  } on FirebaseException catch (e) {
    if (e.code == 'canceled') {
      throw Exception('تمّ إلغاء الرفع.');
    }
    rethrow;
  }

  if (isAborted != null && isAborted()) {
    throw Exception('تمّ إلغاء الرفع.');
  }

  final url = await ref.getDownloadURL();
  return ChatUploadResult(url: url, path: path, contentType: ct, size: size);
}

class ChatRepository {
  ChatRepository._();
  static final ChatRepository instance = ChatRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _messages =>
      _db.collection(ChatPaths.messages);
  CollectionReference<Map<String, dynamic>> get _members =>
      _db.collection(ChatPaths.members);
  DocumentReference<Map<String, dynamic>> get _meta =>
      _db.collection(ChatPaths.meta).doc('group');

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  // ─── الرسائل ─────────────────────────────────────────────

  /// بثّ آخر [limit] رسالة (تنازليّاً) — الرسائل المحذوفة "عندي" تُرشَّح هنا.
  ///
  /// الترتيب على `sentAtMs` (طابع محلّي يُكتب مع كلّ رسالة) وليس على
  /// serverTimestamp: الحقل موجود فوراً حتى في الكتابات المعلَّقة، فتظهر
  /// رسالتك لحظيّاً وتعمل الدردشة دون انقطاع أثناء ضعف الشبكة.
  Stream<List<ChatMessage>> messagesStream({int limit = 60}) {
    final uid = _uid;
    return _messages
        .orderBy('sentAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map(ChatMessage.fromDoc)
              .where((m) => !m.hiddenFor.contains(uid))
              .toList(),
        );
  }

  Map<String, dynamic> _senderFields() {
    final u = FirebaseAuth.instance.currentUser;
    final name = (u?.displayName?.trim().isNotEmpty == true)
        ? u!.displayName!
        : (u?.email?.split('@').first ?? 'مستخدم');
    return {
      'senderId': u?.uid ?? '',
      'senderName': name,
      'senderPhoto': u?.photoURL ?? '',
    };
  }

  Future<void> sendText(String text, {ChatReplyRef? replyTo}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _messages.add({
      ..._senderFields(),
      'type': 'text',
      'text': t,
      'att': null,
      'replyTo': replyTo?.toMap(),
      'sentAtMs': DateTime.now().millisecondsSinceEpoch,
      'createdAt': FieldValue.serverTimestamp(),
      'deleted': false,
      'deletedBy': '',
      'hiddenFor': <String>[],
      'reactions': <String, String>{},
    });
  }

  /// رفع ملفّ من مسار على الجهاز ثم إرسال رسالة تشير إليه.
  Future<void> sendAttachmentFromPath({
    required String filePath,
    required String filename,
    required String contentType,
    required ChatMessageType type,
    String caption = '',
    int? durationMs,
    ChatReplyRef? replyTo,
    void Function(double pct)? onProgress,
    bool Function()? isAborted,
  }) async {
    final up = await chatUploadFile(
      file: File(filePath),
      filename: filename,
      contentType: contentType,
      folder: ChatPaths.storageFolder,
      onProgress: onProgress,
      isAborted: isAborted,
    );
    await _messages.add({
      ..._senderFields(),
      'type': chatTypeToString(type),
      'text': caption.trim(),
      'att': ChatAttachment(
        url: up.url,
        path: up.path,
        name: filename,
        size: up.size,
        contentType: up.contentType,
        durationMs: durationMs,
      ).toMap(),
      'replyTo': replyTo?.toMap(),
      'sentAtMs': DateTime.now().millisecondsSinceEpoch,
      'createdAt': FieldValue.serverTimestamp(),
      'deleted': false,
      'deletedBy': '',
      'hiddenFor': <String>[],
      'reactions': <String, String>{},
    });
  }

  /// حذف عندي فقط — تبقى الرسالة ظاهرة للبقيّة (مطابق لواتساب).
  Future<void> deleteForMe(String messageId) async {
    await _messages.doc(messageId).update({
      'hiddenFor': FieldValue.arrayUnion([_uid]),
    });
  }

  /// حذف عند الجميع — للمرسِل نفسه أو للمالك/مشرف المجموعة. تُمسح الحمولة
  /// ويُحذف مرفق Storage (بأفضل جهد) وتبقى وثيقة "تم حذف الرسالة".
  Future<void> deleteForEveryone(ChatMessage msg) async {
    await _messages.doc(msg.id).update({
      'deleted': true,
      'deletedBy': _uid,
      'deletedAt': FieldValue.serverTimestamp(),
      'text': '',
      'att': null,
    });
    final path = msg.attachment?.path ?? '';
    if (path.isNotEmpty) {
      try {
        await FirebaseStorage.instance.ref(path).delete();
      } catch (_) {
        // أفضل جهد — الوثيقة حُذفت منطقيّاً على أيّ حال.
      }
    }
  }

  // ─── التفاعلات (إيموجي مثل واتساب) ───────────────────────

  /// ضبط تفاعلي على رسالة: emoji جديد يستبدل السابق، و null يزيله.
  Future<void> setReaction(String messageId, String? emoji) async {
    await _messages.doc(messageId).update({
      'reactions.$_uid': (emoji == null || emoji.isEmpty)
          ? FieldValue.delete()
          : emoji,
    });
  }

  // ─── هويّة المجموعة ──────────────────────────────────────
  // الاسم والصورة: **يعدّلهما أيّ عضو معتمَد** (مالكاً كان أو مشرفاً) — مثل
  // واتساب. أمّا القفل فللمالك وحده، والتثبيت للمالك ومشرف المجموعة ⭐.

  Stream<ChatGroupMeta> metaStream() => _meta.snapshots().map(
    (d) => d.exists ? ChatGroupMeta.fromDoc(d) : ChatGroupMeta.fallback,
  );

  /// اسم من قام بآخر تعديل — يُعرض في معلومات المجموعة (شفافيّة).
  Map<String, dynamic> _editorFields() {
    final u = FirebaseAuth.instance.currentUser;
    final name = (u?.displayName?.trim().isNotEmpty == true)
        ? u!.displayName!
        : (u?.email?.split('@').first ?? 'مشرف');
    return {
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedByUid': u?.uid ?? '',
      'updatedByName': name,
    };
  }

  Future<void> setGroupName(String name) async {
    await _meta.set({
      'name': name.trim(),
      ..._editorFields(),
    }, SetOptions(merge: true));
  }

  /// رفع صورة المجموعة وتحديث الهويّة (متاح لكلّ المشرفين).
  Future<void> setGroupPhotoFromPath(String filePath, String filename) async {
    final up = await chatUploadFile(
      file: File(filePath),
      filename: filename,
      contentType: guessContentType(filename),
      folder: ChatPaths.metaFolder,
    );
    await _meta.set({
      'photoUrl': up.url,
      'photoPath': up.path,
      ..._editorFields(),
    }, SetOptions(merge: true));
  }

  /// إزالة صورة المجموعة (العودة للأيقونة الافتراضيّة).
  Future<void> clearGroupPhoto() async {
    await _meta.set({
      'photoUrl': '',
      'photoPath': '',
      ..._editorFields(),
    }, SetOptions(merge: true));
  }

  Future<void> setLocked(bool locked) async {
    await _meta.set({
      'locked': locked,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// تثبيت رسالة (null لإلغاء التثبيت) — للمالك 👑 ومشرف المجموعة ⭐.
  Future<void> setPinned(ChatReplyRef? ref) async {
    await _meta.set({
      'pinned': ref?.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ─── الأعضاء والحضور ─────────────────────────────────────

  /// إضافة/تحديث العضو الحالي تلقائيّاً — تُستدعى عند فتح اللوحة (أي أنّ
  /// كلّ من يدخل تطبيق الإدارة ينضمّ للمجموعة دون أيّ خطوة يدويّة).
  /// صامتة عند الفشل: انقطاع الشبكة أو قواعد لم تُنشر بعد يجب ألّا يُسقط
  /// اللوحة — شاشة الدردشة تعرض الخطأ الفعلي عند فتحها.
  ///
  /// [role]: دور اللوحة الحالي (owner/supervisor) — يُخزَّن ليُعرض وسام
  /// المالك 👑 لبقيّة الأعضاء.
  Future<void> upsertSelf({String? role}) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    final name = (u.displayName?.trim().isNotEmpty == true)
        ? u.displayName!
        : (u.email?.split('@').first ?? 'مستخدم');
    try {
      await _members.doc(u.uid).set({
        'name': name,
        'email': (u.email ?? '').toLowerCase(),
        'photo': u.photoURL ?? '',
        'role': ?role,
        'lastSeenAt': FieldValue.serverTimestamp(),
        'lastActiveAtMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
      final doc = await _members.doc(u.uid).get();
      final data = doc.data() ?? {};
      if (!data.containsKey('joinedAt')) {
        await _members.doc(u.uid).set({
          'joinedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (_) {
      // أفضل جهد — تُعاد المحاولة عند الفتح التالي للوحة/الدردشة.
    }
  }

  /// نبضة حضور دوريّة — تجعل العضو «متصلاً الآن» لبقيّة المجموعة.
  Future<void> presenceTick() async {
    if (_uid.isEmpty) return;
    try {
      await _members.doc(_uid).set({
        'lastActiveAtMs': DateTime.now().millisecondsSinceEpoch,
        'lastSeenAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// تحديث مؤشّر القراءة — كلّ رسالة أقدم من هذا الطابع تُعتبر مقروءة منّي.
  Future<void> markRead() async {
    if (_uid.isEmpty) return;
    try {
      await _members.doc(_uid).set({
        'lastReadAtMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// إشارة «يكتب الآن…» (تُستدعى مقنَّنة أثناء الكتابة).
  Future<void> typingTick() async {
    if (_uid.isEmpty) return;
    try {
      await _members.doc(_uid).set({
        'typingAtMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// اختيار صورة شخصيّة للمجموعة (تظهر مع اسمي في الدردشة تلقائيّاً).
  Future<void> setMyPhotoFromPath(String filePath, String filename) async {
    final up = await chatUploadFile(
      file: File(filePath),
      filename: filename,
      contentType: guessContentType(filename),
      folder: ChatPaths.avatarsFolder,
    );
    await _members.doc(_uid).set({
      'customPhoto': up.url,
      'customPhotoPath': up.path,
    }, SetOptions(merge: true));
  }

  /// إزالة صورتي المخصّصة (يعود لصورة Google).
  Future<void> clearMyPhoto() async {
    await _members.doc(_uid).set({
      'customPhoto': '',
      'customPhotoPath': '',
    }, SetOptions(merge: true));
  }

  /// تغيير اسمي المعروض في المجموعة (ويُعلِّم اكتمال إعداد الملفّ الشخصي).
  Future<void> setMyName(String name) async {
    await _members.doc(_uid).set({
      'customName': name.trim(),
      'profileSet': true,
    }, SetOptions(merge: true));
  }

  /// جلب وثيقتي (لملء حوار الملفّ الشخصي وفحص أوّل مرّة).
  Future<ChatMember?> fetchSelf() async {
    if (_uid.isEmpty) return null;
    try {
      final doc = await _members.doc(_uid).get();
      return doc.exists ? ChatMember.fromDoc(doc) : null;
    } catch (_) {
      return null;
    }
  }

  /// تعيين/إزالة مشرف مجموعة ⭐ (صلاحيّات داخل الدردشة فقط) — للمالك.
  Future<void> setChatRole(String uid, String? role) async {
    await _members.doc(uid).set({
      'chatRole': (role == null || role.isEmpty) ? FieldValue.delete() : role,
    }, SetOptions(merge: true));
  }

  /// إزالة عضو من المجموعة بالبريد — يستدعيها المالك عند حذف/حظر مشرف من
  /// شاشة «الحساب والمشرفون» (الإزالة التلقائيّة المقابلة للإضافة التلقائيّة).
  Future<void> removeMemberByEmail(String email) async {
    final e = email.trim().toLowerCase();
    if (e.isEmpty) return;
    try {
      final snap = await _members.where('email', isEqualTo: e).get();
      for (final d in snap.docs) {
        await d.reference.delete();
      }
    } catch (_) {
      // أفضل جهد — فقدان الصلاحيّة يمنع وصوله للدردشة على أيّ حال.
    }
  }

  Stream<List<ChatMember>> membersStream() => _members
      .orderBy('name')
      .snapshots()
      .map((s) => s.docs.map(ChatMember.fromDoc).toList());

  /// بثّ عدد الرسائل غير المقروءة (تقريبي، حتى 60 رسالة) — لشارة اللوحة.
  Stream<int> unreadCountStream() {
    final uid = _uid;
    if (uid.isEmpty) return Stream.value(0);
    return _messages
        .orderBy('sentAtMs', descending: true)
        .limit(60)
        .snapshots()
        .asyncMap((snap) async {
          final meDoc = await _members.doc(uid).get();
          final lastRead =
              ((meDoc.data() ?? const {})['lastReadAtMs'] as num?)?.toInt() ??
              0;
          return snap.docs
              .map(ChatMessage.fromDoc)
              .where(
                (m) =>
                    !m.deleted &&
                    m.senderId != uid &&
                    !m.hiddenFor.contains(uid) &&
                    m.sentAtMs > lastRead,
              )
              .length;
        });
  }
}

/// تخمين MIME من الامتداد (لاختيار نوع الفقاعة وقاعدة Storage الملائمة).
String guessContentType(String filename) {
  final ext = filename.contains('.')
      ? filename.split('.').last.toLowerCase()
      : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    '3gp' => 'video/3gpp',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'pdf' => 'application/pdf',
    'epub' => 'application/epub+zip',
    'zip' => 'application/zip',
    'apk' => 'application/vnd.android.package-archive',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'txt' => 'text/plain',
    _ => 'application/octet-stream',
  };
}

/// نوع الرسالة الملائم لمرفق بحسب MIME.
ChatMessageType chatTypeForMime(String contentType) {
  if (contentType.startsWith('image/')) return ChatMessageType.image;
  if (contentType.startsWith('video/')) return ChatMessageType.video;
  if (contentType.startsWith('audio/')) return ChatMessageType.audio;
  return ChatMessageType.file;
}

/// تنسيق حجم ملفّ للعرض.
String formatBytes(int bytes) {
  if (bytes <= 0) return '';
  const units = ['بايت', 'ك.ب', 'م.ب', 'غ.ب'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}
