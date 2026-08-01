/**
 * Backend المرجعي المشترك لتطبيقي منبر ادكصهك (mxqp-8d1e8).
 *
 * مبادئ الحماية:
 * - العمليات الحساسة onCall تتطلب Firebase App Check.
 * - المستمع يسجل دخولاً مجهولاً قبل إنشاء مساهمة/ملاحظة/مشاهدة.
 * - صلاحية الإدارة = بريد المالك أو role=supervisor و blocked!=true.
 * - البيانات الخاصة بالمالك لا تُكتب من أي عميل، بل عبر Admin SDK فقط.
 */
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const crypto = require("crypto");

admin.initializeApp();

const db = admin.firestore();
// اسم الحاوية صراحةً: admin.storage().bucket() بلا اسم يرمي خطأً عند تحميل
// الوحدة إذا خلا FIREBASE_CONFIG من storageBucket (كما في فحص النشر المحلي)،
// فيفشل اكتشاف الدوال كلها بمهلة. المشاريع الجديدة حاويتها *.firebasestorage.app.
const bucket = admin.storage().bucket(
  JSON.parse(process.env.FIREBASE_CONFIG || "{}").storageBucket
    || "mxqp-8d1e8.firebasestorage.app",
);
const TOPIC = "content";
const OWNER_EMAIL = "bdalmjydtbwn812@gmail.com";
const ADMINS_COLLECTION = "dashboard_admins";
const CODE_TTL_MS = 10 * 60 * 1000;
const CODE_REQUEST_INTERVAL_MS = 60 * 1000;
const MAX_CODE_ATTEMPTS = 5;
const MAX_SUBMISSION_BYTES = 100 * 1024 * 1024;
const VIEW_MILESTONES = [100, 500, 1000, 5000, 10000];

function normalizeEmail(value) {
  return String(value || "").trim().toLowerCase();
}

function cleanString(value, maxLength) {
  return String(value || "").trim().slice(0, maxLength);
}

function requireString(value, field, minLength, maxLength) {
  const result = cleanString(value, maxLength);
  if (result.length < minLength) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `الحقل ${field} غير صالح.`,
    );
  }
  return result;
}

function contextEmail(context) {
  return normalizeEmail(context.auth && context.auth.token
    ? context.auth.token.email
    : "");
}

// وضع المراقبة أولاً (الخطوة 7 من تسلسل النشر الآمن): لا يُرفض الطلب بلا
// رمز App Check قبل تسجيل تواقيع Play وتفعيل Play Integrity — يُقلَب إلى
// true بعد التأكد من أن كل الطلبات الشرعية تحمل الرمز.
const APP_CHECK_ENFORCED = false;

function assertAppCheck(context) {
  if (!context.app) {
    if (APP_CHECK_ENFORCED) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "تعذر التحقق من سلامة التطبيق (App Check).",
      );
    }
    console.warn("App Check token missing — monitoring mode, request allowed.");
  }
}

function assertSignedIn(context) {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError("unauthenticated", "يجب تسجيل الدخول.");
  }
  return context.auth.uid;
}

async function assertAuthorized(context) {
  assertAppCheck(context);
  assertSignedIn(context);
  const email = contextEmail(context);
  if (!email) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "الحساب لا يملك بريداً موثقاً.",
    );
  }
  if (email === OWNER_EMAIL) return { email, owner: true };
  const snap = await db.collection(ADMINS_COLLECTION).doc(email).get();
  const data = snap.data() || {};
  if (snap.exists && data.role === "supervisor" && data.blocked !== true) {
    return { email, owner: false };
  }
  throw new functions.https.HttpsError("permission-denied", "الحساب غير مخول.");
}

async function assertOwner(context) {
  assertAppCheck(context);
  assertSignedIn(context);
  if (contextEmail(context) !== OWNER_EMAIL) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "هذه العملية خاصة بمالك التطبيق.",
    );
  }
  return OWNER_EMAIL;
}

function hashId(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function safeData(data) {
  const out = {};
  Object.entries(data || {}).forEach(([key, value]) => {
    if (value !== undefined && value !== null) out[key] = String(value);
  });
  return out;
}

async function consumeRateLimit({ uid, action, limit, windowMs, minIntervalMs }) {
  const ref = db.collection("private_rate_limits")
    .doc(hashId(`${action}:${uid}`));
  const now = Date.now();
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.data() || {};
    let windowStart = Number(current.windowStart || 0);
    let count = Number(current.count || 0);
    const lastAt = Number(current.lastAt || 0);
    if (!windowStart || now - windowStart >= windowMs) {
      windowStart = now;
      count = 0;
    }
    if (lastAt && now - lastAt < minIntervalMs) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        "طلبات متتابعة بسرعة كبيرة. حاول لاحقاً.",
      );
    }
    if (count >= limit) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        "تم بلوغ الحد المسموح مؤقتاً.",
      );
    }
    tx.set(ref, {
      uid,
      action,
      windowStart,
      count: count + 1,
      lastAt: now,
      expiresAt: now + windowMs * 2,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

async function auditOwnerAction(actorEmail, action, targetId, details) {
  await db.collection("owner_audit_logs").add({
    actorEmail,
    action,
    targetId: targetId || "",
    details: details || {},
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
  });
}

async function writeAdminAlert(email, title, body, data) {
  const metadata = safeData(data);
  const type = cleanString(metadata.type, 40);
  const refId = cleanString(
    metadata.refId
      || metadata.submissionId
      || metadata.lessonId
      || metadata.candidateEmail
      || metadata.id,
    180,
  );
  await db.collection("admin_alerts").add({
    email: normalizeEmail(email),
    excludeEmail: normalizeEmail(metadata.excludeEmail),
    title: cleanString(title, 120),
    body: cleanString(body, 700),
    type,
    refId,
    data: metadata,
    readBy: [],
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
  });
}

async function clearAdminAlerts(type, refId) {
  const normalizedType = cleanString(type, 40);
  const normalizedRef = cleanString(refId, 180);
  if (!normalizedType || !normalizedRef) return 0;
  const snap = await db.collection("admin_alerts").get();
  const refs = snap.docs.filter((doc) => {
    const value = doc.data() || {};
    const metadata = value.data || {};
    const itemType = cleanString(value.type || metadata.type, 40);
    const itemRef = cleanString(
      value.refId
        || metadata.refId
        || metadata.submissionId
        || metadata.lessonId
        || metadata.candidateEmail
        || metadata.id,
      180,
    );
    return itemType === normalizedType && itemRef === normalizedRef;
  }).map((doc) => doc.ref);
  for (let offset = 0; offset < refs.length; offset += 400) {
    const batch = db.batch();
    refs.slice(offset, offset + 400).forEach((ref) => batch.delete(ref));
    await batch.commit();
  }
  return refs.length;
}

async function writeUserNotification(uid, title, body, data) {
  const userId = cleanString(uid, 180);
  if (!userId) return null;
  const metadata = safeData(data);
  return db.collection("user_notifications").doc(userId).collection("items").add({
    title: cleanString(title, 120),
    body: cleanString(body, 700),
    type: cleanString(metadata.type, 40),
    refId: cleanString(metadata.refId || metadata.id, 180),
    data: metadata,
    read: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
  });
}

async function logPublicNotification(title, body, data) {
  await db.collection("notifications").add({
    title: cleanString(title || "منبر ادكصهك", 100),
    body: cleanString(body, 500),
    type: cleanString(data && data.type || "manual", 40),
    refId: cleanString(data && data.id, 160) || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
  });
}

async function pushToTopic(title, body, data) {
  const t = cleanString(title || "منبر ادكصهك", 100);
  const b = cleanString(body, 500);
  await logPublicNotification(t, b, data);
  return admin.messaging().send({
    topic: TOPIC,
    notification: { title: t, body: b },
    data: Object.assign(
      { click_action: "FLUTTER_NOTIFICATION_CLICK" },
      safeData(data),
    ),
    android: {
      priority: "high",
      notification: { channelId: "content_updates", sound: "default" },
    },
  });
}

async function pushToCondition(title, body, data, condition) {
  const t = cleanString(title || "منبر ادكصهك", 100);
  const b = cleanString(body, 500);
  await logPublicNotification(t, b, data);
  return admin.messaging().send({
    condition,
    notification: { title: t, body: b },
    data: Object.assign(
      { click_action: "FLUTTER_NOTIFICATION_CLICK" },
      safeData(data),
    ),
    android: {
      priority: "high",
      notification: { channelId: "content_updates", sound: "default" },
    },
  });
}

async function pushToToken(token, title, body, data) {
  if (!token) return null;
  try {
    return await admin.messaging().send({
      token,
      notification: {
        title: cleanString(title, 100),
        body: cleanString(body, 500),
      },
      data: Object.assign(
        { click_action: "FLUTTER_NOTIFICATION_CLICK" },
        safeData(data),
      ),
      android: {
        priority: "high",
        notification: { channelId: "content_updates", sound: "default" },
      },
    });
  } catch (error) {
    console.error("pushToToken failed", error);
    return null;
  }
}

async function activeAdminTokens(ownerOnly) {
  const snap = await db.collection("admin_device_tokens").get();
  if (snap.empty) return [];
  const adminCache = new Map();
  const accepted = [];
  for (const doc of snap.docs) {
    const value = doc.data() || {};
    const email = normalizeEmail(value.email);
    const token = cleanString(value.token, 4096);
    if (!email || !token) continue;
    if (email === OWNER_EMAIL) {
      accepted.push({
        ref: doc.ref,
        token,
        email,
        uid: cleanString(value.uid || doc.id, 180),
        chatMuted: value.chatMuted === true,
      });
      continue;
    }
    if (ownerOnly) continue;
    let authorized = adminCache.get(email);
    if (authorized === undefined) {
      const adminSnap = await db.collection(ADMINS_COLLECTION).doc(email).get();
      const data = adminSnap.data() || {};
      authorized = adminSnap.exists
        && data.role === "supervisor"
        && data.blocked !== true;
      adminCache.set(email, authorized);
    }
    if (authorized) {
      accepted.push({
        ref: doc.ref,
        token,
        email,
        uid: cleanString(value.uid || doc.id, 180),
        chatMuted: value.chatMuted === true,
      });
    }
  }
  return accepted;
}

async function pushToAdmins(title, body, data, ownerOnly = false) {
  const targets = await activeAdminTokens(ownerOnly);
  return sendToAdminTargets(targets, title, body, data);
}

async function pushToAdminsFiltered(title, body, data, options = {}) {
  const targets = (await activeAdminTokens(options.ownerOnly === true)).filter((item) => {
    if (options.targetEmail && item.email !== normalizeEmail(options.targetEmail)) return false;
    if (options.excludeEmail && item.email === normalizeEmail(options.excludeEmail)) return false;
    if (options.excludeUid && item.uid === cleanString(options.excludeUid, 180)) return false;
    if (options.respectChatMute && item.chatMuted) return false;
    return true;
  });
  return sendToAdminTargets(targets, title, body, data);
}

async function sendToAdminTargets(targets, title, body, data) {
  if (!targets.length) return { successCount: 0, failureCount: 0 };
  let successCount = 0;
  let failureCount = 0;
  for (let offset = 0; offset < targets.length; offset += 500) {
    const chunk = targets.slice(offset, offset + 500);
    const response = await admin.messaging().sendEachForMulticast({
      tokens: chunk.map((item) => item.token),
      notification: {
        title: cleanString(title, 100),
        body: cleanString(body, 500),
      },
      data: Object.assign(
        { click_action: "FLUTTER_NOTIFICATION_CLICK" },
        safeData(data),
      ),
      android: {
        priority: "high",
        notification: { channelId: "admin_alerts", sound: "default" },
      },
    });
    successCount += response.successCount;
    failureCount += response.failureCount;
    const removals = [];
    response.responses.forEach((item, index) => {
      const code = item.error && item.error.code || "";
      if (code.includes("registration-token-not-registered")
          || code.includes("invalid-registration-token")) {
        removals.push(chunk[index].ref.delete());
      }
    });
    await Promise.all(removals);
  }
  return { successCount, failureCount };
}

function unwrapLegacy(raw) {
  if (raw && raw.data && typeof raw.data === "object") {
    return Object.assign({}, raw.data, raw);
  }
  return raw || {};
}

// ─── المحتوى المنشور وإشعاراته ─────────────────────────────────────
exports.onLessonCreated = functions.firestore
  .document("lessons/{id}")
  .onCreate(async (snap) => {
    const d = unwrapLegacy(snap.data());
    if (d.publishAt) {
      const at = Date.parse(d.publishAt);
      if (!Number.isNaN(at) && at > Date.now()) return null;
    }
    const title = cleanString(d.title || d.name, 180);
    const subId = cleanString(d.subcategoryId, 160);
    if (subId) {
      await pushToCondition(
        "درس جديد",
        title || "أُضيف درس صوتي جديد",
        { type: "lesson", id: snap.id, subId },
        `'${TOPIC}' in topics || 'sec_${subId}' in topics`,
      );
    } else {
      await pushToTopic(
        "درس جديد",
        title || "أُضيف درس صوتي جديد",
        { type: "lesson", id: snap.id },
      );
    }
    // يمنع ازدواج الإشعار مع publishScheduledLessons عندما يكون publishAt
    // وقتاً ماضياً لحظة الإنشاء (رفع طويل تجاوز موعد الجدولة).
    await snap.ref.set({ publishNotified: true }, { merge: true })
      .catch((error) => console.error("mark publishNotified failed", error));
    return null;
  });

exports.onSubcategoryCreated = functions.firestore
  .document("subcategories/{id}")
  .onCreate((snap) => {
    const d = unwrapLegacy(snap.data());
    return pushToTopic(
      "قسم فرعي جديد",
      cleanString(d.name, 180) || "أُضيف قسم فرعي جديد",
      { type: "subcategory", id: snap.id },
    );
  });

exports.onCategoryCreated = functions.firestore
  .document("categories/{id}")
  .onCreate((snap) => {
    const d = unwrapLegacy(snap.data());
    return pushToTopic(
      "قسم جديد",
      cleanString(d.name, 180) || "أُضيف قسم رئيسي جديد",
      { type: "category", id: snap.id },
    );
  });

exports.onBookCreated = functions.firestore
  .document("books/{id}")
  .onCreate((snap) => {
    const d = unwrapLegacy(snap.data());
    return pushToTopic(
      "كتاب جديد",
      cleanString(d.name, 180) || "أُضيف كتاب جديد",
      { type: "book", id: snap.id },
    );
  });

exports.onLessonMilestone = functions.firestore
  .document("lessons/{id}")
  .onUpdate(async (change) => {
    const before = unwrapLegacy(change.before.data());
    const after = unwrapLegacy(change.after.data());
    const previousViews = Number(before.views || 0);
    const nextViews = Number(after.views || 0);
    if (nextViews <= previousViews) return null;
    const crossed = VIEW_MILESTONES.find(
      (milestone) => previousViews < milestone && nextViews >= milestone,
    );
    if (!crossed) return null;
    const lessonTitle = cleanString(after.title || "درس", 180);
    const authorEmail = normalizeEmail(after.createdByEmail || after.addedBy);
    const body = `الدرس «${lessonTitle}» وصل إلى ${crossed} استماع.`;
    // صاحب الدرس يُخاطَب باسم «درسك» (تنبيهاً ودفعاً)، والبقية بالنص العام.
    const tasks = [
      writeAdminAlert("", "🎉 إنجاز استماع جديد", body, {
        type: "engagement",
        lessonId: change.after.id,
        refId: change.after.id,
        excludeEmail: authorEmail,
      }),
      pushToAdminsFiltered("🎉 إنجاز استماع جديد", body, {
        type: "engagement",
        lessonId: change.after.id,
      }, { excludeEmail: authorEmail }),
    ];
    if (authorEmail) {
      tasks.push(writeAdminAlert(authorEmail, "🎉 إنجاز جديد لدرسك", body, {
        type: "engagement",
        lessonId: change.after.id,
        refId: change.after.id,
      }));
      tasks.push(pushToAdminsFiltered("🎉 إنجاز جديد لدرسك", body, {
        type: "engagement",
        lessonId: change.after.id,
      }, { targetEmail: authorEmail }));
    }
    await Promise.all(tasks);
    return null;
  });

async function dispatchScheduledLesson(doc, origin) {
  const dispatchRef = db.collection("notification_dispatches")
    .doc(`scheduled_lesson_${doc.id}`);
  const now = Date.now();
  const claimed = await db.runTransaction(async (tx) => {
    const [dispatchSnap, lessonSnap] = await Promise.all([
      tx.get(dispatchRef),
      tx.get(doc.ref),
    ]);
    if (!lessonSnap.exists) return false;
    const lesson = unwrapLegacy(lessonSnap.data());
    const dispatch = dispatchSnap.data() || {};
    if (lesson.publishNotified === true || dispatch.status === "sent") return false;
    if (dispatch.status === "claimed" && Number(dispatch.leaseUntil || 0) > now) {
      return false;
    }
    tx.set(dispatchRef, {
      lessonId: doc.id,
      status: "claimed",
      origin,
      claimedAt: admin.firestore.FieldValue.serverTimestamp(),
      leaseUntil: now + 5 * 60 * 1000,
      attempts: Number(dispatch.attempts || 0) + 1,
    }, { merge: true });
    return true;
  });
  if (!claimed) return false;
  const fresh = await doc.ref.get();
  if (!fresh.exists) return false;
  const value = unwrapLegacy(fresh.data());
  const title = cleanString(value.title || value.name, 180);
  const subId = cleanString(value.subcategoryId, 160);
  try {
    if (subId) {
      await pushToCondition(
        "درس جديد",
        title || "أُضيف درس صوتي جديد",
        { type: "lesson", id: doc.id, subId },
        `'${TOPIC}' in topics || 'sec_${subId}' in topics`,
      );
    } else {
      await pushToTopic(
        "درس جديد",
        title || "أُضيف درس صوتي جديد",
        { type: "lesson", id: doc.id },
      );
    }
    const batch = db.batch();
    batch.set(dispatchRef, {
      status: "sent",
      sentAt: admin.firestore.FieldValue.serverTimestamp(),
      leaseUntil: 0,
    }, { merge: true });
    batch.update(doc.ref, {
      publishNotified: true,
      publishedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await batch.commit();
    return true;
  } catch (error) {
    await dispatchRef.set({
      status: "failed",
      leaseUntil: 0,
      lastError: cleanString(error && error.message, 500),
      failedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true }).catch(() => {});
    throw error;
  }
}

exports.publishScheduledLessons = functions.pubsub
  .schedule("*/15 * * * *")
  .timeZone("Asia/Riyadh")
  .onRun(async () => {
    const nowIso = new Date().toISOString();
    const snap = await db.collection("lessons")
      .where("publishAt", "<=", nowIso)
      .get();
    await Promise.all(snap.docs.map(
      (doc) => dispatchScheduledLesson(doc, "scheduler")
        .catch((error) => console.error("scheduled publish failed", doc.id, error)),
    ));
    return null;
  });

exports.publishScheduledLesson = functions.https.onCall(async (data, context) => {
  const actor = await assertAuthorized(context);
  const lessonId = requireString(data && data.lessonId, "lessonId", 1, 180);
  const ref = db.collection("lessons").doc(lessonId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new functions.https.HttpsError("not-found", "الدرس غير موجود.");
  }
  if (unwrapLegacy(snap.data()).publishNotified !== true) {
    await ref.update({ publishAt: new Date().toISOString() });
  }
  const sent = await dispatchScheduledLesson(await ref.get(), `manual:${actor.email}`);
  await auditOwnerAction(actor.email, "publish_scheduled_lesson", lessonId, { sent });
  return { ok: true, id: lessonId, sent };
});

exports.weeklyDigest = functions.pubsub
  .schedule("0 9 * * 1")
  .timeZone("Asia/Riyadh")
  .onRun(async () => {
    const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const snap = await db.collection("lessons").get();
    let newCount = 0;
    let totalViews = 0;
    snap.forEach((doc) => {
      const d = unwrapLegacy(doc.data());
      totalViews += Number(d.views || 0);
      let createdAt = 0;
      if (d.createdAtTs && typeof d.createdAtTs.toMillis === "function") {
        createdAt = d.createdAtTs.toMillis();
      } else {
        createdAt = Date.parse(d.createdAt || "") || 0;
      }
      if (createdAt >= weekAgo) newCount += 1;
    });
    const title = "📊 تقرير الأسبوع";
    const body = `دروس جديدة هذا الأسبوع: ${newCount} · إجمالي الاستماع: ${totalViews}.`;
    await writeAdminAlert("", title, body, { type: "weekly_digest" });
    await pushToAdmins(title, body, { type: "weekly_digest" });
    return null;
  });

// ─── الاستدعاءات العامة المحمية بـ App Check وحدود المعدل ───────────
exports.incrementLessonView = functions.https.onCall(async (data, context) => {
  assertAppCheck(context);
  const uid = assertSignedIn(context);
  const lessonId = requireString(data && data.lessonId, "lessonId", 1, 180);
  await consumeRateLimit({
    uid,
    action: "lesson-views-day",
    limit: 500,
    windowMs: 24 * 60 * 60 * 1000,
    minIntervalMs: 1200,
  });
  const perLessonRef = db.collection("private_rate_limits")
    .doc(hashId(`lesson-view:${uid}:${lessonId}`));
  const lessonRef = db.collection("lessons").doc(lessonId);
  const now = Date.now();
  const counted = await db.runTransaction(async (tx) => {
    const [rateSnap, lessonSnap] = await Promise.all([
      tx.get(perLessonRef),
      tx.get(lessonRef),
    ]);
    if (!lessonSnap.exists) {
      throw new functions.https.HttpsError("not-found", "الدرس غير موجود.");
    }
    const lastAt = Number((rateSnap.data() || {}).lastAt || 0);
    if (lastAt && now - lastAt < 30 * 1000) return false;
    const current = unwrapLegacy(lessonSnap.data());
    tx.set(perLessonRef, {
      uid,
      action: "lesson-view",
      lessonId,
      lastAt: now,
      expiresAt: now + 7 * 24 * 60 * 60 * 1000,
    });
    tx.update(lessonRef, { views: Number(current.views || 0) + 1 });
    return true;
  });
  return { ok: true, counted };
});

exports.sendFeedback = functions.https.onCall(async (data, context) => {
  assertAppCheck(context);
  const uid = assertSignedIn(context);
  await consumeRateLimit({
    uid,
    action: "feedback",
    limit: 12,
    windowMs: 24 * 60 * 60 * 1000,
    minIntervalMs: 10 * 1000,
  });
  const lessonId = requireString(data && data.lessonId, "lessonId", 1, 180);
  const type = requireString(data && data.type, "type", 1, 40);
  const allowedTypes = ["benefited", "audio_issue", "other", "copyright", "abuse"];
  if (!allowedTypes.includes(type)) {
    throw new functions.https.HttpsError("invalid-argument", "نوع الملاحظة غير صالح.");
  }
  const note = cleanString(data && data.note, 500);
  const lessonSnap = await db.collection("lessons").doc(lessonId).get();
  if (!lessonSnap.exists) {
    throw new functions.https.HttpsError("not-found", "الدرس غير موجود.");
  }
  const ref = await db.collection("feedback").add({
    uid,
    lessonId,
    type,
    note,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
  });
  const lesson = unwrapLegacy(lessonSnap.data());
  const lessonTitle = cleanString(lesson.title || "درس", 180);
  const authorEmail = normalizeEmail(lesson.createdByEmail || lesson.addedBy);
  const labels = {
    benefited: "أفاد مستمع بأنه انتفع بالدرس",
    audio_issue: "أبلغ مستمع عن مشكلة في الصوت",
    other: "أرسل مستمع ملاحظة على الدرس",
    copyright: "ورد بلاغ حقوق نشر على الدرس",
    abuse: "ورد بلاغ إساءة على الدرس",
  };
  const alertTitle = labels[type] || "تفاعل جديد مع درس";
  const alertBody = `${alertTitle}: «${lessonTitle}»${note ? ` — ${note}` : "."}`;
  // صاحب الدرس يُخاطَب باسم «درسك» (تنبيهاً ودفعاً)، والبقية بالنص العام —
  // بلا ازدواج إشعارات لأي أحد.
  const tasks = [
    writeAdminAlert("", alertTitle, alertBody, {
      type: "engagement",
      lessonId,
      refId: lessonId,
      feedbackId: ref.id,
      excludeEmail: authorEmail,
    }),
    pushToAdminsFiltered(alertTitle, alertBody, {
      type: "engagement",
      lessonId,
      feedbackId: ref.id,
    }, { excludeEmail: authorEmail }),
  ];
  if (authorEmail) {
    tasks.push(writeAdminAlert(authorEmail, "تفاعل جديد مع درسك", alertBody, {
      type: "engagement",
      lessonId,
      refId: lessonId,
      feedbackId: ref.id,
    }));
    tasks.push(pushToAdminsFiltered("تفاعل جديد مع درسك", alertBody, {
      type: "engagement",
      lessonId,
      feedbackId: ref.id,
    }, { targetEmail: authorEmail }));
  }
  await Promise.all(tasks);
  return { ok: true, feedbackId: ref.id };
});

exports.createSubmission = functions.https.onCall(async (data, context) => {
  assertAppCheck(context);
  const uid = assertSignedIn(context);

  const title = requireString(data && data.title, "title", 3, 120);
  const submitterName = cleanString(data && data.submitterName, 60);
  const note = cleanString(data && data.note, 500);
  const categoryId = cleanString(data && data.categoryId, 180);
  const categoryName = cleanString(data && data.categoryName, 180);
  const subcategoryId = cleanString(data && data.subcategoryId, 180);
  const subcategoryName = cleanString(data && data.subcategoryName, 180);
  const storagePath = requireString(data && data.storagePath, "storagePath", 1, 700);
  const fileName = cleanString(data && data.fileName, 255);
  const audioUrl = cleanString(data && data.audioUrl, 2500);
  const fcmToken = cleanString(data && data.fcmToken, 4096);
  const termsAcceptedAt = cleanString(data && data.termsAcceptedAt, 80);
  const parsedTermsAcceptedAt = Date.parse(termsAcceptedAt);
  const accepted = Boolean(termsAcceptedAt)
    && !Number.isNaN(parsedTermsAcceptedAt)
    && parsedTermsAcceptedAt <= Date.now() + 5 * 60 * 1000;
  if (!(data && data.rightsConfirmed === true) || !accepted) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "يجب تأكيد حق النشر والموافقة على سياسة المحتوى.",
    );
  }
  const requiredPrefix = `submissions/${uid}/`;
  if (!storagePath.startsWith(requiredPrefix) || storagePath.includes("..")) {
    throw new functions.https.HttpsError("permission-denied", "مسار الملف غير صالح.");
  }
  let metadata;
  try {
    [metadata] = await bucket.file(storagePath).getMetadata();
  } catch (error) {
    console.error("submission metadata failed", error);
    throw new functions.https.HttpsError("not-found", "ملف المساهمة غير موجود.");
  }
  const size = Number(metadata.size || 0);
  const contentType = String(metadata.contentType || "");
  if (size <= 0 || size > MAX_SUBMISSION_BYTES || !contentType.startsWith("audio/")) {
    throw new functions.https.HttpsError("invalid-argument", "ملف الصوت غير صالح.");
  }

  const pathParts = storagePath.split("/");
  const pathSubmissionId = pathParts.length >= 4 ? pathParts[2] : "";
  const requestedId = cleanString(
    data && data.submissionId || pathSubmissionId,
    180,
  );
  const ref = requestedId && /^[A-Za-z0-9_-]+$/.test(requestedId)
    ? db.collection("lesson_submissions").doc(requestedId)
    : db.collection("lesson_submissions").doc();
  if (!storagePath.includes(`/${ref.id}/`) && requestedId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "معرف المساهمة لا يطابق مسار الملف.",
    );
  }
  const existing = await ref.get();
  if (existing.exists) {
    const existingData = existing.data() || {};
    if (existingData.uid === uid && existingData.storagePath === storagePath) {
      return { ok: true, id: ref.id, submissionId: ref.id, existing: true };
    }
    throw new functions.https.HttpsError("already-exists", "المساهمة موجودة مسبقاً.");
  }
  await consumeRateLimit({
    uid,
    action: "submission",
    limit: 5,
    windowMs: 24 * 60 * 60 * 1000,
    minIntervalMs: 60 * 1000,
  });
  await ref.set({
    uid,
    submitterName,
    title,
    categoryId,
    categoryName,
    subcategoryId,
    subcategoryName,
    note,
    audioUrl,
    storagePath,
    fileName: fileName || storagePath.split("/").pop(),
    fileSize: size,
    contentType,
    fcmToken,
    status: "pending",
    rejectReason: "",
    rightsConfirmed: true,
    termsAccepted: true,
    termsAcceptedAt,
    termsAcceptedAtTs: admin.firestore.FieldValue.serverTimestamp(),
    contentPolicyVersion: cleanString(data && data.contentPolicyVersion, 40) || "2026-07",
    createdAt: new Date().toISOString(),
    createdAtTs: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
  });
  return { ok: true, id: ref.id, submissionId: ref.id };
});

// ينشئ الدرس من هوية Firebase الموثقة، ولا يثق بأي createdBy يرسله العميل.
exports.createLesson = functions.https.onCall(async (data, context) => {
  const actor = await assertAuthorized(context);
  const input = data && data.lesson && typeof data.lesson === "object"
    ? data.lesson
    : data || {};
  const title = requireString(input.title || input.name, "title", 2, 180);
  const audioUrl = requireString(input.audioUrl || input.url, "audioUrl", 8, 2500);
  try {
    const parsed = new URL(audioUrl);
    if (!["https:", "http:"].includes(parsed.protocol)) throw new Error("protocol");
  } catch (_) {
    throw new functions.https.HttpsError("invalid-argument", "رابط الصوت غير صالح.");
  }
  const publishAt = cleanString(input.publishAt, 80);
  if (publishAt && Number.isNaN(Date.parse(publishAt))) {
    throw new functions.https.HttpsError("invalid-argument", "موعد النشر غير صالح.");
  }
  const storagePath = cleanString(
    input.storagePath || input.audioStoragePath,
    700,
  );
  if (storagePath.startsWith("submissions/")) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "لا يجوز نشر درس مباشر من مجلد المساهمات الخاص.",
    );
  }
  const nowIso = new Date().toISOString();
  const lessonData = {
    title,
    normalizedTitle: title.toLocaleLowerCase("ar").replace(/\s+/g, " ").trim(),
    audioUrl,
    categoryId: cleanString(input.categoryId, 180),
    categoryName: cleanString(input.categoryName, 180),
    subcategoryId: cleanString(input.subcategoryId, 180),
    subcategoryName: cleanString(input.subcategoryName, 180),
    description: cleanString(input.description, 3000),
    sheikhName: cleanString(input.sheikhName, 180),
    featured: input.featured === true,
    views: 0,
    createdAt: nowIso,
    createdAtTs: admin.firestore.FieldValue.serverTimestamp(),
    createdByUid: context.auth.uid,
    createdByEmail: actor.email,
    addedBy: actor.email,
    updatedByUid: context.auth.uid,
    updatedByEmail: actor.email,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    publishNotified: false,
  };
  if (storagePath) {
    lessonData.storagePath = storagePath;
    lessonData.audioStoragePath = storagePath;
  }
  if (publishAt) lessonData.publishAt = new Date(publishAt).toISOString();
  if (Number.isFinite(Number(input.duration))) {
    lessonData.duration = Number(input.duration);
  }
  if (Number.isFinite(Number(input.durationSeconds))) {
    lessonData.durationSeconds = Number(input.durationSeconds);
  }
  if (Number.isFinite(Number(input.order))) lessonData.order = Number(input.order);
  const optionalStrings = [
    "source", "sourceUrl", "bookId", "imageUrl", "transcript",
  ];
  optionalStrings.forEach((key) => {
    const value = cleanString(input[key], key === "transcript" ? 10000 : 2500);
    if (value) lessonData[key] = value;
  });
  if (Array.isArray(input.tags)) {
    lessonData.tags = input.tags
      .slice(0, 20)
      .map((item) => cleanString(item, 60))
      .filter(Boolean);
  }
  const lessonRef = db.collection("lessons").doc();
  await lessonRef.set(lessonData);
  await auditOwnerAction(actor.email, "create_lesson", lessonRef.id, {
    title,
    scheduled: Boolean(publishAt),
  });
  return { ok: true, id: lessonRef.id };
});

async function anonymizePublishedLessons(uid) {
  const snap = await db.collection("lessons")
    .where("submittedByUid", "==", uid)
    .get();
  for (let offset = 0; offset < snap.docs.length; offset += 400) {
    const batch = db.batch();
    snap.docs.slice(offset, offset + 400).forEach((doc) => {
      batch.update(doc.ref, {
        submittedByUid: admin.firestore.FieldValue.delete(),
        submittedBy: admin.firestore.FieldValue.delete(),
        contributorDeletedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });
    await batch.commit();
  }
  return snap.size;
}

async function deleteQuery(query, beforeDelete) {
  const snap = await query.get();
  for (const doc of snap.docs) {
    if (beforeDelete) await beforeDelete(doc.data() || {});
  }
  for (let offset = 0; offset < snap.docs.length; offset += 400) {
    const batch = db.batch();
    snap.docs.slice(offset, offset + 400).forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
  }
  return snap.size;
}

exports.deleteMyData = functions.runWith({ timeoutSeconds: 120, memory: "512MB" })
  .https.onCall(async (_data, context) => {
    assertAppCheck(context);
    const uid = assertSignedIn(context);
    await consumeRateLimit({
      uid,
      action: "delete-my-data",
      limit: 2,
      windowMs: 24 * 60 * 60 * 1000,
      minIntervalMs: 60 * 1000,
    });
    const submissions = await deleteQuery(
      db.collection("lesson_submissions").where("uid", "==", uid),
      async (value) => {
        if (value.storagePath) await deleteFileIfExists(value.storagePath);
      },
    );
    const feedback = await deleteQuery(
      db.collection("feedback").where("uid", "==", uid),
    );
    const anonymizedLessons = await anonymizePublishedLessons(uid);
    await db.collection("admin_device_tokens").doc(uid).delete().catch(() => {});
    const rates = await deleteQuery(
      db.collection("private_rate_limits").where("uid", "==", uid),
    );
    await admin.auth().deleteUser(uid).catch((error) => {
      if (error.code !== "auth/user-not-found") throw error;
    });
    return {
      ok: true,
      deleted: { submissions, feedback, rates },
      anonymizedLessons,
    };
  });

// ─── أدوات الملفات والمساهمات الإدارية الذرية ───────────────────────
function storagePathFromUrl(pathOrUrl) {
  const value = String(pathOrUrl || "").trim();
  if (!value) return "";
  if (!/^https?:/i.test(value)) return value.replace(/^\/+/, "");
  try {
    const url = new URL(value);
    const marker = "/o/";
    const index = url.pathname.indexOf(marker);
    if (index >= 0) return decodeURIComponent(url.pathname.slice(index + marker.length));
  } catch (_) {
    return "";
  }
  return "";
}

async function deleteFileIfExists(pathOrUrl) {
  const path = storagePathFromUrl(pathOrUrl);
  if (!path) return false;
  try {
    await bucket.file(path).delete({ ignoreNotFound: true });
    return true;
  } catch (error) {
    if (error.code === 404) return true;
    console.error("storage delete failed", path, error);
    throw error;
  }
}

function safeFileName(value) {
  const original = cleanString(value, 255) || "lesson.mp3";
  return original.replace(/[^\p{L}\p{N}._-]+/gu, "_");
}

async function copySubmissionAudio(sourcePath, lessonId, fileName) {
  const source = bucket.file(sourcePath);
  const [metadata] = await source.getMetadata();
  const destinationPath = `lessons/${lessonId}/${safeFileName(fileName)}`;
  const destination = bucket.file(destinationPath);
  await source.copy(destination);
  const token = crypto.randomUUID();
  await destination.setMetadata({
    contentType: metadata.contentType || "audio/mpeg",
    cacheControl: "public,max-age=3600",
    metadata: {
      firebaseStorageDownloadTokens: token,
      sourceSubmissionPath: sourcePath,
    },
  });
  const audioUrl = `https://firebasestorage.googleapis.com/v0/b/${encodeURIComponent(bucket.name)}`
    + `/o/${encodeURIComponent(destinationPath)}?alt=media&token=${token}`;
  return { destinationPath, audioUrl };
}

exports.approveSubmission = functions.runWith({ timeoutSeconds: 120, memory: "512MB" })
  .https.onCall(async (data, context) => {
    const actor = await assertAuthorized(context);
    const submissionId = requireString(
      data && data.submissionId,
      "submissionId",
      1,
      180,
    );
    const submissionRef = db.collection("lesson_submissions").doc(submissionId);
    const firstSnap = await submissionRef.get();
    if (!firstSnap.exists) {
      throw new functions.https.HttpsError("not-found", "المساهمة غير موجودة.");
    }
    const original = firstSnap.data() || {};
    if (original.status !== "pending") {
      if (["approved", "approved_edited"].includes(original.status)
          && original.publishedLessonId) {
        return {
          ok: true,
          id: original.publishedLessonId,
          lessonId: original.publishedLessonId,
          storagePath: cleanString(original.publishedStoragePath, 700),
          alreadyApproved: true,
        };
      }
      throw new functions.https.HttpsError(
        "failed-precondition",
        "سبق حسم هذه المساهمة.",
      );
    }
    const title = requireString(
      data && data.title || original.title,
      "title",
      3,
      120,
    );
    const categoryId = cleanString(data && data.categoryId || original.categoryId, 180);
    const categoryName = cleanString(data && data.categoryName || original.categoryName, 180);
    const subcategoryId = cleanString(
      data && data.subcategoryId || original.subcategoryId,
      180,
    );
    const subcategoryName = cleanString(
      data && data.subcategoryName || original.subcategoryName,
      180,
    );
    const sourcePath = requireString(original.storagePath, "storagePath", 1, 700);
    const lessonRef = db.collection("lessons").doc();
    let published;
    try {
      published = await copySubmissionAudio(
        sourcePath,
        lessonRef.id,
        original.fileName,
      );
      const edited = title !== cleanString(original.title, 120)
        || categoryId !== cleanString(original.categoryId, 180)
        || subcategoryId !== cleanString(original.subcategoryId, 180);
      const status = edited ? "approved_edited" : "approved";
      await db.runTransaction(async (tx) => {
        const currentSnap = await tx.get(submissionRef);
        if (!currentSnap.exists || currentSnap.data().status !== "pending") {
          throw new functions.https.HttpsError(
            "aborted",
            "حُسمت المساهمة من مشرف آخر.",
          );
        }
        tx.create(lessonRef, {
          title,
          normalizedTitle: title.toLocaleLowerCase("ar").replace(/\s+/g, " ").trim(),
          categoryId,
          categoryName,
          subcategoryId,
          subcategoryName,
          audioUrl: published.audioUrl,
          audioStoragePath: published.destinationPath,
          storagePath: published.destinationPath,
          views: 0,
          createdAt: new Date().toISOString(),
          createdAtTs: admin.firestore.FieldValue.serverTimestamp(),
          addedBy: actor.email,
          createdByUid: context.auth.uid,
          createdByEmail: actor.email,
          updatedByUid: context.auth.uid,
          updatedByEmail: actor.email,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          sourceSubmissionId: submissionId,
          submittedByUid: cleanString(original.uid, 180),
          submittedBy: cleanString(original.submitterName, 60),
        });
        tx.update(submissionRef, {
          status,
          publishedLessonId: lessonRef.id,
          publishedTitle: title,
          publishedCategoryName: categoryName,
          publishedSubcategoryName: subcategoryName,
          publishedStoragePath: published.destinationPath,
          decidedBy: actor.email,
          decidedAt: new Date().toISOString(),
          decidedAtTs: admin.firestore.FieldValue.serverTimestamp(),
          cleanupPending: false,
        });
      });
    } catch (error) {
      if (published && published.destinationPath) {
        await deleteFileIfExists(published.destinationPath).catch(() => {});
      }
      throw error;
    }
    try {
      await deleteFileIfExists(sourcePath);
    } catch (_) {
      await submissionRef.update({ cleanupPending: true }).catch(() => {});
    }
    await auditOwnerAction(
      actor.email,
      "approve_submission",
      submissionId,
      { lessonId: lessonRef.id },
    );
    return {
      ok: true,
      id: lessonRef.id,
      lessonId: lessonRef.id,
      audioUrl: published.audioUrl,
      storagePath: published.destinationPath,
    };
  });

exports.rejectSubmission = functions.https.onCall(async (data, context) => {
  const actor = await assertAuthorized(context);
  const submissionId = requireString(
    data && data.submissionId,
    "submissionId",
    1,
    180,
  );
  const reason = requireString(data && data.reason, "reason", 2, 300);
  const ref = db.collection("lesson_submissions").doc(submissionId);
  let storagePath = "";
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "المساهمة غير موجودة.");
    }
    const value = snap.data() || {};
    if (value.status !== "pending") {
      if (value.status === "rejected") return;
      throw new functions.https.HttpsError(
        "failed-precondition",
        "سبق حسم هذه المساهمة.",
      );
    }
    storagePath = cleanString(value.storagePath, 700);
    tx.update(ref, {
      status: "rejected",
      rejectReason: reason,
      decidedBy: actor.email,
      decidedAt: new Date().toISOString(),
      decidedAtTs: admin.firestore.FieldValue.serverTimestamp(),
      cleanupPending: Boolean(storagePath),
    });
  });
  if (storagePath) {
    try {
      await deleteFileIfExists(storagePath);
      await ref.update({ cleanupPending: false });
    } catch (_) {
      // تبقى cleanupPending=true لإعادة المحاولة الآمنة لاحقاً.
    }
  }
  await auditOwnerAction(actor.email, "reject_submission", submissionId, { reason });
  return { ok: true, id: submissionId };
});

async function deleteSubmissionHandler(data, context) {
  const actor = await assertAuthorized(context);
  const submissionId = requireString(
    data && data.submissionId,
    "submissionId",
    1,
    180,
  );
  const ref = db.collection("lesson_submissions").doc(submissionId);
  const snap = await ref.get();
  if (!snap.exists) return { ok: true, alreadyDeleted: true };
  const value = snap.data() || {};
  if (value.storagePath) await deleteFileIfExists(value.storagePath);
  await ref.delete();
  await auditOwnerAction(actor.email, "delete_submission", submissionId, {});
  return { ok: true };
}

exports.deleteSubmission = functions.https.onCall(deleteSubmissionHandler);
// اسم بديل تستدعيه نسخ لوحة الإدارة المثبتة قبل توحيد الاسم — أبقه منشوراً.
exports.deleteSubmissionRecord = functions.https.onCall(deleteSubmissionHandler);

exports.deleteMySubmission = functions.https.onCall(async (data, context) => {
  assertAppCheck(context);
  const uid = assertSignedIn(context);
  const submissionId = requireString(
    data && data.submissionId,
    "submissionId",
    1,
    180,
  );
  const ref = db.collection("lesson_submissions").doc(submissionId);
  const snap = await ref.get();
  if (!snap.exists) return { ok: true, alreadyDeleted: true };
  const value = snap.data() || {};
  if (value.uid !== uid || value.status !== "pending") {
    throw new functions.https.HttpsError("permission-denied", "لا يمكن حذف هذا الطلب.");
  }
  if (value.storagePath) await deleteFileIfExists(value.storagePath);
  await ref.delete();
  return { ok: true };
});

async function queueStorageCleanup(paths, reason, targetId) {
  const unique = [...new Set((paths || []).map(storagePathFromUrl).filter(Boolean))];
  if (!unique.length) return "";
  const ref = await db.collection("storage_cleanup_jobs").add({
    paths: unique,
    reason,
    targetId: targetId || "",
    status: "pending",
    attempts: 0,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: Date.now(),
  });
  return ref.id;
}

function lessonStoragePaths(value) {
  return [...new Set([
    value && value.storagePath,
    value && value.audioStoragePath,
    value && value.audioUrl,
  ].map(storagePathFromUrl).filter(Boolean))];
}

async function deletePathsBestEffort(paths, reason, targetId) {
  const failed = [];
  for (const path of paths) {
    try {
      await deleteFileIfExists(path);
    } catch (_) {
      failed.push(path);
    }
  }
  const cleanupJobId = failed.length
    ? await queueStorageCleanup(failed, reason, targetId)
    : "";
  return { failed, cleanupJobId };
}

async function deleteLessonHandler(data, context) {
  const actor = await assertAuthorized(context);
  const lessonId = requireString(data && data.lessonId, "lessonId", 1, 180);
  const lessonRef = db.collection("lessons").doc(lessonId);
  const reviewRef = db.collection("owner_lesson_reviews").doc(lessonId);
  const [lessonSnap, reviewSnap] = await Promise.all([
    lessonRef.get(),
    reviewRef.get(),
  ]);
  if (!lessonSnap.exists) return { ok: true, alreadyDeleted: true };
  const paths = lessonStoragePaths(unwrapLegacy(lessonSnap.data()));
  const batch = db.batch();
  batch.delete(lessonRef);
  if (reviewSnap.exists) {
    batch.update(reviewRef, {
      status: "deleted",
      resolution: "delete_by_admin",
      resolvedBy: actor.email,
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  await batch.commit();
  const cleanup = await deletePathsBestEffort(paths, "delete_lesson", lessonId);
  await auditOwnerAction(actor.email, "delete_lesson", lessonId, {
    cleanupPending: cleanup.failed.length > 0,
    cleanupJobId: cleanup.cleanupJobId,
  });
  return {
    ok: true,
    id: lessonId,
    cleanupPending: cleanup.failed.length > 0,
    cleanupJobId: cleanup.cleanupJobId,
  };
}

exports.deleteLesson = functions.runWith({ timeoutSeconds: 120, memory: "512MB" })
  .https.onCall(deleteLessonHandler);
exports.deleteLessonPermanently = functions.runWith({ timeoutSeconds: 120, memory: "512MB" })
  .https.onCall(deleteLessonHandler);

async function deleteRefsInBatches(refs) {
  for (let offset = 0; offset < refs.length; offset += 400) {
    const batch = db.batch();
    refs.slice(offset, offset + 400).forEach((ref) => batch.delete(ref));
    await batch.commit();
  }
}

exports.deleteSubcategoryCascade = functions.runWith({ timeoutSeconds: 540, memory: "512MB" })
  .https.onCall(async (data, context) => {
    const actor = await assertAuthorized(context);
    const subcategoryId = requireString(
      data && data.subcategoryId,
      "subcategoryId",
      1,
      180,
    );
    const [subcategorySnap, lessonsSnap] = await Promise.all([
      db.collection("subcategories").doc(subcategoryId).get(),
      db.collection("lessons").where("subcategoryId", "==", subcategoryId).get(),
    ]);
    const paths = lessonsSnap.docs.flatMap(
      (doc) => lessonStoragePaths(unwrapLegacy(doc.data())),
    );
    const refs = lessonsSnap.docs.map((doc) => doc.ref);
    if (subcategorySnap.exists) refs.push(subcategorySnap.ref);
    await deleteRefsInBatches(refs);
    const cleanup = await deletePathsBestEffort(
      paths,
      "delete_subcategory_cascade",
      subcategoryId,
    );
    await auditOwnerAction(actor.email, "delete_subcategory_cascade", subcategoryId, {
      lessonsDeleted: lessonsSnap.size,
      cleanupPending: cleanup.failed.length > 0,
      cleanupJobId: cleanup.cleanupJobId,
    });
    return {
      ok: true,
      id: subcategoryId,
      lessonsDeleted: lessonsSnap.size,
      cleanupPending: cleanup.failed.length > 0,
    };
  });

exports.deleteCategoryCascade = functions.runWith({ timeoutSeconds: 540, memory: "1GB" })
  .https.onCall(async (data, context) => {
    const actor = await assertAuthorized(context);
    const categoryId = requireString(data && data.categoryId, "categoryId", 1, 180);
    const [categorySnap, subcategoriesSnap, categoryLessonsSnap, booksSnap] = await Promise.all([
      db.collection("categories").doc(categoryId).get(),
      db.collection("subcategories").where("categoryId", "==", categoryId).get(),
      db.collection("lessons").where("categoryId", "==", categoryId).get(),
      db.collection("books").where("categoryId", "==", categoryId).get(),
    ]);
    const lessonMap = new Map(categoryLessonsSnap.docs.map((doc) => [doc.id, doc]));
    for (const subcategory of subcategoriesSnap.docs) {
      const snap = await db.collection("lessons")
        .where("subcategoryId", "==", subcategory.id)
        .get();
      snap.docs.forEach((doc) => lessonMap.set(doc.id, doc));
    }
    const lessons = [...lessonMap.values()];
    const paths = lessons.flatMap((doc) => lessonStoragePaths(unwrapLegacy(doc.data())));
    booksSnap.docs.forEach((doc) => {
      const value = unwrapLegacy(doc.data());
      [value.storagePath, value.pdfStoragePath, value.fileUrl, value.url]
        .map(storagePathFromUrl)
        .filter(Boolean)
        .forEach((path) => paths.push(path));
    });
    const refs = [
      ...lessons.map((doc) => doc.ref),
      ...booksSnap.docs.map((doc) => doc.ref),
      ...subcategoriesSnap.docs.map((doc) => doc.ref),
    ];
    if (categorySnap.exists) refs.push(categorySnap.ref);
    await deleteRefsInBatches(refs);
    const cleanup = await deletePathsBestEffort(
      paths,
      "delete_category_cascade",
      categoryId,
    );
    await auditOwnerAction(actor.email, "delete_category_cascade", categoryId, {
      subcategoriesDeleted: subcategoriesSnap.size,
      lessonsDeleted: lessons.length,
      booksDeleted: booksSnap.size,
      cleanupPending: cleanup.failed.length > 0,
      cleanupJobId: cleanup.cleanupJobId,
    });
    return {
      ok: true,
      id: categoryId,
      subcategoriesDeleted: subcategoriesSnap.size,
      lessonsDeleted: lessons.length,
      booksDeleted: booksSnap.size,
      cleanupPending: cleanup.failed.length > 0,
    };
  });

exports.onSubmissionCreated = functions.firestore
  .document("lesson_submissions/{id}")
  .onCreate(async (snap) => {
    const d = snap.data() || {};
    const title = cleanString(d.title, 120);
    const who = cleanString(d.submitterName, 60) || "مستمع";
    const alertTitle = "مساهمة جديدة بانتظار المراجعة";
    const alertBody = `أرسل ${who} درساً مقترحاً: «${title}».`;
    await Promise.all([
      writeAdminAlert("", alertTitle, alertBody, {
        type: "submission",
        submissionId: snap.id,
      }),
      pushToAdmins(alertTitle, alertBody, {
        type: "submission",
        submissionId: snap.id,
      }),
    ]);
    return null;
  });

exports.onSubmissionDecided = functions.firestore
  .document("lesson_submissions/{id}")
  .onUpdate(async (change) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};
    if (before.status !== "pending" || after.status === "pending") return null;
    const token = cleanString(after.fcmToken, 4096);
    const title = cleanString(after.publishedTitle || after.title, 120);
    if (after.status === "approved" || after.status === "approved_edited") {
      const edited = after.status === "approved_edited";
      const notificationTitle = edited
        ? "نُشرت مساهمتك بعد المراجعة"
        : "نُشرت مساهمتك";
      const notificationBody = `نُشر الدرس «${title}». شكراً لمساهمتك.`;
      const notificationData = {
        type: "submission",
        id: change.after.id,
        refId: change.after.id,
        lessonId: after.publishedLessonId || "",
        result: after.status,
      };
      await Promise.all([
        clearAdminAlerts("submission", change.after.id),
        writeUserNotification(after.uid, notificationTitle, notificationBody, notificationData),
        pushToToken(token, notificationTitle, notificationBody, notificationData),
      ]);
      return null;
    }
    if (after.status === "rejected") {
      const reason = cleanString(after.rejectReason, 300);
      const notificationTitle = "نتيجة مراجعة مساهمتك";
      const notificationBody = reason
        ? `لم يُنشر «${title}»: ${reason}`
        : `لم يُنشر «${title}».`;
      const notificationData = {
        type: "submission",
        id: change.after.id,
        refId: change.after.id,
        result: "rejected",
      };
      await Promise.all([
        clearAdminAlerts("submission", change.after.id),
        writeUserNotification(after.uid, notificationTitle, notificationBody, notificationData),
        pushToToken(token, notificationTitle, notificationBody, notificationData),
      ]);
      return null;
    }
    return null;
  });

// تنظيف التنبيهات المستهلَكة: مساهمات حُسمت، تنبيهات نسخ قديمة بلا type
// (يستحيل ربطها بمصدرها — النسخ الحالية تكتب type دائماً)، ورموز اعتماد انتهت
// صلاحيتها دون حسم.
exports.cleanupResolvedAdminAlerts = functions.https.onCall(async (_data, context) => {
  await assertAuthorized(context);
  const alertsSnap = await db.collection("admin_alerts").get();
  const parsed = alertsSnap.docs.map((doc) => {
    const value = doc.data() || {};
    const metadata = value.data || {};
    return {
      ref: doc.ref,
      type: cleanString(value.type || metadata.type, 40),
      submissionId: cleanString(
        value.refId || metadata.refId || metadata.submissionId,
        180,
      ),
      expiresAt: Number(metadata.expiresAt || 0),
    };
  });
  const stale = parsed
    .filter((item) => !item.type
      || (item.type === "owner_code" && item.expiresAt && item.expiresAt < Date.now()))
    .map((item) => item.ref);

  // التنبيهات المرتبطة بوثيقة حالة: تُحذف حين لا تعود الوثيقة معلّقة.
  const trackedKinds = [
    { type: "submission", collection: "lesson_submissions" },
    { type: "suspicious_lesson", collection: "owner_lesson_reviews" },
  ];
  for (const kind of trackedKinds) {
    const tracked = parsed.filter(
      (item) => item.type === kind.type && item.submissionId,
    );
    if (!tracked.length) continue;
    const uniqueIds = [...new Set(tracked.map((item) => item.submissionId))];
    const statusById = new Map();
    for (let offset = 0; offset < uniqueIds.length; offset += 300) {
      const refs = uniqueIds.slice(offset, offset + 300)
        .map((id) => db.collection(kind.collection).doc(id));
      const docs = await db.getAll(...refs);
      docs.forEach((doc) => {
        statusById.set(doc.id, doc.exists ? cleanString((doc.data() || {}).status, 40) : "missing");
      });
    }
    tracked
      .filter((item) => statusById.get(item.submissionId) !== "pending")
      .forEach((item) => stale.push(item.ref));
  }
  for (let offset = 0; offset < stale.length; offset += 400) {
    const batch = db.batch();
    stale.slice(offset, offset + 400).forEach((ref) => batch.delete(ref));
    await batch.commit();
  }
  return { ok: true, deleted: stale.length };
});

// إشعار خاص بأعضاء مجموعة الإدارة الموثقين، مع احترام الكتم واستبعاد المرسل.
exports.onAdminChatMessageCreated = functions.firestore
  .document("admin_chat_messages/{id}")
  .onCreate(async (snap) => {
    const value = snap.data() || {};
    if (value.deleted === true) return null;
    const senderId = cleanString(value.senderId, 180);
    const senderName = cleanString(value.senderName || "عضو", 100);
    const typeLabels = {
      image: "صورة",
      video: "فيديو",
      audio: "مقطع صوتي",
      voice: "رسالة صوتية",
      file: "ملف",
    };
    const messageType = cleanString(value.type, 20);
    const preview = cleanString(value.text, 160)
      || typeLabels[messageType]
      || "رسالة جديدة";
    await pushToAdminsFiltered(
      `رسالة من ${senderName}`,
      preview,
      { type: "admin_chat", messageId: snap.id, senderId },
      { excludeUid: senderId, respectChatMute: true },
    );
    return null;
  });

// إشعار المحادثة الفرديّة: يصل الطرف الآخر وحده (لا المجموعة ولا غيرهما).
exports.onAdminDmMessageCreated = functions.firestore
  .document("admin_dm_threads/{threadId}/messages/{msgId}")
  .onCreate(async (snap, context) => {
    const value = snap.data() || {};
    if (value.deleted === true) return null;
    const senderId = cleanString(value.senderId, 180);
    const senderName = cleanString(value.senderName || "مشرف", 100);
    const threadId = cleanString(context.params.threadId, 400);
    // طرفا المحادثة من معرّفها الحتمي (uidA__uidB) ومن وثيقتها احتياطاً.
    let members = threadId.split("__").filter(Boolean);
    if (members.length !== 2) {
      const threadSnap = await db.collection("admin_dm_threads")
        .doc(threadId).get();
      const data = threadSnap.data() || {};
      members = Array.isArray(data.members) ? data.members.map(String) : [];
    }
    const target = members.find((uid) => uid && uid !== senderId);
    if (!target) return null;

    const typeLabels = {
      image: "صورة",
      video: "فيديو",
      audio: "مقطع صوتي",
      voice: "رسالة صوتيّة",
      file: "ملف",
    };
    const messageType = cleanString(value.type, 20);
    const preview = cleanString(value.text, 160)
      || typeLabels[messageType]
      || "رسالة خاصّة";

    // الرمز المستهدف: جهاز العضو المعتمَد فقط، مع احترام كتم الدردشة.
    const tokens = (await activeAdminTokens(false)).filter(
      (item) => item.uid === target && !item.chatMuted,
    );
    return sendToAdminTargets(
      tokens,
      `رسالة خاصّة من ${senderName}`,
      preview,
      { type: "admin_dm", threadId, senderId },
    );
  });

// ─── نظام المراجعة السرية للدروس المشبوهة (للمالك فقط) ─────────────
//
// مبدأ التشخيص: «لا إهمال ولا حساسية مفرطة».
//   • كل سبب يُكتب بالعربية مع الدليل (العبارة الملتقطة وموضعها وسياقها).
//   • الأنماط تطابق كلمات كاملة (\b الإنجليزية لا تعمل مع العربية، لذا
//     نستخدم lookaround على حروف/أرقام يونيكود) — «اقتل» لا تلتقط «اقتلعت».
//   • درجتان: قاطعة (score ≥ 4) تفتح مراجعة وتنبّه المالك وحدها، وسياقية
//     (score ≤ 3) لا تكفي وحدها — تحتاج قرينة أخرى لبلوغ عتبة التنبيه.
//   • كون الدرس من إنشاء مشرف ليس شبهة إطلاقاً (هذا عملهم الطبيعي).
//   • السوابق العربية تلتصق بالكلمة (والمخدرات، بالسلاح، فاقتلوا) — نسمح
//     بها اختيارياً قبل الجذر كي لا تفلت، مع بقاء حد الكلمة قبلها وبعدها.
const wholeWord = (alternatives) =>
  new RegExp(
    `(?<![\\p{L}\\p{N}])(?:و|ف)?(?:بال|كال|لل|ال|ب|ك|ل)?(?:${alternatives})(?![\\p{L}\\p{N}])`,
    "iu",
  );

const SUSPICIOUS_PATTERNS = [
  // قاطعة — تكفي وحدها لفتح المراجعة وتنبيه المالك.
  { pattern: wholeWord("داعش|القاعدة|تفجير|قنبلة|عبوة\\s+ناسفة"), reason: "إشارة محتملة إلى محتوى متطرف أو متفجرات", score: 5 },
  { pattern: /<script|javascript:|data:text\/html/iu, reason: "شفرة أو رابط غير آمن داخل البيانات", score: 5 },
  { pattern: wholeWord("كافر\\s+يستحق|مرتد\\s+يستحق|سفك\\s+الدماء?"), reason: "عبارة تحريض أو تكفير صريحة", score: 4 },
  // سياقية — ترد كثيراً في المحتوى الديني والتعليمي المشروع (أحكام، سيرة،
  // تحذير من المخدرات…)، فلا تفتح مراجعة إلا مع قرينة أخرى.
  { pattern: wholeWord("اقتل|اقتلوا|القتل|اغتيال|تحريض"), reason: "لفظ متصل بالعنف قد يكون في سياق مشروع", score: 3 },
  { pattern: wholeWord("تكفير|سلاح|أسلحة|مخدرات|تهريب"), reason: "لفظ متصل بنشاط خطر قد يكون في سياق مشروع", score: 3 },
  { pattern: wholeWord("مقرصن|مقرصنة|نسخة\\s+مسروقة"), reason: "مشكلة حقوق نشر محتملة", score: 3 },
];

/// أدنى درجة خطورة تفتح مراجعة وتنبيهاً — ما دونها ليس شبهة تستحق الإزعاج.
const SUSPICION_ALERT_THRESHOLD = 4;

function lessonModerationFields(raw) {
  const d = unwrapLegacy(raw);
  const title = cleanString(d.title || d.name, 300);
  return {
    title,
    normalizedTitle: cleanString(d.normalizedTitle, 300)
      || title.toLocaleLowerCase("ar").replace(/\s+/g, " ").trim(),
    description: cleanString(d.description || d.note || d.text, 2000),
    audioUrl: cleanString(d.audioUrl || d.url, 2500),
    storagePath: cleanString(d.storagePath || d.audioStoragePath, 700),
    categoryId: cleanString(d.categoryId, 180),
    subcategoryId: cleanString(d.subcategoryId, 180),
    publishAt: cleanString(d.publishAt, 100),
    publishNotified: d.publishNotified === true,
    addedBy: cleanString(d.addedBy, 180),
    createdByEmail: normalizeEmail(d.createdByEmail || d.addedBy),
    createdByUid: cleanString(d.createdByUid, 180),
    updatedByEmail: normalizeEmail(d.updatedByEmail),
    updatedByUid: cleanString(d.updatedByUid, 180),
  };
}

/// مقتطف سياق حول موضع المطابقة — يُعرض للمالك دليلاً لا تخميناً.
function evidenceExcerpt(text, index, length) {
  const start = Math.max(0, index - 25);
  const end = Math.min(text.length, index + length + 25);
  const prefix = start > 0 ? "…" : "";
  const suffix = end < text.length ? "…" : "";
  return `${prefix}${text.slice(start, end).trim()}${suffix}`;
}

function inspectLesson(raw) {
  const fields = lessonModerationFields(raw);
  const combined = `${fields.title}\n${fields.description}`;
  const reasons = [];
  let riskScore = 0;
  const sources = [
    ["العنوان", fields.title],
    ["الوصف", fields.description],
  ];
  SUSPICIOUS_PATTERNS.forEach((item) => {
    for (const [label, text] of sources) {
      if (!text) continue;
      const match = item.pattern.exec(text);
      if (match) {
        reasons.push(
          `${item.reason} — وردت عبارة «${match[0]}» في ${label}: `
          + `"${evidenceExcerpt(text, match.index, match[0].length)}"`,
        );
        riskScore += item.score;
        break; // يكفي دليل واحد لكل نمط.
      }
    }
  });
  if (!fields.title) {
    reasons.push("الدرس بلا عنوان إطلاقاً");
    riskScore += 2;
  }
  if (fields.title && fields.title.length < 3) {
    reasons.push(`العنوان أقصر من أن يكون دالاً: «${fields.title}»`);
    riskScore += 2;
  }
  if (/(\p{L}|\p{N})\1{5,}/u.test(fields.title)) {
    reasons.push("العنوان يحوي تكراراً غير طبيعي لنفس الحرف");
    riskScore += 2;
  }
  if (!fields.audioUrl) {
    reasons.push("الدرس بلا رابط صوت");
    riskScore += 2;
  } else {
    try {
      const host = new URL(fields.audioUrl).hostname.toLowerCase();
      const approved = host === "firebasestorage.googleapis.com"
        || host.endsWith("storage.googleapis.com")
        || host.endsWith("res.cloudinary.com");
      if (!approved) {
        reasons.push(`مصدر الصوت خارج تخزين التطبيق المعتمد: ${host}`);
        riskScore += 2;
      }
    } catch (_) {
      reasons.push("رابط الصوت ليس رابطاً صالحاً أصلاً");
      riskScore += 3;
    }
  }
  const emailMatch = /\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/u.exec(combined);
  const phoneMatch = /(?:\+?\d[\s-]?){9,}/u.exec(combined);
  if (emailMatch || phoneMatch) {
    const found = emailMatch ? `بريد إلكتروني «${emailMatch[0]}»` : `رقم يشبه الهاتف «${(phoneMatch[0] || "").trim()}»`;
    reasons.push(`البيانات تتضمن ما يشبه معلومات اتصال شخصية: ${found}`);
    riskScore += 2;
  }
  if (fields.publishAt) {
    const parsedPublishAt = Date.parse(fields.publishAt);
    if (Number.isNaN(parsedPublishAt)) {
      reasons.push(`تاريخ النشر المجدول غير مفهوم: «${fields.publishAt}»`);
      riskScore += 2;
    } else if (!fields.publishNotified
        && parsedPublishAt < Date.now() - 24 * 60 * 60 * 1000) {
      reasons.push("درس مجدول تجاوز موعد نشره بأكثر من يوم دون أن يُنشر");
      riskScore += 2;
    }
  }
  // البصمة تستثني publishNotified: قلبُه علامة نشر إجرائية (يكتبها
  // onLessonCreated والمجدول) لا تغييراً في المحتوى، وإدراجه كان يعيد
  // فتح المراجعة وتنبيه المالك مرتين لنفس الدرس.
  return {
    fields,
    reasons: [...new Set(reasons)],
    riskScore,
    fingerprint: hashId(
      JSON.stringify({ ...fields, publishNotified: undefined }),
    ),
  };
}

async function recordSuspiciousLesson(
  lessonId,
  raw,
  source,
  notifyOwner,
  extraReasons = [],
  preloaded = null,
) {
  const result = inspectLesson(raw);
  extraReasons.forEach((reason) => {
    if (reason) {
      result.reasons.push(reason);
      result.riskScore += 2;
    }
  });
  const checks = [];
  if (preloaded) {
    if (result.fields.categoryId
        && !preloaded.categoryIds.has(result.fields.categoryId)) {
      result.reasons.push("القسم الرئيسي المُشار إليه غير موجود في القاعدة");
      result.riskScore += 2;
    }
    if (result.fields.subcategoryId) {
      if (!preloaded.subcategoryParents.has(result.fields.subcategoryId)) {
        result.reasons.push("القسم الفرعي المُشار إليه غير موجود في القاعدة");
        result.riskScore += 2;
      } else {
        const parent = preloaded.subcategoryParents.get(result.fields.subcategoryId);
        if (result.fields.categoryId && parent && parent !== result.fields.categoryId) {
          result.reasons.push("القسم الفرعي المحدد لا يتبع القسم الرئيسي المحدد");
          result.riskScore += 3;
        }
      }
    }
    if (result.fields.normalizedTitle
        && (preloaded.titleCounts.get(result.fields.normalizedTitle) || 0) > 1) {
      result.reasons.push("العنوان مطابق حرفياً لدرس آخر موجود");
      result.riskScore += 2;
    }
    if (result.fields.audioUrl
        && (preloaded.audioUrlCounts.get(result.fields.audioUrl) || 0) > 1) {
      result.reasons.push("رابط الصوت نفسه مستخدم في درس آخر");
      result.riskScore += 3;
    }
    if (result.fields.storagePath
        && (preloaded.storagePathCounts.get(result.fields.storagePath) || 0) > 1) {
      result.reasons.push("ملف الصوت المخزَّن نفسه مستخدم في درس آخر");
      result.riskScore += 4;
    }
  } else if (result.fields.categoryId) {
    checks.push(
      db.collection("categories").doc(result.fields.categoryId).get()
        .then((snap) => {
          if (!snap.exists) {
            result.reasons.push("القسم الرئيسي المُشار إليه غير موجود في القاعدة");
            result.riskScore += 2;
          }
        }),
    );
  }
  if (!preloaded && result.fields.subcategoryId) {
    checks.push(
      db.collection("subcategories").doc(result.fields.subcategoryId).get()
        .then((snap) => {
          if (!snap.exists) {
            result.reasons.push("القسم الفرعي المُشار إليه غير موجود في القاعدة");
            result.riskScore += 2;
          } else {
            const parent = cleanString((snap.data() || {}).categoryId, 180);
            if (result.fields.categoryId && parent && parent !== result.fields.categoryId) {
              result.reasons.push("القسم الفرعي المحدد لا يتبع القسم الرئيسي المحدد");
              result.riskScore += 3;
            }
          }
        }),
    );
  }
  if (!preloaded && result.fields.normalizedTitle) {
    checks.push(
      db.collection("lessons")
        .where("normalizedTitle", "==", result.fields.normalizedTitle)
        .limit(3)
        .get()
        .then((snap) => {
          if (snap.docs.some((doc) => doc.id !== lessonId)) {
            result.reasons.push("العنوان مطابق حرفياً لدرس آخر موجود");
            result.riskScore += 2;
          }
        }),
    );
  }
  if (!preloaded && result.fields.audioUrl) {
    checks.push(
      db.collection("lessons").where("audioUrl", "==", result.fields.audioUrl)
        .limit(3).get().then((snap) => {
          if (snap.docs.some((doc) => doc.id !== lessonId)) {
            result.reasons.push("رابط الصوت نفسه مستخدم في درس آخر");
            result.riskScore += 3;
          }
        }),
    );
  }
  if (!preloaded && result.fields.storagePath) {
    checks.push(
      db.collection("lessons").where("storagePath", "==", result.fields.storagePath)
        .limit(3).get().then((snap) => {
          if (snap.docs.some((doc) => doc.id !== lessonId)) {
            result.reasons.push("ملف الصوت المخزَّن نفسه مستخدم في درس آخر");
            result.riskScore += 4;
          }
        }),
    );
  }
  await Promise.all(checks);
  result.reasons = [...new Set(result.reasons)];
  const ref = db.collection("owner_lesson_reviews").doc(lessonId);
  const existing = await ref.get();
  const old = existing.data() || {};
  // دون العتبة = ليس شبهة تستحق مراجعة المالك. يشمل هذا المراجعات المعلّقة
  // من منطق قديم أشد حساسية — تُغلق تلقائياً ويُمسح تنبيهها مهما كانت بصمتها.
  if (!result.reasons.length || result.riskScore < SUSPICION_ALERT_THRESHOLD) {
    if (existing.exists && old.status === "pending") {
      await ref.update({
        status: "auto_cleared",
        resolution: result.reasons.length
          ? "below_alert_threshold"
          : "no_longer_flagged",
        resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await clearAdminAlerts("suspicious_lesson", lessonId);
    }
    return false;
  }
  if (old.status === "verified" && old.fingerprint === result.fingerprint) {
    return false;
  }
  const unchangedPending = old.status === "pending"
    && old.fingerprint === result.fingerprint;
  await ref.set({
    lessonId,
    lessonTitle: result.fields.title,
    reasons: result.reasons,
    riskScore: result.riskScore,
    riskLevel: result.riskScore >= 7 ? "high" : result.riskScore >= 4 ? "medium" : "low",
    status: "pending",
    fingerprint: result.fingerprint,
    source,
    lessonSnapshot: result.fields,
    detectedAt: admin.firestore.FieldValue.serverTimestamp(),
    detectedAtMs: Date.now(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  if (notifyOwner && !unchangedPending) {
    const title = "تنبيه خاص: درس يحتاج مراجعتك";
    const body = `«${result.fields.title || lessonId}» — ${result.reasons[0]}`;
    await Promise.all([
      writeAdminAlert(OWNER_EMAIL, title, body, {
        type: "suspicious_lesson",
        reviewId: lessonId,
        lessonId,
      }),
      pushToAdmins(title, body, {
        type: "suspicious_lesson",
        reviewId: lessonId,
        lessonId,
      }, true),
    ]);
  }
  return true;
}

exports.onLessonSuspicionCreated = functions.firestore
  .document("lessons/{lessonId}")
  .onCreate((snap, context) => recordSuspiciousLesson(
    context.params.lessonId,
    snap.data(),
    "created",
    true,
  ));

exports.onLessonSuspicionUpdated = functions.firestore
  .document("lessons/{lessonId}")
  .onUpdate(async (change, context) => {
    const before = inspectLesson(change.before.data());
    const after = inspectLesson(change.after.data());
    if (before.fingerprint === after.fingerprint) return null;
    return recordSuspiciousLesson(
      context.params.lessonId,
      change.after.data(),
      "updated",
      true,
    );
  });

exports.scanSuspiciousLessons = functions.runWith({ timeoutSeconds: 540, memory: "512MB" })
  .https.onCall(async (_data, context) => {
    await assertOwner(context);
    const [snap, categoriesSnap, subcategoriesSnap] = await Promise.all([
      db.collection("lessons").get(),
      db.collection("categories").get(),
      db.collection("subcategories").get(),
    ]);
    const preloaded = {
      categoryIds: new Set(categoriesSnap.docs.map((doc) => doc.id)),
      subcategoryParents: new Map(subcategoriesSnap.docs.map((doc) => [
        doc.id,
        cleanString(unwrapLegacy(doc.data()).categoryId, 180),
      ])),
      titleCounts: new Map(),
      audioUrlCounts: new Map(),
      storagePathCounts: new Map(),
    };
    const increment = (map, key) => {
      if (key) map.set(key, (map.get(key) || 0) + 1);
    };
    snap.docs.forEach((doc) => {
      const fields = lessonModerationFields(doc.data());
      increment(preloaded.titleCounts, fields.normalizedTitle);
      increment(preloaded.audioUrlCounts, fields.audioUrl);
      increment(preloaded.storagePathCounts, fields.storagePath);
    });
    let suspicious = 0;
    const concurrency = 20;
    for (let offset = 0; offset < snap.docs.length; offset += concurrency) {
      const results = await Promise.all(
        snap.docs.slice(offset, offset + concurrency).map((doc) =>
          recordSuspiciousLesson(
            doc.id,
            doc.data(),
            "manual_scan",
            false,
            [],
            preloaded,
          )),
      );
      suspicious += results.filter(Boolean).length;
    }
    await auditOwnerAction(OWNER_EMAIL, "scan_suspicious_lessons", "", {
      scanned: snap.size,
      suspicious,
    });
    if (suspicious) {
      await pushToAdmins(
        "اكتمل فحص الدروس",
        `تم فحص ${snap.size} درساً والعثور على ${suspicious} درساً يحتاج المراجعة.`,
        { type: "suspicious_scan", suspicious },
        true,
      );
    }
    return { ok: true, scanned: snap.size, suspicious };
  });

exports.resolveSuspiciousLesson = functions.runWith({ timeoutSeconds: 120, memory: "512MB" })
  .https.onCall(async (data, context) => {
    const actorEmail = await assertOwner(context);
    const reviewId = requireString(data && data.reviewId, "reviewId", 1, 180);
    const lessonId = requireString(data && data.lessonId, "lessonId", 1, 180);
    const action = cleanString(data && data.action, 20);
    if (!["verified", "delete"].includes(action)) {
      throw new functions.https.HttpsError("invalid-argument", "الإجراء غير صالح.");
    }
    const reviewRef = db.collection("owner_lesson_reviews").doc(reviewId);
    const lessonRef = db.collection("lessons").doc(lessonId);
    const [reviewSnap, lessonSnap] = await Promise.all([
      reviewRef.get(),
      lessonRef.get(),
    ]);
    if (!reviewSnap.exists || reviewSnap.data().lessonId !== lessonId) {
      throw new functions.https.HttpsError("not-found", "سجل المراجعة غير موجود.");
    }
    let cleanup = { failed: [], cleanupJobId: "" };
    if (action === "verified") {
      if (!lessonSnap.exists) {
        throw new functions.https.HttpsError("not-found", "الدرس غير موجود.");
      }
      const batch = db.batch();
      batch.update(reviewRef, {
        status: "verified",
        resolvedBy: actorEmail,
        resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
        resolution: "verified",
      });
      batch.update(lessonRef, {
        moderationStatus: "verified",
        moderationVerifiedBy: actorEmail,
        moderationVerifiedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await batch.commit();
    } else {
      const paths = lessonSnap.exists
        ? lessonStoragePaths(unwrapLegacy(lessonSnap.data()))
        : [];
      const batch = db.batch();
      if (lessonSnap.exists) batch.delete(lessonRef);
      batch.update(reviewRef, {
        status: "deleted",
        resolvedBy: actorEmail,
        resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
        resolution: "delete",
      });
      await batch.commit();
      cleanup = await deletePathsBestEffort(
        paths,
        "delete_suspicious_lesson",
        lessonId,
      );
    }
    // اتُّخذ القرار — تنبيه «درس يحتاج مراجعتك» يختفي من تنبيهات المالك.
    await clearAdminAlerts("suspicious_lesson", lessonId);
    await auditOwnerAction(actorEmail, `suspicious_${action}`, lessonId, {
      reviewId,
      cleanupPending: cleanup.failed.length > 0,
      cleanupJobId: cleanup.cleanupJobId,
    });
    return {
      ok: true,
      action,
      lessonId,
      cleanupPending: cleanup.failed.length > 0,
      cleanupJobId: cleanup.cleanupJobId,
    };
  });

// ─── الإشعار اليدوي من تطبيق الإدارة ────────────────────────────────
exports.sendNotification = functions.https.onCall(async (data, context) => {
  const actor = await assertAuthorized(context);
  const title = cleanString(data && data.title, 80);
  const body = cleanString(data && data.body, 500);
  if (!title && !body) {
    throw new functions.https.HttpsError("invalid-argument", "العنوان أو النص مطلوب.");
  }
  const messageId = await pushToTopic(title || "إشعار", body, { type: "manual" });
  await auditOwnerAction(actor.email, "send_notification", "", {
    title,
    bodyLength: body.length,
  });
  return { ok: true, messageId };
});

// تنظيف يومي للملفات اليتيمة وإعادة محاولة مهام تنظيف التخزين الفاشلة.
exports.cleanupOrphanSubmissionUploads = functions.runWith({
  timeoutSeconds: 540,
  memory: "512MB",
}).pubsub.schedule("30 3 * * *").timeZone("Asia/Riyadh").onRun(async () => {
  const now = Date.now();
  const [files] = await bucket.getFiles({ prefix: "submissions/" });
  const submissionsSnap = await db.collection("lesson_submissions").get();
  const submissions = new Map(
    submissionsSnap.docs.map((doc) => [doc.id, doc.data() || {}]),
  );
  let deletedOrphans = 0;
  let failedOrphans = 0;
  for (const file of files) {
    const parts = file.name.split("/");
    if (parts.length < 4) continue;
    const submissionId = parts[2];
    const submission = submissions.get(submissionId);
    const createdAt = Date.parse(file.metadata && file.metadata.timeCreated || "") || 0;
    const oldEnough = createdAt && now - createdAt > 24 * 60 * 60 * 1000;
    const orphan = !submission && oldEnough;
    const decidedLeftover = submission && submission.status !== "pending";
    if (!orphan && !decidedLeftover) continue;
    try {
      await file.delete({ ignoreNotFound: true });
      deletedOrphans += 1;
    } catch (error) {
      console.error("orphan cleanup failed", file.name, error);
      failedOrphans += 1;
    }
  }

  const jobsSnap = await db.collection("storage_cleanup_jobs")
    .where("status", "==", "pending")
    .limit(100)
    .get();
  let completedJobs = 0;
  for (const job of jobsSnap.docs) {
    const value = job.data() || {};
    const failed = [];
    for (const path of Array.isArray(value.paths) ? value.paths : []) {
      try {
        await deleteFileIfExists(path);
      } catch (_) {
        failed.push(path);
      }
    }
    if (!failed.length) {
      await job.ref.update({
        status: "done",
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      completedJobs += 1;
    } else {
      await job.ref.update({
        paths: failed,
        attempts: Number(value.attempts || 0) + 1,
        lastAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  await auditOwnerAction("system", "cleanup_orphan_submission_uploads", "", {
    scannedFiles: files.length,
    deletedOrphans,
    failedOrphans,
    cleanupJobsScanned: jobsSnap.size,
    completedJobs,
  });
  return null;
});

// ─── اعتماد المشرفين: رمز مستقل لكل بريد ────────────────────────────
function generateSixDigitCode() {
  return String(crypto.randomInt(0, 1_000_000)).padStart(6, "0");
}

exports.onCodeRequested = functions.firestore
  .document("dashboard_code_requests/{email}")
  .onCreate(async (snap, context) => {
    const email = normalizeEmail(decodeURIComponent(context.params.email));
    const requestData = snap.data() || {};
    try {
      if (email === OWNER_EMAIL) {
        await snap.ref.update({ result: "already_authorized" });
        return null;
      }
      const adminSnap = await db.collection(ADMINS_COLLECTION).doc(email).get();
      const adminData = adminSnap.data() || {};
      if (adminSnap.exists) {
        await snap.ref.update({
          result: adminData.blocked === true ? "blocked" : "already_authorized",
        });
        return null;
      }
      const codeRef = db.collection("dashboard_owner_codes").doc(email);
      const now = Date.now();
      const codeSnap = await codeRef.get();
      const previous = codeSnap.data() || {};
      const lastRequestedAt = Number(previous.lastRequestedAt || 0);
      if (lastRequestedAt && now - lastRequestedAt < CODE_REQUEST_INTERVAL_MS) {
        await snap.ref.update({
          result: "rate_limited",
          retryAfterSec: Math.ceil(
            (CODE_REQUEST_INTERVAL_MS - (now - lastRequestedAt)) / 1000,
          ),
        });
        return null;
      }
      const codeData = {
        code: generateSixDigitCode(),
        candidateUid: cleanString(requestData.uid, 180),
        candidateEmail: email,
        candidateName: cleanString(requestData.name, 100),
        candidatePhotoURL: cleanString(requestData.photoURL, 2048),
        createdAt: now,
        expiresAt: now + CODE_TTL_MS,
        attempts: 0,
        lastRequestedAt: now,
      };
      await codeRef.set(codeData);
      // مرآة توافق مؤقتة للنسخة القديمة التي تراقب current فقط.
      await db.collection("dashboard_owner_codes").doc("current").set(codeData);
      await snap.ref.update({ result: "ok" });
      const candidate = codeData.candidateName || email;
      const alertBody = `رمز اعتماد ${candidate} هو ${codeData.code}، وصالح لمدة 10 دقائق.`;
      await clearAdminAlerts("owner_code", email);
      await Promise.all([
        writeAdminAlert(OWNER_EMAIL, "رمز اعتماد مشرف جديد", alertBody, {
          type: "owner_code",
          refId: email,
          candidateEmail: email,
          expiresAt: codeData.expiresAt,
        }),
        pushToAdmins(
          "رمز اعتماد مشرف جديد",
          alertBody,
          { type: "owner_code", candidateEmail: email },
          true,
        ),
      ]);
      return null;
    } catch (error) {
      console.error("onCodeRequested failed", error);
      await snap.ref.update({ result: "error" }).catch(() => {});
      return null;
    }
  });

exports.onCodeVerifyRequested = functions.firestore
  .document("dashboard_code_verify/{email}")
  .onCreate(async (snap, context) => {
    const email = normalizeEmail(decodeURIComponent(context.params.email));
    const entered = cleanString((snap.data() || {}).code, 6);
    const codeRef = db.collection("dashboard_owner_codes").doc(email);
    const adminRef = db.collection(ADMINS_COLLECTION).doc(email);
    const now = Date.now();
    try {
      await db.runTransaction(async (tx) => {
        const codeSnap = await tx.get(codeRef);
        if (!codeSnap.exists) {
          tx.update(snap.ref, { result: "no_code" });
          return;
        }
        const value = codeSnap.data() || {};
        if (now > Number(value.expiresAt || 0)) {
          tx.delete(codeRef);
          tx.update(snap.ref, { result: "expired" });
          return;
        }
        const attempts = Number(value.attempts || 0);
        if (attempts >= MAX_CODE_ATTEMPTS) {
          tx.delete(codeRef);
          tx.update(snap.ref, { result: "too_many_attempts" });
          return;
        }
        if (!/^\d{6}$/.test(entered) || entered !== String(value.code || "")) {
          const next = attempts + 1;
          if (next >= MAX_CODE_ATTEMPTS) {
            tx.delete(codeRef);
            tx.update(snap.ref, { result: "too_many_attempts" });
          } else {
            tx.update(codeRef, { attempts: next });
            tx.update(snap.ref, { result: "invalid" });
          }
          return;
        }
        tx.set(adminRef, {
          email,
          role: "supervisor",
          blocked: false,
          displayName: cleanString(value.candidateName, 100),
          photoURL: cleanString(value.candidatePhotoURL, 2048),
          addedBy: "owner_code_approval",
          addedAt: now,
          lastSignedInAt: now,
        });
        tx.delete(codeRef);
        tx.update(snap.ref, { result: "ok" });
      });
      const mirrorRef = db.collection("dashboard_owner_codes").doc("current");
      const mirror = await mirrorRef.get();
      if (mirror.exists && normalizeEmail(mirror.data().candidateEmail) === email) {
        await mirrorRef.delete();
      }
      const resultSnap = await snap.ref.get();
      const result = cleanString((resultSnap.data() || {}).result, 40);
      if (["ok", "expired", "too_many_attempts", "no_code"].includes(result)) {
        await clearAdminAlerts("owner_code", email);
      }
    } catch (error) {
      console.error("onCodeVerifyRequested failed", error);
      await snap.ref.update({ result: "error" }).catch(() => {});
    }
    return null;
  });
