// THROWAWAY HARNESS - hosts the MethodChannel that drives RecorderService.
//
// All recording happens in RecorderService. This activity is a thin shell
// that:
//   - Forwards start/stop/getState calls from Dart to the service.
//   - Bridges OS audio-focus changes from this Activity context (cheap on
//     Android, only emits "interruption" markers; the recorder's own
//     AudioRecord is independent of focus changes here).
//
// Phase 2 will move all of this into the real Android module.

package app.didisnorelastnight.smoke.phase_1_harness

import android.content.Context
import android.content.Intent
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "app.didisnorelastnight.smoke/audio"
    private var channel: MethodChannel? = null
    private var focusRequest: AudioFocusRequest? = null
    private var beganAtMs: Long = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, RecorderService::class.java)
                        .setAction(RecorderService.ACTION_START)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stop" -> {
                    val intent = Intent(this, RecorderService::class.java)
                        .setAction(RecorderService.ACTION_STOP)
                    startService(intent)
                    result.success(true)
                }
                "getState" -> {
                    val state = mapOf(
                        "running" to RecorderService.running,
                        "sessionStartedAtMs" to RecorderService.sessionStartedAtMs,
                        "totalBytes" to RecorderService.totalBytes,
                        "lastHeartbeatBytes" to RecorderService.lastHeartbeatBytes,
                        "lastHeartbeatAtMs" to RecorderService.lastHeartbeatAtMs,
                        "currentSegmentFile" to RecorderService.currentSegmentFile,
                    )
                    result.success(state)
                }
                else -> result.notImplemented()
            }
        }
        registerAudioFocusListener()
    }

    private fun registerAudioFocusListener() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val listener = AudioManager.OnAudioFocusChangeListener { focusChange ->
            when (focusChange) {
                AudioManager.AUDIOFOCUS_LOSS,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    beganAtMs = System.currentTimeMillis()
                    channel?.invokeMethod("interruptionBegan", null)
                }
                AudioManager.AUDIOFOCUS_GAIN -> {
                    val args = mapOf("shouldResume" to true)
                    channel?.invokeMethod("interruptionEnded", args)
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setOnAudioFocusChangeListener(listener)
                .build()
            focusRequest = req
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                listener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
    }

    override fun onDestroy() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        }
        super.onDestroy()
    }
}
