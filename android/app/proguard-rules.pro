# قواعد keep لنسخة release المقلَّصة بـ R8.
# مكتبات Flutter وFirebase تشحن قواعدها الاستهلاكية تلقائياً؛ ما يلي يغطي
# الحالات المعروفة التي لا تغطّيها تلك القواعد.

# flutter_local_notifications: يسترجع الإشعارات عبر Gson بأنواع generics.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.dexterous.** { *; }
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
