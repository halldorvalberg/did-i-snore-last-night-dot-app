// THROWAWAY HARNESS - Phase 2 will rebuild this properly.
//
// MainActivity for the Phase 1 smoke-test harness.
//
// Hosts the `app.didisnorelastnight.smoke/audio` MethodChannel and forwards
// AudioManager focus changes to Dart. The `record` package handles AudioRecord
// errors via its stream; we don't duplicate that path here.
//
// `flutter create .` writes a default MainActivity. After bootstrap.sh, copy
// this file over the generated one (paths must match the application id).

package app.didisnorelastnight.smoke.phase_1_harness

import android.content.Context
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
