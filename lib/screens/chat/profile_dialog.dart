import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/chat_repository.dart';
import 'chat_ui.dart';
import 'message_bubble.dart';

/// حوار الملفّ الشخصي في المجموعة: اختيار الاسم المعروض والصورة الشخصيّة.
/// يظهر تلقائيّاً مرّة واحدة بعد أوّل تسجيل دخول (firstRun)، ويُفتح لاحقاً
/// من «معلومات المجموعة» متى شاء العضو.
Future<void> showProfileDialog(
  BuildContext context, {
  bool firstRun = false,
}) async {
  final repo = ChatRepository.instance;
  final me = await repo.fetchSelf();
  if (!context.mounted) return;

  final googleName =
      FirebaseAuth.instance.currentUser?.displayName ??
      FirebaseAuth.instance.currentUser?.email?.split('@').first ??
      'مستخدم';
  final nameCtrl = TextEditingController(
    text: (me?.customName.isNotEmpty ?? false) ? me!.customName : googleName,
  );
  String? pickedPhotoPath;
  bool saving = false;

  await showDialog<void>(
    context: context,
    barrierDismissible: !firstRun,
    builder: (dialogCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(
        builder: (ctx, setState) {
          Future<void> pickPhoto() async {
            final res = await FilePicker.platform.pickFiles(
              type: FileType.image,
              withData: false,
            );
            final p = res?.files.firstOrNull?.path;
            if (p != null) setState(() => pickedPhotoPath = p);
          }

          Future<void> save() async {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) return;
            setState(() => saving = true);
            try {
              await repo.setMyName(name);
              if (pickedPhotoPath != null) {
                await repo.setMyPhotoFromPath(
                  pickedPhotoPath!,
                  pickedPhotoPath!.split(RegExp(r'[\\/]')).last,
                );
              }
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            } catch (e) {
              setState(() => saving = false);
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text('تعذّر الحفظ: $e'),
                    backgroundColor: ChatColors.rose,
                  ),
                );
              }
            }
          }

          return AlertDialog(
            title: Text(firstRun ? 'أهلاً بك في المجموعة! 👋' : 'ملفّي الشخصي'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (firstRun)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: Text(
                      'اختر اسمك وصورتك — هكذا سيراك بقيّة الأعضاء في دردشة الإدارة. يمكنك تغييرهما لاحقاً من معلومات المجموعة.',
                      style: TextStyle(
                        fontSize: 12,
                        color: ChatColors.textMuted,
                      ),
                    ),
                  ),
                InkWell(
                  onTap: saving ? null : pickPhoto,
                  borderRadius: BorderRadius.circular(48),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      pickedPhotoPath != null
                          ? CircleAvatar(
                              radius: 40,
                              backgroundImage: FileImage(
                                File(pickedPhotoPath!),
                              ),
                            )
                          : MemberAvatar(
                              uid: me?.uid ?? '',
                              name: nameCtrl.text,
                              photo: me?.displayPhoto ?? '',
                              radius: 40,
                            ),
                      PositionedDirectional(
                        bottom: -2,
                        end: -2,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: ChatColors.accentDark,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.photo_camera,
                            size: 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'اضغط الصورة لتغييرها',
                  style: TextStyle(fontSize: 10.5, color: ChatColors.textMuted),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  maxLength: 40,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    labelText: 'اسمي في المجموعة',
                    hintText: 'اكتب اسمك…',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
            actions: [
              if (!firstRun)
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.of(dialogCtx).pop(),
                  child: const Text('إلغاء'),
                ),
              FilledButton.icon(
                onPressed: saving || nameCtrl.text.trim().isEmpty ? null : save,
                icon: saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check, size: 16),
                label: Text(firstRun ? 'ابدأ' : 'حفظ'),
              ),
            ],
          );
        },
      ),
    ),
  );
  nameCtrl.dispose();
}
