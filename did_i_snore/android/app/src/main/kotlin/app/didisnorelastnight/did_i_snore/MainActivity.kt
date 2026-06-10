package app.didisnorelastnight.did_i_snore

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        // Must match the channel names in lib/recorder/mic_source.dart.
        private const val METHOD_CHANNEL = "app.didisnorelastnight/recorder"
        private const val EVENT_CHANNEL = "app.didisnorelastnight/recorder/pcm"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Control channel: start/stop the native foreground recorder service.
        // We use ContextCompat.startForegroundService for ACTION_START so the
        // OS grants the FGS-promotion window; the service then calls
        // startForeground() synchronously (the §1.4 bug-A fix).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, RecorderService::class.java).apply {
                            action = RecorderService.ACTION_START
                        }
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    }
                    "stop" -> {
                        val intent = Intent(this, RecorderService::class.java).apply {
                            action = RecorderService.ACTION_STOP
                        }
                        // Plain startService for stop — the service is already
                        // foreground; we just deliver the drain command.
                        startService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // PCM stream: the service worker thread pushes chunks onto PcmBus,
        // which hops to the main thread and calls this sink.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    PcmBus.setSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    PcmBus.setSink(null)
                }
            })
    }
}
