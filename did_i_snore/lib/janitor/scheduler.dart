/// Phase 9 janitor scheduling. Spec §9 lines 963–966.
///
/// Two entry points the rest of the app should ever care about:
///
/// - [registerAndroidWorker] — Android-only WorkManager registration.
///   Called once from `main.dart` after the binding is initialised; the
///   periodic task fires every `RetentionCfg.janitorIntervalHours` and
///   runs [runAll] from the platform-spawned isolate.
/// - [runJanitorOnce] — runs [runAll] synchronously (well, awaited)
///   once. Wired into:
///     1. App launch (Phase 9 `app.dart` boot — fires after the DB and
///        docs dir are ready, before the home screen mounts).
///     2. The iOS recorder-stop hook (`RecorderService.stop()` →
///        fire-and-forget; iOS has no reliable background scheduler
///        while the audio session was active, so the stop hook is the
///        nearest thing to a periodic).
///
/// One helper covers both iOS triggers because the work is identical
/// — running the five-pass [runAll]. The Android worker also calls the
/// same helper from its callback; the platform-specific surface is
/// just *when* it fires.
///
/// **WorkManager periodic minimum is 15 minutes.** The Android docs
/// floor periodic intervals at 15 minutes regardless of what we
/// request, and Doze can stretch it much further (sometimes to many
/// hours on idle phones). Because [runAll] is idempotent, the actual
/// cadence doesn't matter for correctness — only for "how stale can
/// the orphan files get." `RetentionCfg.janitorIntervalHours = 6` is
/// our nominal target; the OS will run it less often under battery
/// pressure and that's fine.
///
/// **iOS does NOT use BGTaskScheduler.** Spec §9 line 966 — the audio
/// session being active makes BG scheduling unreliable, and the
/// app-launch + recorder-stop pair gives us at least one run per
/// session. Acceptable for v1.
///
/// **Logger seam.** Same pattern as `EncodeQueue.onLog`: a
/// callback-typedef so the scheduler doesn't drag in the (still
/// Phase-11) debug-log facility. Production passes a `print` shim or
/// a no-op; tests inject a list-recorder.
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../config/constants.dart';
import '../data/db.dart';
import 'janitor.dart';

/// Logger seam — same shape as `EncodeQueue.EncodeLogger`. The
/// scheduler's only side-effects are filesystem (via [runAll]) and a
/// log line per cycle, so a callback is enough.
typedef SchedulerLogger = void Function(
    String event, Map<String, Object?> fields);

void _noopLogger(String event, Map<String, Object?> fields) {}

/// AppDb factory seam. The Android worker callback runs in a fresh
/// isolate that has no access to providers, so it constructs its own
/// AppDb — but tests need to inject an in-memory DB without going
/// through `getApplicationDocumentsDirectory()`. Same nullable-
/// injection pattern used elsewhere in this layer.
typedef AppDbFactory = AppDb Function();

/// Documents-dir factory seam. Mirror of [AppDbFactory] for the docs
/// directory.
typedef DocsDirFactory = Future<Directory> Function();

/// Default factory — opens the singleton AppDb. Production wires this;
/// tests override.
AppDb _defaultAppDbFactory() => AppDb();

/// Default factory — resolves the application documents directory via
/// `path_provider`. Used by [callbackDispatcher] inside the spawned
/// WorkManager isolate where the main-isolate's `docsDirProvider` is
/// out of scope. Tests don't reach this path; they call
/// [runJanitorOnce] directly with an injected `Directory`.
Future<Directory> _defaultDocsDirFactory() =>
    getApplicationDocumentsDirectory();

/// Runs the full janitor cycle once. Used by:
/// - The iOS launch hook (call from `main.dart`).
/// - The iOS recorder-stop hook (`RecorderService.stop()`).
/// - The Android WorkManager callback (forwarded by
///   [callbackDispatcher]).
///
/// Returns the [JanitorRunResult] so callers can log per-pass counts.
/// Errors propagate to the caller; the WorkManager dispatcher catches
/// them and reports a failed task so the OS can retry on the next
/// cycle.
Future<JanitorRunResult> runJanitorOnce({
  required AppDb db,
  required Directory docsDir,
  SchedulerLogger onLog = _noopLogger,
}) async {
  final result = await runAll(db, docsDir);
  onLog('janitor_cycle', {
    'hardDeleted': result.hardDeleted,
    'autoPruned': result.autoPruned,
    'pending': result.pending,
    'orphan': result.orphan,
    'missing': result.missing,
  });
  return result;
}

/// Hook the recorder-controller calls after a successful `stop()`. iOS
/// only — on Android the WorkManager periodic owns the cadence and we
/// don't want to double-run on every stop tap (which is the dominant
/// path on Android, since the FGS keeps the app alive).
///
/// Fire-and-forget on the caller side: the stop UX should not block
/// on a janitor cycle. Errors are swallowed (logged via [onLog] if
/// provided).
///
/// Idempotent — [runAll] is.
Future<void> runOnRecorderStop({
  required AppDb db,
  required Directory docsDir,
  SchedulerLogger onLog = _noopLogger,
}) async {
  if (!Platform.isIOS) {
    // Android: WorkManager handles cadence. Avoid double-runs on the
    // common "stop tap" path. The Android FGS lifetime + WorkManager
    // periodic together are the sufficient set.
    return;
  }
  try {
    await runJanitorOnce(db: db, docsDir: docsDir, onLog: onLog);
  } catch (e, st) {
    // Don't propagate — stop() must be smooth. Log so a future field
    // report can see the failure.
    onLog('janitor_recorder_stop_failed', {
      'error': e.toString(),
      'stack': st.toString(),
    });
  }
}

/// Hook the app calls on cold launch — runs the cycle once after the
/// DB + docs dir are ready, before the home screen mounts. Spec §9
/// line 966 (iOS) but safe to call on Android too: a startup cycle is
/// cheap (returns 0s on a clean state) and shortens the worst-case
/// "files orphaned at midnight, picked up at 6 AM" window when the
/// user opens the app to check last night.
///
/// Returns the [JanitorRunResult] — exposed so the boot path in
/// `app.dart` can log it once for diagnostic visibility.
Future<JanitorRunResult> runOnAppLaunch({
  required AppDb db,
  required Directory docsDir,
  SchedulerLogger onLog = _noopLogger,
}) {
  return runJanitorOnce(db: db, docsDir: docsDir, onLog: onLog);
}

/// Registers the Android WorkManager periodic. No-op on non-Android.
/// Idempotent — `Workmanager.registerPeriodicTask` replaces an
/// existing registration with the same `uniqueName` rather than
/// double-scheduling.
///
/// Call once from `main.dart` after `WidgetsFlutterBinding.ensureInitialized`.
/// On iOS this returns immediately; the iOS triggers are app-launch
/// + recorder-stop (see above).
///
/// **Why not also `BGTaskScheduler` on iOS:** the audio session being
/// active blocks BG-task scheduling reliably. Spec §9 line 966.
Future<void> registerAndroidWorker({
  SchedulerLogger onLog = _noopLogger,
}) async {
  if (!Platform.isAndroid) return;

  // Initialize WorkManager with our top-level dispatcher (must be a
  // top-level or static function with the `vm:entry-point` pragma so
  // the platform-spawned isolate can find it).
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    _janitorTaskName,
    _janitorTaskName,
    frequency: const Duration(
      hours: RetentionCfg.janitorIntervalHours,
    ),
    constraints: Constraints(
      networkType: NetworkType.notRequired,
      requiresBatteryNotLow: false,
      requiresCharging: false,
      requiresDeviceIdle: false,
      requiresStorageNotLow: false,
    ),
  );
  onLog('janitor_worker_registered', {
    'frequencyHours': RetentionCfg.janitorIntervalHours,
  });
}

/// WorkManager unique-name. Stable across releases so a re-registration
/// replaces the existing task instead of stacking up.
const String _janitorTaskName = 'did_i_snore.janitor';

/// Top-level dispatcher for WorkManager. Must be top-level + annotated
/// with `vm:entry-point` so the platform-spawned isolate can resolve
/// it via the Dart isolate registry.
///
/// On iOS this never runs (we don't register the worker there). On
/// Android, the platform spawns a fresh Dart isolate, calls this
/// function, and reads its return as the task result. We construct an
/// AppDb + docs dir locally because providers are scope-bound to the
/// main isolate and aren't reachable here.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != _janitorTaskName) {
      // Unknown task — fail so WorkManager doesn't loop on it. Should
      // be unreachable; we only register one task name.
      return false;
    }
    if (!Platform.isAndroid) return true;
    try {
      final db = _defaultAppDbFactory();
      final docsDir = await _defaultDocsDirFactory();
      await runJanitorOnce(db: db, docsDir: docsDir);
      await db.close();
      return true;
    } catch (_) {
      // Return false so WorkManager schedules a retry per its backoff
      // policy. Idempotent runAll means a retry is harmless.
      return false;
    }
  });
}
