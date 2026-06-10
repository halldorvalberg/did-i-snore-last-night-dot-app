// Singleton bridge for RecorderService control/status EVENTS (not PCM audio).
//
// Mirrors `PcmBus` exactly — same volatile-sink + main-looper-hop pattern —
// but on a SEPARATE EventChannel so the high-rate PCM stream and the low-rate
// event stream never share a sink. The events here are small JSON-ish maps
// (`{"type": "...", "atMs": <epoch ms>}`), not raw audio buffers.
//
// Why a second channel rather than multiplexing onto PcmBus: the PCM sink
// ships `ByteArray` payloads ~10×/sec on the hot path; interleaving control
// maps onto it would force every Dart PCM listener to type-check each event,
// and a torn type assumption there would corrupt the audio pipeline. Keeping
// events on their own channel keeps the hot path byte-only.
//
// Current producers (see RecorderService):
//   - "interruption_began" — our AudioRecord was silenced (phone call,
//     concurrent-capture preemption, or privacy mic-mute). Maps to the
//     Android equivalent of the iOS §10.2 interruption `.began`.
//   - "interruption_ended" — the silencing lifted and we're capturing real
//     audio again. Dart writes a `recording_gaps` row covering the dead
//     period (reason='interruption').
//
// Detection is privacy-respecting: it relies solely on
// AudioManager.registerAudioRecordingCallback → isClientSilenced. We do NOT
// use READ_PHONE_STATE / PhoneStateListener, and we do NOT request audio
// focus (this is a passive recorder; §1.2 forbids announcing ourselves).
//
// Lifecycle: MainActivity's StreamHandler registers the sink in onListen and
// clears it in onCancel. When no Dart listener is attached (sink == null) the
// event is dropped — acceptable, same as PcmBus: MicSource subscribes BEFORE
// it invokes `start`, so steady-state always has a sink ready.

package app.didisnorelastnight.did_i_snore

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object RecorderEventBus {
    private val mainHandler = Handler(Looper.getMainLooper())

    // Volatile: written from the main thread (onListen/onCancel), read from
    // the worker thread (the AudioRecordingCallback fires on a binder thread).
    // A torn read is impossible for a reference, and we only ever touch
    // `.success()` after re-posting onto the main thread.
    @Volatile
    private var sink: EventChannel.EventSink? = null

    fun setSink(s: EventChannel.EventSink?) {
        sink = s
    }

    /** Forward one event map to Dart. Safe to call from any thread. */
    fun emit(event: Map<String, Any?>) {
        // Snapshot once; the sink could be cleared between this check and the
        // posted runnable, so re-read inside the runnable too.
        if (sink == null) return
        mainHandler.post {
            sink?.success(event)
        }
    }
}
