package com.example.echonote

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native mic capture for live transcription — the Android twin of
 * ios/Runner/MicStreamChannel.swift, with the same contract: MethodChannel
 * `echonote/mic`, 16 kHz mono PCM16 little-endian chunks on EventChannel
 * `echonote/mic/pcm`, and the same error codes (see
 * docs/specs/feature-native-mic-stream/ and docs/specs/feature-echo-core-w3/).
 *
 * Bound to the FlutterEngine, so a configuration change does not stop a
 * running stream; the Activity is attached separately for permission
 * prompts and the background signal.
 */
class MicStreamChannel(messenger: BinaryMessenger, private val context: Context) :
    EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, "echonote/mic")
    private val eventChannel = EventChannel(messenger, "echonote/mic/pcm")
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val prefs = context.getSharedPreferences("echonote_mic", Context.MODE_PRIVATE)

    var activity: Activity? = null

    // Main thread only.
    private var eventSink: EventChannel.EventSink? = null
    private var isRunning = false
    /** Bumped on every start/stop so chunks queued from an older session are dropped. */
    private var generation = 0
    private var recorder: AudioRecord? = null
    private var reader: Thread? = null
    private var focusRequest: AudioFocusRequest? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            // A call or another recorder took the audio; ducking is fine.
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ->
                main.post { endWithError("INTERRUPTED", "Audio focus lost") }
        }
    }

    init {
        methodChannel.setMethodCallHandler(::handle)
        eventChannel.setStreamHandler(this)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPermissionStatus" -> result.success(permissionStatus())
            "requestPermission" -> requestPermission(result)
            "start" -> start(call, result)
            "stop" -> {
                stopCapture(sendEndOfStream = true)
                result.success(null)
            }
            "openSettings" -> result.success(openSettings())
            else -> result.notImplemented()
        }
    }

    // region Permission

    /**
     * Android has no "never asked" state of its own, and
     * shouldShowRequestPermissionRationale is false both before the first
     * request and after "don't ask again". So permanentlyDenied is only
     * reported after one of our own requests came back denied with the
     * rationale off; a grant that expired ("Only this time") or was revoked
     * in Settings reads as undetermined, and requesting shows the dialog again.
     */
    private fun permissionStatus(): String {
        if (hasPermission()) return "granted"
        val rationale = activity?.let {
            ActivityCompat.shouldShowRequestPermissionRationale(it, Manifest.permission.RECORD_AUDIO)
        } ?: false
        return when {
            rationale -> "denied"
            prefs.getBoolean(KEY_DENIED_FOR_GOOD, false) -> "permanentlyDenied"
            else -> "undetermined"
        }
    }

    private fun hasPermission() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        when (permissionStatus()) {
            "granted" -> return result.success(true)
            // The system would not show a dialog anyway.
            "permanentlyDenied" -> return result.success(false)
        }
        val act = activity ?: return result.success(false)
        if (pendingPermissionResult != null) {
            return result.error("ALREADY_RUNNING", "A permission request is already showing", null)
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_CODE)
    }

    /** Forwarded from MainActivity.onRequestPermissionsResult. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        // Denied and the system will not ask again (or dismissed in a way it
        // counts as such): only Settings can grant it from here.
        val rationale = activity?.let {
            ActivityCompat.shouldShowRequestPermissionRationale(it, Manifest.permission.RECORD_AUDIO)
        } ?: false
        prefs.edit().putBoolean(KEY_DENIED_FOR_GOOD, !granted && !rationale).apply()
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    private fun openSettings(): Boolean = try {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (e: Exception) {
        false
    }

    // endregion

    // region Capture

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (isRunning) {
            return result.error("ALREADY_RUNNING", "Mic stream is already running", null)
        }
        if (!hasPermission()) {
            return result.error("PERMISSION_DENIED", "Microphone permission not granted", null)
        }
        val sampleRate = call.argument<Int>("sampleRate") ?: 16000
        val chunkMs = call.argument<Int>("chunkMs") ?: 100
        // 2 bytes per sample, so always an even byte count.
        val chunkBytes = sampleRate * chunkMs / 1000 * 2

        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            return result.error("FORMAT_UNSUPPORTED", "$sampleRate Hz mono PCM16 is not supported", null)
        }
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, sampleRate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, chunkBytes * 4),
            )
        } catch (e: Exception) {
            return result.error("AUDIO_SESSION_ERROR", e.message ?: "AudioRecord failed", null)
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return result.error("AUDIO_SESSION_ERROR", "AudioRecord could not be initialized", null)
        }
        if (!requestAudioFocus()) {
            record.release()
            return result.error("AUDIO_SESSION_ERROR", "Audio focus was not granted", null)
        }
        try {
            record.startRecording()
        } catch (e: Exception) {
            record.release()
            abandonAudioFocus()
            return result.error("AUDIO_SESSION_ERROR", e.message ?: "startRecording failed", null)
        }
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            record.release()
            abandonAudioFocus()
            return result.error("AUDIO_SESSION_ERROR", "Microphone is in use by another app", null)
        }

        recorder = record
        isRunning = true
        generation += 1
        val gen = generation
        reader = Thread({ readLoop(record, chunkBytes, gen) }, "echonote-mic").apply { start() }
        result.success(null)
    }

    /** Blocking reads on a background thread; each full chunk hops to main. */
    private fun readLoop(record: AudioRecord, chunkBytes: Int, gen: Int) {
        while (true) {
            val chunk = ByteArray(chunkBytes)
            var filled = 0
            while (filled < chunkBytes) {
                val n = record.read(chunk, filled, chunkBytes - filled)
                if (n < 0) {
                    // Stopped/released from main (normal stop), or a real error
                    // such as the permission being revoked mid-recording.
                    main.post {
                        if (isRunning && generation == gen) {
                            endWithError("AUDIO_SESSION_ERROR", "AudioRecord.read failed ($n)")
                        }
                    }
                    return
                }
                if (n == 0 && record.recordingState != AudioRecord.RECORDSTATE_RECORDING) return
                filled += n
            }
            main.post {
                if (isRunning && generation == gen) eventSink?.success(chunk)
            }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, main)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusListener, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE,
            )
        }
        return granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
    }

    /** Forwarded from MainActivity.onStop: no background recording. */
    fun onAppBackgrounded() {
        endWithError("BACKGROUNDED", "App entered the background")
    }

    /** Sends a stream error, then ends the stream (error first, then endOfStream). */
    private fun endWithError(code: String, message: String) {
        if (!isRunning) return
        eventSink?.error(code, message, null)
        stopCapture(sendEndOfStream = true)
    }

    /** Idempotent: does nothing when not running. */
    private fun stopCapture(sendEndOfStream: Boolean) {
        if (!isRunning) return
        isRunning = false
        generation += 1
        recorder?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        recorder = null
        reader = null
        abandonAudioFocus()
        if (sendEndOfStream) eventSink?.endOfStream()
    }

    // endregion

    // region EventChannel.StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    /** The Dart side stopped listening: release the mic rather than record into nowhere. */
    override fun onCancel(arguments: Any?) {
        stopCapture(sendEndOfStream = false)
        eventSink = null
    }

    // endregion

    private companion object {
        const val REQUEST_CODE = 4217
        const val KEY_DENIED_FOR_GOOD = "record_audio_denied_for_good"
    }
}
