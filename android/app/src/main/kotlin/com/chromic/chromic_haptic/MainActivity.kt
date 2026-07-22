package com.chromic.chromic_haptic

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/**
 * Chromic Haptic — Android native vibration engine v3 + file picker.
 *
 * Design rules (verified against real Android API docs):
 *  - ALL events use `createOneShot(12-15ms)` ONLY.
 *    `createWaveform()` blocks the vibrator and cannot be preempted;
 *    it would drop beat events during word_sustain.
 *  - Between sequential oneShots we leave ~10ms idle → beat events
 *    can preempt within 10ms max (imperceptible).
 *  - ADSR envelope is achieved via amplitude variation across
 *    sequential oneShots, controlled by Flutter (haptic_engine.dart).
 *  - On API 33+ we query `getResonantFrequency()` + `getQFactor()`
 *    to report the device's real LRA parameters to Flutter.
 */
class MainActivity : FlutterActivity() {
    private val HAPTIC_CHANNEL = "com.chromic/haptic"

    companion object {
        private const val PICK_FILE_REQUEST = 42
    }

    // ── File picker state ──
    private var filePickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Haptic channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTIC_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "vibrate" -> {
                        val durationMs = call.argument<Int>("durationMs") ?: 15
                        val amplitude = call.argument<Int>("amplitude") ?: 128
                        vibrate(durationMs, amplitude)
                        result.success(true)
                    }
                    "getDeviceCaps" -> {
                        result.success(getDeviceCaps())
                    }
                    "cancel" -> {
                        cancelVibration()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── File picker channel (separate to avoid MissingPluginException) ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.chromic/filepicker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFile" -> {
                        filePickerResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "audio/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                                "audio/mpeg", "audio/mp4", "audio/wav",
                                "audio/flac", "audio/ogg", "audio/aac",
                                "audio/x-m4a", "audio/x-wav"
                            ))
                        }
                        startActivityForResult(intent, PICK_FILE_REQUEST)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── File picker result handler (old-style, FlutterActivity extends Activity) ──

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != PICK_FILE_REQUEST) return

        val result = filePickerResult
        filePickerResult = null

        if (resultCode != RESULT_OK || data?.data == null || result == null) {
            result?.success(null) // user cancelled
            return
        }

        val uri = data.data!!

        try {
            val name = getFileName(uri) ?: "track.m4a"
            val cacheDir = File(cacheDir, "uploads/${UUID.randomUUID()}")
            cacheDir.mkdirs()
            val destFile = File(cacheDir, name)

            contentResolver.openInputStream(uri)?.use { input ->
                destFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }

            result.success(mapOf(
                "path" to destFile.absolutePath,
                "name" to name
            ))
        } catch (e: Exception) {
            result.error("PICK_ERROR", e.message, null)
        }
    }

    // ── Device capability query (API 33+) ──

    private fun getDeviceCaps(): Map<String, Any> {
        val vibrator = getVibrator()

        val caps = mutableMapOf<String, Any>(
            "hasAmplitudeControl" to hasAmplitude(),
            "apiLevel" to Build.VERSION.SDK_INT,
            "minPulseIntervalMs" to 25,  // safe default for all LRA
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            try {
                caps["resonantFrequencyHz"] = vibrator.resonantFrequency
                caps["qFactor"] = vibrator.qFactor
                val bandwidth = if (vibrator.qFactor > 0f)
                    vibrator.resonantFrequency / vibrator.qFactor
                else 0f
                caps["bandwidthHz"] = bandwidth
            } catch (_: Exception) {
                caps["resonantFrequencyHz"] = 230f  // fallback
                caps["qFactor"] = 30f
                caps["bandwidthHz"] = 7.7f
            }
        } else {
            caps["resonantFrequencyHz"] = 230f  // generic LRA
            caps["qFactor"] = 30f
            caps["bandwidthHz"] = 7.7f
        }

        return caps
    }

    private fun hasAmplitude(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                getVibrator().hasAmplitudeControl()
            } else false
        } catch (_: Exception) {
            false
        }
    }

    // ── File picker helpers ──

    private fun getFileName(uri: Uri): String? {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && index >= 0) return cursor.getString(index)
        }
        return uri.lastPathSegment
    }

    // ── Vibration: oneShot ONLY (no waveform!) ──

    /**
     * Fire a one-shot vibration with capped duration.
     *
     * ALL haptic events use createOneShot with 12-20ms duration.
     * Intensity is encoded in amplitude, NOT duration.
     * This ensures the vibrator is never blocked for more than 20ms,
     * so beat events can always preempt within one tick.
     */
    private fun vibrate(durationMs: Int, amplitude: Int) {
        val vibrator = getVibrator()

        // Cap duration: beat=15ms, word=20ms max.
        // Even if Flutter sends longer, we cap to 20ms to keep the vibrator free.
        val effectiveMs = minOf(durationMs.toLong(), 20L)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Cancel any running vibration first (ensures no queue buildup)
            vibrator.cancel()
            vibrator.vibrate(
                VibrationEffect.createOneShot(effectiveMs, amplitude)
            )
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(effectiveMs)
        }
    }

    private fun cancelVibration() {
        try {
            getVibrator().cancel()
        } catch (_: Exception) {
            // ignore
        }
    }

    // ── Vibrator accessor ──

    private fun getVibrator(): Vibrator {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vm.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
    }
}
