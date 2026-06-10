/// Phase 9 crash detection. Spec §9 lines 940–949.
///
/// Recording sessions can end three ways: clean stop, app crash, or
/// phone reboot/death. The user-facing distinction matters — a "weekly
/// mid-event crash" without instrumentation just looks like "weird
/// missing data" forever. With this module, we get a counter and a
/// `recording_gaps` row the timeline can render as a gap marker.
///
/// **State persisted to `shared_preferences`:**
///
/// - [_kSessionStartedAt] — epoch ms set on `RecorderService.start()`,
///   cleared on clean `stop()`. Survives process death because
///   `shared_preferences` is backed by NSUserDefaults / Android
///   SharedPreferences, both of which write through synchronously
///   under `commit()` (and Flutter's wrapper uses commit).
/// - [_kLastCleanShutdownAt] — epoch ms set on clean `stop()`, cleared
///   on `start()`. Together with `session_started_at`, this is the
///   crash-detection signal: present `start` + absent `stop` = crash.
/// - [_kLastHeartbeatAt] — epoch ms updated periodically by
///   `RecorderService` while a session is active. The recovery path
///   uses this as the gap *end* — the recorder was demonstrably alive
///   at this moment, so the gap can't extend past it.
///
/// **Why these three keys (not, say, a `session_id`):** the spec calls
/// out exactly these three signals, and they're the minimum sufficient
/// set for "did the previous session end cleanly?" plus "what is the
/// recovered gap window?". A monotonic session id would let us
/// distinguish multiple lost sessions, but v1 only needs to surface
/// the *most recent* crash.
///
/// **Idempotent.** [detectAndClear] always clears [_kSessionStartedAt]
/// at the end, so a second call sees no crash signal even if the
/// inserted gap row hasn't yet propagated through the UI's stream
/// providers. The clean-shutdown / start methods are pure key writes
/// that are safe to re-run.
///
/// **Logger seam.** Same pattern as `EncodeQueue.onLog`: a callback
/// typedef so this module doesn't depend on the (still-Phase-11)
/// debug-log facility. Production passes a `print` shim or a no-op;
/// tests inject a list-recorder.
library;

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import '../data/db.dart';

/// `shared_preferences` keys. Underscored prefix so a future
/// `SharedPreferences.getKeys()` audit can grep for them; `did_i_snore.`
/// namespace prevents collisions with anything `record` / `permission_handler`
/// might persist (neither does today, but defensive).
const String _kSessionStartedAt = 'did_i_snore.session_started_at';
const String _kLastCleanShutdownAt =
    'did_i_snore.last_clean_shutdown_at';
const String _kLastHeartbeatAt = 'did_i_snore.last_heartbeat_at';

/// Logger seam.
typedef CrashLogger = void Function(
    String event, Map<String, Object?> fields);

void _noopLogger(String event, Map<String, Object?> fields) {}

/// Result of [CrashHeartbeat.detectAndClear].
class CrashDetectionResult {
  /// True iff the previous session ended unexpectedly — i.e.
  /// `session_started_at` was set and `last_clean_shutdown_at` was
  /// not.
  final bool detected;

  /// Recording-gap start, in epoch ms. Computed as
  /// `max(session_started_at, last_heartbeat - heartbeat_interval)`.
  /// The clamp prevents a crash that happened minutes after a
  /// long-quiescent session start from emitting a gap that swallows
  /// the entire session — we know the recorder was alive at the last
  /// heartbeat. Null when no crash was detected.
  final DateTime? gapStart;

  /// Recording-gap end, in epoch ms. The last heartbeat we recorded;
  /// fallback to `now` when no heartbeat had been written yet (e.g.
  /// crash within the first heartbeat interval). Null when no crash
  /// was detected.
  final DateTime? gapEnd;

  const CrashDetectionResult({
    required this.detected,
    required this.gapStart,
    required this.gapEnd,
  });

  /// Convenience — "no crash to report".
  factory CrashDetectionResult.none() => const CrashDetectionResult(
        detected: false,
        gapStart: null,
        gapEnd: null,
      );
}

/// Pure persistence + detection helper. Static because it has no
/// state — `shared_preferences` is the singleton, and the AppDb is
/// passed in to [detectAndClear] for the gap insert.
class CrashHeartbeat {
  CrashHeartbeat._();

  /// Called on `RecorderService.start()`. Writes `session_started_at`
  /// = now and clears `last_clean_shutdown_at` so the *next* launch's
  /// crash detector reads "session in progress, no clean stop yet".
  ///
  /// Idempotent — a second call within the same session overwrites
  /// the timestamp (which is fine; the "session start" anchor is the
  /// most recent start regardless of how the user got there).
  static Future<void> markSessionStarted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kSessionStartedAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.remove(_kLastCleanShutdownAt);
    // Reset the heartbeat — leftover from a previous session would
    // skew the next crash-recovery's gap end.
    await prefs.remove(_kLastHeartbeatAt);
  }

  /// Called on clean `RecorderService.stop()`. Writes
  /// `last_clean_shutdown_at = now` and clears `session_started_at` so
  /// the next launch sees "no session in progress" and the crash
  /// detector returns [CrashDetectionResult.none].
  ///
  /// Idempotent — clearing an already-clear key is a no-op.
  static Future<void> markCleanShutdown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLastCleanShutdownAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.remove(_kSessionStartedAt);
    await prefs.remove(_kLastHeartbeatAt);
  }

  /// Called periodically by `RecorderService` while a session is
  /// active (every `RetentionCfg.heartbeatIntervalSeconds`). Writes
  /// `last_heartbeat_at = now`. Cheap; `shared_preferences` writes are
  /// async-batched.
  static Future<void> writeHeartbeat() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLastHeartbeatAt,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Called on app launch (from `app.dart` boot, before the home
  /// screen mounts). If the previous session ended unexpectedly,
  /// inserts a `recording_gaps` row with `reason='crash'` covering the
  /// computed window and returns [CrashDetectionResult] with the
  /// `detected=true` flag and gap timestamps. Always clears
  /// `session_started_at` at the end so a second call within the same
  /// launch returns [CrashDetectionResult.none].
  ///
  /// **Idempotent.** Even if the caller re-invokes (e.g. a hot-restart
  /// in dev), the cleared `session_started_at` makes the second run a
  /// no-op.
  ///
  /// `now` is injectable so tests can drive the "missing heartbeat
  /// falls back to now" branch deterministically.
  static Future<CrashDetectionResult> detectAndClear(
    AppDb db, {
    DateTime Function() now = _systemNow,
    CrashLogger onLog = _noopLogger,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionStartedAt = prefs.getInt(_kSessionStartedAt);
    final lastCleanShutdown = prefs.getInt(_kLastCleanShutdownAt);

    if (sessionStartedAt == null || lastCleanShutdown != null) {
      // No session in progress, or the session ended cleanly.
      return CrashDetectionResult.none();
    }

    final lastHeartbeat = prefs.getInt(_kLastHeartbeatAt);
    final nowMs = now().millisecondsSinceEpoch;

    // Gap end: last heartbeat (recorder was demonstrably alive then),
    // falling back to `now` when no heartbeat had been written yet
    // (e.g. crash within the first heartbeat interval).
    final gapEndMs = lastHeartbeat ?? nowMs;

    // Gap start: clamp `session_started_at` upward so a crash that
    // happens minutes after a long-quiescent session doesn't emit a
    // gap that swallows the whole session. The recorder was alive at
    // `last_heartbeat`, and a heartbeat interval is the maximum
    // possible time since the last alive-check.
    final heartbeatIntervalMs =
        RetentionCfg.heartbeatIntervalSeconds * 1000;
    final clampedFromHeartbeat =
        lastHeartbeat != null ? lastHeartbeat - heartbeatIntervalMs : null;
    final gapStartMs = clampedFromHeartbeat != null
        ? (sessionStartedAt > clampedFromHeartbeat
            ? sessionStartedAt
            : clampedFromHeartbeat)
        : sessionStartedAt;

    // Insert a `recording_gaps` row. The Phase 8 timeline interleave
    // logic is already in place; this row will surface as a `GapTile`
    // with `reason='crash'` once the night's stream provider emits it.
    await db.into(db.recordingGaps).insert(
          RecordingGapsCompanion(
            startedAt: Value(gapStartMs),
            endedAt: Value(gapEndMs),
            reason: const Value('crash'),
          ),
        );

    onLog('crash_detected', {
      'gapStart': gapStartMs,
      'gapEnd': gapEndMs,
      'durationMs': gapEndMs - gapStartMs,
      'hadHeartbeat': lastHeartbeat != null,
    });

    // Clear the session marker so a second `detectAndClear` is a
    // no-op. Leave `last_clean_shutdown_at` alone — it's null on this
    // path and stays that way.
    await prefs.remove(_kSessionStartedAt);
    await prefs.remove(_kLastHeartbeatAt);

    return CrashDetectionResult(
      detected: true,
      gapStart: DateTime.fromMillisecondsSinceEpoch(gapStartMs),
      gapEnd: DateTime.fromMillisecondsSinceEpoch(gapEndMs),
    );
  }
}

DateTime _systemNow() => DateTime.now();
