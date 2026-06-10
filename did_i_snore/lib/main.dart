/// App entry point.
///
/// Phase 9 wires three startup tasks before the first frame:
///
/// 1. **Crash detection.** [CrashHeartbeat.detectAndClear] runs once
///    and inserts a `recording_gaps` row if the previous session
///    ended unexpectedly. The first launch in a fresh install is a
///    no-op.
/// 2. **Janitor cycle.** [runOnAppLaunch] runs the five-pass
///    [runAll] so a user opening the app to check last night sees a
///    clean state. Idempotent; a no-op when nothing needs cleaning.
/// 3. **Android WorkManager registration.** [registerAndroidWorker]
///    schedules the periodic janitor task. No-op on iOS — that
///    platform's triggers are app-launch (this file) and
///    recorder-stop (the recorder controller).
///
/// All three are awaited inside an `unawaited`-wrapped helper so the
/// UI mounts immediately; the user sees the consent / home screen
/// while these run in the background. They fire on the main isolate
/// (the WorkManager *registration* runs on the main isolate; the
/// task callback runs in a platform-spawned isolate via
/// `lib/janitor/scheduler.dart::callbackDispatcher`).
///
/// **DB ownership.** A single [ProviderContainer] is constructed in
/// [main] and passed both to the boot tasks (which read
/// [appDbProvider]) and to [UncontrolledProviderScope] for the App.
/// One `AppDb` instance for the process; Drift's "multiple
/// databases" race-condition warning cannot fire.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'janitor/scheduler.dart';
import 'recorder/crash_heartbeat.dart';
import 'ui/providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // One `ProviderContainer` for the whole process. Boot tasks read
  // `appDbProvider` from it before first paint; the App below mounts
  // the same container via `UncontrolledProviderScope`. Result: a
  // single `AppDb` is ever opened — Drift's "multiple databases"
  // race-condition warning cannot fire.
  final container = ProviderContainer();
  // Fire-and-forget the boot tasks. Awaiting would delay first paint
  // by the cost of one `df`, one DB open, and a janitor cycle —
  // typically <100 ms but unbounded if the disk is slow. The user
  // shouldn't stare at a blank screen for that.
  unawaited(_runBootTasks(container));
  runApp(UncontrolledProviderScope(container: container, child: const App()));
}

Future<void> _runBootTasks(ProviderContainer container) async {
  try {
    // Single DB for the whole process — same handle the home screen,
    // recorder controller, and Manage Storage screen will read.
    final db = container.read(appDbProvider);
    final docsDir = await getApplicationDocumentsDirectory();
    // Crash detection first — inserts the `recording_gaps` row before
    // the timeline's stream provider has a chance to surface "gap?
    // what gap?" on a fresh fetch.
    await CrashHeartbeat.detectAndClear(db);
    // Janitor cycle — five-pass cleanup. Idempotent.
    await runOnAppLaunch(db: db, docsDir: docsDir);
    // Android only — register the periodic worker. iOS triggers fire
    // from app-launch (this very call) + recorder-stop hook.
    await registerAndroidWorker();
    // No `db.close()` here — the container owns the handle and the
    // App is about to use it. The container disposes on test
    // tear-down (production scope is process-lifetime).
  } catch (_) {
    // Swallow — boot tasks should never crash the app. A real
    // failure becomes visible via `crash_detected` not firing or via
    // the janitor's idempotent retry on the next launch / cycle.
  }
}
