import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'chat_repository.dart';

/// 💬 المحادثات الفرديّة بين المشرفين (نمط واتساب: محادثة خاصّة لكلّ ثنائي).
///
/// البنية:
///   • `admin_dm_threads/{threadId}` — بيانات المحادثة:
///     `members: [uidA, uidB]` (مرتَّبة أبجديّاً فيكون المعرّف حتميّاً)،
///     آخر رسالة ووقتها ومرسِلها، ومؤشّرات القراءة والكتابة لكلّ عضو.
///   • `admin_dm_threads/{threadId}/messages/{msgId}` — الرسائل بنفس شكل
///     رسائل المجموعة تماماً (فتُعاد استعمال نفس الفقاعة والمزايا).
///
/// الأمان: القواعد تسمح بالقراءة/الكتابة فقط لعضوَي المحادثة، ولا يصل
/// إليها تطبيق منبر العامّ إطلاقاً.
class DmPaths {
  DmPaths._();
  static const String threads = 'admin_dm_threads';
  static const String messages = 'messages';
  static const String storageFolder = 'admin_chat/dm';

  /// معرّف حتميّ للمحادثة بين طرفين (مستقلّ عن ترتيب الاستدعاء).
  static String threadId(String a, String b) {
    final ids = [a, b]..sort();
    return '${ids[0]}__${ids[1]}';
  }
}

/// ملخّص محادثة فرديّة كما يظهر في قائمة «الرسائل الخاصّة».
class DmThread {
  const DmThread({
    required this.id,
    required this.members,
    required this.lastText,
    required this.lastType,
    required this.lastSenderId,
    required this.lastAtMs,
    required this.readAtMs,
  });

  final String id;
  final List<String> members;
  final String lastText;
  final ChatMessageType lastType;
  final String lastSenderId;
  final int lastAtMs;

  /// آخر لحظة قراءة لكلّ عضو {uid: ms}.
  final Map<String, int> readAtMs;

  String otherOf(String myUid) =>
      members.firstWhere((m) => m != myUid, orElse: () => myUid);

  /// عدد غير المقروء تقريبيّ: رسالة أحدث من آخر قراءتي ومن غيري.
  bool hasUnreadFor(String myUid) =>
      lastSenderId.isNotEmpty &&
      lastSenderId != myUid &&
      lastAtMs > (readAtMs[myUid] ?? 0);

  /// معاينة آخر رسالة بنمط واتساب (مع بادئة «أنت:» لرسائلي).
  String previewFor(String myUid) {
    final body = lastType == ChatMessageType.text
        ? lastText
        : chatTypeLabel(lastType);
    if (body.isEmpty) return 'لا رسائل بعد';
    return lastSenderId == myUid ? 'أنت: $body' : body;
  }

  static DmThread fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map?)?.cast<String, dynamic>() ?? {};
    final read = <String, int>{};
    if (d['readAtMs'] is Map) {
      (d['readAtMs'] as Map).forEach((k, v) {
        if (v is num) read['$k'] = v.toInt();
      });
    }
    return DmThread(
      id: doc.id,
      members: (d['members'] is List)
          ? (d['members'] as List).map((e) => '$e').toList()
          : const [],
      lastText: '${d['lastText'] ?? ''}',
      lastType: chatTypeFromString('${d['lastType'] ?? 'text'}'),
      lastSenderId: '${d['lastSenderId'] ?? ''}',
      lastAtMs: (d['lastAtMs'] is num) ? (d['lastAtMs'] as num).toInt() : 0,
      readAtMs: read,
    );
  }
}

class DmRepository {
  DmRepository._();
  static final DmRepository instance = DmRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  DocumentReference<Map<String, dynamic>> _thread(String id) =>
      _db.collection(DmPaths.threads).doc(id);

  CollectionReference<Map<String, dynamic>> _msgs(String id) =>
      _thread(id).collection(DmPaths.messages);

  /// كلّ محادثاتي (الأحدث أولاً).
  Stream<List<DmThread>> threadsStream() {
    final uid = _uid;
    if (uid.isEmpty) return Stream.value(const []);
    return _db
        .collection(DmPaths.threads)
        .where('members', arrayContains: uid)
        .snapshots()
        .map((s) {
          final list = s.docs.map(DmThread.fromDoc).toList();
          list.sort((a, b) => b.lastAtMs.compareTo(a.lastAtMs));
          return list;
        });
  }

  /// عدد المحادثات التي تحوي رسائل لم أقرأها (شارة اللوحة).
  Stream<int> unreadThreadsStream() {
    final uid = _uid;
    if (uid.isEmpty) return Stream.value(0);
    return threadsStream().map(
      (list) => list.where((t) => t.hasUnreadFor(uid)).length,
    );
  }

  Stream<DmThread?> threadStream(String threadId) =>
      _thread(threadId).snapshots().map((d) => d.exists ? DmThread.fromDoc(d) : null);

  Stream<List<ChatMessage>> messagesStream(String threadId, {int limit = 60}) {
    final uid = _uid;
    return _msgs(threadId)
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

  /// يضمن وجود وثيقة المحادثة قبل أوّل رسالة (تحتاجها القواعد للتحقّق من
  /// العضويّة، ويحتاجها بثّ القائمة لإظهار المحادثة فوراً).
  Future<String> ensureThread(String otherUid) async {
    final id = DmPaths.threadId(_uid, otherUid);
    final members = [_uid, otherUid]..sort();
    await _thread(id).set({
      'members': members,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return id;
  }

  Future<void> _touchThread({
    required String threadId,
    required String otherUid,
    required String lastText,
    required ChatMessageType type,
  }) async {
    final members = [_uid, otherUid]..sort();
    await _thread(threadId).set({
      'members': members,
      'lastText': lastText.length > 120
          ? '${lastText.substring(0, 120)}…'
          : lastText,
      'lastType': chatTypeToString(type),
      'lastSenderId': _uid,
      'lastAtMs': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': FieldValue.serverTimestamp(),
      'readAtMs': {_uid: DateTime.now().millisecondsSinceEpoch},
    }, SetOptions(merge: true));
  }

  Future<void> sendText({
    required String threadId,
    required String otherUid,
    required String text,
    ChatReplyRef? replyTo,
    ChatReplyRef? fromGroup,
  }) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _msgs(threadId).add({
      ..._senderFields(),
      'type': 'text',
      'text': t,
      'att': null,
      'replyTo': replyTo?.toMap(),
      // اقتباس رسالة من المجموعة عند «الردّ بشكل خاص» (نمط واتساب).
      'fromGroup': fromGroup?.toMap(),
      'sentAtMs': DateTime.now().millisecondsSinceEpoch,
      'createdAt': FieldValue.serverTimestamp(),
      'deleted': false,
      'deletedBy': '',
      'hiddenFor': <String>[],
      'reactions': <String, String>{},
    });
    await _touchThread(
      threadId: threadId,
      otherUid: otherUid,
      lastText: t,
      type: ChatMessageType.text,
    );
  }

  Future<void> sendAttachmentFromPath({
    required String threadId,
    required String otherUid,
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
      folder: '${DmPaths.storageFolder}/$threadId',
      onProgress: onProgress,
      isAborted: isAborted,
    );
    await _msgs(threadId).add({
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
    await _touchThread(
      threadId: threadId,
      otherUid: otherUid,
      lastText: caption.trim().isEmpty ? filename : caption.trim(),
      type: type,
    );
  }

  Future<void> deleteForMe(String threadId, String messageId) =>
      _msgs(threadId).doc(messageId).update({
        'hiddenFor': FieldValue.arrayUnion([_uid]),
      });

  /// حذف عند الطرفين — للمرسِل نفسه فقط (لا إشراف في المحادثات الخاصّة).
  Future<void> deleteForEveryone(String threadId, ChatMessage msg) async {
    await _msgs(threadId).doc(msg.id).update({
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
      } catch (_) {}
    }
  }

  Future<void> setReaction(
    String threadId,
    String messageId,
    String? emoji,
  ) => _msgs(threadId).doc(messageId).update({
    'reactions.$_uid': (emoji == null || emoji.isEmpty)
        ? FieldValue.delete()
        : emoji,
  });

  Future<void> markRead(String threadId) async {
    if (_uid.isEmpty) return;
    try {
      await _thread(threadId).set({
        'readAtMs': {_uid: DateTime.now().millisecondsSinceEpoch},
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> typingTick(String threadId) async {
    if (_uid.isEmpty) return;
    try {
      await _thread(threadId).set({
        'typingAtMs': {_uid: DateTime.now().millisecondsSinceEpoch},
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// هل الطرف الآخر يكتب الآن؟ (يقرأ خريطة typingAtMs من وثيقة المحادثة)
  Stream<bool> otherTypingStream(String threadId, String otherUid) =>
      _thread(threadId).snapshots().map((d) {
        final data = d.data();
        if (data == null) return false;
        final map = data['typingAtMs'];
        if (map is! Map) return false;
        final v = map[otherUid];
        if (v is! num) return false;
        return DateTime.now().millisecondsSinceEpoch - v.toInt() <
            kTypingWindow.inMilliseconds;
      });
}
