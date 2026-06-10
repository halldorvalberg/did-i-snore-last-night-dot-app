// Production native Android foreground Service that owns AudioRecord directly
// and STREAMS PCM to Dart over an EventChannel.
//
// Why native (see docs/IMPLEMENTATION.md §1.4): the `flutter_background_service`
// + `record` stack has two fatal bugs on Android 14+ for an all-night recorder:
//   Bug A — the plugin calls Service.startForeground() too late, so Android's
//           FGS-promotion timer (5–30s) fires while the Dart engine is still
//           booting and the OS throws ForegroundServiceDidNotStartInTimeException,
//           SIGKILLing the whole process.
//   Bug B — the UI→service-isolate `invoke('start')` races listener
//           registration and the start command is dropped on the floor.
// Both were observed on the Nothing Phone 3a during Phase 1 smoke testing.
//
// This service is the §1.4 lock-in. It differs from the throwaway harness in
// one way: instead of writing 30s .pcm segments + a heartbeat.log to disk, it
// forwards each AudioRecord.read chunk to Dart via `PcmBus`. The Dart pipeline
// (slicer → ring → gate → …) consumes that stream exactly as it would consume
// the `record` plugin stream on iOS. Crash detection is Dart-side
// (shared_preferences via CrashHeartbeat) — this service writes NO heartbeat.
//
// Invariants kept from the harness (§1.4):
//   - startForeground() called SYNCHRONOUSLY in onStartCommand BEFORE any other
//     work, with FOREGROUND_SERVICE_TYPE_MICROPHONE (bug-A fix).
//   - AudioRecord owned on a worker thread; no Dart roundtrip on the hot path.
//   - MediaRecorder.AudioSource.UNPROCESSED on API ≥24 (disables OS AGC/NS so
//     calibration thresholds reflect real ambient energy). minSdk=24 (§2.1)
//     guarantees this source; the VOICE_RECOGNITION fallback below 24 is dead
//     code we never ship.
//   - IMPORTANCE_LOW ongoing notification (doubles as the mic indicator).
//   - START_STICKY; clean stop via ACTION_STOP → drain → stopForeground+stopSelf.
//   - Same process (no android:process).

package app.didisnorelastnight.did_i_snore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class RecorderService : Service() {

    companion object {
        private const val TAG = "RecorderService"

        const val ACTION_START = "app.didisnorelastnight.START"
        const val ACTION_STOP = "app.didisnorelastnight.STOP"

        private const val CHANNEL_ID = "recorder"
        private const val CHANNEL_NAME = "Recording"
        private const val NOTIF_ID = 1001

        private const val SAMPLE_RATE_HZ = 16_000
        private const val NUM_CHANNELS = 1
        private const val BYTES_PER_SAMPLE = 2
        private const val BYTES_PER_SECOND = SAMPLE_RATE_HZ * NUM_CHANNELS * BYTES_PER_SAMPLE

        // 100ms read chunks (= 3_200 bytes). Small enough to keep the Dart
        // pipeline's framing latency low, large enough that we're not waking
        // the kernel constantly. The downstream slicer re-frames to 20ms.
        private const val READ_CHUNK_BYTES = BYTES_PER_SECOND / 10  // 3_200
    }

    private val stopRequested = AtomicBoolean(false)
    private var workerThread: Thread? = null

    // ---- interruption detection (Android equivalent of §10.2) -----------
    //
    // We detect "the mic went deaf mid-recording" (phone call, concurrent-
    // capture preemption, privacy mic-mute) purely via
    // AudioManager.registerAudioRecordingCallback → isClientSilenced. No
    // READ_PHONE_STATE, no PhoneStateListener, no audio focus — see
    // RecorderEventBus header for the privacy rationale (§1.2 forbids
    // announcing ourselves). Route changes (Bluetooth) are deliberately NOT
    // handled here: a BT route change doesn't silence AudioRecord on Android,
    // so reason='route_change' is deferred.
    //
    // `isClientSilenced` is API 29+. Below that the platform gives us no
    // silencing signal, so detection is simply absent (best-effort; we ship
    // API 24+ but the real device is 36). We do not add a focus-based
    // fallback — that would contradict the passive-recorder contract.
    private var audioManager: AudioManager? = null
    private var recordingCallback: AudioManager.AudioRecordingCallback? = null

    // Session id of OUR AudioRecord, captured once after start so the
    // callback can pick our config out of the system-wide list by matching
    // `config.clientAudioSessionId`.
    private var audioSessionId: Int = AudioManager.AUDIO_SESSION_ID_GENERATE

    // Previous silenced state, so we only emit on TRANSITIONS:
    //   false → true  = interruption began
    //   true  → false = interruption ended
    // Volatile: written on the binder thread the callback fires on, read
    // there too; kept volatile so a future cross-thread reset stays visible.
    @Volatile
    private var wasSilenced = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // CRITICAL (bug-A fix, §1.4): promote to foreground before anything
        // else. The OS measures the time between startForegroundService() and
        // this call. Anything async here risks the 5–30s FGS-promotion timer
        // and a process-wide SIGKILL.
        startInForeground()

        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "ACTION_STOP received")
                stopRequested.set(true)
                // Don't stopSelf() yet — let the worker drain and release the
                // AudioRecord cleanly. It calls stopForeground+stopSelf when
                // it's done.
            }
            else -> {
                // Default action == start (covers ACTION_START and the
                // implicit start when no action is set).
                if (workerThread == null) {
                    Log.i(TAG, "ACTION_START received, spinning recorder")
                    stopRequested.set(false)
                    workerThread = thread(start = true, name = "RecorderWorker") {
                        runRecorder()
                    }
                } else {
                    Log.i(TAG, "ACTION_START received but worker already running")
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        stopRequested.set(true)
        workerThread?.join(2_000)
        workerThread = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Foreground-service plumbing
    // ------------------------------------------------------------------

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val chan = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while Did I Snore? is recording."
                    setShowBadge(false)
                }
                mgr.createNotificationChannel(chan)
            }
        }
    }

    private fun buildNotification(): Notification {
        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = if (tapIntent != null) {
            PendingIntent.getActivity(
                this, 0, tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else null

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle("Did I Snore? is recording")
            .setContentText("Listening for sounds while you sleep. Tap to manage.")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (pi != null) builder.setContentIntent(pi)
        return builder.build()
    }

    private fun startInForeground() {
        val notif = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    // ------------------------------------------------------------------
    // Recorder worker
    // ------------------------------------------------------------------

    private fun runRecorder() {
        val source = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            MediaRecorder.AudioSource.UNPROCESSED
        } else {
            MediaRecorder.AudioSource.VOICE_RECOGNITION
        }

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE_HZ,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            Log.e(TAG, "AudioRecord.getMinBufferSize returned $minBuffer; aborting")
            stopForegroundAndSelf()
            return
        }
        // 4× minBuffer keeps us comfortable across short HAL stalls.
        val bufferBytes = maxOf(minBuffer * 4, READ_CHUNK_BYTES * 4)

        val recorder = try {
            AudioRecord(
                source,
                SAMPLE_RATE_HZ,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "AudioRecord SecurityException — RECORD_AUDIO not granted?", e)
            stopForegroundAndSelf()
            return
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord did not initialize (state=${recorder.state})")
            recorder.release()
            stopForegroundAndSelf()
            return
        }

        recorder.startRecording()
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            Log.e(TAG, "AudioRecord did not enter RECORDING state")
            recorder.release()
            stopForegroundAndSelf()
            return
        }

        Log.i(TAG, "recorder started: source=$source sampleRate=$SAMPLE_RATE_HZ")

        // Register the silencing watcher now that AudioRecord is live and has
        // a real session id. Must be after startRecording() so our config
        // actually appears in the system list.
        audioSessionId = recorder.audioSessionId
        wasSilenced = false
        registerRecordingCallback()

        try {
            while (!stopRequested.get()) {
                // Allocate a fresh buffer per read: the bytes are handed off to
                // Dart on another thread (via PcmBus → main-thread sink), so we
                // can't reuse one ByteArray without risking a torn read while
                // the previous chunk is still in flight.
                val chunk = ByteArray(READ_CHUNK_BYTES)
                val read = recorder.read(chunk, 0, chunk.size)
                if (read < 0) {
                    Log.w(TAG, "AudioRecord.read returned $read")
                    // Don't break immediately; keep trying for one more tick so
                    // transient HAL errors recover.
                    Thread.sleep(50)
                    continue
                }
                if (read == 0) {
                    Thread.sleep(10)
                    continue
                }

                // Forward exactly `read` bytes to Dart. On the common path
                // read == READ_CHUNK_BYTES; on the tail of a short read we
                // copy down to avoid shipping stale buffer bytes.
                val out = if (read == chunk.size) chunk else chunk.copyOf(read)
                PcmBus.emit(out)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "recorder loop crashed", t)
        } finally {
            // Unregister BEFORE releasing AudioRecord. If we were stopped
            // mid-interruption (wasSilenced == true), the Dart side closes
            // the gap from its tracked start to `now` when MicSource.stop()
            // tears down — we deliberately do NOT synthesize an
            // "interruption_ended" here, because on a clean stop the mic
            // never actually resumed. (See recorder_service.dart stop().)
            unregisterRecordingCallback()
            try { recorder.stop() } catch (_: Throwable) {}
            try { recorder.release() } catch (_: Throwable) {}
            stopForegroundAndSelf()
        }
    }

    // ------------------------------------------------------------------
    // Interruption detection (isClientSilenced transitions)
    // ------------------------------------------------------------------

    private fun registerRecordingCallback() {
        // isClientSilenced (and thus any useful signal) is API 29+. Below
        // that we register nothing and interruption detection is absent.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.i(TAG, "interruption detection unavailable (API < 29)")
            return
        }
        val mgr = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (mgr == null) {
            Log.w(TAG, "AUDIO_SERVICE unavailable; interruption detection off")
            return
        }
        val cb = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(
                configs: MutableList<AudioRecordingConfiguration>,
            ) {
                handleRecordingConfigChanged(configs)
            }
        }
        // Run the callback on the main looper handler — emissions hop to the
        // main thread anyway (RecorderEventBus), and keeping callback +
        // emit on one thread avoids any wasSilenced read/write race.
        mgr.registerAudioRecordingCallback(cb, mainHandlerOrNull())
        audioManager = mgr
        recordingCallback = cb
        Log.i(TAG, "registered AudioRecordingCallback (sessionId=$audioSessionId)")
    }

    private fun unregisterRecordingCallback() {
        val mgr = audioManager
        val cb = recordingCallback
        if (mgr != null && cb != null) {
            try { mgr.unregisterAudioRecordingCallback(cb) } catch (_: Throwable) {}
            Log.i(TAG, "unregistered AudioRecordingCallback")
        }
        audioManager = null
        recordingCallback = null
        wasSilenced = false
    }

    private fun handleRecordingConfigChanged(
        configs: List<AudioRecordingConfiguration>,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        // Find OUR config by session id. The system list contains every
        // active capture client; matching clientAudioSessionId isolates ours
        // so another app's mic muting can't be misread as our interruption.
        val ours = configs.firstOrNull {
            it.clientAudioSessionId == audioSessionId
        } ?: return  // our config briefly absent (e.g. mid-reconfig); ignore.

        val silenced = ours.isClientSilenced
        if (silenced == wasSilenced) return  // no transition

        wasSilenced = silenced
        val atMs = System.currentTimeMillis()
        if (silenced) {
            Log.i(TAG, "silenced-began atMs=$atMs (mic taken — call/preempt/mute)")
            RecorderEventBus.emit(
                mapOf("type" to "interruption_began", "atMs" to atMs),
            )
        } else {
            Log.i(TAG, "silenced-ended atMs=$atMs (mic returned)")
            RecorderEventBus.emit(
                mapOf("type" to "interruption_ended", "atMs" to atMs),
            )
        }
    }

    /** Main-looper Handler for callback delivery, or null on the off chance
     * the looper is unavailable (registerAudioRecordingCallback accepts a
     * null handler and falls back to the calling thread's looper). */
    private fun mainHandlerOrNull(): android.os.Handler? =
        android.os.Looper.getMainLooper()?.let { android.os.Handler(it) }

    private fun stopForegroundAndSelf() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {}
        stopSelf()
    }
}
