// Singleton bridge between the RecorderService worker thread (producer) and
// the Flutter EventChannel sink (consumer).
//
// The AudioRecord read loop runs on a background worker thread, but
// EventChannel.EventSink methods MUST be invoked on the main/UI thread. So the
// worker calls `PcmBus.emit(bytes)` from any thread, and we hop to the main
// looper before touching the sink.
//
// Lifecycle: MainActivity's StreamHandler registers the sink in onListen and
// clears it in onCancel. When no Dart listener is attached (sink == null) the
// chunk is dropped — this is fine and expected during the brief window between
// service start and EventChannel subscription; MicSource subscribes BEFORE it
// invokes the `start` method, so steady-state has a sink ready.

package app.didisnorelastnight.did_i_snore

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object PcmBus {
    private val mainHandler = Handler(Looper.getMainLooper())

    // Volatile: written from the main thread (onListen/onCancel), read from the
    // worker thread (emit). A torn read is impossible for a reference, and we
    // only ever touch `.success()` after re-posting onto the main thread.
    @Volatile
    private var sink: EventChannel.EventSink? = null

    fun setSink(s: EventChannel.EventSink?) {
        sink = s
    }

    /** Forward one PCM chunk to Dart. Safe to call from any thread. */
    fun emit(bytes: ByteArray) {
        // Snapshot once; the sink could be cleared between this check and the
        // posted runnable, so re-read inside the runnable too.
        if (sink == null) return
        mainHandler.post {
            sink?.success(bytes)
        }
    }
}
