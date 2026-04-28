// THROWAWAY HARNESS - native Android FGS that owns AudioRecord directly.
//
// Why this exists: flutter_background_service v5 has two fatal bugs on
// Android 14+ for this use case:
//   1. The Dart isolate that runs the service initializes async; the UI
//      side's `invoke('start')` races the listener registration and is
//      sometimes dropped on the floor.
//   2. The native plugin's call to startForeground() is too late, so the
//      OS throws ForegroundServiceDidNotStartInTimeException after ~30s
//      and SIGKILLs the entire process — taking the FGS, the recorder,
//      and the heartbeat log writer with it.
//
// Both observed on a Nothing Phone 3a (Android 14, OneOS skin) during
// Phase 1 smoke testing on 2026-04-28.
//
// This service:
//   - Calls startForeground() synchronously in onStartCommand BEFORE doing
//     anything else. That's the only way to satisfy Android's FGS timer
//     reliably.
//   - Owns the AudioRecord directly on a worker thread. No Dart roundtrip
//     on the hot path.
//   - Writes 30s PCM segments and a CSV heartbeat log to the same paths
//     the Dart smoke_verifier expects (<filesDir>/app_flutter/smoke/...).
//     We mirror path_provider's getApplicationDocumentsDirectory layout
//     so the verifier doesn't need changes.
//   - Sets foregroundServiceType=microphone via the manifest entry.
//   - Uses AudioSource.UNPROCESSED on API 24+; falls back silently to
//     VOICE_RECOGNITION on older devices (we won't ship there anyway —
//     minSdk=24 is enforced in the real app).

package app.didisnorelastnight.smoke.phase_1_harness

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

class RecorderService : Service() {

    companion object {
        private const val TAG = "RecorderService"

        const val ACTION_START = "app.didisnorelastnight.smoke.START"
        const val ACTION_STOP = "app.didisnorelastnight.smoke.STOP"

        private const val CHANNEL_ID = "smoke_recorder"
        private const val CHANNEL_NAME = "Smoke recorder"
        private const val NOTIF_ID = 1001

        private const val SAMPLE_RATE_HZ = 16_000
        private const val NUM_CHANNELS = 1
        private const val BYTES_PER_SAMPLE = 2
        // 32_000 bytes/s -> 1_920_000 bytes/min. The smoke verifier checks
        // delta against this number with a ±5% band.
        private const val BYTES_PER_SECOND = SAMPLE_RATE_HZ * NUM_CHANNELS * BYTES_PER_SAMPLE
        private const val SEGMENT_BYTES = BYTES_PER_SECOND * 30  // 960_000

        // 100ms read chunks. Small enough to make the byte-count granular,
        // large enough that we're not waking the kernel constantly.
        private const val READ_CHUNK_BYTES = BYTES_PER_SECOND / 10  // 3_200

        // Heartbeat tick interval.
        private const val HEARTBEAT_INTERVAL_MS = 60_000L

        // Cached state for the MethodChannel state query. Volatile so the
        // UI thread can read while the recorder thread writes.
        @Volatile var running: Boolean = false
            private set
        @Volatile var sessionStartedAtMs: Long = 0L
            private set
        @Volatile var totalBytes: Long = 0L
            private set
        @Volatile var lastHeartbeatBytes: Long = 0L
            private set
        @Volatile var lastHeartbeatAtMs: Long = 0L
            private set
        @Volatile var currentSegmentFile: String = ""
            private set
    }

    private val stopRequested = AtomicBoolean(false)
    private var workerThread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // CRITICAL: promote to foreground before anything else. The OS
        // measures the time between startForegroundService() and this
        // call. Anything async here risks the 5–30s timer.
        startInForeground()

        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "ACTION_STOP received")
                stopRequested.set(true)
                // Don't stopSelf() yet — let the worker drain and close
                // segments cleanly. It calls stopForeground+stopSelf when
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
                    description = "Phase 1 smoke recording — tap to manage."
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
            .setContentTitle("Smoke test recording")
            .setContentText("Tap to manage.")
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

        val sessionStartMs = System.currentTimeMillis()
        sessionStartedAtMs = sessionStartMs
        running = true
        totalBytes = 0L
        lastHeartbeatBytes = 0L
        lastHeartbeatAtMs = 0L
        currentSegmentFile = ""

        appendHeartbeatLine("SESSION_START,$sessionStartMs,${iso8601(sessionStartMs)}")

        val chunk = ByteArray(READ_CHUNK_BYTES)
        var segmentBytes = 0
        var segmentOut: FileOutputStream? = null
        var segmentPath = ""
        var lastHeartbeatTickMs = sessionStartMs
        var lastHeartbeatTotalBytes = 0L

        try {
            while (!stopRequested.get()) {
                if (segmentOut == null) {
                    val (path, fos) = openNewSegment()
                    segmentPath = path
                    segmentOut = fos
                    segmentBytes = 0
                    currentSegmentFile = path
                }

                val read = recorder.read(chunk, 0, chunk.size)
                if (read < 0) {
                    Log.w(TAG, "AudioRecord.read returned $read")
                    // Don't break immediately; keep trying for one more
                    // tick so transient errors recover.
                    Thread.sleep(50)
                    continue
                }
                if (read == 0) {
                    Thread.sleep(10)
                    continue
                }

                // Write what fits in the current segment, rotate, write rest.
                var off = 0
                while (off < read) {
                    val space = SEGMENT_BYTES - segmentBytes
                    if (space <= 0) {
                        segmentOut?.flush()
                        segmentOut?.close()
                        val (path, fos) = openNewSegment()
                        segmentPath = path
                        segmentOut = fos
                        segmentBytes = 0
                        currentSegmentFile = path
                        continue
                    }
                    val take = minOf(read - off, space)
                    segmentOut!!.write(chunk, off, take)
                    segmentBytes += take
                    totalBytes += take
                    off += take
                }

                val now = System.currentTimeMillis()
                if (now - lastHeartbeatTickMs >= HEARTBEAT_INTERVAL_MS) {
                    val total = totalBytes
                    val delta = total - lastHeartbeatTotalBytes
                    appendHeartbeatLine(
                        "${iso8601(now)},$now,$total,$delta,$segmentPath",
                    )
                    lastHeartbeatBytes = delta
                    lastHeartbeatAtMs = now
                    lastHeartbeatTickMs = now
                    lastHeartbeatTotalBytes = total
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "recorder loop crashed", t)
        } finally {
            try { recorder.stop() } catch (_: Throwable) {}
            try { recorder.release() } catch (_: Throwable) {}
            try { segmentOut?.flush() } catch (_: Throwable) {}
            try { segmentOut?.close() } catch (_: Throwable) {}
            val nowMs = System.currentTimeMillis()
            appendHeartbeatLine("SESSION_STOP,$nowMs,${iso8601(nowMs)}")
            running = false
            currentSegmentFile = ""
            stopForegroundAndSelf()
        }
    }

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

    // ------------------------------------------------------------------
    // Disk layout
    // ------------------------------------------------------------------

    private fun smokeDir(): File {
        // path_provider.getApplicationDocumentsDirectory() on Android
        // returns `<dataDir>/app_flutter`, NOT `<filesDir>/app_flutter`
        // (filesDir is `<dataDir>/files`, a sibling of app_flutter).
        // Use dataDir so the smoke verifier and any future Dart tooling
        // sees the recorder's output without path translation.
        val docs = File(dataDir, "app_flutter")
        val smoke = File(docs, "smoke")
        if (!smoke.exists()) smoke.mkdirs()
        return smoke
    }

    private fun heartbeatFile(): File = File(smokeDir(), "heartbeat.log")

    private fun openNewSegment(): Pair<String, FileOutputStream> {
        val now = Date()
        val ymd = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now)
        val hms = SimpleDateFormat("HH-mm-ss", Locale.US).format(now)
        val dayDir = File(smokeDir(), ymd)
        if (!dayDir.exists()) dayDir.mkdirs()
        val f = File(dayDir, "$hms.pcm")
        return f.absolutePath to FileOutputStream(f, false)
    }

    private fun appendHeartbeatLine(line: String) {
        try {
            heartbeatFile().appendText("$line\n")
        } catch (t: Throwable) {
            Log.w(TAG, "heartbeat append failed", t)
        }
    }

    private fun iso8601(epochMs: Long): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
        return fmt.format(Date(epochMs))
    }
}
