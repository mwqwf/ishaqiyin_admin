package com.ali.ishaqiyin_admin

import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.min

/** جسر استقبال الصوتيات المشتركة دون إجراء نسخ ثقيل على UI thread. */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "menbar_admin/share"
        private const val MAX_FILE_BYTES = 100L * 1024L * 1024L
        private const val MAX_BATCH_BYTES = 200L * 1024L * 1024L
        private const val COPY_TIMEOUT_SECONDS = 30L
    }

    private data class CopiedFile(val path: String, val bytes: Long)

    private var channel: MethodChannel? = null
    private val executor = Executors.newCachedThreadPool()
    private val pendingPaths = Collections.synchronizedSet(linkedSetOf<String>())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingShared", "getInitialShared" -> {
                    result.success(snapshotPending())
                }
                "acknowledgeShared" -> {
                    val paths = (call.arguments as? List<*>)
                        ?.mapNotNull { it?.toString() }
                        .orEmpty()
                    executor.execute { cleanupAcknowledged(paths) }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        captureShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShare(intent)
    }

    private fun captureShare(intent: Intent?) {
        if (intent == null) return
        val uris = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) uris.add(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val list = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (list != null) uris.addAll(list)
            }
            else -> return
        }
        if (uris.isEmpty()) return

        // كل النسخ والفحص يجريان خارج main thread. يبقى الحدث pending حتى
        // يؤكد Dart إغلاق نموذج الإضافة، فلا تضيع مشاركة warm-start.
        executor.execute {
            val copiedPaths = ArrayList<String>()
            var batchBytes = 0L
            for (uri in uris) {
                val remaining = MAX_BATCH_BYTES - batchBytes
                if (remaining <= 0) break
                val maxForThisFile = min(MAX_FILE_BYTES, remaining)
                val future = executor.submit<CopiedFile?> {
                    copyToCache(uri, maxForThisFile)
                }
                val copied = try {
                    future.get(COPY_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                } catch (_: Exception) {
                    future.cancel(true)
                    null
                } ?: continue
                batchBytes += copied.bytes
                copiedPaths.add(copied.path)
            }
            if (copiedPaths.isEmpty()) return@execute
            pendingPaths.addAll(copiedPaths)
            runOnUiThread { deliverPending() }
        }
    }

    private fun deliverPending() {
        val paths = snapshotPending()
        if (paths.isNotEmpty()) {
            channel?.invokeMethod("onShared", paths)
        }
    }

    private fun snapshotPending(): ArrayList<String> =
        synchronized(pendingPaths) { ArrayList(pendingPaths) }

    private fun cleanupAcknowledged(paths: List<String>) {
        for (path in paths) {
            val removed = pendingPaths.remove(path)
            if (!removed) continue
            try {
                val file = File(path)
                val intakeDir = File(cacheDir, "shared_intake").canonicalFile
                val candidate = file.canonicalFile
                if (candidate.parentFile == intakeDir) candidate.delete()
            } catch (_: Exception) {
                // cache مؤقت؛ نظام Android يستطيع تنظيفه لاحقاً.
            }
        }
    }

    private fun copyToCache(uri: Uri, maxBytes: Long): CopiedFile? {
        var outFile: File? = null
        return try {
            val declaredSize = querySize(uri)
            if (declaredSize != null && declaredSize > maxBytes) return null

            val rawName = queryDisplayName(uri)
                ?: "shared_${System.currentTimeMillis()}.mp3"
            val safeName = rawName.replace(Regex("[^\\p{L}\\p{N}._ -]"), "_")
                .takeLast(120)
            val outDir = File(cacheDir, "shared_intake").apply { mkdirs() }
            outFile = File(outDir, "${System.nanoTime()}_$safeName")
            var total = 0L
            contentResolver.openInputStream(uri)?.use { input ->
                outFile.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (Thread.currentThread().isInterrupted) {
                            throw InterruptedException()
                        }
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > maxBytes) {
                            throw IllegalArgumentException("shared file too large")
                        }
                        output.write(buffer, 0, read)
                    }
                }
            } ?: return null
            CopiedFile(outFile.absolutePath, total)
        } catch (_: Exception) {
            try { outFile?.delete() } catch (_: Exception) {}
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? = queryColumn(
        uri,
        android.provider.OpenableColumns.DISPLAY_NAME
    )

    private fun querySize(uri: Uri): Long? = queryColumn(
        uri,
        android.provider.OpenableColumns.SIZE
    )?.toLongOrNull()

    private fun queryColumn(uri: Uri, column: String): String? {
        return try {
            contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(column)
                if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                    cursor.getString(index)
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }
}
